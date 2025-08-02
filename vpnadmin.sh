#!/bin/bash

# 全自动OpenVPN用户管理脚本
# 自动从Squid配置提取IP池，无需人工交互

# 配置路径
SQUID_CONF="/etc/squid/squid.conf"
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="$OPENVPN_DIR/easy-rsa"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
BASE_CONF="$CLIENT_DIR/base.conf"

# 检查root权限
[ "$(id -u)" != "0" ] && { echo "必须使用root运行"; exit 1; }

# 非交互式初始化PKI
init_pki() {
    echo "正在初始化PKI..."
    rm -rf "$EASY_RSA_DIR"
    make-cadir "$EASY_RSA_DIR"
    cd "$EASY_RSA_DIR" || exit

    # 创建自动应答的vars文件
    cat > vars <<'EOF'
set_var EASYRSA_BATCH           "yes"
set_var EASYRSA_REQ_COUNTRY     "CN"
set_var EASYRSA_REQ_PROVINCE    "Beijing"
set_var EASYRSA_REQ_CITY        "Beijing"
set_var EASYRSA_REQ_ORG         "My Company"
set_var EASYRSA_REQ_EMAIL       "admin@example.com"
set_var EASYRSA_REQ_OU          "IT"
set_var EASYRSA_REQ_CN          "VPN CA"
EOF

    # 初始化并构建CA
    ./easyrsa init-pki
    ./easyrsa build-ca nopass <<< "yes"  # 自动确认CA创建
    
    # 生成其他必要文件
    ./easyrsa gen-dh
    ./easyrsa build-server-full server nopass
    ./easyrsa gen-crl

    # 复制证书文件
    cp pki/{ca.crt,issued/server.crt,private/{ca,server}.key,dh.pem,crl.pem} "$OPENVPN_DIR/"
    chmod 600 "$OPENVPN_DIR"/*.key
}


# 自动提取并分配IP
get_available_ip() {
    # 从Squid配置提取IP池
    mapfile -t IP_POOL < <(grep -oP 'acl ip_\d+ myip \K[\d.]+' "$SQUID_CONF" | sort -t. -k4n)
    [ ${#IP_POOL[@]} -eq 0 ] && { echo "错误：Squid配置中未找到IP池"; exit 1; }
    
    # 获取已分配IP
    USED_IPS=()
    [ -d "$OPENVPN_DIR/ccd" ] && \
        mapfile -t USED_IPS < <(grep -hoP 'ifconfig-push \K[\d.]+' "$OPENVPN_DIR"/ccd/* 2>/dev/null)
    
    # 返回第一个未使用的IP
    for ip in "${IP_POOL[@]}"; do
        [[ " ${USED_IPS[*]} " =~ " $ip " ]] || { echo "$ip"; return; }
    done
    
    echo "错误：所有IP地址已分配" >&2
    exit 1
}

# 配置OpenVPN服务
setup_openvpn() {
    echo "正在配置OpenVPN服务..."
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
verb 0
crl-verify $OPENVPN_DIR/crl.pem
client-config-dir $OPENVPN_DIR/ccd
EOF

    # 生成TLS-auth密钥
    openvpn --genkey --secret "$OPENVPN_DIR/ta.key"
    mkdir -p "$OPENVPN_DIR/ccd"
}

# 创建客户端模板
create_client_tpl() {
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
verb 1
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
}

# 全自动添加用户
add_user() {
    local username="$1"
    [ -z "$username" ] && { echo "用法: $0 adduser <用户名>"; exit 1; }
    
    local client_ip=$(get_available_ip)
    [ -z "$client_ip" ] && exit 1

    echo "正在为用户 $username 分配IP: $client_ip"
    
    # 签发客户端证书（非交互式）
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa --batch build-client-full "$username" nopass
    
    # 生成客户端配置
    awk -v cert="$(cat "pki/issued/$username.crt")" \
        -v key="$(cat "pki/private/$username.key")" \
        '/<cert>/{print;print cert;next} /<key>/{print;print key;next} 1' \
        "$BASE_CONF" > "$CLIENT_DIR/$username.ovpn"

    # 设置固定IP
    echo "ifconfig-push $client_ip 255.255.255.0" > "$OPENVPN_DIR/ccd/$username"
    
    echo "用户添加成功:"
    echo "IP地址: $client_ip"
    echo "配置文件: $CLIENT_DIR/$username.ovpn"
}

# 删除用户
del_user() {
    local username="$1"
    [ -z "$username" ] && { echo "用法: $0 deluser <用户名>"; exit 1; }
    
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa revoke "$username"
    ./easyrsa gen-crl
    cp pki/crl.pem "$OPENVPN_DIR/"
    
    rm -f \
        "pki/issued/$username.crt" \
        "pki/private/$username.key" \
        "pki/reqs/$username.req" \
        "$CLIENT_DIR/$username.ovpn" \
        "$OPENVPN_DIR/ccd/$username"
    
    echo "用户 $username 已删除"
}

# 主逻辑
case "$1" in
    install)
        init_pki
        setup_openvpn
        create_client_tpl
        systemctl enable --now openvpn@server
        echo "OpenVPN安装完成"
        ;;
    adduser)
        add_user "$2"
        ;;
    deluser)
        del_user "$2"
        ;;
    *)
        echo "用法: $0 {install|adduser <用户名>|deluser <用户名>}"
        exit 1
        ;;
esac
