#!/bin/bash
# 内网PPTP/Squid代理管理系统 - 多IP优化版
# 版本: 2.1
# 最后更新: 2023-10-16

# 配置常量
CONFIG_DIR="/etc/pptp_squid_proxy"
PORT_BASE=10000
MAX_INSTANCES=200
SQUID_CONF="/etc/squid/squid.conf"
LOG_FILE="/var/log/pptp_manager.log"
LOCAL_IPS=($(ip -o addr show | awk '!/^[0-9]+: lo|inet6/ {gsub(/\/.*/, "", $4); print $4}'))

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
    log "INFO" "检测到本地IP地址: ${LOCAL_IPS[*]}"
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
        "/etc/ppp"
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
            # 检查端口是否被系统占用
            if ! ss -tuln | grep -q ":${port} "; then
                echo "$port"
                return 0
            else
                log "WARNING" "端口 $port 已被系统占用，跳过"
            fi
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

    # 优先使用Squid配置中的IP对
    while IFS= read -r line; do
        read -r v4ip v6ip <<< "$line"
        if [ -z "${used_ips[$v4ip]}" ]; then
            echo "$v4ip $v6ip"
            return 0
        fi
    done < <(get_all_ip_pairs 2>/dev/null)

    # 如果没有Squid配置的IP，则使用本地IP
    for ip in "${LOCAL_IPS[@]}"; do
        if [ -z "${used_ips[$ip]}" ]; then
            echo "$ip"
            return 0
        fi
    done
    
    log "ERROR" "无可用IP地址"
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
    local username=$(awk -F= '/^username/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local password=$(awk -F= '/^password/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")

    # PPTP配置
    cat > "/etc/pptpd/${instance_id}.conf" <<EOF
option /etc/ppp/options.pptpd.${instance_id}
localip ${v4ip}
remoteip ${v4ip%.*}.$((${v4ip##*.}+1))-${v4ip%.*}.$((${v4ip##*.}+5))
listen ${v4ip}
port ${port}
EOF

    # PPP选项
    cat > "/etc/ppp/options.pptpd.${instance_id}" <<EOF
name ${instance_id}
require-mschap-v2
proxyarp
lock
nobsdcomp
novj
novjccomp
nologfd
ms-dns 8.8.8.8
mtu 1200
mru 1200
EOF

    # 认证信息
    echo "${username} * ${password} *" >> "/etc/ppp/chap-secrets"

    # 防火墙规则
    for ip in "${LOCAL_IPS[@]}"; do
        iptables -A INPUT -d ${ip} -p tcp --dport ${port} -j ACCEPT
        iptables -A INPUT -d ${ip} -p gre -j ACCEPT
        iptables -t nat -A PREROUTING -d ${ip} -p tcp -j REDIRECT --to-port 3128
    done
    iptables-save > /etc/iptables/rules.v4

    # 重启服务
    systemctl restart pptpd 2>/dev/null
    
    log "SUCCESS" "实例 $instance_id 配置应用成功"
}

# 创建VPN实例
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
    local password=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 12)
    local username="vpnuser_${instance_id}"

    log "INFO" "正在创建实例 $instance_id..."
    
    cat > "$config_file" <<EOF
[config]
port = ${port}
v4ip = ${v4ip}
v6ip = ${v6ip}
username = ${username}
password = ${password}
status = active
created = $(date +%Y-%m-%d)
EOF

    apply_instance_config "$instance_id"
    
    log "SUCCESS" "实例创建成功: $instance_id"
    echo -e "${GREEN}实例创建成功:${NC}"
    echo -e "ID: ${GREEN}${instance_id}${NC}"
    echo -e "PPTP端口: ${GREEN}${port}${NC}"
    echo -e "绑定IPv4: ${GREEN}${v4ip}${NC}"
    [ -n "$v6ip" ] && echo -e "绑定IPv6: ${GREEN}${v6ip}${NC}"
    echo -e "用户名: ${GREEN}${username}${NC}"
    echo -e "密码: ${GREEN}${password}${NC}"
}

# 删除实例
delete_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && {
        log "ERROR" "实例 $instance_id 不存在"
        return 1
    }

    log "INFO" "正在删除实例 $instance_id..."
    
    local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")
    local username=$(awk -F= '/^username/ {gsub(/[[:space:]]/, "", $2); print $2}' "$config_file")

    # 清理配置
    rm -f "/etc/pptpd/${instance_id}.conf"
    rm -f "/etc/ppp/options.pptpd.${instance_id}"
    rm -f "$config_file"
    
    # 从认证文件删除
    sed -i "/^${username} /d" "/etc/ppp/chap-secrets"
    
    # 清理防火墙规则
    for ip in "${LOCAL_IPS[@]}"; do
        iptables -D INPUT -d ${ip} -p tcp --dport ${port} -j ACCEPT 2>/dev/null
        iptables -D INPUT -d ${ip} -p gre -j ACCEPT 2>/dev/null
    done
    iptables-save > /etc/iptables/rules.v4
    
    log "SUCCESS" "实例 $instance_id 已删除"
    echo -e "${GREEN}实例 $instance_id 已成功删除${NC}"
}

# 列出所有实例
list_instances() {
    shopt -s nullglob
    local instances=("${CONFIG_DIR}"/instances/*.conf)
    shopt -u nullglob

    if [ ${#instances[@]} -eq 0 ]; then
        log "INFO" "没有找到任何实例"
        echo -e "${YELLOW}没有找到任何实例${NC}"
        return
    fi

    log "INFO" "列出所有实例 (共 ${#instances[@]} 个)"
    echo -e "${GREEN}已创建实例列表 (共 ${#instances[@]} 个):${NC}"
    printf "%-10s %-15s %-10s %-20s %-15s\n" "ID" "IPv4" "端口" "创建时间" "状态"
    echo "==================================================================="
    
    for conf in "${instances[@]}"; do
        local id=$(basename "$conf" .conf)
        local v4ip=$(awk -F= '/^v4ip/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        local port=$(awk -F= '/^port/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        local created=$(awk -F= '/^created/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        local status=$(awk -F= '/^status/ {gsub(/[[:space:]]/, "", $2); print $2}' "$conf")
        
        printf "%-10s %-15s %-10s %-20s %-15s\n" "$id" "$v4ip" "$port" "$created" "$status"
    done
}

# 显示实例详情
show_instance() {
    local instance_id=$1
    local config_file="${CONFIG_DIR}/instances/${instance_id}.conf"
    
    [ ! -f "$config_file" ] && {
        log "ERROR" "实例 $instance_id 不存在"
        echo -e "${RED}实例 $instance_id 不存在${NC}"
        return 1
    }
    
    log "INFO" "显示实例详情: $instance_id"
    echo -e "${GREEN}实例 ${instance_id} 详情:${NC}"
    echo "========================================"
    awk -F= '/^\[config\]/ {next} {gsub(/[[:space:]]/, "", $1); 
    printf "%-10s: %s\n", $1, $2}' "$config_file"
    echo "========================================"
}

# 显示主菜单
show_menu() {
    clear
    echo -e "${GREEN}内网PPTP/Squid代理管理系统${NC}"
    echo -e "版本: ${BLUE}2.1${NC}"
    echo -e "服务器IP: ${BLUE}${LOCAL_IPS[*]}${NC}"
    echo "----------------------------------------"
    echo "1. 创建新VPN实例"
    echo "2. 列出所有实例"
    echo "3. 删除实例"
    echo "4. 查看实例详情"
    echo "5. 查看系统日志"
    echo "6. 退出"
    echo "----------------------------------------"
}

# 主程序
main() {
    # 检查root权限
    [ "$(id -u)" != "0" ] && {
        echo -e "${RED}错误: 需要root权限运行此脚本${NC}"
        exit 1
    }

    # 初始化
    init_log
    init_config_dir

    # 检查PPTPD是否安装
    if ! command -v pptpd >/dev/null 2>&1; then
        log "ERROR" "PPTPD服务未安装"
        echo -e "${RED}错误: PPTPD服务未安装${NC}"
        echo -e "请先安装PPTPD服务:"
        echo -e "Ubuntu/Debian: apt-get install pptpd"
        echo -e "CentOS/RHEL: yum install pptpd"
        exit 1
    fi

    # 主循环
    while true; do
        show_menu
        read -p "请选择操作[1-6]: " choice
        
        case $choice in
            1)
                read -p "输入实例ID (数字或字母组合): " instance_id
                if [[ ! "$instance_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    echo -e "${RED}无效的实例ID，只能包含字母、数字、下划线和连字符${NC}"
                    read -p "按Enter继续..."
                    continue
                fi
                create_instance "$instance_id"
                ;;
            2) list_instances ;;
            3)
                list_instances
                if [ $? -eq 0 ]; then
                    read -p "输入要删除的实例ID: " instance_id
                    delete_instance "$instance_id"
                fi
                ;;
            4)
                list_instances
                if [ $? -eq 0 ]; then
                    read -p "输入要查看的实例ID: " instance_id
                    show_instance "$instance_id"
                fi
                ;;
            5)
                echo -e "${GREEN}显示最后20条系统日志:${NC}"
                tail -n 20 "$LOG_FILE"
                ;;
            6) 
                log "INFO" "用户退出系统"
                echo -e "${GREEN}退出系统${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
        
        read -p "按Enter继续..."
    done
}

# 启动主程序
main "$@"
