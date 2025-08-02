#!/bin/bash

# 全功能OpenVPN管理脚本（用户名/密码认证）
# 功能：用户管理 | IP分配 | 状态查看
# 版本：4.0

# 配置路径
SQUID_CONF="/etc/squid/squid.conf"
OPENVPN_DIR="/etc/openvpn"
CLIENT_DIR="$OPENVPN_DIR/client-configs"
USER_PASS_FILE="$OPENVPN_DIR/user-pass"
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

# 获取可用IP
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

# 添加用户
add_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 adduser <用户名> [密码]"; exit 1; }
    
    local password="${2:-$(openssl rand -base64 12)}"
    local client_ip=$(get_available_ip)
    [ -z "$client_ip" ] && exit 1

    # 管理用户凭据
    touch "$USER_PASS_FILE"
    chmod 600 "$USER_PASS_FILE"
    sed -i "/^$username:/d" "$USER_PASS_FILE"
    echo "$username:$(openssl passwd -1 "$password")" >> "$USER_PASS_FILE"
    
    # 分配IP
    mkdir -p "$OPENVPN_DIR/ccd"
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
verb 1
auth-user-pass
<tls-auth>
$(cat "$OPENVPN_DIR/ta.key")
</tls-auth>
key-direction 1
EOF
    
    log "用户添加成功: $username IP: $client_ip"
    echo "=== 用户信息 ==="
    echo "用户名: $username"
    echo "密码: $password"
    echo "配置文件: $CLIENT_DIR/$username.ovpn"
    echo "下载命令: scp root@$(hostname -I | awk '{print $1}'):$CLIENT_DIR/$username.ovpn ."
}

# 删除用户
del_user() {
    local username="$1"
    [ -z "$username" ] && { log "用法: $0 deluser <用户名>"; exit 1; }
    
    # 移除用户记录
    sed -i "/^$username:/d" "$USER_PASS_FILE"
    rm -f "$OPENVPN_DIR/ccd/$username" "$CLIENT_DIR/$username.ovpn"
    
    log "用户 $username 已删除"
}

# 列出所有用户
list_users() {
    echo "=== VPN用户列表 ==="
    echo "用户名 | IP地址 | 最后登录"
    echo "----------------------------------------"
    
    # 获取状态信息
    declare -A status_map
    while read -r line; do
        if [[ $line == CLIENT_LIST* ]]; then
            IFS=',' read -ra parts <<< "$line"
            status_map["${parts[1]}"]="${parts[3]} (Since ${parts[4]})"
        fi
    done < "$STATUS_FILE" 2>/dev/null
    
    # 显示所有用户
    for ccd_file in "$OPENVPN_DIR"/ccd/*; do
        [ -f "$ccd_file" ] || continue
        local username=$(basename "$ccd_file")
        local ip=$(grep -oP 'ifconfig-push \K[\d.]+' "$ccd_file")
        local status="${status_map[$username]:-"未连接"}"
        printf "%-10s | %-15s | %s\n" "$username" "$ip" "$status"
    done
}

# 查看连接状态
show_status() {
    echo "=== 当前VPN连接状态 ==="
    if [ -f "$STATUS_FILE" ]; then
        column -t -s ',' "$STATUS_FILE" | awk '
            /^CLIENT_LIST/ {print "用户: "$2"\tIP: "$3"\t连接时间: "$4}
            /^ROUTING_TABLE/ {print "路由: "$2" -> "$3"\t虚拟IP: "$4}
        '
    else
        echo "没有活跃的连接"
    fi
}

# 主菜单
main() {
    init_log
    check_root
    
    case "$1" in
        add)
            add_user "$2" "$3"
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
            echo "OpenVPN管理脚本"
            echo "用法: $0 {adduser|deluser|list|status}"
            echo "  adduser <用户名> [密码]  - 添加VPN用户"
            echo "  deluser <用户名>         - 删除VPN用户"
            echo "  list                     - 列出所有用户"
            echo "  status                   - 查看连接状态"
            exit 1
            ;;
    esac
}

main "$@"
