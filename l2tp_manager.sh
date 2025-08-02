#!/bin/bash
# 完全修正版智能L2TP/Squid代理管理系统

CONFIG_DIR="/etc/l2tp_squid_proxy"
PORT_BASE=10000
MAX_INSTANCES=200
SQUID_CONF="/etc/squid/squid.conf"

# 初始化配置目录
init_config_dir() {
    mkdir -p "${CONFIG_DIR}/instances" || { echo "无法创建配置目录"; exit 1; }
    mkdir -p "/etc/xl2tpd/instances" || { echo "无法创建L2TP实例目录"; exit 1; }
    mkdir -p "/etc/ipsec.d" || { echo "无法创建IPsec目录"; exit 1; }
    mkdir -p "/etc/ppp" || { echo "无法创建PPP目录"; exit 1; }
    
    touch "/etc/ppp/chap-secrets" || { echo "无法创建chap-secrets文件"; exit 1; }
    touch "/etc/ipsec.secrets" || { echo "无法创建ipsec.secrets文件"; exit 1; }
    chmod 600 "/etc/ppp/chap-secrets" "/etc/ipsec.secrets"
}

# 获取所有可用的IP对
get_all_ip_pairs() {
    declare -A ip_pairs
    local index v4ip v6ip

    # 从Squid配置中提取所有IP映射
    while read -r line; do
        if [[ $line =~ acl\ ip_([0-9]+)\ myip\ ([0-9.]+) ]]; then
            index=${BASH_REMATCH[1]}
            v4ip=${BASH_REMATCH[2]}
            v6ip_line=$(grep -A1 "acl ip_${index}" "$SQUID_CONF" | tail -1)
            if [[ $v6ip_line =~ tcp_outgoing_address\ ([^[:space:]]+) ]]; then
                ip_pairs["$v4ip"]=${BASH_REMATCH[1]}
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
    # 获取所有已使用的IPv4
    declare -A used_ips
    for conf in "${CONFIG_DIR}"/instances/*.conf 2>/dev/null; do
        [ -f "$conf" ] && {
            local used_ip=$(awk -F= '/^v4ip/ {gsub(/ /,"",$2); print $2}' "$conf")
            used_ips["$used_ip"]=1
        }
    done

    # 查找第一个未使用的IP对
    while read -r line; do
        read -r v4ip v6ip <<< "$line"
        [ -z "${used_ips[$v4ip]}" ] && {
            echo "$v4ip $v6ip"
            return 0
        }
    done < <(get_all_ip_pairs)

    echo ""
    return 1
}

# 创建VPN实例
create_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ -f "$config_file" ] && { echo "实例 ${instance_id} 已存在"; return 1; }

    local port=$(get_available_port)
    [ -z "$port" ] && { echo "错误: 无可用端口"; return 1; }

    local ip_pair=$(get_available_ip_pair)
    if [ -z "$ip_pair" ]; then
        echo "错误: 无可用IP对，请检查："
        echo "1. Squid配置是否存在 ($SQUID_CONF)"
        echo "2. Squid是否配置了足够的IP映射"
        echo "3. 是否所有IP都已被占用"
        return 1
    fi

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

# 其余函数保持不变...

# 主程序
init_config_dir

# 检查Squid配置
[ ! -f "$SQUID_CONF" ] && {
    echo "错误: 找不到Squid配置文件 $SQUID_CONF"
    echo "请先正确配置Squid代理服务"
    exit 1
}

while true; do
    show_menu
    read -p "请选择操作: " choice
    
    case $choice in
        1)
            read -p "输入实例ID (数字或字母组合): " instance_id
            [ -z "$instance_id" ] && { echo "实例ID不能为空"; continue; }
            create_instance "$instance_id"
            ;;
        2) list_instances ;;
        3)
            read -p "输入要删除的实例ID: " instance_id
            delete_instance "$instance_id"
            ;;
        4)
            read -p "输入要查看的实例ID: " instance_id
            show_instance "$instance_id"
            ;;
        5) exit 0 ;;
        *) echo "无效选择" ;;
    esac
    
    read -p "按Enter继续..."
done
