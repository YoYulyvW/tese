#!/bin/bash
# Auto SNAT Daemon
# 版本: 2.1

### 配置区 (用户可自定义) ###
SERVICE_NAME="auto-snatd"
SCRIPT_PATH="/usr/local/sbin/$SERVICE_NAME"
LOG_DIR="/root/snat_logs"  
LOG_FILE="$LOG_DIR/auto-snat.log"
TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
INTERVAL_MIN=4             # 默认4分钟检查一次
MAX_LOG_SIZE=1             # 日志轮转大小(MB)
MAX_LOG_FILES=3            # 保留的历史日志文件数

### 初始化设置 ###
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

### 增强日志函数 ###
log() {
    local level="INFO"
    [ -n "$2" ] && level="$1" && shift
    
    # 日志写入
    echo "$(date '+%F %T') - [$level] $1" >> "$LOG_FILE"
    
    # 控制台彩色输出
    if [ -t 1 ]; then
        case "$level" in
            ERROR) color="\033[31m" ;;
            WARN)  color="\033[33m" ;;
            INFO)  color="\033[32m" ;;
            *)     color="\033[0m"  ;;
        esac
        echo -e "${color}$(date '+%F %T') - [$level] $1\033[0m"
    fi
    
    # 日志轮转
    if [ $(stat -c%s "$LOG_FILE") -gt $((MAX_LOG_SIZE * 1024 * 1024)) ]; then
        for ((i=MAX_LOG_FILES-1; i>=1; i--)); do
            [ -f "$LOG_FILE.$i" ] && mv "$LOG_FILE.$i" "$LOG_FILE.$((i+1))"
        done
        mv "$LOG_FILE" "$LOG_FILE.1"
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE"
    fi
}

### 检查root权限 ###
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR" "必须使用root用户运行此脚本"
        exit 1
    fi
}

### 服务管理菜单 ###
service_menu() {
    echo -e "\n检测到已安装的服务: $SERVICE_NAME"
    echo "1. 卸载服务"
    echo "2. 重新安装"
    echo "3. 查看状态"
    echo "4. 查看日志"
    echo "5. 退出"
    
    read -p "请选择操作 [1-5]: " choice
    case $choice in
        1) uninstall_service ;;
        2) reinstall_service ;;
        3) show_status ;;
        4) show_logs ;;
        5) exit 0 ;;
        *) echo "无效选择"; exit 1 ;;
    esac
}

### 卸载服务 ###
uninstall_service() {
    systemctl stop "$SERVICE_NAME.timer" 2>/dev/null
    systemctl disable "$SERVICE_NAME.timer" 2>/dev/null
    rm -f "$SCRIPT_PATH" "$SERVICE_FILE" "$TIMER_FILE"
    systemctl daemon-reload
    log "INFO" "成功卸载 $SERVICE_NAME"
    exit 0
}

### 重新安装 ###
reinstall_service() {
    systemctl stop "$SERVICE_NAME.timer" 2>/dev/null
    log "INFO" "开始重新安装服务..."
}

### 显示状态 ###
show_status() {
    echo -e "\n服务状态:"
    systemctl status "$SERVICE_NAME.timer" --no-pager
    echo -e "\n最近执行:"
    systemctl list-timers | grep "$SERVICE_NAME"
    echo -e "\n当前SNAT规则:"
    iptables -t nat -L POSTROUTING -n --line-numbers | grep SNAT
    exit 0
}

### 查看日志 ###
show_logs() {
    echo -e "\n最近日志内容:"
    tail -n20 "$LOG_FILE"
    exit 0
}

### 生成守护脚本 ###
generate_daemon() {
    cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
# Auto SNAT Daemon 工作脚本

LOG_DIR="/root/snat_logs"
LOG_FILE="$LOG_DIR/auto-snat.log"

log() {
    local level="INFO"
    [ -n "$2" ] && level="$1" && shift
    echo "$(date '+%F %T') - [$level] $1" >> "$LOG_FILE"
}

get_network_info() {
    # 检查网络接口
    local errors=0
    if ! ip link show tunx >/dev/null 2>&1; then
        log "ERROR" "tunx 接口不存在"
        ((errors++))
    fi
    
    if ! ip link show eth0 >/dev/null 2>&1; then
        log "ERROR" "eth0 接口不存在"
        ((errors++))
    fi
    [ $errors -gt 0 ] && return 1

    # 获取IP信息
    TUNX_IP=$(ip -4 addr show tunx | grep -oP 'inet \K[\d.]+')
    if [ -z "$TUNX_IP" ]; then
        log "ERROR" "无法获取 tunx IP"
        return 1
    fi

    TUNX_NET="${TUNX_IP%.*}.0/24"
    ETH0_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    if [ -z "$ETH0_IP" ]; then
        log "ERROR" "无法获取 eth0 IP"
        return 1
    fi

    echo "$TUNX_NET $ETH0_IP"
}

delete_old_rules() {
    local tunx_net="$1"
    local rules=()
    mapfile -t rules < <(iptables -t nat -L POSTROUTING --line-numbers -n | \
                         awk -v net="$tunx_net" '$0 ~ "-s " net ".*-o eth0.*SNAT" {print $1}')
    
    # 反向删除确保编号正确
    for ((i=${#rules[@]}-1; i>=0; i--)); do
        iptables -t nat -D POSTROUTING "${rules[i]}"
        log "INFO" "删除旧规则 #${rules[i]}"
    done
}

update_snat() {
    local network_info
    if ! network_info=$(get_network_info); then
        return 1
    fi

    read -r TUNX_NET ETH0_IP <<< "$network_info"

    # 检查现有规则
    CURRENT_TARGET=$(iptables -t nat -S POSTROUTING | \
                    grep -m1 "^-A POSTROUTING -s $TUNX_NET -o eth0 -j SNAT" | \
                    grep -oP '(?<=--to-source )[\d.]+')

    if [ "$CURRENT_TARGET" = "$ETH0_IP" ]; then
        log "INFO" "SNAT规则已是最新 ($TUNX_NET -> $ETH0_IP)"
        return 0
    fi

    # 删除旧规则
    delete_old_rules "$TUNX_NET"

    # 添加新规则
    if iptables -t nat -A POSTROUTING -s "$TUNX_NET" -o eth0 -j SNAT --to-source "$ETH0_IP"; then
        log "INFO" "成功添加规则: $TUNX_NET -> $ETH0_IP"
        # 持久化规则
        if iptables-save > /etc/iptables/rules.v4; then
            log "INFO" "规则已持久化"
        else
            log "ERROR" "规则持久化失败"
            return 1
        fi
    else
        log "ERROR" "添加新规则失败"
        return 1
    fi
}

# 主执行
update_snat
EOF

    chmod 755 "$SCRIPT_PATH"
}

### 创建systemd服务 ###
setup_systemd() {
    # 服务单元
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Auto SNAT Daemon
After=network.target
ConditionPathExists=$SCRIPT_PATH

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    # 定时器单元
    cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run $SERVICE_NAME every $INTERVAL_MIN minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL_MIN}min
AccuracySec=1min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME.timer"
}

### 主安装流程 ###
main_install() {
    check_root
    
    # 检测现有服务
    if systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
        service_menu
    fi

    log "INFO" "开始安装 $SERVICE_NAME 服务"
    
    generate_daemon
    setup_systemd
    
    # 首次执行
    if "$SCRIPT_PATH"; then
        log "INFO" "服务安装完成并首次执行成功"
    else
        log "ERROR" "服务安装完成但首次执行失败"
    fi

    echo -e "\n\033[32m✔ 安装完成\033[0m"
    echo "服务名称: $SERVICE_NAME"
    echo "日志文件: $LOG_FILE"
    echo "执行间隔: $INTERVAL_MIN 分钟"
    echo "定时器状态: $(systemctl is-active "$SERVICE_NAME.timer")"
    echo -e "\n使用以下命令管理服务:"
    echo "systemctl status $SERVICE_NAME.timer"
    echo "journalctl -u $SERVICE_NAME"
    echo "tail -f $LOG_FILE"
}

### 执行主函数 ###
main_install
