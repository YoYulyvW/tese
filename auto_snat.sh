#!/bin/bash

# 配置参数
SERVICE_NAME="auto-snatd"
INSTALL_DIR="/usr/local/sbin"
LOG_DIR="/root/snat_logs"  # 日志存放目录
LOG_FILE="$LOG_DIR/auto-snat.log"

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用root用户运行此脚本!"
    exit 1
fi

# 创建日志目录
mkdir -p $LOG_DIR
chmod 700 $LOG_DIR

# 生成守护脚本
cat > $INSTALL_DIR/$SERVICE_NAME <<'EOF'
#!/bin/bash

# 日志配置
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"
MAX_LOG_SIZE=1048576  # 1MB

# 日志记录函数
log() {
    # 确保日志文件存在
    [ -d "$LOG_DIR" ] || mkdir -p $LOG_DIR
    [ -f "$LOG_FILE" ] || touch $LOG_FILE
    
    # 日志轮转（如果超过最大大小）
    if [ $(stat -c%s "$LOG_FILE") -gt $MAX_LOG_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# 网络检测函数
check_network() {
    # 检测tunx接口
    if ! ip -4 addr show tunx &>/dev/null; then
        log "[错误] tunx接口不存在"
        return 1
    fi
    
    # 检测eth0接口
    if ! ip -4 addr show eth0 &>/dev/null; then
        log "[错误] eth0接口不存在"
        return 1
    fi
    return 0
}

# SNAT规则更新函数
update_snat() {
    # 获取tunx网络信息
    TUNX_INFO=$(ip -4 addr show tunx | grep -oP 'inet \K[\d./]+')
    IFS='/' read -r TUNX_IP TUNX_CIDR <<< "$TUNX_INFO"
    
    # 计算源网络
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$TUNX_IP"
    MASK=$((0xffffffff << (32 - TUNX_CIDR) & 0xffffffff))
    NETWORK="$((ip1 & (MASK >> 24))).$((ip2 & (MASK >> 16 & 0xff))).$((ip3 & (MASK >> 8 & 0xff))).$((ip4 & (MASK & 0xff)))"
    SOURCE_NET="$NETWORK/$TUNX_CIDR"
    
    # 获取eth0当前IP
    ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    
    # 检查现有规则
    CURRENT_TARGET=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -oP "SNAT\s+all\s+.*to:\K[\d.]+" | head -n1)
    
    if [ "$CURRENT_TARGET" = "$ETH0_IP" ]; then
        log "[信息] SNAT规则已是最新 (目标IP: $ETH0_IP)"
        return 0
    fi
    
    # 更新规则
    log "[操作] 更新SNAT规则: $SOURCE_NET → $ETH0_IP"
    iptables -t nat -F POSTROUTING 2>/dev/null
    iptables -t nat -A POSTROUTING -s "$SOURCE_NET" -j SNAT --to-source "$ETH0_IP"
    
    # 持久化
    if command -v iptables-save >/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        log "[操作] 规则已持久化"
    fi
}

# 主循环
log "[启动] SNAT守护服务启动"
while true; do
    if check_network; then
        update_snat
    else
        log "[警告] 网络检查失败，等待重试..."
    fi
    sleep 60
done
EOF

# 设置权限
chmod 700 $INSTALL_DIR/$SERVICE_NAME

# 创建systemd服务
cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Auto SNAT Daemon
After=network.target
StartLimitIntervalSec=60

[Service]
Type=simple
ExecStart=$INSTALL_DIR/$SERVICE_NAME
Restart=always
RestartSec=5s
User=root
Group=root

# 日志限制
LogRateLimitIntervalSec=60
LogRateLimitBurst=100

[Install]
WantedBy=multi-user.target
EOF

# 启用服务
systemctl daemon-reload
systemctl enable --now $SERVICE_NAME.service

# 创建卸载脚本
cat > $INSTALL_DIR/uninstall-$SERVICE_NAME <<EOF
#!/bin/bash
systemctl stop $SERVICE_NAME
systemctl disable $SERVICE_NAME
rm -f /etc/systemd/system/$SERVICE_NAME.service
rm -f $INSTALL_DIR/$SERVICE_NAME
systemctl daemon-reload
echo "服务已卸载"
echo "日志文件仍保留在: $LOG_DIR"
EOF
chmod +x $INSTALL_DIR/uninstall-$SERVICE_NAME

# 完成提示
echo -e "\n\033[32m✔ 安装完成\033[0m"
echo "服务名称: $SERVICE_NAME"
echo "日志目录: $LOG_DIR"
echo "检测间隔: 60秒"
echo "卸载命令: $INSTALL_DIR/uninstall-$SERVICE_NAME"
echo -e "\n当前状态:"
systemctl status $SERVICE_NAME --no-pager | grep -A 3 "Active:"