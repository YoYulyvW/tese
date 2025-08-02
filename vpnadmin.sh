#!/bin/bash
# OpenVPN全自动管理脚本
# 功能：自动修复证书问题 | 用户管理 | 服务监控

CONFIG_DIR="/etc/openvpn"
EASYRSA_DIR="$CONFIG_DIR/easy-rsa"
SERVER_CONF="$CONFIG_DIR/server.conf"
USER_DB="$CONFIG_DIR/user-pass.db"
CCD_DIR="$CONFIG_DIR/ccd"
LOG_FILE="/var/log/vpnadmin.log"

# 初始化日志
init_log() {
    mkdir -p $(dirname "$LOG_FILE")
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# 检查root权限
check_root() {
    [ "$EUID" -ne 0 ] && echo "✗ 需要root权限" | tee -a "$LOG_FILE" && exit 1
}

# 安装依赖
install_deps() {
    echo "▶ 安装依赖..." | tee -a "$LOG_FILE"
    apt update -y >> "$LOG_FILE" 2>&1
    apt install -y openvpn easy-rsa >> "$LOG_FILE" 2>&1 || {
        echo "✗ 依赖安装失败" | tee -a "$LOG_FILE"
        exit 1
    }
    ln -s /usr/share/easy-rsa/* /usr/local/bin/ 2>/dev/null
}

# 初始化PKI
init_pki() {
    echo "▶ 生成证书..." | tee -a "$LOG_FILE"
    rm -rf "$EASYRSA_DIR"
    make-cadir "$EASYRSA_DIR"
    cd "$EASYRSA_DIR" || exit 1
    
    # 非交互式生成证书
    export EASYRSA_BATCH=1
    ./easyrsa init-pki >> "$LOG_FILE" 2>&1
    ./easyrsa build-ca nopass >> "$LOG_FILE" 2>&1
    ./easyrsa build-server-full server nopass >> "$LOG_FILE" 2>&1
    ./easyrsa gen-dh >> "$LOG_FILE" 2>&1
    
    # 修复权限
    chmod 600 pki/private/*
    chmod 644 pki/issued/*
}

# 创建运行时目录
create_runtime_dirs() {
    echo "▶ 创建运行时目录..." | tee -a "$LOG_FILE"
    mkdir -p /run/openvpn "$CCD_DIR"
    chown nobody:nogroup /run/openvpn
}

# 生成服务配置
generate_config() {
    echo "▶ 生成服务配置..." | tee -a "$LOG_FILE"
    cat > "$SERVER_CONF" <<EOF
port 1194
proto udp
dev tun
server 10.8.0.0 255.255.255.0
topology subnet
keepalive 10 120
user nobody
group nogroup
persist-key
persist-tun
cipher AES-256-CBC
auth SHA256
verb 3
explicit-exit-notify 1
duplicate-cn
auth-user-pass-verify $CONFIG_DIR/auth.sh via-file
script-security 3
username-as-common-name
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
client-config-dir $CCD_DIR
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem
writepid /run/openvpn/server.pid
status /run/openvpn/server.status 10
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
}

# 配置系统参数
configure_system() {
    echo "▶ 配置系统参数..." | tee -a "$LOG_FILE"
    # 启用IP转发
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >> "$LOG_FILE" 2>&1
    
    # 防火墙规则
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
    iptables-save > /etc/iptables/rules.v4
}

# 启动服务
start_service() {
    echo "▶ 启动服务..." | tee -a "$LOG_FILE"
    systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
    sleep 2
    
    if systemctl is-active --quiet openvpn@server; then
        echo "✓ OpenVPN运行成功" | tee -a "$LOG_FILE"
    else
        echo "✗ 服务启动失败! 调试命令:" | tee -a "$LOG_FILE"
        echo "journalctl -u openvpn@server -n 50 --no-pager" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 用户管理
manage_user() {
    case "$1" in
        add)
            [ -z "$2" ] && { echo "用法: $0 add <用户名> [密码]"; exit 1; }
            local pass=${3:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)}
            echo "$2 $pass" >> "$USER_DB"
            
            # 分配IP
            local last_ip=$(grep -o '10.8.0.[0-9]\+' "$USER_DB" | cut -d. -f4 | sort -n | tail -1)
            local new_ip="10.8.0.$((last_ip + 1))"
            
            # CCD配置
            cat > "$CCD_DIR/$2" <<EOF
ifconfig-push $new_ip 255.255.255.0
push "route 0.0.0.0 0.0.0.0"
EOF
            
            echo "✓ 用户添加成功"
            echo "用户名: $2"
            echo "密码: $pass"
            echo "内网IP: $new_ip"
            ;;
        del)
            [ -z "$2" ] && { echo "用法: $0 del <用户名>"; exit 1; }
            sed -i "/^$2 /d" "$USER_DB"
            rm -f "$CCD_DIR/$2"
            echo "✓ 用户已删除"
            ;;
        passwd)
            [ -z "$2" ] || [ -z "$3" ] && { echo "用法: $0 passwd <用户名> <新密码>"; exit 1; }
            sed -i "/^$2 /d" "$USER_DB"
            echo "$2 $3" >> "$USER_DB"
            echo "✓ 密码已修改"
            ;;
        *)
            echo "无效操作"
            exit 1
            ;;
    esac
}

# 服务状态
show_status() {
    echo -e "\n=== OpenVPN状态 ==="
    systemctl is-active openvpn@server && \
        echo -e "服务状态: \e[32m运行中\e[0m" || \
        echo -e "服务状态: \e[31m未运行\e[0m"
    
    echo -e "\n=== 用户列表 ==="
    [ -s "$USER_DB" ] && awk '{print "用户名:", $1, "密码:", $2}' "$USER_DB" || echo "无用户"
    
    echo -e "\n=== 连接客户端 ==="
    [ -f "/run/openvpn/server.status" ] && \
        awk '/^CLIENT_LIST/{print $2, $3}' "/run/openvpn/server.status" || \
        echo "无活跃连接"
}

# 主流程
main() {
    check_root
    init_log
    
    case "$1" in
        init)
            install_deps
            init_pki
            create_runtime_dirs
            generate_config
            configure_system
            start_service
            ;;
        add|del|passwd)
            manage_user "$@"
            ;;
        status)
            show_status
            ;;
        *)
            echo "OpenVPN管理脚本"
            echo "用法: $0 {init|add|del|passwd|status}"
            echo "  init    初始化服务"
            echo "  add     添加用户"
            echo "  del     删除用户"
            echo "  passwd  修改密码"
            echo "  status  查看状态"
            exit 1
            ;;
    esac
}

main "$@"
