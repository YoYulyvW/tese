#!/bin/bash

# OpenVPN管理脚本（增强版）
# 修复问题：IP显示 | 用户列表 | 文件清理 | 代理池管理
# 版本：5.1

# 配置路径
SQUID_CONF="/etc/squid/squid.conf"
OPENVPN_DIR="/etc/openvpn"
EASY_RSA_DIR="$OPENVPN_DIR/easy-rsa"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
CCD_DIR="$OPENVPN_DIR/ccd"
LOG_FILE="/var/log/vpnadmin.log"
STATUS_FILE="$OPENVPN_DIR/openvpn-status.log"
PROXY_POOL=("10.0.3.1" "10.0.3.2" "10.0.2.2") # 需要屏蔽的代理IP

# 初始化环境
init_env() {
    mkdir -p "$CLIENT_DIR" "$CCD_DIR"
    touch "$LOG_FILE"
    chmod 600 "$OPENVPN_DIR"/*.key 2>/dev/null
}

# 日志记录
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 获取可用IP
get_available_ip() {
    # 从Squid配置提取所有IP
    mapfile -t ALL_IPS < <(grep -oP 'acl ip_\d+ myip \K[\d.]+' "$SQUID_CONF" | sort -t. -k4n)
    
    # 排除已用IP和代理池IP
    USED_IPS=($(grep -hoP 'ifconfig-push \K[\d.]+' "$CCD_DIR"/* 2>/dev/null))
    EXCLUDE_IPS=("${PROXY_POOL[@]}" "${USED_IPS[@]}")
    
    for ip in "${ALL_IPS[@]}"; do
        if ! printf '%s\n' "${EXCLUDE_IPS[@]}" | grep -q "^${ip}$"; then
            echo "$ip"
            return 0
        fi
    done
    
    log "错误：没有可用的IP地址"
    exit 1
}

# 添加用户
add_user() {
    [ -z "$1" ] && { log "用法: $0 add <用户名>"; exit 1; }
    local username="$1"
    local client_ip=$(get_available_ip)
    
    # 清理旧文件
    rm -f "$CLIENT_DIR/$username.ovpn" "$CCD_DIR/$username" 2>/dev/null
    
    # 签发证书
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa build-client-full "$username" nopass >> "$LOG_FILE" 2>&1 || {
        log "证书签发失败"; exit 1
    }
    
    # 分配IP
    echo "ifconfig-push $client_ip 255.255.255.0" > "$CCD_DIR/$username"
    
    # 生成客户端配置
    cat > "$CLIENT_DIR/$username.ovpn" <<EOF
client
dev tun
proto udp
remote $(hostname -I | awk '{print $1}') 1194
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
    
    # 显示信息
    log "用户添加成功: $username"
    echo "=== 连接信息 ==="
    echo "服务器IP: $(hostname -I | awk '{print $1}')"
    echo "端口: 1194"
    echo "分配IP: $client_ip"
    echo "配置文件: $CLIENT_DIR/$username.ovpn"
    echo "下载: scp root@$(hostname -I | awk '{print $1}'):$CLIENT_DIR/$username.ovpn ."
}

# 删除用户
del_user() {
    [ -z "$1" ] && { log "用法: $0 del <用户名>"; exit 1; }
    local username="$1"
    
    cd "$EASY_RSA_DIR" || exit
    ./easyrsa revoke "$username" >> "$LOG_FILE" 2>&1
    ./easyrsa gen-crl >> "$LOG_FILE" 2>&1
    cp pki/crl.pem "$OPENVPN_DIR/"
    
    rm -f \
        "pki/issued/$username.crt" \
        "pki/private/$username.key" \
        "pki/reqs/$username.req" \
        "$CLIENT_DIR/$username.ovpn" \
        "$CCD_DIR/$username"
    
    log "用户 $username 已删除"
}

# 列出用户
list_users() {
    echo "=== VPN用户列表 ==="
    echo "用户名 | 分配IP | 证书状态"
    echo "--------------------------"
    
    # 获取吊销列表
    declare -A revoked
    cd "$EASY_RSA_DIR" || exit
    while read -r line; do
        if [[ $line =~ ^R.*CN=([^/]+) ]]; then
            revoked["${BASH_REMATCH[1]}"]=1
        fi
    done < <(./easyrsa list-crl 2>/dev/null)
    
    # 列出所有配置
    for ccd_file in "$CCD_DIR"/*; do
        [ -f "$ccd_file" ] || continue
        local username=$(basename "$ccd_file")
        local ip=$(grep -oP 'ifconfig-push \K[\d.]+' "$ccd_file")
        local status="有效"
        [ -n "${revoked[$username]}" ] && status="已吊销"
        
        printf "%-10s | %-15s | %s\n" "$username" "$ip" "$status"
    done
}

# 主菜单
main() {
    init_env
    case "$1" in
        add)
            add_user "$2"
            ;;
        del)
            del_user "$2"
            ;;
        list)
            list_users
            ;;
        *)
            echo "OpenVPN管理脚本"
            echo "用法: $0 {add|del|list} [用户名]"
            echo "  add <用户名>  - 添加用户并分配IP"
            echo "  del <用户名>  - 删除用户并释放IP"
            echo "  list          - 列出所有用户"
            exit 1
            ;;
    esac
}

main "$@"
