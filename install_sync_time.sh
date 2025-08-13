#!/bin/bash
# Amlogic S9xxx Armbian 北京时间自动同步管理脚本
# 首次运行：安装并启用开机同步
# 后续运行：可选择卸载

SERVICE_FILE="/etc/systemd/system/sync-time.service"
SCRIPT_FILE="/usr/local/bin/sync_time.sh"

# 检测是否已安装
if [[ -f "$SERVICE_FILE" ]]; then
    echo "=== 检测到已安装开机时间同步服务 ==="
    read -p "是否要卸载这个服务? (y/N): " choice
    case "$choice" in
        y|Y)
            echo "[1/3] 停止并禁用服务..."
            systemctl stop sync-time.service
            systemctl disable sync-time.service

            echo "[2/3] 删除服务文件和脚本..."
            rm -f "$SERVICE_FILE" "$SCRIPT_FILE"

            echo "[3/3] 重新加载 systemd..."
            systemctl daemon-reload

            echo "✅ 卸载完成"
            exit 0
            ;;
        *)
            echo "❌ 已取消卸载"
            exit 0
            ;;
    esac
fi

echo "=== 开始安装并设置开机自动同步北京时间 ==="

# 1. 安装 ntpdate
if ! command -v ntpdate >/dev/null 2>&1; then
    echo "[1/5] 正在安装 ntpdate..."
    apt update && apt install -y ntpdate
else
    echo "[1/5] ntpdate 已安装"
fi

# 2. 设置时区
echo "[2/5] 设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

# 3. 创建同步脚本
echo "[3/5] 创建同步脚本 $SCRIPT_FILE ..."
cat > "$SCRIPT_FILE" << 'EOF'
#!/bin/bash
# 同步北京时间脚本
sleep 10  # 延迟10秒，确保网络已连接
/usr/sbin/ntpdate ntp.aliyun.com
EOF
chmod +x "$SCRIPT_FILE"

# 4. 创建 systemd 服务
echo "[4/5] 创建 systemd 服务 $SERVICE_FILE ..."
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Sync Time to Beijing Time at Startup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync_time.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 5. 启用并立即运行
echo "[5/5] 启用并运行时间同步服务..."
systemctl daemon-reload
systemctl enable sync-time.service
systemctl start sync-time.service

echo "=== 安装完成 ==="
date -R
