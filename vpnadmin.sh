#!/bin/bash
# OpenVPN 全自动管理脚本 (PVE8 LXC 专用版)
# 功能：初始化服务 | 用户管理 | 自动修复
# 最后更新：2025-08-02

CONFIG_DIR="/etc/openvpn"
SERVER_CONF="$CONFIG_DIR/server.conf"
EASYRSA_DIR="$CONFIG_DIR/easy-rsa"
USER_DB="$CONFIG_DIR/user-pass.db"
CCD_DIR="$CONFIG_DIR/ccd"
LOG_FILE="/var/log/vpnadmin.log"
PORT=1194

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 初始化日志
init_log() {
    mkdir -p $(dirname "$LOG_FILE")
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo -e "\n=== 操作开始 $(date) ===" | tee -a "$LOG_FILE"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ 必须使用root权限运行！${NC}" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 检查容器环境
check_container() {
    if ! grep -q container=lxc /proc/1/environ; then
        echo -e "${YELLOW}⚠️ 建议在PVE LXC容器内运行本脚本${NC}" | tee -a "$LOG_FILE"
        read -p "继续执行？(y/n) " -n 1 -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
}

# 安装依赖
install_deps() {
    echo -e "${YELLOW}▶ 安装必要依赖...${NC}" | tee -a "$LOG_FILE"
    apt update -y >> "$LOG_FILE" 2>&1
    apt install -y openvpn easy-rsa iptables >> "$LOG_FILE" 2>&1 || {
        echo -e "${RED}✗ 依赖安装失败，请检查日志: $LOG_FILE${NC}" | tee -a "$LOG_FILE"
        exit 1
    }
}

# 修复TUN设备
fix_tun_device() {
    echo -e "${YELLOW}▶ 修复TUN/TAP设备...${NC}" | tee -a "$LOG_FILE"
    
    # 确保设备目录存在
    mkdir -p /dev/net 2>/dev/null
    
    # 创建设备（如果不存在）
    if [ ! -c /dev/net/tun ]; then
        mknod -m 666 /dev/net/tun c 10 200 2>/dev/null || {
            echo -e "${RED}✗ 无法创建TUN设备，请检查权限${NC}" | tee -a "$LOG_FILE"
            exit 1
        }
    fi
    
    # 验证设备
    if [ -c /dev/net/tun ]; then
        echo -e "${GREEN}✓ TUN设备已就绪: $(ls -l /dev/net/tun)${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${RED}✗ TUN设备创建失败${NC}" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 生成证书
generate_certs() {
    echo -e "${YELLOW}▶ 生成证书...${NC}" | tee -a "$LOG_FILE"
    
    # 初始化PKI
    [ ! -d "$EASYRSA_DIR" ] && {
        make-cadir "$EASYRSA_DIR"
        cd "$EASYRSA_DIR" || exit 1
        ./easyrsa init-pki >> "$LOG_FILE" 2>&1
        ./easyrsa build-ca nopass >> "$LOG_FILE" 2>&1
        ./easyrsa build-server-full server nopass >> "$LOG_FILE" 2>&1
        ./easyrsa gen-dh >> "$LOG_FILE" 2>&1
    }
    
    # 验证证书
    if [ -f "$EASYRSA_DIR/pki/issued/server.crt" ]; then
        echo -e "${GREEN}✓ 证书生成成功${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${RED}✗ 证书生成失败${NC}" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 配置OpenVPN服务
configure_openvpn() {
    echo -e "${YELLOW}▶ 生成服务配置...${NC}" | tee -a "$LOG_FILE"
    
    # 创建基础配置
    cat > "$SERVER_CONF" <<EOF
port $PORT
proto udp
dev tun
server 10.8.0.0 255.255.255.0
topology subnet
keepalive 10 120
persist-tun
persist-key
user nobody
group nogroup
verb 3
explicit-exit-notify 1
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
ca $EASYRSA_DIR/pki/ca.crt
cert $EASYRSA_DIR/pki/issued/server.crt
key $EASYRSA_DIR/pki/private/server.key
dh $EASYRSA_DIR/pki/dh.pem
status /var/log/openvpn-status.log
log /var/log/openvpn.log
EOF

    # 现代加密配置
    if openvpn --version | grep -q '2.5'; then
        echo "data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC" >> "$SERVER_CONF"
        echo "data-ciphers-fallback AES-256-CBC" >> "$SERVER_CONF"
    else
        echo "cipher AES-256-CBC" >> "$SERVER_CONF"
    fi
}

# 配置系统参数
setup_system() {
    echo -e "${YELLOW}▶ 配置系统参数...${NC}" | tee -a "$LOG_FILE"
    
    # 启用IP转发
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >> "$LOG_FILE" 2>&1
    
    # 基础防火墙规则（使用临时文件）
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>> "$LOG_FILE"
}

# 启动服务
start_service() {
    echo -e "${YELLOW}▶ 启动OpenVPN服务...${NC}" | tee -a "$LOG_FILE"
    
    # 确保端口释放
    fuser -k $PORT/udp 2>/dev/null
    
    # 创建服务配置文件
    mkdir -p /etc/systemd/system/openvpn@.service.d
    cat > /etc/systemd/system/openvpn@.service.d/override.conf <<EOF
[Service]
ExecStartPre=/bin/sh -c '[ -c /dev/net/tun ] || { mkdir -p /dev/net && mknod -m 666 /dev/net/tun c 10 200; }'
RestartSec=5
EOF
    
    systemctl daemon-reload
    systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
    
    sleep 2
    
    if systemctl is-active --quiet openvpn@server; then
        echo -e "${GREEN}✓ OpenVPN服务启动成功${NC}" | tee -a "$LOG_FILE"
    else
        echo -e "${RED}✗ 服务启动失败！最后日志：${NC}" | tee -a "$LOG_FILE"
        journalctl -u openvpn@server -n 10 --no-pager | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 用户管理
manage_user() {
    case "$1" in
        add)
            [ -z "$2" ] && { echo -e "${RED}用法: $0 add <用户名> [密码]${NC}"; exit 1; }
            local pass=${3:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)}
            echo "$2 $pass" >> "$USER_DB"
            echo -e "${GREEN}✓ 用户添加成功:\n用户名: $2\n密码: $pass${NC}"
            ;;
        del)
            [ -z "$2" ] && { echo -e "${RED}用法: $0 del <用户名>${NC}"; exit 1; }
            sed -i "/^$2 /d" "$USER_DB"
            echo -e "${GREEN}✓ 用户已删除${NC}"
            ;;
        passwd)
            [ -z "$2" ] || [ -z "$3" ] && { echo -e "${RED}用法: $0 passwd <用户名> <新密码>${NC}"; exit 1; }
            sed -i "/^$2 /d" "$USER_DB"
            echo "$2 $3" >> "$USER_DB"
            echo -e "${GREEN}✓ 密码已修改${NC}"
            ;;
        *)
            echo -e "${RED}无效操作${NC}"
            exit 1
            ;;
    esac
}

# 显示状态
show_status() {
    echo -e "\n${YELLOW}=== OpenVPN 状态 ===${NC}"
    
    # 服务状态
    if systemctl is-active --quiet openvpn@server; then
        echo -e "${GREEN}● 服务状态: 运行中${NC}"
    else
        echo -e "${RED}● 服务状态: 未运行${NC}"
    fi
    
    # 连接信息
    echo -e "\n${YELLOW}● 监听端口:${NC}"
    ss -tulnp | grep -E ":$PORT|openvpn"
    
    # 用户列表
    echo -e "\n${YELLOW}● 用户列表:${NC}"
    [ -s "$USER_DB" ] && column -t "$USER_DB" || echo "无用户"
    
    # 路由信息
    echo -e "\n${YELLOW}● 路由表:${NC}"
    ip route show | grep -E "tun|10.8.0"
}

# 主菜单
main_menu() {
    case "$1" in
        init)
            check_root
            check_container
            init_log
            install_deps
            fix_tun_device
            generate_certs
            configure_openvpn
            setup_system
            start_service
            echo -e "${GREEN}\n✓ 初始化完成！详细日志见: $LOG_FILE${NC}"
            ;;
        add|del|passwd)
            check_root
            manage_user "$@"
            ;;
        status)
            show_status
            ;;
        *)
            echo -e "${YELLOW}OpenVPN 管理脚本 (PVE8 LXC 专用)${NC}"
            echo "用法: $0 {init|add|del|passwd|status}"
            echo "  init     - 初始化VPN服务"
            echo "  add      - 添加用户 (自动生成密码)"
            echo "  del      - 删除用户"
            echo "  passwd   - 修改密码"
            echo "  status   - 查看状态"
            exit 1
            ;;
    esac
}

main_menu "$@"
