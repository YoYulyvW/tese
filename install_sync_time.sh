#!/bin/bash
# 一键安装并设置开机自动同步北京时间
# 适用于 Amlogic S9xxx Armbian

echo "=== 设置北京时间同步（Amlogic S9xxx Armbian） ==="

# 1. 安装 ntpdate
if ! command -v ntpdate >/dev/null 2>&1; then
    echo "[1/5] 正在安装 ntpdate..."
    apt update && apt install -y ntpdate
else
    echo "[1/5] ntpdate 已安装"
fi

# 2. 设置时区为 Asia/Shanghai
echo "[2/5] 设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

# 3. 创建同步脚本
echo "[3/5] 创建同步脚本 /usr/local/bin/sync_time.sh ..."
cat > /usr/local/bin/sync_time.sh << 'EOF'
#!/bin/bash
# 同步北京时间脚本
sleep 10  # 延迟10秒，确保网络已连接
/usr/sbin/ntpdate ntp.aliyun.com
EOF
chmod +x /usr/local/bin/sync_time.sh

# 4. 创建 systemd 服务
echo "[4/5] 创建 systemd 服务 /etc/systemd/system/sync-time.service ..."
cat > /etc/systemd/system/sync-time.service << 'EOF'
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

echo "=== 设置完成 ==="
date -R
