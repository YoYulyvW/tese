#!/bin/bash

# OpenVPN管理脚本（证书认证版）
# 认证方式：tls-crypt + CA证书 + 客户端证书
# 版本：5.0

# 配置路径
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="$OPENVPN_DIR/easy-rsa"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
LOG_FILE="/var/log/vpnadmin.log"
STATUS_FILE="$OPENVPN_DIR/openvpn-status.log"

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

# 初始化PKI
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
    ./easyrsa build-ca nopass >> "$LOG_FILE" 2>&1
    ./easyrsa gen-dh >> "$LOG_FILE" 2>&1
    ./easyrsa build-server-full server nopass >> "$LOG_FILE" 2>&1
    ./easyrsa gen-crl >> "$LOG_FILE" 2>&1

    # 生成tls-crypt密钥
    openvpn --genkey --secret "$OPENVPN_DIR/tls-crypt.key" >> "$LOG_FILE" 2>&1
    
    # 部署证书
    cp pki/{ca.crt,issued/server.crt,private/{ca,server}.key,dh.pem,crl.pem} "$OPENVPN_DIR/"
    chmod 600 "$OPENVPN_DIR"/*.key
    
    log "PKI初始化完成"
}

# 配置OpenVPN服务
setup_server() {
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
tls-crypt $OPENVPN_DIR/tls-crypt.key
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun
status $STATUS_FILE 30
status-version 2
verb 3
crl-verify $OPENVPN_DIR/crl.pem
EOF

    systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
    log "OpenVPN服务配置完成"
}

# 添加用户
add_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 add <用户名>"; exit 1; }
    
    cd "$EASY_RSA_DIR" || exit
    
    # 签发客户端证书
    ./easyrsa build-client-full "$username" nopass >> "$LOG_FILE" 2>&1 || {
        log "错误：证书签发失败"; exit 1
    }
    
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
cipher AES-256-GCM
verb 3
<ca>
$(cat "$OPENVPN_DIR/ca.crt")
</ca>
<cert>
$(cat "$EASY_RSA_DIR/pki/issued/$username.crt")
</cert>
<key>
$(cat "$EASY_RSA_DIR/pki/private/$username.key")
</key>
<tls-crypt>
$(cat "$OPENVPN_DIR/tls-crypt.key")
</tls-crypt>
EOF
    
    log "用户 $username 添加成功"
    echo "=== 客户端配置 ==="
    echo "文件路径: $CLIENT_DIR/$username.ovpn"
    echo "下载命令: scp root@$(hostname -I | awk '{print $1}'):$CLIENT_DIR/$username.ovpn ."
}

# 删除用户
del_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 del <用户名>"; exit 1; }
    
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa revoke "$username" >> "$LOG_FILE" 2>&1
    ./easyrsa gen-crl >> "$LOG_FILE" 2>&1
    cp pki/crl.pem "$OPENVPN_DIR/"
    
    rm -f \
        "pki/issued/$username.crt" \
        "pki/private/$username.key" \
        "pki/reqs/$username.req" \
        "$CLIENT_DIR/$username.ovpn"
    
    log "用户 $username 已吊销"
}

# 列出用户
list_users() {
    echo "=== VPN用户列表 ==="
    echo "用户名 | 证书状态 | 吊销状态"
    echo "--------------------------"
    
    cd "$EASY_RSA_DIR" || exit
    
    # 获取吊销列表
    declare -A revoked_certs
    while read -r line; do
        if [[ $line =~ ^R.*CN=([^/]+) ]]; then
            revoked_certs["${BASH_REMATCH[1]}"]=1
        fi
    done < <(./easyrsa list-crl 2>/dev/null)
    
    # 列出所有证书
    while read -r line; do
        if [[ $line =~ ^V.*CN=([^/]+) ]]; then
            local user="${BASH_REMATCH[1]}"
            local status="有效"
            [ -n "${revoked_certs[$user]}" ] && status="已吊销"
            printf "%-10s | %-10s | %s\n" "$user" "已签发" "$status"
        fi
    done < <(./easyrsa list-crt 2>/dev/null)
}

# 查看状态
show_status() {
    echo "=== OpenVPN服务状态 ==="
    systemctl status openvpn@server --no-pager
    
    echo -e "\n=== 当前连接 ==="
    if [ -f "$STATUS_FILE" ]; then
        column -t -s ',' "$STATUS_FILE" | awk '
            /^CLIENT_LIST/ {print "用户: "$2"\tIP: "$3"\t连接时间: "$4}
            /^ROUTING_TABLE/ {print "路由: "$2" -> "$3"\t虚拟IP: "$4}
        '
    else
        echo "没有活跃连接"
    fi
}

# 主菜单
main() {
    init_log
    check_root
    
    case "$1" in
        install)
            init_pki
            setup_server
            ;;
        add)
            add_user "$2"
            ;;
        del)
            del_user "$2"
            ;;
        list)
            list_users
            ;;
        status)
            show_status
            ;;
        *)
            echo "OpenVPN证书管理脚本"
            echo "用法: $0 {install|add|del|list|status}"
            echo "  install       - 初始化PKI和服务器配置"
            echo "  add <用户名> - 添加VPN用户"
            echo "  del <用户名> - 删除/吊销用户"
            echo "  list          - 列出所有用户证书"
            echo "  status        - 查看服务状态和连接"
            exit 1
            ;;
    esac
}

main "$@"
