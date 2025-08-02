#!/bin/bash
# OpenVPN用户管理脚本 (纯VPN版)
# 功能: 初始化 | 用户管理 | 状态监控
# 特性:
# 1. 自动安装OpenVPN依赖
# 2. 用户名/密码认证
# 3. 每个用户独立内网IP
# 4. 强制所有流量通过VPN

CONFIG_DIR="/etc/openvpn"
USER_DB="$CONFIG_DIR/user-pass.db"
VPN_NET="10.8.0.0/24"
CCD_DIR="$CONFIG_DIR/ccd"
USER_IP_MAP="$CONFIG_DIR/user-ip.map"
LOG_FILE="/var/log/vpnadmin.log"

# 初始化日志
init_log() {
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 检查root权限
check_root() {
    [ "$EUID" -ne 0 ] && echo "错误: 需要root权限" | tee -a "$LOG_FILE" && exit 1
}

# 安装OpenVPN依赖
install_dependencies() {
    echo "检查OpenVPN依赖..." | tee -a "$LOG_FILE"
    
    if ! command -v openvpn &>/dev/null; then
        echo "正在安装OpenVPN..." | tee -a "$LOG_FILE"
        apt update -y >> "$LOG_FILE" 2>&1
        apt install -y openvpn iptables-persistent easy-rsa >> "$LOG_FILE" 2>&1 || {
            echo "安装失败! 查看日志: $LOG_FILE" | tee -a "$LOG_FILE"
            exit 1
        }
    fi
}

# 初始化目录结构
init_dirs() {
    mkdir -p "$CCD_DIR" "$CONFIG_DIR"
    touch "$USER_DB" "$USER_IP_MAP"
    chmod 600 "$USER_DB" "$USER_IP_MAP"
}

# 获取下一个可用VPN IP
get_next_vpn_ip() {
    local base_ip="10.8.0"
    local last_ip=$(grep -E "$base_ip\.[0-9]+$" "$USER_IP_MAP" 2>/dev/null | cut -d' ' -f2 | sort -t. -k4 -n | tail -1)
    
    if [ -z "$last_ip" ]; then
        echo "${base_ip}.2"
    else
        local last_octet=${last_ip##*.}
        echo "${base_ip}.$((last_octet + 1))"
    fi
}

# 配置系统参数
configure_system() {
    echo "配置网络参数..." | tee -a "$LOG_FILE"
    
    # 启用IP转发
    grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || {
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p >> "$LOG_FILE" 2>&1
    }
    
    # 基础NAT规则
    iptables -t nat -C POSTROUTING -s "$VPN_NET" -o eth0 -j MASQUERADE 2>/dev/null || {
        iptables -t nat -A POSTROUTING -s "$VPN_NET" -o eth0 -j MASQUERADE
    }
    
    # 保存iptables规则
    iptables-save > /etc/iptables/rules.v4 2>> "$LOG_FILE"
}

# 初始化OpenVPN服务
init_vpn() {
    echo "初始化OpenVPN配置..." | tee -a "$LOG_FILE"
    
    # 生成CA证书
    [ ! -d "$CONFIG_DIR/easy-rsa" ] && {
        make-cadir "$CONFIG_DIR/easy-rsa"
        cd "$CONFIG_DIR/easy-rsa"
        ./easyrsa init-pki
        ./easyrsa build-ca nopass
        ./easyrsa gen-dh
    }
    
    # 创建服务配置
    cat > "$CONFIG_DIR/server.conf" <<EOF
port 1194
proto udp
dev tun
server ${VPN_NET%/*} 255.255.255.0
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
verb 3
explicit-exit-notify 1
duplicate-cn
auth-user-pass-verify $CONFIG_DIR/auth.sh via-file
script-security 3
username-as-common-name
tmp-dir /dev/shm
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
client-config-dir $CCD_DIR
ca $CONFIG_DIR/easy-rsa/pki/ca.crt
cert $CONFIG_DIR/easy-rsa/pki/issued/server.crt
key $CONFIG_DIR/easy-rsa/pki/private/server.key
dh $CONFIG_DIR/easy-rsa/pki/dh.pem
EOF

    # 认证脚本
    cat > "$CONFIG_DIR/auth.sh" <<'EOF'
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
    chmod +x "$CONFIG_DIR/auth.sh"

    # 启动服务
    systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
    sleep 2
    
    if ! systemctl is-active --quiet openvpn@server; then
        echo "OpenVPN启动失败! 检查日志: journalctl -u openvpn@server" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "OpenVPN服务已就绪" | tee -a "$LOG_FILE"
}

# 用户管理
manage_user() {
    local action=$1 username=$2 password=$3
    
    # 密码生成
    if [ -z "$password" ]; then
        password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
        echo "生成密码: $password" | tee -a "$LOG_FILE"
    fi

    # 删除旧记录
    sed -i "/^$username /d" "$USER_DB"
    
    if [ "$action" = "add" ]; then
        # 添加用户
        echo "$username $password" >> "$USER_DB"
        local vpn_ip=$(get_next_vpn_ip)
        
        # CCD配置
        cat > "$CCD_DIR/$username" <<EOF
ifconfig-push $vpn_ip 255.255.255.0
push "route 0.0.0.0 0.0.0.0"
EOF
        
        # 记录IP分配
        echo "$username $vpn_ip" >> "$USER_IP_MAP"
        
        echo "用户添加成功:" | tee -a "$LOG_FILE"
        echo "用户名: $username" | tee -a "$LOG_FILE"
        echo "密码: $password" | tee -a "$LOG_FILE"
        echo "内网IP: $vpn_ip" | tee -a "$LOG_FILE"
        
    elif [ "$action" = "del" ]; then
        # 删除用户
        if grep -q "^$username " "$USER_IP_MAP"; then
            rm -f "$CCD_DIR/$username"
            sed -i "/^$username /d" "$USER_IP_MAP"
            echo "用户 $username 已删除" | tee -a "$LOG_FILE"
        else
            echo "用户 $username 不存在" | tee -a "$LOG_FILE"
        fi
    fi
}

# 状态检查
show_status() {
    echo -e "\n===== VPN服务状态 =====" | tee -a "$LOG_FILE"
    
    # 服务状态
    if systemctl is-active --quiet openvpn@server; then
        echo -e "状态: \e[32m运行中\e[0m" | tee -a "$LOG_FILE"
    else
        echo -e "状态: \e[31m未运行\e[0m" | tee -a "$LOG_FILE"
    fi
    
    # 连接用户
    echo -e "\n当前连接:" | tee -a "$LOG_FILE"
    if [ -f "/etc/openvpn/server/openvpn-status.log" ]; then
        awk '/^CLIENT_LIST/{printf "%-15s %-20s %-15s\n", $2, $3, $4}' "/etc/openvpn/server/openvpn-status.log" | tee -a "$LOG_FILE"
    else
        echo "无活跃连接" | tee -a "$LOG_FILE"
    fi
    
    # 用户列表
    echo -e "\n用户列表:" | tee -a "$LOG_FILE"
    if [ -s "$USER_IP_MAP" ]; then
        printf "%-15s %-15s\n" "用户名" "内网IP" | tee -a "$LOG_FILE"
        while read -r line; do
            printf "%-15s %-15s\n" $(echo "$line" | awk '{print $1, $2}') | tee -a "$LOG_FILE"
        done < "$USER_IP_MAP"
    else
        echo "无注册用户" | tee -a "$LOG_FILE"
    fi
    
    # 路由信息
    echo -e "\n路由表:" | tee -a "$LOG_FILE"
    ip route show table all | grep -E "10.8.0|tun0" | tee -a "$LOG_FILE"
}

# 主程序
check_root
init_log

case "$1" in
    init)
        install_dependencies
        init_dirs
        configure_system
        init_vpn
        echo "初始化完成! 日志: $LOG_FILE" | tee -a "$LOG_FILE"
        ;;
    add)
        [ -z "$2" ] && {
            echo "用法: $0 add <用户名> [密码]" | tee -a "$LOG_FILE"
            exit 1
        }
        manage_user "add" "$2" "$3"
        ;;
    del)
        [ -z "$2" ] && {
            echo "用法: $0 del <用户名>" | tee -a "$LOG_FILE"
            exit 1
        }
        manage_user "del" "$2"
        ;;
    passwd)
        [ -z "$2" ] || [ -z "$3" ] && {
            echo "用法: $0 passwd <用户名> <新密码>" | tee -a "$LOG_FILE"
            exit 1
        }
        sed -i "/^$2 /d" "$USER_DB"
        echo "$2 $3" >> "$USER_DB"
        echo "密码已修改" | tee -a "$LOG_FILE"
        ;;
    status)
        show_status
        ;;
    *)
        echo "OpenVPN管理脚本" | tee -a "$LOG_FILE"
        echo "用法: $0 {init|add|del|passwd|status}" | tee -a "$LOG_FILE"
        echo "  init    - 初始化VPN服务" | tee -a "$LOG_FILE"
        echo "  add     - 添加用户" | tee -a "$LOG_FILE"
        echo "  del     - 删除用户" | tee -a "$LOG_FILE"
        echo "  passwd  - 修改密码" | tee -a "$LOG_FILE"
        echo "  status  - 查看状态" | tee -a "$LOG_FILE"
        exit 1
esac
