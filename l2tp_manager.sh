#!/bin/bash
# 智能L2TP/IPsec VPN管理脚本 (与Squid IPv6代理深度集成)

# 全局配置
CONFIG_DIR="/etc/l2tp_squid_proxy"
PORT_BASE=10000
MAX_INSTANCES=200  # 与Squid管理的IP数量一致

# 检查root权限
[ "$(id -u)" != "0" ] && { echo "错误: 需要root权限"; exit 1; }

# 初始化环境
init_env() {
    mkdir -p $CONFIG_DIR/instances
    apt-get update
    apt-get install -y xl2tpd strongswan net-tools iptables-persistent jq
    
    # 备份原始配置
    cp /etc/ipsec.conf ${CONFIG_DIR}/ipsec.conf.bak 2>/dev/null
    cp /etc/xl2tpd/xl2tpd.conf ${CONFIG_DIR}/xl2tpd.conf.bak 2>/dev/null
}

# 自动端口分配
get_available_port() {
    local used_ports=$(grep -hr "port =" ${CONFIG_DIR}/instances/*.conf | awk '{print $3}' | sort -n)
    for (( port=PORT_BASE; port<PORT_BASE+MAX_INSTANCES; port++ )); do
        if ! echo "$used_ports" | grep -q "^${port}$"; then
            echo $port
            return
        fi
    done
    echo ""
}

# 自动IP分配 (与Squid配置同步)
get_vpn_ip_pair() {
    # 从Squid配置提取可用的IP对
    local squid_conf="/etc/squid/squid.conf"
    local used_ips=$(grep -Po 'tcp_outgoing_address \K[0-9.]+' ${CONFIG_DIR}/instances/*.conf 2>/dev/null)
    
    # 解析Squid配置中的IP映射关系
    declare -A ip_pairs
    while read -r line; do
        if [[ $line =~ acl\ ip_([0-9]+)\ myip\ ([0-9.]+) ]]; then
            local index=${BASH_REMATCH[1]}
            local v4ip=${BASH_REMATCH[2]}
            local v6ip=$(grep -m1 -A1 "acl ip_${index}" $squid_conf | grep -Po 'tcp_outgoing_address \K[^ ]+')
            ip_pairs["$v4ip"]=$v6ip
        fi
    done < "$squid_conf"
    
    # 找出未被VPN使用的IP
    for v4ip in "${!ip_pairs[@]}"; do
        if ! grep -q "$v4ip" <<< "$used_ips"; then
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
    
    # 获取可用资源
    local port=$(get_available_port)
    local ip_pair=$(get_vpn_ip_pair)
    
    if [ -z "$port" ] || [ -z "$ip_pair" ]; then
        echo "错误: 无可用资源(端口或IP)"
        exit 1
    fi
    
    read -r v4ip v6ip <<< "$ip_pair"
    local psk=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16)
    local password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12)
    
    # 生成配置
    cat > $config_file <<EOF
# 实例ID: $instance_id
port = $port
v4ip = $v4ip
v6ip = $v6ip
psk = $psk
username = vpnuser_${instance_id}
password = $password
status = active
created = $(date +%Y-%m-%d)
EOF
    
    # 应用配置
    apply_instance_config $instance_id
    echo "已创建实例 ${instance_id}:"
    echo "L2TP端口: ${port}"
    echo "客户端IPv4: ${v4ip}"
    echo "绑定IPv6: ${v6ip}"
    echo "PSK: ${psk}"
    echo "用户名: vpnuser_${instance_id}"
    echo "密码: ${password}"
}

# 应用实例配置
apply_instance_config() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    source $config_file
    
    # IPsec配置
    cat > /etc/ipsec.d/${instance_id}.conf <<EOF
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
    mkdir -p /etc/xl2tpd/instances/
    cat > /etc/xl2tpd/instances/${instance_id}.conf <<EOF
[lns ${instance_id}]
local ip = ${v4ip}
ip range = ${v4ip%.*}.$((${v4ip##*.}+1))-${v4ip%.*}.$((${v4ip##*.}+5))
pppoptfile = /etc/ppp/options.xl2tpd.${instance_id}
length bit = yes
EOF
    
    # PPP选项
    cat > /etc/ppp/options.xl2tpd.${instance_id} <<EOF
${v4ip}:${v4ip}
ms-dns 8.8.8.8
mtu 1200
mru 1200
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF
    
    # 认证信息
    echo "vpnuser_${instance_id} * ${password} *" >> /etc/ppp/chap-secrets
    echo ": PSK \"${psk}\"" >> /etc/ipsec.secrets
    
    # 防火墙规则
    iptables -A INPUT -p udp --dport ${port} -j ACCEPT
    iptables -A INPUT -p udp --dport $((port+1)) -j ACCEPT
    iptables -t nat -A PREROUTING -d ${v4ip} -p tcp -j REDIRECT --to-port 3128
    
    # 保存配置
    iptables-save > /etc/iptables/rules.v4
}

# 管理菜单
show_menu() {
    echo "智能L2TP/Squid代理管理系统"
    echo "1. 创建新VPN实例"
    echo "2. 列出所有实例"
    echo "3. 删除实例"
    echo "4. 查看实例详情"
    echo "5. 退出"
    
    read -p "请选择操作: " choice
    case $choice in
        1) 
            read -p "输入实例ID: " instance_id
            create_instance $instance_id
            ;;
        2) 
            ls ${CONFIG_DIR}/instances/ | sed 's/.conf//'
            ;;
        3)
            read -p "输入要删除的实例ID: " instance_id
            rm -f ${CONFIG_DIR}/instances/${instance_id}.conf
            echo "已删除实例 ${instance_id}"
            ;;
        4)
            read -p "输入实例ID: " instance_id
            cat ${CONFIG_DIR}/instances/${instance_id}.conf 2>/dev/null || echo "实例不存在"
            ;;
        5)
            exit 0
            ;;
        *)
            echo "无效选择"
            ;;
    esac
}

# 主程序
init_env
while true; do
    show_menu
    read -p "按Enter继续..."
done
