#!/bin/bash

# 全自动OpenVPN管理脚本（用户名/密码认证版）
# 功能：自动IP分配 | 用户管理 | 密码认证
# 版本：3.0
# 最后更新：2023-11-15

# 配置路径
SQUID_CONF="/etc/squid/squid.conf"
OPENVPN_DIR="/etc/openvpn"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
USER_PASS_FILE="$OPENVPN_DIR/user-pass"
LOG_FILE="/var/log/vpnadmin.log"

# 初始化日志
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "====== $(date) ======" >> "$LOG_FILE"
}

# 记录日志
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 检查root权限
check_root() {
    [ "$(id -u)" != "0" ] && { log "错误：必须使用root权限运行"; exit 1; }
}

# 安装必要组件
install_deps() {
    log "正在安装OpenVPN..."
    apt-get update >> "$LOG_FILE" 2>&1
    apt-get install -y openvpn easy-rsa >> "$LOG_FILE" 2>&1
}

# 配置OpenVPN服务（密码认证版）
setup_openvpn() {
    log "正在配置OpenVPN服务（密码认证）..."
    
    # 生成随机密码文件密钥
    openvpn --genkey --secret "$OPENVPN_DIR/ta.key" >> "$LOG_FILE" 2>&1
    
    # 创建服务端配置
    cat > "$OPENVPN_DIR/server.conf" <<EOF
port 1194
proto udp
dev tun
server 10.8.0.0 255.255.255.0
topology subnet
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
tls-auth $OPENVPN_DIR/ta.key 0
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status $OPENVPN_DIR/openvpn-status.log
verb 3
client-config-dir $OPENVPN_DIR/ccd
script-security 2
auth-user-pass-verify $OPENVPN_DIR/check_user.sh via-file
username-as-common-name
verify-client-cert none
EOF

    # 创建用户验证脚本
    cat > "$OPENVPN_DIR/check_user.sh" <<EOF
#!/bin/bash
[ ! -f "$USER_PASS_FILE" ] && exit 1
grep -q "^\\\$1:\\\$2\$" "$USER_PASS_FILE"
EOF
    chmod +x "$OPENVPN_DIR/check_user.sh"
    
    # 创建CCD目录
    mkdir -p "$OPENVPN_DIR/ccd"
    
    log "OpenVPN服务配置完成"
}

# 从Squid配置提取可用IP
get_available_ip() {
    mapfile -t IP_POOL < <(grep -oP 'acl ip_\d+ myip \K[\d.]+' "$SQUID_CONF" | sort -t. -k4n)
    [ ${#IP_POOL[@]} -eq 0 ] && { log "错误：Squid配置中未找到IP池"; exit 1; }
    
    USED_IPS=()
    [ -d "$OPENVPN_DIR/ccd" ] && \
        mapfile -t USED_IPS < <(grep -hoP 'ifconfig-push \K[\d.]+' "$OPENVPN_DIR"/ccd/* 2>/dev/null)
    
    for ip in "${IP_POOL[@]}"; do
        [[ " ${USED_IPS[*]} " =~ " $ip " ]] || { echo "$ip"; return 0; }
    done
    
    log "错误：所有IP地址已分配"
    exit 1
}

# 添加VPN用户
add_user() {
    local username="$1"
    local password="$2"
    [ -z "$username" ] && { log "用法: $0 adduser <用户名> <密码>"; exit 1; }
    [ -z "$password" ] && password=$(openssl rand -base64 12) # 自动生成密码
    
    local client_ip=$(get_available_ip)
    [ -z "$client_ip" ] && exit 1

    log "正在为用户 $username 分配IP: $client_ip"
    
    # 添加用户凭据
    echo "$username:$(openssl passwd -1 "$password")" >> "$USER_PASS_FILE"
    
    # 设置固定IP
    echo "ifconfig-push $client_ip 255.255.255.0" > "$OPENVPN_DIR/ccd/$username"
    
    # 生成客户端配置
    mkdir -p "$CLIENT_DIR"
    cat > "$CLIENT_DIR/$username.ovpn" <<EOF
client
dev tun
proto udp
remote $(curl -s ifconfig.me) 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 3
auth-user-pass
<tls-auth>
$(cat "$OPENVPN_DIR/ta.key")
</tls-auth>
key-direction 1
EOF
    
    log "用户 $username 添加成功"
    log "IP地址: $client_ip"
    log "用户名: $username"
    log "密码: $password"
    log "配置文件: $CLIENT_DIR/$username.ovpn"
    echo "您可以下载客户端配置文件:"
    echo "scp root@$(hostname -I | awk '{print $1}'):$CLIENT_DIR/$username.ovpn ."
}

# 删除用户
del_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 deluser <用户名>"; exit 1; }
    
    # 删除用户凭据
    sed -i "/^$username:/d" "$USER_PASS_FILE"
    
    # 删除CCD配置
    rm -f "$OPENVPN_DIR/ccd/$username"
    
    log "用户 $username 已删除"
}

# 列出所有用户
list_users() {
    log "已配置的VPN用户:"
    echo "用户名 | IP地址"
    echo "----------------"
    for ccd_file in "$OPENVPN_DIR"/ccd/*; do
        if [ -f "$ccd_file" ]; then
            username=$(basename "$ccd_file")
            ip=$(grep -oP 'ifconfig-push \K[\d.]+' "$ccd_file")
            echo "$username | $ip"
        fi
    done | tee -a "$LOG_FILE"
}

# 主函数
main() {
    init_log
    check_root
    
    case "$1" in
        install)
            install_deps
            setup_openvpn
            systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
            log "OpenVPN安装完成"
            ;;
        adduser)
            add_user "$2" "$3"
            ;;
        deluser)
            del_user "$2"
            ;;
        list)
            list_users
            ;;
        *)
            echo "用法: $0 {install|adduser <用户名> [密码]|deluser <用户名>|list}"
            exit 1
            ;;
    esac
}

main "$@"
