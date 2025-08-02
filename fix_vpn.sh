#!/bin/bash
# OpenVPN 全自动修复安装脚本
# 功能：修复所有常见问题 | 自动配置 | 状态检查

CONFIG_FILE="/etc/openvpn/server.conf"
LOG_FILE="/var/log/vpn_install.log"

# 初始化日志
init_log() {
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "=== 开始执行 $(date) ==="
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "✗ 必须使用root权限运行！" | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 安装依赖
install_deps() {
    echo "▶ 安装必要依赖..." | tee -a "$LOG_FILE"
    apt update -y >> "$LOG_FILE" 2>&1
    apt install -y openvpn easy-rsa iptables >> "$LOG_FILE" 2>&1
}

# 修复TUN/TAP设备
fix_tun_device() {
    echo "▶ 修复TUN/TAP设备..." | tee -a "$LOG_FILE"
    
    # 创建设备目录
    mkdir -p /dev/net >> "$LOG_FILE" 2>&1
    
    # 创建设备文件
    if [ ! -c /dev/net/tun ]; then
        mknod /dev/net/tun c 10 200 >> "$LOG_FILE" 2>&1
        chmod 666 /dev/net/tun >> "$LOG_FILE" 2>&1
    fi
    
    # 加载内核模块
    if ! lsmod | grep -q tun; then
        modprobe tun >> "$LOG_FILE" 2>&1
        echo "tun" >> /etc/modules
    fi
    
    # 永久生效配置
    cat > /etc/udev/rules.d/90-tun.rules <<EOF
KERNEL=="tun", MODE="0666", GROUP="nogroup"
EOF
}

# 更新OpenVPN配置
update_config() {
    echo "▶ 更新OpenVPN配置..." | tee -a "$LOG_FILE"
    
    # 备份原配置
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak" >> "$LOG_FILE" 2>&1
    
    # 更新加密配置
    sed -i '/^cipher AES-256-CBC/a data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC\ndata-ciphers-fallback AES-256-CBC' "$CONFIG_FILE"
    
    # 移除冲突配置
    sed -i 's/^duplicate-cn/;duplicate-cn/' "$CONFIG_FILE"
    
    # 添加缺失配置
    grep -q "^topology subnet" "$CONFIG_FILE" || echo "topology subnet" >> "$CONFIG_FILE"
    grep -q "^persist-tun" "$CONFIG_FILE" || echo "persist-tun" >> "$CONFIG_FILE"
}

# 配置系统参数
setup_system() {
    echo "▶ 配置系统参数..." | tee -a "$LOG_FILE"
    
    # 启用IP转发
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p >> "$LOG_FILE" 2>&1
    
    # 基础防火墙规则
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE >> "$LOG_FILE" 2>&1
    iptables-save > /etc/iptables/rules.v4 >> "$LOG_FILE" 2>&1
    
    # 创建systemd服务配置
    mkdir -p /etc/systemd/system/openvpn@.service.d
    cat > /etc/systemd/system/openvpn@.service.d/10-tun.conf <<EOF
[Service]
ExecStartPre=/bin/mkdir -p /dev/net
ExecStartPre=/bin/mknod /dev/net/tun c 10 200
ExecStartPre=/bin/chmod 666 /dev/net/tun
RestartSec=5
Restart=always
EOF
}

# 启动服务
start_service() {
    echo "▶ 启动OpenVPN服务..." | tee -a "$LOG_FILE"
    
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable --now openvpn@server >> "$LOG_FILE" 2>&1
    
    sleep 3
    
    if systemctl is-active --quiet openvpn@server; then
        echo "✓ OpenVPN服务运行成功！" | tee -a "$LOG_FILE"
        echo "服务状态: $(systemctl status openvpn@server --no-pager | grep Active)" | tee -a "$LOG_FILE"
    else
        echo "✗ 服务启动失败！最后10行日志：" | tee -a "$LOG_FILE"
        journalctl -u openvpn@server -n 10 --no-pager | tee -a "$LOG_FILE"
        exit 1
    fi
}

# 验证修复
verify_fix() {
    echo "▶ 验证修复结果..." | tee -a "$LOG_FILE"
    
    echo -e "\n=== 设备检查 ===" | tee -a "$LOG_FILE"
    ls -l /dev/net/tun | tee -a "$LOG_FILE"
    
    echo -e "\n=== 模块检查 ===" | tee -a "$LOG_FILE"
    lsmod | grep tun | tee -a "$LOG_FILE"
    
    echo -e "\n=== 连接测试 ===" | tee -a "$LOG_FILE"
    ping -c 3 10.8.0.1 | tee -a "$LOG_FILE"
    
    echo -e "\n=== 服务状态 ===" | tee -a "$LOG_FILE"
    systemctl status openvpn@server --no-pager | head -n 10 | tee -a "$LOG_FILE"
}

# 主执行流程
main() {
    init_log
    check_root
    install_deps
    fix_tun_device
    update_config
    setup_system
    start_service
    verify_fix
    
    echo -e "\n✓ 所有修复已完成！详细日志见: $LOG_FILE" | tee -a "$LOG_FILE"
    echo "客户端配置需包含以下参数：" | tee -a "$LOG_FILE"
    echo "cipher AES-256-CBC" | tee -a "$LOG_FILE"
    echo "auth SHA256" | tee -a "$LOG_FILE"
}

main
