#!/bin/bash

# 全自动OpenVPN管理脚本
# 功能：自动IP分配 | 非交互式证书签发 | 用户管理
# 版本：2.0
# 最后更新：2023-11-15

# 配置路径
SQUID_CONF="/etc/squid/squid.conf"
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="$OPENVPN_DIR/easy-rsa"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
BASE_CONF="$CLIENT_DIR/base.conf"
LOG_FILE="/var/log/vpnadmin.log"

# 初始化日志
init_log() {
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

# 初始化PKI（完全非交互）
init_pki() {
    log "正在初始化PKI..."
    
    rm -rf "$EASY_RSA_DIR"
    make-cadir "$EASY_RSA_DIR"
    
    # 创建自动应答配置
    cat > "$EASY_RSA_DIR/vars" <<'EOF'
set_var EASYRSA_BATCH           "1"
set_var EASYRSA_REQ_COUNTRY     "CN"
set_var EASYRSA_REQ_PROVINCE    "Beijing"
set_var EASYRSA_REQ_CITY        "Beijing"
set_var EASYRSA_REQ_ORG         "MyVPN"
set_var EASYRSA_REQ_EMAIL       "admin@myvpn.com"
set_var EASYRSA_REQ_OU          "VPN"
set_var EASYRSA_REQ_CN          "VPN-CA"
set_var EASYRSA_KEY_SIZE        2048
set_var EASYRSA_ALGO            rsa
set_var EASYRSA_CURVE           secp384r1
EOF

    cd "$EASY_RSA_DIR" || exit
    
    # 非交互式初始化
    ./easyrsa init-pki >> "$LOG_FILE" 2>&1
    
    # 自动构建CA
    expect <<EOF >> "$LOG_FILE" 2>&1
spawn ./easyrsa build-ca nopass
expect "Confirm removal:"
send "yes\r"
expect eof
EOF

    ./easyrsa gen-dh >> "$LOG_FILE" 2>&1
    ./easyrsa build-server-full server nopass >> "$LOG_FILE" 2>&1
    ./easyrsa gen-crl >> "$LOG_FILE" 2>&1

    # 部署证书
    cp pki/{ca.crt,issued/server.crt,private/{ca,server}.key,dh.pem,crl.pem} "$OPENVPN_DIR/"
    chmod 600 "$OPENVPN_DIR"/*.key
    
    log "PKI初始化完成"
}

# 从Squid配置提取可用IP
get_available_ip() {
    # 提取IP池并排序
    mapfile -t IP_POOL < <(grep -oP 'acl ip_\d+ myip \K[\d.]+' "$SQUID_CONF" | sort -t. -k4n)
    [ ${#IP_POOL[@]} -eq 0 ] && { log "错误：Squid配置中未找到IP池"; exit 1; }
    
    # 获取已分配IP
    USED_IPS=()
    [ -d "$OPENVPN_DIR/ccd" ] && \
        mapfile -t USED_IPS < <(grep -hoP 'ifconfig-push \K[\d.]+' "$OPENVPN_DIR"/ccd/* 2>/dev/null)
    
    # 返回第一个可用IP
    for ip in "${IP_POOL[@]}"; do
        [[ " ${USED_IPS[*]} " =~ " $ip " ]] || { echo "$ip"; return 0; }
    done
    
    log "错误：所有IP地址已分配"
    exit 1
}

# 配置OpenVPN服务
setup_openvpn() {
    log "正在配置OpenVPN服务..."
    
    cat > "$OPENVPN_DIR/server.conf" <<EOF
port 1194
proto udp
dev tun
ca $OPENVPN_DIR/ca.crt
cert $OPENVPN_DIR/server.crt
key $OPENVPN_DIR/server.key
dh $OPENVPN_DIR/dh.pem
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
crl-verify $OPENVPN_DIR/crl.pem
client-config-dir $OPENVPN_DIR/ccd
EOF

    openvpn --genkey --secret "$OPENVPN_DIR/ta.key" >> "$LOG_FILE" 2>&1
    mkdir -p "$OPENVPN_DIR/ccd"
    
    log "OpenVPN服务配置完成"
}

# 创建客户端模板
create_client_template() {
    mkdir -p "$CLIENT_DIR"
    
    cat > "$BASE_CONF" <<EOF
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
<ca>
$(cat "$OPENVPN_DIR/ca.crt")
</ca>
<cert>
</cert>
<key>
</key>
<tls-auth>
$(cat "$OPENVPN_DIR/ta.key")
</tls-auth>
key-direction 1
EOF
    
    log "客户端模板创建完成"
}

# 添加VPN用户
add_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 adduser <用户名>"; exit 1; }
    
    local client_ip=$(get_available_ip)
    [ -z "$client_ip" ] && exit 1

    log "正在为用户 $username 分配IP: $client_ip"
    
    # 非交互式签发证书
    cd "$EASY_RSA_DIR" || exit
    expect <<EOF >> "$LOG_FILE" 2>&1
spawn ./easyrsa build-client-full "$username" nopass
expect "Confirm request details:"
send "yes\r"
expect eof
EOF

    # 生成客户端配置
    awk -v cert="$(cat "pki/issued/$username.crt")" \
        -v key="$(cat "pki/private/$username.key")" \
        '/<cert>/{print;print cert;next} /<key>/{print;print key;next} 1' \
        "$BASE_CONF" > "$CLIENT_DIR/$username.ovpn"

    # 设置固定IP
    echo "ifconfig-push $client_ip 255.255.255.0" > "$OPENVPN_DIR/ccd/$username"
    
    log "用户 $username 添加成功"
    log "IP地址: $client_ip"
    log "配置文件: $CLIENT_DIR/$username.ovpn"
}

# 删除用户
del_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 deluser <用户名>"; exit 1; }
    
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa revoke "$username" >> "$LOG_FILE" 2>&1
    ./easyrsa gen-crl >> "$LOG_FILE" 2>&1
    cp pki/crl.pem "$OPENVPN_DIR/"
    
    rm -f \
        "pki/issued/$username.crt" \
        "pki/private/$username.key" \
        "pki/reqs/$username.req" \
        "$CLIENT_DIR/$username.ovpn" \
        "$OPENVPN_DIR/ccd/$username"
    
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
            init_pki
            setup_openvpn
            create_client_template
            systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
            log "OpenVPN安装完成"
            ;;
        adduser)
            add_user "$2"
            ;;
        deluser)
            del_user "$2"
            ;;
        list)
            list_users
            ;;
        *)
            echo "用法: $0 {install|adduser <用户名>|deluser <用户名>|list}"
            exit 1
            ;;
    esac
}

main "$@"
