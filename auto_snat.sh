#!/bin/bash
# auto-snatd 安装/更新/卸载脚本（修正版，SNAT 仅在目标 IP 变化时更新）

SERVICE_NAME="auto-snatd"
INSTALL_DIR="/usr/local/sbin"
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"
MAX_LOG_LINES=50
TIMER_INTERVAL="4min"

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请用 root 运行"
    exit 1
fi

# 非首次安装判断
if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] || systemctl list-timers --all | grep -q "$SERVICE_NAME.timer"; then
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

# SNAT 更新脚本
cat > "$INSTALL_DIR/$SERVICE_NAME" <<'EOF'
#!/bin/bash
LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"
MAX_LOG_LINES=50

log() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR"
    [ -f "$LOG_FILE" ] || touch "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    if [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

check_network() {
    ip -4 addr show eth0 &>/dev/null || { log "[错误] eth0 接口不存在"; return 1; }
    ip -4 addr show tunx &>/dev/null || { log "[错误] tunx 接口不存在"; return 1; }
    return 0
}

update_snat() {
    # 获取 tunx 网络
    TUNX_INFO=$(ip -4 addr show tunx | grep -oP 'inet \K[\d./]+')
    [ -z "$TUNX_INFO" ] && { log "[错误] tunx IP 获取失败"; return 1; }
    IFS='/' read -r TUNX_IP TUNX_CIDR <<< "$TUNX_INFO"

    # 计算源网段
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$TUNX_IP"
    MASK=$((0xffffffff << (32 - TUNX_CIDR) & 0xffffffff))
    NETWORK="$((ip1 & (MASK >> 24))).$((ip2 & (MASK >> 16 & 0xff))).$((ip3 & (MASK >> 8 & 0xff))).$((ip4 & (MASK & 0xff)))"
    SOURCE_NET="$NETWORK/$TUNX_CIDR"

    # 获取 eth0 主 IP（忽略 secondary IP）
    ETH0_IP=$(ip -4 addr show eth0 | awk '/inet / && $2 !~ /127/ {print $2; exit}' | cut -d/ -f1)
    [ -z "$ETH0_IP" ] && { log "[错误] 获取 eth0 主 IP 失败"; return 1; }

    # 检查现有规则是否已经存在目标 IP
    EXISTING=$(iptables -t nat -L POSTROUTING -n --line-numbers | awk -v src="$SOURCE_NET" -v target="$ETH0_IP" \
        '$1=="SNAT" && $4==src && $10==target {found=1} END{if(found) exit 0; else exit 1}')
    if [ $? -eq 0 ]; then
        log "[信息] SNAT 规则已是最新 (目标IP: $ETH0_IP)"
        return 0
    fi

    # 删除旧规则
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -P "\-s $SOURCE_NET .* -o eth0 .* -j SNAT" \
        | while read -r RULE; do
            RULE_DELETE=$(echo "$RULE" | sed 's/^-A /-D /')
            iptables -t nat $RULE_DELETE
        done

    # 添加新规则
    iptables -t nat -A POSTROUTING -s "$SOURCE_NET" -o eth0 -j SNAT --to-source "$ETH0_IP"
    log "[操作] 更新 SNAT 规则: $SOURCE_NET → $ETH0_IP"

    # 持久化
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

# systemd 服务
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

# 安装完成后立即执行一次 SNAT 更新
echo "➡ 立即执行一次 SNAT 检查/更新..."
systemctl start "$SERVICE_NAME.service"
sleep 1

# 获取当前 SNAT 规则目标 IP
ETH0_IP=$(ip -4 addr show eth0 | awk '/inet / && $2 !~ /127/ {print $2; exit}' | cut -d/ -f1)
CURRENT_IP=$(iptables -t nat -S POSTROUTING 2>/dev/null \
    | grep -m1 -P "\-o eth0 .* -j SNAT" \
    | sed -n 's/.*--to-source \([0-9.]\+\).*/\1/p')
[ -z "$CURRENT_IP" ] && CURRENT_IP="$ETH0_IP"

echo -e "\n✔ 安装完成并已立即执行一次 SNAT 更新"
echo "服务名称: $SERVICE_NAME"
echo "日志目录: $LOG_DIR"
echo "执行间隔: $TIMER_INTERVAL"
echo "当前 SNAT 目标 IP: $CURRENT_IP"
echo "卸载/更新：重新运行本安装脚本"
echo -e "\n当前定时器状态:"
systemctl list-timers | grep "$SERVICE_NAME"
