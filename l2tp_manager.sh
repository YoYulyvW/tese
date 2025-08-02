#!/bin/bash
# 修正版智能L2TP/IPsec VPN管理脚本

CONFIG_DIR="/etc/l2tp_squid_proxy"
PORT_BASE=10000
MAX_INSTANCES=200

# 初始化配置目录
init_config_dir() {
    mkdir -p "${CONFIG_DIR}/instances"
    mkdir -p "/etc/xl2tpd/instances"
    mkdir -p "/etc/ipsec.d"
    mkdir -p "/etc/ppp"
    
    # 初始化必要文件
    touch "/etc/ppp/chap-secrets"
    touch "/etc/ipsec.secrets"
    chmod 600 "/etc/ppp/chap-secrets" "/etc/ipsec.secrets"
}

# 获取可用端口
get_available_port() {
    for (( port=PORT_BASE; port<PORT_BASE+MAX_INSTANCES; port++ )); do
        if ! grep -q -r "port = $port" "${CONFIG_DIR}/instances" 2>/dev/null; then
            echo $port
            return
        fi
    done
    echo ""
}

# 从Squid配置获取IP对
get_vpn_ip_pair() {
    local squid_conf="/etc/squid/squid.conf"
    [ ! -f "$squid_conf" ] && { echo ""; return; }

    declare -A ip_pairs
    while read -r line; do
        if [[ $line =~ acl\ ip_([0-9]+)\ myip\ ([0-9.]+) ]]; then
            local index=${BASH_REMATCH[1]}
            local v4ip=${BASH_REMATCH[2]}
            local v6ip_line=$(grep -A1 "acl ip_${index}" "$squid_conf" | tail -1)
            if [[ $v6ip_line =~ tcp_outgoing_address\ ([^[:space:]]+) ]]; then
                ip_pairs["$v4ip"]=${BASH_REMATCH[1]}
            fi
        fi
    done < "$squid_conf"

    # 找出未被使用的IP
    for v4ip in "${!ip_pairs[@]}"; do
        if ! grep -q -r "v4ip = $v4ip" "${CONFIG_DIR}/instances" 2>/dev/null; then
            echo "$v4ip ${ip_pairs[$v4ip]}"
            return
        fi
    done

    echo ""
}

# 创建VPN实例
create_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ -f "$config_file" ] && { echo "实例 ${instance_id} 已存在"; return 1; }

    local port=$(get_available_port)
    [ -z "$port" ] && { echo "错误: 无可用端口"; return 1; }

    local ip_pair=$(get_vpn_ip_pair)
    [ -z "$ip_pair" ] && { echo "错误: 无可用IP对"; return 1; }

    read -r v4ip v6ip <<< "$ip_pair"
    local psk=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16)
    local password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12)
    local username="vpnuser_${instance_id}"

    # 生成实例配置
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

    # 应用配置
    apply_instance_config "$instance_id"
    
    echo "实例创建成功:"
    echo "ID: ${instance_id}"
    echo "L2TP端口: ${port}"
    echo "客户端IPv4: ${v4ip}"
    echo "绑定IPv6: ${v6ip}"
    echo "PSK: ${psk}"
    echo "用户名: ${username}"
    echo "密码: ${password}"
}

# 应用实例配置
apply_instance_config() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && { echo "配置不存在"; return 1; }

    # 读取配置
    local port=$(awk -F= '/^port/ {print $2}' "$config_file" | tr -d ' ')
    local v4ip=$(awk -F= '/^v4ip/ {print $2}' "$config_file" | tr -d ' ')
    local psk=$(awk -F= '/^psk/ {print $2}' "$config_file" | tr -d ' ')
    local username=$(awk -F= '/^username/ {print $2}' "$config_file" | tr -d ' ')
    local password=$(awk -F= '/^password/ {print $2}' "$config_file" | tr -d ' ')

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
}

# 显示实例列表
list_instances() {
    echo "已创建实例:"
    for conf in "${CONFIG_DIR}"/instances/*.conf; do
        [ -f "$conf" ] || continue
        local id=$(basename "$conf" .conf)
        local status=$(awk -F= '/^status/ {print $2}' "$conf" | tr -d ' ')
        local created=$(awk -F= '/^created/ {print $2}' "$conf" | tr -d ' ')
        printf "ID: %-5s 状态: %-6s 创建时间: %s\n" "$id" "$status" "$created"
    done
}

# 删除实例
delete_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && { echo "实例不存在"; return 1; }

    # 清理配置
    rm -f "/etc/ipsec.d/${instance_id}.conf"
    rm -f "/etc/xl2tpd/instances/${instance_id}.conf"
    rm -f "/etc/ppp/options.xl2tpd.${instance_id}"
    
    # 从认证文件删除
    local username=$(awk -F= '/^username/ {print $2}' "$config_file" | tr -d ' ')
    sed -i "/^${username} /d" "/etc/ppp/chap-secrets"
    sed -i "/${instance_id}/d" "/etc/ipsec.secrets"
    
    # 删除实例配置
    rm -f "$config_file"
    echo "实例 ${instance_id} 已删除"
}

# 显示实例详情
show_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && { echo "实例不存在"; return 1; }
    
    echo "实例 ${instance_id} 详情:"
    grep -v '^#' "$config_file" | sed 's/^/  /'
}

# 主菜单
show_menu() {
    clear
    echo "智能L2TP/Squid代理管理系统"
    echo "1. 创建新VPN实例"
    echo "2. 列出所有实例"
    echo "3. 删除实例"
    echo "4. 查看实例详情"
    echo "5. 退出"
}

# 主程序
init_config_dir

while true; do
    show_menu
    read -p "请选择操作: " choice
    
    case $choice in
        1)
            read -p "输入实例ID: " instance_id
            create_instance "$instance_id"
            ;;
        2)
            list_instances
            ;;
        3)
            read -p "输入要删除的实例ID: " instance_id
            delete_instance "$instance_id"
            ;;
        4)
            read -p "输入要查看的实例ID: " instance_id
            show_instance "$instance_id"
            ;;
        5)
            exit 0
            ;;
        *)
            echo "无效选择"
            ;;
    esac
    
    read -p "按Enter继续..."
done
