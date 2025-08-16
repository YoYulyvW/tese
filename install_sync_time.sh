#!/bin/bash
# Amlogic S9xxx Armbian 北京时间自动同步管理脚本
# 首次运行：安装并启用开机同步 + 每4分钟自动同步
# 后续运行：可选择卸载，或修复缺失的定时器

SERVICE_FILE="/etc/systemd/system/sync-time.service"
TIMER_SERVICE_FILE="/etc/systemd/system/sync-time.timer"
TIMER_UNIT_FILE="/etc/systemd/system/sync-time-task.service"
SCRIPT_FILE="/usr/local/bin/sync_time.sh"
LOG_FILE="/root/sync_time.log"

# 限制日志行数（保留最近 50 行）
limit_log_size() {
    if [[ -f "$LOG_FILE" ]]; then
        local lines
        lines=$(wc -l < "$LOG_FILE")
        if (( lines > 50 )); then
            tail -n 50 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

# 检查是否已安装
if [[ -f "$SERVICE_FILE" ]]; then
    if [[ -f "$TIMER_SERVICE_FILE" && -f "$TIMER_UNIT_FILE" ]]; then
        echo "=== 检测到已安装开机同步 + 定时器 ==="
        read -p "是否要卸载服务与定时器? (y/N): " choice
        case "$choice" in
            y|Y)
                echo "[1/5] 停止并禁用服务和定时器..."
                systemctl stop sync-time.timer sync-time.service sync-time-task.service
                systemctl disable sync-time.timer sync-time.service sync-time-task.service

                echo "[2/5] 删除服务、定时器和脚本..."
                rm -f "$SERVICE_FILE" "$TIMER_SERVICE_FILE" "$TIMER_UNIT_FILE" "$SCRIPT_FILE" "$LOG_FILE"

                echo "[3/5] 重新加载 systemd..."
                systemctl daemon-reload

                echo "✅ 卸载完成"
                exit 0
                ;;
            *)
                echo "❌ 已取消卸载"
                exit 0
                ;;
        esac
    else
        echo "⚠ 检测到缺少定时器配置"
        read -p "是否要修复添加定时器? (y/N): " fix_choice
        case "$fix_choice" in
            y|Y)
                echo "🔧 正在修复定时器..."
                # 创建定时器任务
                cat > "$TIMER_UNIT_FILE" <<EOF
[Unit]
Description=Sync Time to Beijing Time every 4 minutes

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF

                # 创建定时器配置
                cat > "$TIMER_SERVICE_FILE" <<EOF
[Unit]
Description=Run sync-time-task every 4 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=4min
Persistent=true

[Install]
WantedBy=timers.target
EOF

                systemctl daemon-reload
                systemctl enable sync-time.timer
                systemctl start sync-time.timer
                echo "✅ 定时器修复完成"
                exit 0
                ;;
            *)
                echo "❌ 已取消修复"
                exit 0
                ;;
        esac
    fi
fi

echo "=== 开始安装并设置开机自动同步北京时间 + 每4分钟定时同步 ==="

# 1. 安装 ntpdate
if ! command -v ntpdate >/dev/null 2>&1; then
    echo "[1/6] 正在安装 ntpdate..."
    apt update && apt install -y ntpdate
else
    echo "[1/6] ntpdate 已安装"
fi

# 2. 设置时区
echo "[2/6] 设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

# 3. 创建同步脚本
echo "[3/6] 创建同步脚本 $SCRIPT_FILE ..."
cat > "$SCRIPT_FILE" <<EOF
#!/bin/bash
# 同步北京时间脚本
sleep 10  # 延迟10秒，确保网络已连接
{
    echo "==== [\$(date '+%Y-%m-%d %H:%M:%S')] 同步北京时间 ===="
    /usr/sbin/ntpdate -u ntp.aliyun.com
} >> "$LOG_FILE" 2>&1

# 保留最近 50 行日志
if [[ -f "$LOG_FILE" ]]; then
    lines=\$(wc -l < "$LOG_FILE")
    if (( lines > 50 )); then
        tail -n 50 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi
EOF
chmod +x "$SCRIPT_FILE"

# 4. 创建开机服务
echo "[4/6] 创建 systemd 开机服务 $SERVICE_FILE ..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sync Time to Beijing Time at Startup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 5. 创建定时任务服务
cat > "$TIMER_UNIT_FILE" <<EOF
[Unit]
Description=Sync Time to Beijing Time every 4 minutes

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
EOF

# 6. 创建定时器
cat > "$TIMER_SERVICE_FILE" <<EOF
[Unit]
Description=Run sync-time-task every 4 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=4min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 启用并启动
systemctl daemon-reload
systemctl enable sync-time.service
systemctl start sync-time.service
systemctl enable sync-time.timer
systemctl start sync-time.timer

echo "=== 安装完成 ==="
date -R
