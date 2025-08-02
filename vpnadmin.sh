#!/bin/bash
# OpenVPN用户管理脚本 (用户名/密码认证)
# 支持: 创建用户 | 删除用户 | 修改密码 | 查看状态
# 自动从Squid配置读取代理IP池
# 确保每个用户流量通过独立代理IP处理

CONFIG_DIR="/etc/openvpn"
USER_DB="$CONFIG_DIR/user-pass.db"
SQUID_CONF="/etc/squid/squid.conf"
VPN_NET="10.8.0.0/24"
SQUID_PORT=3128
CCD_DIR="$CONFIG_DIR/ccd"
USER_IP_MAP="$CONFIG_DIR/user-ip.map"

# 检查root权限
check_root() {
    [ "$EUID" -ne 0 ] && echo "错误: 需要root权限运行此脚本" && exit 1
}

# 初始化目录和文件
init_dirs() {
    mkdir -p $CCD_DIR
    touch $USER_IP_MAP
    chmod 600 $USER_DB $USER_IP_MAP
}

# 从Squid配置提取代理IP池
get_proxy_ips() {
    # 提取所有http_port配置
    local ports=($(grep -E '^http_port' $SQUID_CONF | awk '{print $2}'))
    
    # 提取IP地址
    local ips=()
    for port in "${ports[@]}"; do
        # 处理IP:PORT格式
        if [[ $port == *:* ]]; then
            ips+=("${port%:*}")
        # 处理纯端口格式
        elif [[ $port =~ ^[0-9]+$ ]]; then
            ips+=("0.0.0.0")
        fi
    done
    
    # 处理0.0.0.0情况（获取所有eth0 IP）
    if [[ " ${ips[@]} " =~ " 0.0.0.0 " ]]; then
        ips=($(ip -o -4 addr show dev eth0 | awk '{split($4, a, "/"); print a[1]}' | grep -v '^10\.8\.'))
    fi
    
    # 去重并返回
    printf "%s\n" "${ips[@]}" | sort -u
}

# 获取下一个可用VPN IP
get_next_vpn_ip() {
    local base_ip="10.8.0"
    local last_ip=$(grep -E "$base_ip\.[0-9]+$" $USER_IP_MAP | cut -d' ' -f2 | sort -t. -k4 -n | tail -1)
    
    if [ -z "$last_ip" ]; then
        echo "${base_ip}.2"
    else
        local last_octet=${last_ip##*.}
        echo "${base_ip}.$((last_octet + 1))"
    fi
}

# 初始化OpenVPN服务
init_vpn() {
    echo "正在初始化OpenVPN服务..."
    
    # 安装必要软件
    apt update >/dev/null 2>&1
    apt install -y openvpn iptables-persistent >/dev/null 2>&1

    # 创建基本配置
    cat > $CONFIG_DIR/server.conf <<EOF
port 1194
proto udp
dev tun
server 10.8.0.0 255.255.255.0
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
verb 3
explicit-exit-notify 1
client-to-client
duplicate-cn
auth-user-pass-verify $CONFIG_DIR/auth.sh via-file
script-security 3
username-as-common-name
tmp-dir /dev/shm
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
client-config-dir $CCD_DIR
EOF

    # 创建认证脚本
    cat > $CONFIG_DIR/auth.sh <<'EOF'
#!/bin/bash
[ "$script_type" != "user-pass-verify" ] && exit 1
USER_DB="/etc/openvpn/user-pass.db"
[ ! -f "$USER_DB" ] && exit 1
while read -r line; do
    if [ "$(echo "$line" | cut -d' ' -f1)" = "$1" ] && \
       [ "$(echo "$line" | cut -d' ' -f2)" = "$2" ]; then
        exit 0
    fi
done < <(awk '!a[$1]++' "$USER_DB")
exit 1
EOF
    chmod +x $CONFIG_DIR/auth.sh

    # 创建空用户数据库
    touch $USER_DB
    chmod 600 $USER_DB

    # 配置IP转发和防火墙
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    sysctl -p >/dev/null

    # 配置透明代理规则
    iptables -t nat -A POSTROUTING -s $VPN_NET -o eth0 -j MASQUERADE
    iptables -t nat -A PREROUTING -s $VPN_NET -p tcp --dport 80 -j REDIRECT --to-port $SQUID_PORT
    iptables -t nat -A PREROUTING -s $VPN_NET -p tcp --dport 443 -j REDIRECT --to-port $SQUID_PORT
    iptables-save > /etc/iptables/rules.v4

    systemctl enable --now openvpn@server >/dev/null 2>&1
    echo "OpenVPN服务已初始化完成!"
    echo "代理IP池: ($(get_proxy_ips | tr '\n' ' '))"
}

# 添加/修改VPN用户
manage_user() {
    local action=$1 username=$2 password=$3
    
    # 密码生成逻辑
    if [ -z "$password" ]; then
        password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
        echo "已生成随机密码: $password"
    fi

    # 删除旧记录
    sed -i "/^$username /d" $USER_DB
    
    if [ "$action" = "add" ]; then
        # 添加新用户
        echo "$username $password" >> $USER_DB
        
        # 分配代理IP (轮询)
        local proxy_ips=($(get_proxy_ips))
        local proxy_count=${#proxy_ips[@]}
        [ $proxy_count -eq 0 ] && echo "警告: 未找到代理IP" && return 1
        
        # 分配VPN IP
        local vpn_ip=$(get_next_vpn_ip)
        
        # 获取当前用户索引
        local user_count=$(grep -c . $USER_DB)
        local user_index=$(( (user_count - 1) % proxy_count ))
        local assigned_ip=${proxy_ips[$user_index]}
        
        # 创建CCD配置文件
        cat > $CCD_DIR/$username <<EOF
ifconfig-push $vpn_ip 255.255.255.0
push "route 0.0.0.0 0.0.0.0"
EOF
        
        # 添加SNAT规则
        iptables -t nat -A POSTROUTING -s $vpn_ip -o eth0 -j SNAT --to-source $assigned_ip
        
        # 记录用户IP映射
        echo "$username $vpn_ip $assigned_ip" >> $USER_IP_MAP
        
        echo "用户 $username 已创建"
        echo "VPN分配IP: $vpn_ip"
        echo "代理出口IP: $assigned_ip"
        echo "用户名: $username"
        echo "密码: $password"
    elif [ "$action" = "del" ]; then
        # 获取用户IP映射
        local user_info=$(grep "^$username " $USER_IP_MAP)
        if [ -n "$user_info" ]; then
            local vpn_ip=$(echo $user_info | awk '{print $2}')
            local proxy_ip=$(echo $user_info | awk '{print $3}')
            
            # 删除SNAT规则
            iptables -t nat -D POSTROUTING -s $vpn_ip -o eth0 -j SNAT --to-source $proxy_ip 2>/dev/null
            
            # 删除CCD文件
            rm -f $CCD_DIR/$username
            
            # 删除映射记录
            sed -i "/^$username /d" $USER_IP_MAP
        fi
        
        echo "用户 $username 已删除"
    fi
    
    # 保存防火墙规则
    iptables-save > /etc/iptables/rules.v4
}

# 显示VPN状态
show_status() {
    # 服务状态
    systemctl is-active openvpn@server >/dev/null && \
        echo -e "OpenVPN状态: \e[32m运行中\e[0m" || \
        echo -e "OpenVPN状态: \e[31m未运行\e[0m"
    
    # 用户连接状态
    echo -e "\n当前连接用户:"
    if [ -f "/etc/openvpn/server/openvpn-status.log" ]; then
        awk '/^CLIENT_LIST/{printf "%-15s %-20s %-15s %-15s\n", $2, $3, $4, "在线"}' /etc/openvpn/server/openvpn-status.log | sort
    else
        echo "  无在线用户"
    fi
    
    # 用户列表
    echo -e "\n已创建用户:"
    if [ -s $USER_IP_MAP ]; then
        while read -r line; do
            username=$(echo $line | awk '{print $1}')
            vpn_ip=$(echo $line | awk '{print $2}')
            proxy_ip=$(echo $line | awk '{print $3}')
            printf "%-15s %-15s %-15s\n" $username $vpn_ip $proxy_ip
        done < $USER_IP_MAP | sort
    else
        echo "  无注册用户"
    fi
    
    # 代理IP池信息
    echo -e "\n代理IP池 (来自Squid配置):"
    local proxy_ips=($(get_proxy_ips))
    if [ ${#proxy_ips[@]} -gt 0 ]; then
        for ip in "${proxy_ips[@]}"; do
            local user_count=$(grep -c "$ip$" $USER_IP_MAP)
            echo "- $ip : $user_count 用户使用"
        done
    else
        echo "  未找到有效代理IP"
    fi
    
    # 流量统计
    echo -e "\nVPN流量统计:"
    iptables -nvL -t nat | grep -E "SNAT|REDIRECT" | awk '
        /SNAT/ {printf "%-15s %-15s %-10s %-10s\n", $11, $9, $1, $2}
        /REDIRECT/ {printf "%-15s %-15s %-10s %-10s\n", "HTTP/HTTPS", "所有用户", $1, $2}
    '
}

# 主程序
check_root
init_dirs

case "$1" in
    init)
        init_vpn
        ;;
    add)
        if [ -z "$2" ]; then
            echo "用法: $0 add <用户名> [密码]"
            exit 1
        fi
        manage_user "add" "$2" "$3"
        ;;
    del)
        if [ -z "$2" ]; then
            echo "用法: $0 del <用户名>"
            exit 1
        fi
        manage_user "del" "$2"
        ;;
    passwd)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "用法: $0 passwd <用户名> <新密码>"
            exit 1
        fi
        # 修改密码但不改变IP分配
        sed -i "/^$2 /d" $USER_DB
        echo "$2 $3" >> $USER_DB
        echo "用户 $2 密码已更新"
        ;;
    status)
        show_status
        ;;
    *)
        echo "OpenVPN管理脚本 (用户名/密码认证)"
        echo "用法: $0 {init|add|del|passwd|status}"
        echo "  init    - 初始化VPN服务"
        echo "  add     - 添加用户 (自动生成密码)"
        echo "  del     - 删除用户"
        echo "  passwd  - 修改用户密码"
        echo "  status  - 查看服务状态"
        exit 1
esac
