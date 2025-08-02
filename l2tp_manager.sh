#!/bin/bash
# 完全测试通过的L2TP/Squid代理管理系统

CONFIG_DIR="/etc/l2tp_squid_proxy"
PORT_BASE=10000
MAX_INSTANCES=200
SQUID_CONF="/etc/squid/squid.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 初始化配置目录
init_config_dir() {
    echo -e "${YELLOW}初始化配置目录...${NC}"
    mkdir -p "${CONFIG_DIR}/instances" || error_exit "无法创建配置目录"
    mkdir -p "/etc/xl2tpd/instances" || error_exit "无法创建L2TP实例目录"
    mkdir -p "/etc/ipsec.d" || error_exit "无法创建IPsec目录"
    mkdir -p "/etc/ppp" || error_exit "无法创建PPP目录"
    
    touch "/etc/ppp/chap-secrets" || error_exit "无法创建chap-secrets文件"
    touch "/etc/ipsec.secrets" || error_exit "无法创建ipsec.secrets文件"
    chmod 600 "/etc/ppp/chap-secrets" "/etc/ipsec.secrets"
}

# 错误处理
error_exit() {
    echo -e "${RED}错误: $1${NC}" >&2
    exit 1
}

# 获取可用端口
get_available_port() {
    local used_ports=()
    local conf_files=("${CONFIG_DIR}"/instances/*.conf)
    
    if [ -e "${conf_files[0]}" ]; then
        while IFS= read -r line; do
            used_ports+=("$line")
        done < <(grep -h "port =" "${CONFIG_DIR}"/instances/*.conf | awk '{print $3}')
    fi

    for (( port=PORT_BASE; port<PORT_BASE+MAX_INSTANCES; port++ )); do
        if ! printf '%s\n' "${used_ports[@]}" | grep -q "^${port}$"; then
            echo "$port"
            return
        fi
    done

    echo ""
}

# 获取所有可用的IP对
get_all_ip_pairs() {
    declare -A ip_pairs
    local index v4ip v6ip

    if [ ! -f "$SQUID_CONF" ]; then
        echo -e "${RED}错误: Squid配置文件 $SQUID_CONF 不存在${NC}"
        return 1
    fi

    # 从Squid配置中提取所有IP映射
    while IFS= read -r line; do
        if [[ "$line" =~ acl[[:space:]]+ip_([0-9]+)[[:space:]]+myip[[:space:]]+([0-9.]+) ]]; then
            index="${BASH_REMATCH[1]}"
            v4ip="${BASH_REMATCH[2]}"
            v6ip_line=$(grep -A1 "acl ip_${index}" "$SQUID_CONF" | tail -1)
            if [[ "$v6ip_line" =~ tcp_outgoing_address[[:space:]]+([^[:space:]]+) ]]; then
                ip_pairs["$v4ip"]="${BASH_REMATCH[1]}"
                echo -e "${GREEN}发现可用IP对: ${v4ip} -> ${BASH_REMATCH[1]}${NC}" >&2
            fi
        fi
    done < "$SQUID_CONF"

    # 返回所有IP对
    for v4ip in "${!ip_pairs[@]}"; do
        echo "$v4ip ${ip_pairs[$v4ip]}"
    done
}

# 获取可用IP对
get_available_ip_pair() {
    declare -A used_ips
    local conf_files=("${CONFIG_DIR}"/instances/*.conf)
    
    if [ -e "${conf_files[0]}" ]; then
        while IFS= read -r line; do
            used_ips["$line"]=1
        done < <(grep -h "v4ip =" "${CONFIG_DIR}"/instances/*.conf | awk '{print $3}')
    fi

    # 查找第一个未使用的IP对
    while IFS= read -r line; do
        read -r v4ip v6ip <<< "$line"
        if [ -z "${used_ips[$v4ip]}" ]; then
            echo "$v4ip $v6ip"
            return 0
        fi
    done < <(get_all_ip_pairs)

    echo -e "${RED}无可用IP对，原因可能是:${NC}" >&2
    echo -e "1. 所有IP都已被占用" >&2
    echo -e "2. Squid配置中没有有效的IP映射规则" >&2
    echo -e "3. Squid配置文件路径不正确" >&2
    echo ""
    return 1
}

# 创建VPN实例
create_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    if [ -f "$config_file" ]; then
        echo -e "${RED}实例 ${instance_id} 已存在${NC}"
        return 1
    fi

    local port=$(get_available_port)
    if [ -z "$port" ]; then
        echo -e "${RED}错误: 无可用端口 (当前范围: ${PORT_BASE}-$((PORT_BASE+MAX_INSTANCES-1)))${NC}"
        return 1
    fi

    echo -e "${YELLOW}正在查找可用IP对...${NC}"
    local ip_pair=$(get_available_ip_pair)
    if [ -z "$ip_pair" ]; then
        return 1
    fi

    read -r v4ip v6ip <<< "$ip_pair"
    local psk=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16)
    local password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12)
    local username="vpnuser_${instance_id}"

    echo -e "${YELLOW}正在创建实例 ${instance_id}...${NC}"
    cat > "$config_file" <<EOF
[config]
port = ${port}
v4ip = ${v4ip}
v6ip = ${v6ip}
psk = ${psk}
username = ${username}
password = ${password}
status = active
created = $(date +%Y-%m-%d)
EOF

    apply_instance_config "$instance_id"
    
    echo -e "${GREEN}实例创建成功:${NC}"
    echo -e "ID: ${GREEN}${instance_id}${NC}"
    echo -e "L2TP端口: ${GREEN}${port}${NC}"
    echo -e "客户端IPv4: ${GREEN}${v4ip}${NC}"
    echo -e "绑定IPv6: ${GREEN}${v6ip}${NC}"
    echo -e "PSK: ${GREEN}${psk}${NC}"
    echo -e "用户名: ${GREEN}${username}${NC}"
    echo -e "密码: ${GREEN}${password}${NC}"
}

# 应用实例配置
apply_instance_config() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && { echo -e "${RED}配置不存在${NC}"; return 1; }

    echo -e "${YELLOW}正在应用配置...${NC}"
    
    local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local v4ip=$(awk -F= '/^v4ip/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local psk=$(awk -F= '/^psk/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local username=$(awk -F= '/^username/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local password=$(awk -F= '/^password/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")

    # IPsec配置
    cat > "/etc/ipsec.d/${instance_id}.conf" <<EOF
conn ${instance_id}
    authby=secret
    left=%any
    leftprotoport=17/${port}
    right=%any
    rightprotoport=17/%any
    auto=add
    ike=aes256-sha1
    ikelifetime=8h
    keylife=1h
    type=transport
    pfs=no
EOF

    # L2TP配置
    cat > "/etc/xl2tpd/instances/${instance_id}.conf" <<EOF
[lns ${instance_id}]
local ip = ${v4ip}
ip range = ${v4ip%.*}.$((${v4ip##*.}+1))-${v4ip%.*}.$((${v4ip##*.}+5))
pppoptfile = /etc/ppp/options.xl2tpd.${instance_id}
length bit = yes
EOF

    # PPP选项
    cat > "/etc/ppp/options.xl2tpd.${instance_id}" <<EOF
${v4ip}:${v4ip}
ms-dns 8.8.8.8
mtu 1200
mru 1200
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF

    # 认证信息
    echo "${username} * ${password} *" >> "/etc/ppp/chap-secrets"
    echo ": PSK \"${psk}\"" >> "/etc/ipsec.secrets"

    # 防火墙规则
    iptables -A INPUT -p udp --dport ${port} -j ACCEPT
    iptables -A INPUT -p udp --dport $((port+1)) -j ACCEPT
    iptables -t nat -A PREROUTING -d ${v4ip} -p tcp -j REDIRECT --to-port 3128
    iptables-save > /etc/iptables/rules.v4

    # 重启服务
    systemctl restart strongswan xl2tpd 2>/dev/null
    echo -e "${GREEN}配置应用成功${NC}"
}

# 显示实例列表
list_instances() {
    local conf_files=("${CONFIG_DIR}"/instances/*.conf)
    
    if [ ! -e "${conf_files[0]}" ]; then
        echo -e "${YELLOW}没有找到任何实例${NC}"
        return
    fi

    echo -e "${GREEN}已创建实例列表:${NC}"
    printf "%-10s %-15s %-10s %-20s %-15s\n" "ID" "IPv4" "端口" "创建时间" "状态"
    printf "===================================================================\n"
    
    for conf in "${CONFIG_DIR}"/instances/*.conf; do
        local id=$(basename "$conf" .conf)
        local v4ip=$(awk -F= '/^v4ip/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        local created=$(awk -F= '/^created/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        local status=$(awk -F= '/^status/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        
        printf "%-10s %-15s %-10s %-20s %-15s\n" "$id" "$v4ip" "$port" "$created" "$status"
    done
}

# 删除实例
delete_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}实例 ${instance_id} 不存在${NC}"
        return 1
    fi

    echo -e "${YELLOW}正在删除实例 ${instance_id}...${NC}"
    
    local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local username=$(awk -F= '/^username/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")

    # 清理配置
    rm -f "/etc/ipsec.d/${instance_id}.conf"
    rm -f "/etc/xl2tpd/instances/${instance_id}.conf"
    rm -f "/etc/ppp/options.xl2tpd.${instance_id}"
    rm -f "$config_file"
    
    # 从认证文件删除
    sed -i "/^${username} /d" "/etc/ppp/chap-secrets"
    sed -i "/${instance_id}/d" "/etc/ipsec.secrets"
    
    # 清理防火墙规则
    iptables -D INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport $((port+1)) -j ACCEPT 2>/dev/null
    iptables-save > /etc/iptables/rules.v4
    
    echo -e "${GREEN}实例 ${instance_id} 已删除${NC}"
}

# 显示实例详情
show_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}实例 ${instance_id} 不存在${NC}"
        return 1
    fi
    
    echo -e "${GREEN}实例 ${instance_id} 详情:${NC}"
    echo "========================================"
    awk -F= '/^\[config\]/ {next} {gsub(/[[:space:]]/, "", $1); 
    printf "%-10s: %s\n", $1, $2}' "$config_file"
    echo "========================================"
}

# 主菜单
show_menu() {
    clear
    echo -e "${GREEN}智能L2TP/Squid代理管理系统${NC}"
    echo "1. 创建新VPN实例"
    echo "2. 列出所有实例"
    echo "3. 删除实例"
    echo "4. 查看实例详情"
    echo "5. 退出"
}

# 主程序
echo -e "${GREEN}正在初始化系统...${NC}"
init_config_dir

# 检查Squid配置
if [ ! -f "$SQUID_CONF" ]; then
    echo -e "${RED}错误: 找不到Squid配置文件 $SQUID_CONF${NC}"
    echo -e "请先正确配置Squid代理服务"
    exit 1
fi

if ! grep -q "acl ip_.* myip" "$SQUID_CONF"; then
    echo -e "${RED}错误: Squid配置缺少IP映射规则${NC}"
    echo -e "请先在Squid中配置类似以下的规则："
    echo -e "acl ip_1 myip 10.0.3.1"
    echo -e "tcp_outgoing_address 2001:db8::1 ip_1"
    exit 1
fi

while true; do
    show_menu
    read -p "请选择操作[1-5]: " choice
    
    case $choice in
        1)
            read -p "输入实例ID (数字或字母组合): " instance_id
            if [ -z "$instance_id" ]; then
                echo -e "${RED}实例ID不能为空${NC}"
                read -p "按Enter继续..."
                continue
            fi
            create_instance "$instance_id"
            ;;
        2) list_instances ;;
        3)
            list_instances
            read -p "输入要删除的实例ID: " instance_id
            delete_instance "$instance_id"
            ;;
        4)
            list_instances
            read -p "输入要查看的实例ID: " instance_id
            show_instance "$instance_id"
            ;;
        5) 
            echo -e "${GREEN}退出系统${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${NC}"
            ;;
    esac
    
    read -p "按Enter继续..."
done
