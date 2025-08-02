#!/bin/bash
# 智能PPTP/Squid代理管理系统 - 完全修正版
# 版本: 2.0
# 最后更新: 2023-10-15

# 配置常量
CONFIG_DIR="/etc/pptp_squid_proxy"
PORT_BASE=10000
MAX_INSTANCES=200
SQUID_CONF="/etc/squid/squid.conf"
LOG_FILE="/var/log/pptp_manager.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 初始化日志
init_log() {
    touch "$LOG_FILE" || {
        echo -e "${RED}无法创建日志文件 $LOG_FILE${NC}"
        exit 1
    }
    chmod 640 "$LOG_FILE"
    echo -e "\n\n=== 会话开始于 $(date) ===" >> "$LOG_FILE"
}

# 记录日志
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO") color="$BLUE" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "[$timestamp] [$level] $message" >> "$LOG_FILE"
    echo -e "${color}[$timestamp] $message${NC}" >&2
}

# 初始化配置目录
init_config_dir() {
    log "INFO" "初始化配置目录..."
    
    local dirs=(
        "${CONFIG_DIR}/instances"
        "/etc/pptpd"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log "ERROR" "无法创建目录 $dir"
            exit 1
        }
    done
    
    touch "/etc/ppp/chap-secrets" || {
        log "ERROR" "无法创建chap-secrets文件"
        exit 1
    }
    
    chmod 600 "/etc/ppp/chap-secrets"
    log "SUCCESS" "配置目录初始化完成"
}

# 获取可用端口
get_available_port() {
    local used_ports=()
    shopt -s nullglob
    
    for conf in "${CONFIG_DIR}"/instances/*.conf; do
        local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        used_ports+=("$port")
    done
    shopt -u nullglob

    for (( port=PORT_BASE; port<PORT_BASE+MAX_INSTANCES; port++ )); do
        if ! [[ " ${used_ports[*]} " =~ " $port " ]]; then
            echo "$port"
            return 0
        fi
    done
    
    log "ERROR" "无可用端口 (范围: $PORT_BASE-$((PORT_BASE+MAX_INSTANCES-1)))"
    echo ""
    return 1
}

# 获取可用IP对
get_available_ip_pair() {
    declare -A used_ips
    shopt -s nullglob
    
    for conf in "${CONFIG_DIR}"/instances/*.conf; do
        local used_ip=$(awk -F= '/^v4ip/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        used_ips["$used_ip"]=1
    done
    shopt -u nullglob

    while IFS= read -r line; do
        read -r v4ip v6ip <<< "$line"
        if [ -z "${used_ips[$v4ip]}" ]; then
            echo "$v4ip $v6ip"
            return 0
        fi
    done < <(get_all_ip_pairs)
    
    log "ERROR" "无可用IP对"
    echo ""
    return 1
}

# 应用实例配置
apply_instance_config() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && {
        log "ERROR" "实例配置文件不存在: $config_file"
        return 1
    }

    log "INFO" "正在应用实例 $instance_id 的配置..."
    
    local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local v4ip=$(awk -F= '/^v4ip/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local psk=$(awk -F= '/^psk/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local username=$(awk -F= '/^username/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local password=$(awk -F= '/^password/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")

    # PPTP配置
    cat > "/etc/pptpd.conf" <<EOF
# PPTP 配置
option /etc/ppp/options.pptpd
# 监听端口配置
localip ${v4ip}
remoteip ${v4ip%.*}.$((${v4ip##*.}+1))-${v4ip%.*}.$((${v4ip##*.}+5))
EOF

    # PPP选项
    cat > "/etc/ppp/options.pptpd" <<EOF
name pptpd
refuse-pap
refuse-chap
refuse-mschap
require-mschap-v2
ms-dns 8.8.8.8
mtu 1200
mru 1200
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF

    # 认证信息
    echo "${username} * ${password} *" >> "/etc/ppp/chap-secrets"
    
    # 防火墙规则
    iptables -A INPUT -p tcp --dport ${port} -j ACCEPT
    iptables-save > /etc/iptables/rules.v4

    # 启动PPTP服务
    systemctl restart pptpd 2>/dev/null
    
    log "SUCCESS" "实例 $instance_id 配置应用成功"
}

# 创建PPTP实例
create_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ -f "$config_file" ] && {
        log "ERROR" "实例 $instance_id 已存在"
        return 1
    }

    local port=$(get_available_port)
    [ -z "$port" ] && return 1

    local ip_pair=$(get_available_ip_pair)
    [ -z "$ip_pair" ] && return 1

    read -r v4ip v6ip <<< "$ip_pair"
    local psk=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16)
    local password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12)
    local username="vpnuser_${instance_id}"

    log "INFO" "正在创建实例 $instance_id..."
    
    cat > "$config_file" <<EOF
[config]
port = ${port}
v4ip = ${v4ip}
v6ip = ${v6ip}
psk = ${psk}
username = ${username}
password = ${password}
EOF

    log "SUCCESS" "实例 $instance_id 创建成功"

    # 自动应用配置
    apply_instance_config "$instance_id"
}

# 主程序
main() {
    init_log
    init_config_dir
    create_instance 1
}

main
