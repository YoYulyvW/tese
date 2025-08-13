#!/bin/bash
# Amlogic S9xxx Armbian 自动添加 .250 静态IP 到 eth0

SERVICE_FILE="/etc/systemd/system/add-ip.service"
SCRIPT_FILE="/usr/local/bin/add_ip.sh"

# 检测是否已安装
if [[ -f "$SERVICE_FILE" ]]; then
    echo "=== 检测到已安装开机自动添加IP服务 ==="
    read -p "是否要卸载这个服务? (y/N): " choice
    case "$choice" in
        y|Y)
            systemctl stop add-ip.service
            systemctl disable add-ip.service
            rm -f "$SERVICE_FILE" "$SCRIPT_FILE"
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

echo "=== 开始安装开机自动添加 .250 静态IP 服务 ==="

# 创建执行脚本
cat > "$SCRIPT_FILE" << 'EOF'
#!/bin/bash
# 延迟 5 秒，确保网络接口已获取到 DHCP 地址
sleep 5

# 获取 eth0 的 IPv4 地址
IP=$(ip -4 addr show dev eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

if [[ -n "$IP" ]]; then
    NET_PREFIX=$(echo "$IP" | awk -F. '{print $1"."$2"."$3}')
    NEW_IP="${NET_PREFIX}.250"

    # 检查是否已经存在
    if ! ip addr show dev eth0 | grep -q "$NEW_IP"; then
        ip addr add "$NEW_IP/24" dev eth0
        echo "$(date): 已为 eth0 添加 IP $NEW_IP"
    else
        echo "$(date): IP $NEW_IP 已存在"
    fi
else
    echo "$(date): 未能获取到 eth0 的 DHCP IP"
fi
EOF
chmod +x "$SCRIPT_FILE"

# 创建 systemd 服务
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Add extra .250 IP to eth0 after DHCP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 启用并运行
systemctl daemon-reload
systemctl enable add-ip.service
systemctl start add-ip.service

echo "=== 安装完成，当前 eth0 IP 列表 ==="
ip addr show dev eth0
