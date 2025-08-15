#!/bin/bash
# 安装/更新/卸载 SNAT 定时器服务

SERVICE_NAME="auto-snatd"
INSTALL_DIR="/usr/local/sbin"
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"
MAX_LOG_LINES=50
TIMER_INTERVAL="4min"  # 定时器间隔

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 运行"
    exit 1
fi

# 如果已安装，给选项
if systemctl list-units --full -all | grep -q "^${SERVICE_NAME}.service"; then
    echo "检测到已安装的 ${SERVICE_NAME} 服务"
    read -rp "选择操作: [U]卸载 / [R]重新安装 / [Q]退出: " choice
    case "$choice" in
        U|u)
            echo "➡ 卸载服务..."
            systemctl stop "$SERVICE_NAME.timer" 2>/dev/null
            systemctl disable "$SERVICE_NAME.timer" 2>/dev/null
            systemctl stop "$SERVICE_NAME.service" 2>/dev/null
            systemctl disable "$SERVICE_NAME.service" 2>/dev/null
            rm -f "/etc/systemd/system/$SERVICE_NAME.service"
            rm -f "/etc/systemd/system/$SERVICE_NAME.timer"
            rm -f "$INSTALL_DIR/$SERVICE_NAME"
            systemctl daemon-reload
            echo "✔ 已卸载，日志保留在 $LOG_DIR"
            exit 0
            ;;
        R|r)
            echo "➡ 重新安装服务..."
            systemctl stop "$SERVICE_NAME.timer" 2>/dev/null
            systemctl disable "$SERVICE_NAME.timer" 2>/dev/null
            systemctl stop "$SERVICE_NAME.service" 2>/dev/null
            systemctl disable "$SERVICE_NAME.service" 2>/dev/null
            ;;
        Q|q)
            echo "❌ 退出，不做修改"
            exit 0
            ;;
        *)
            echo "❌ 无效选项"
            exit 1
            ;;
    esac
fi

# 创建日志目录
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

# 守护脚本（执行一次 SNAT 检查/更新）
cat > "$INSTALL_DIR/$SERVICE_NAME" <<'EOF'
#!/bin/bash
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"
MAX_LOG_LINES=50

log() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
    [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    # 保留最近 50 条日志
    if [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

check_network() {
    ip -4 addr show eth0 &>/dev/null || { log "[错误] eth0 接口不存在"; return 1; }
    return 0
}

update_snat() {
    ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    [ -z "$ETH0_IP" ] && { log "[错误] 获取 eth0 IP 失败"; return 1; }

    CURRENT_TARGET=$(iptables -t nat -S POSTROUTING 2>/dev/null \
        | grep -m1 "\-j SNAT" \
        | sed -n 's/.*--to-source \([0-9.]\+\).*/\1/p')

    if [ "$CURRENT_TARGET" = "$ETH0_IP" ]; then
        log "[信息] SNAT 规则已是最新 (目标IP: $ETH0_IP)"
        return 0
    fi

    log "[操作] 更新 SNAT 规则 → $ETH0_IP"
    iptables -t nat -F POSTROUTING 2>/dev/null
    iptables -t nat -A POSTROUTING -j SNAT --to-source "$ETH0_IP"

    if command -v iptables-save >/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
        log "[操作] 规则已持久化"
    fi
}

if check_network; then
    update_snat
else
    log "[警告] 网络检查失败"
fi
EOF
chmod 700 "$INSTALL_DIR/$SERVICE_NAME"

# systemd 服务（单次执行）
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=Auto SNAT Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/$SERVICE_NAME
User=root
Group=root
EOF

# systemd 定时器
cat > "/etc/systemd/system/$SERVICE_NAME.timer" <<EOF
[Unit]
Description=Run Auto SNAT Update every $TIMER_INTERVAL

[Timer]
OnBootSec=1min
OnUnitActiveSec=$TIMER_INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 启用定时器
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME.timer"

# <<< 新增：立即执行一次 SNAT 更新
echo "➡ 立即执行一次 SNAT 检查/更新..."
systemctl start "$SERVICE_NAME.service"

echo -e "\n\033[32m✔ 安装完成并已立即执行一次 SNAT 更新\033[0m"
echo "服务名称: $SERVICE_NAME"
echo "日志目录: $LOG_DIR"
echo "执行间隔: $TIMER_INTERVAL"
echo "卸载/更新：重新运行本安装脚本"
echo -e "\n当前定时器状态:"
systemctl list-timers | grep "$SERVICE_NAME"
