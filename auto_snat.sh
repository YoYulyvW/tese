#!/bin/bash
# Auto SNAT Daemon 安装/管理脚本
SERVICE_NAME="auto-snatd"
SCRIPT_PATH="/usr/local/sbin/$SERVICE_NAME"
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
INTERVAL_MIN=4  # 定时器间隔

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# 日志函数
log() {
    echo "$(date '+%F %T') - $1" >> "$LOG_FILE"
    # 保留最近50条
    tail -n50 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    # 日志轮转1M
    if [ $(stat -c%s "$LOG_FILE") -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
    fi
}

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行此脚本"
    exit 1
fi

# 非首次运行选项
if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
    echo "检测到已安装的 $SERVICE_NAME 服务"
    read -p "选择操作: [U]卸载 / [R]重新安装 / [Q]退出: " CHOICE
    case "$CHOICE" in
        u|U)
            systemctl stop "$SERVICE_NAME"
            systemctl disable "$SERVICE_NAME"
            rm -f "$SCRIPT_PATH" "$SERVICE_FILE" "$TIMER_FILE"
            systemctl daemon-reload
            echo "✅ 已卸载 $SERVICE_NAME"
            exit 0
            ;;
        r|R)
            echo "⚡ 重新安装..."
            ;;
        *)
            echo "❌ 退出，不做修改"
            exit 0
            ;;
    esac
fi

# 生成守护脚本
cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"

log() {
    echo "$(date '+%F %T') - $1" >> "$LOG_FILE"
    tail -n50 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    if [ $(stat -c%s "$LOG_FILE") -gt 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
    fi
}

update_snat() {
    TUNX_IP=$(ip -4 addr show tunx | grep -oP 'inet \K[\d.]+')
    TUNX_NET="${TUNX_IP%.*}.0/24"
    ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)

    # 获取现有规则目标 IP
    CURRENT_TARGET=$(iptables -t nat -S POSTROUTING | grep "^-A POSTROUTING -s $TUNX_NET -o eth0 -j SNAT" | head -n1 | grep -oP '(?<=--to-source )[\d.]+')

    if [ "$CURRENT_TARGET" = "$ETH0_IP" ]; then
        log "信息: SNAT规则已是最新 (目标IP: $ETH0_IP)"
        return 0
    fi

    # 删除旧规则
    for RULE in $(iptables -t nat -S POSTROUTING | grep "^-A POSTROUTING -s $TUNX_NET -o eth0 -j SNAT"); do
        iptables -t nat ${RULE/-A /-D }
    done

    # 添加新规则
    iptables -t nat -A POSTROUTING -s "$TUNX_NET" -o eth0 -j SNAT --to-source "$ETH0_IP"
    iptables-save > /etc/iptables/rules.v4
    log "操作: 更新 SNAT 规则: $TUNX_NET -> $ETH0_IP"
}

update_snat
EOF

chmod +x "$SCRIPT_PATH"

# 创建 systemd service
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Auto SNAT Daemon
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

# 创建 systemd timer
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run $SERVICE_NAME every $INTERVAL_MIN minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=$((INTERVAL_MIN * 60))s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$TIMER_FILE"
systemctl start "$SERVICE_NAME"

# 首次立即执行一次
bash "$SCRIPT_PATH"

echo "✔ 安装完成并已立即执行一次 SNAT 更新"
echo "服务名称: $SERVICE_NAME"
echo "日志目录: $LOG_DIR"
echo "执行间隔: $INTERVAL_MIN 分钟"
echo "卸载/更新：重新运行本安装脚本"
echo
systemctl list-timers | grep "$SERVICE_NAME"
