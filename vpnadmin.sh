#!/bin/bash

# 定义配置文件路径
SQUID_CONF="/etc/squid/squid.conf"
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="$OPENVPN_DIR/easy-rsa"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
BASE_CONF="$CLIENT_DIR/base.conf"

# 检查root权限
if [ "$(id -u)" != "0" ]; then
    echo "错误：此脚本必须以root权限运行！" 1>&2
    exit 1
fi

# 安装必要组件
install_dependencies() {
    echo "▶ 安装必要依赖..."
    apt update
    apt install -y openvpn easy-rsa
}

# 初始化PKI
init_pki() {
    echo "▶ 初始化PKI..."
    rm -rf "$EASY_RSA_DIR"
    make-cadir "$EASY_RSA_DIR"
    cd "$EASY_RSA_DIR" || exit
    
    # 使用新版easy-rsa
    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-dh
    
    # 生成服务器证书
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    
    # 生成CRL
    ./easyrsa gen-crl
    
    # 复制文件到OpenVPN目录
    cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key pki/crl.pem "$OPENVPN_DIR/"
    
    # 设置权限
    chmod 600 "$OPENVPN_DIR"/{ca.key,server.key,dh.pem,crl.pem}
    chmod 644 "$OPENVPN_DIR"/{ca.crt,server.crt}
}

# 从Squid配置中提取可用IPv4地址
get_available_ips() {
    echo "▶ 从Squid配置中提取可用IPv4地址..."
    # 提取所有acl定义的IP
    IP_POOL=($(grep -oP 'acl ip_\d+ myip \K[\d.]+' "$SQUID_CONF" | sort -t . -k 4 -n))
    
    # 提取已使用的IP
    USED_IPS=($(grep -hPo 'ifconfig-push \K[\d.]+' "$OPENVPN_DIR"/ccd/* 2>/dev/null || true))
    
    # 找出未使用的IP
    AVAILABLE_IPS=()
    for ip in "${IP_POOL[@]}"; do
        if ! printf '%s\n' "${USED_IPS[@]}" | grep -q "^${ip}$"; then
            AVAILABLE_IPS+=("$ip")
        fi
    done
    
    if [ ${#AVAILABLE_IPS[@]} -eq 0 ]; then
        echo "错误：没有可用的IPv4地址！" 1>&2
        exit 1
    fi
    
    echo "可用IPv4地址: ${AVAILABLE_IPS[*]}"
}

# 配置OpenVPN服务器
setup_openvpn() {
    echo "▶ 配置OpenVPN服务器..."
    
    # 创建server.conf
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
push "dhcp-option DNS 8.8.4.4"
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
    
    # 创建ccd目录
    mkdir -p "$OPENVPN_DIR/ccd"
    
    # 生成TLS-auth密钥
    openvpn --genkey --secret "$OPENVPN_DIR/ta.key"
}

# 创建客户端配置模板
create_client_template() {
    echo "▶ 创建客户端配置模板..."
    mkdir -p "$CLIENT_DIR"
    
    cat > "$BASE_CONF" <<EOF
client
dev tun
proto udp
remote your-server-ip 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
verb 3
<ca>
EOF
    cat "$OPENVPN_DIR/ca.crt" >> "$BASE_CONF"
    cat >> "$BASE_CONF" <<EOF
</ca>
<cert>
EOF
    # 证书会在创建用户时添加
    cat >> "$BASE_CONF" <<EOF
</cert>
<key>
EOF
    # 私钥会在创建用户时添加
    cat >> "$BASE_CONF" <<EOF
</key>
key-direction 1
<tls-auth>
EOF
    cat "$OPENVPN_DIR/ta.key" >> "$BASE_CONF"
    cat >> "$BASE_CONF" <<EOF
</tls-auth>
EOF
}

# 添加VPN用户
add_vpn_user() {
    if [ -z "$1" ]; then
        echo "用法: $0 adduser <用户名>"
        exit 1
    fi
    
    USERNAME="$1"
    
    # 获取可用IP
    get_available_ips
    CLIENT_IP="${AVAILABLE_IPS[0]}"
    
    echo "▶ 为用户 $USERNAME 分配IP: $CLIENT_IP"
    
    # 生成客户端证书
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa gen-req "$USERNAME" nopass
    ./easyrsa sign-req client "$USERNAME"
    
    # 创建客户端配置文件
    CLIENT_CONF="$CLIENT_DIR/$USERNAME.ovpn"
    cp "$BASE_CONF" "$CLIENT_CONF"
    
    # 插入证书和密钥
    sed -i "/<cert>/r pki/issued/$USERNAME.crt" "$CLIENT_CONF"
    sed -i "/<key>/r pki/private/$USERNAME.key" "$CLIENT_CONF"
    
    # 更新远程IP地址
    SERVER_IP=$(curl -s ifconfig.me)
    sed -i "s/your-server-ip/$SERVER_IP/" "$CLIENT_CONF"
    
    # 创建CCD文件
    echo "ifconfig-push $CLIENT_IP 255.255.255.0" > "$OPENVPN_DIR/ccd/$USERNAME"
    
    echo "✓ 用户 $USERNAME 创建成功"
    echo "✓ 客户端配置文件: $CLIENT_CONF"
    echo "✓ 分配的IPv4地址: $CLIENT_IP"
}

# 列出所有VPN用户
list_users() {
    echo "▶ 已配置的VPN用户:"
    echo "用户名 | 分配的IPv4地址"
    echo "---------------------"
    for ccd_file in "$OPENVPN_DIR"/ccd/*; do
        if [ -f "$ccd_file" ]; then
            username=$(basename "$ccd_file")
            ip=$(grep -oP 'ifconfig-push \K[\d.]+' "$ccd_file")
            echo "$username | $ip"
        fi
    done
}

# 删除VPN用户
del_vpn_user() {
    if [ -z "$1" ]; then
        echo "用法: $0 deluser <用户名>"
        exit 1
    fi
    
    USERNAME="$1"
    
    # 吊销证书
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa revoke "$USERNAME"
    ./easyrsa gen-crl
    
    # 删除相关文件
    rm -f "$EASY_RSA_DIR/pki/issued/$USERNAME.crt"
    rm -f "$EASY_RSA_DIR/pki/private/$USERNAME.key"
    rm -f "$EASY_RSA_DIR/pki/reqs/$USERNAME.req"
    rm -f "$CLIENT_DIR/$USERNAME.ovpn"
    rm -f "$OPENVPN_DIR/ccd/$USERNAME"
    
    # 更新CRL
    cp "$EASY_RSA_DIR/pki/crl.pem" "$OPENVPN_DIR/crl.pem"
    
    echo "✓ 用户 $USERNAME 已删除"
}

# 主菜单
case "$1" in
    install)
        install_dependencies
        init_pki
        setup_openvpn
        create_client_template
        systemctl enable --now openvpn@server
        echo "✓ OpenVPN安装完成"
        ;;
    adduser)
        add_vpn_user "$2"
        ;;
    deluser)
        del_vpn_user "$2"
        ;;
    list)
        list_users
        ;;
    *)
        echo "用法: $0 {install|adduser <用户名>|deluser <用户名>|list}"
        exit 1
        ;;
esac
