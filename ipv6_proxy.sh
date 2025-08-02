#!/bin/bash

# 脚本版本
VERSION="4.1.0-full"

# 配置文件
CONFIG_FILE="/etc/l2tp_ipv6_proxy.conf"
DOMAIN_WHITELIST="/etc/ipv6_whitelist.domains"
IPSET_SCRIPT="/usr/local/bin/update_ipv6_rules"

# 默认白名单(可修改)
DEFAULT_DOMAINS=(
    "*.lyvw.top"
    "*.lyvw.com"
)

## 颜色定义 ##
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查root权限
check_root() {
    [ "$(id -u)" -ne 0 ] && { echo -e "${RED}请使用root用户运行!${NC}"; exit 1; }
}

# 安装DNS和路由组件
install_dnsmasq() {
    apt install -y dnsmasq ipset
    
    # 配置DNS64
    cat > /etc/dnsmasq.conf <<EOF
listen-address=127.0.0.1,${VPN_IPV4_LOCAL}
server=8.8.8.8
server=8.8.4.4
proxy-dnssec
dns64-prefix=64:ff9b::/96
dns64
EOF

    # 初始化白名单文件
    printf "%s\n" "${DEFAULT_DOMAINS[@]}" > $DOMAIN_WHITELIST
    
    systemctl restart dnsmasq
    systemctl enable dnsmasq
}

# 生成IPset更新脚本
generate_ipset_script() {
    cat > $IPSET_SCRIPT <<'EOF'
#!/bin/bash

DOMAIN_WHITELIST="/etc/ipv6_whitelist.domains"
IPSET_NAME="IPV6_WHITELIST"

# 检查是否是全局模式
if grep -q "^\\*$" $DOMAIN_WHITELIST; then
    # 全局模式 - 标记所有流量
    iptables -t mangle -F FORCE_IPV6
    iptables -t mangle -A FORCE_IPV6 -j MARK --set-mark 0x1
    echo "全局模式: 所有流量将强制IPv6出口"
    exit 0
fi

# 创建临时文件
TMP_FILE=$(mktemp)

# 处理每个域名
while read -r domain; do
    [ -z "$domain" ] || [[ "$domain" == \#* ]] && continue
    
    # 查询IPv6地址
    dig +short AAAA "$domain" | grep ':' >> $TMP_FILE
    
    # 通过DNS64生成合成IPv6
    for ipv4 in $(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); do
        printf "64:ff9b::%02x%02x:%02x%02x\n" ${ipv4//./ }
    done >> $TMP_FILE
done < $DOMAIN_WHITELIST

# 更新IPset
ipset create $IPSET_NAME hash:net family inet6 timeout 86400 2>/dev/null || true
ipset flush $IPSET_NAME

# 添加新记录(去重)
sort -u $TMP_FILE | while read ip; do
    ipset add $IPSET_NAME "$ip"
done

# 更新iptables规则
iptables -t mangle -F FORCE_IPV6
iptables -t mangle -A FORCE_IPV6 -m set --match-set $IPSET_NAME dst -j MARK --set-mark 0x1

rm -f $TMP_FILE
EOF

    chmod +x $IPSET_SCRIPT
}

# 配置网络路由规则
configure_network_rules() {
    # 创建mangle表链
    iptables -t mangle -N FORCE_IPV6 2>/dev/null || true
    
    # 创建单独的路由表
    grep -q "ipv6_whitelist" /etc/iproute2/rt_tables || \
        echo "100 ipv6_whitelist" >> /etc/iproute2/rt_tables
    
    # 策略路由规则
    ip -6 rule del fwmark 0x1 2>/dev/null || true
    ip -6 rule add fwmark 0x1 lookup ipv6_whitelist
    
    # 默认路由(替换fe80::1为实际IPv6网关)
    IPV6_GATEWAY=$(ip -6 route show default | awk '{print $3}' | head -n1)
    ip -6 route replace default via $IPV6_GATEWAY table ipv6_whitelist
    
    # 初始更新规则
    $IPSET_SCRIPT
    
    # 定时任务
    echo "*/5 * * * * root $IPSET_SCRIPT" > /etc/cron.d/ipv6_whitelist_update
}

# 域名白名单管理
manage_domains() {
    while true; do
        clear
        echo -e "${GREEN}=== 域名白名单管理 ===${NC}"
        echo -e "当前模式: $([ -f "$DOMAIN_WHITELIST" ] && grep -q "^\\*$" "$DOMAIN_WHITELIST" && echo "全局IPv6模式" || echo "白名单模式")"
        echo -e "\n当前白名单域名:"
        grep -v '^#' "$DOMAIN_WHITELIST" 2>/dev/null || echo "无"
        
        echo -e "\n操作选项:"
        echo "1. 添加域名(支持通配符如 *.example.com)"
        echo "2. 删除域名"
        echo "3. 启用全局IPv6模式(所有流量)"
        echo "4. 禁用全局IPv6模式"
        echo "5. 返回主菜单"
        
        read -p "请选择[1-5]: " choice
        case $choice in
            1)
                read -p "输入要添加的域名: " domain
                echo "$domain" >> $DOMAIN_WHITELIST
                $IPSET_SCRIPT
                ;;
            2)
                read -p "输入要删除的域名: " domain
                sed -i "/^${domain//./\\.}$/d" $DOMAIN_WHITELIST
                $IPSET_SCRIPT
                ;;
            3)
                echo "*" > $DOMAIN_WHITELIST
                $IPSET_SCRIPT
                echo -e "${GREEN}已启用全局IPv6模式!${NC}"
                sleep 2
                ;;
            4)
                printf "%s\n" "${DEFAULT_DOMAINS[@]}" > $DOMAIN_WHITELIST
                $IPSET_SCRIPT
                echo -e "${GREEN}已禁用全局IPv6模式!${NC}"
                sleep 2
                ;;
            5)
                return
                ;;
            *)
                echo -e "${RED}无效选择!${NC}"
                sleep 1
                ;;
        esac
    done
}

# 主安装流程
install_service() {
    check_root
    
    echo -e "${GREEN}=== 开始安装智能IPv6出口服务 ===${NC}"
    
    # 安装必要组件
    apt update
    apt install -y dnsmasq ipset iptables-persistent
    
    # 配置DNS
    install_dnsmasq
    
    # 生成IPset脚本
    generate_ipset_script
    
    # 配置网络规则
    configure_network_rules
    
    # 保存配置
    echo "DOMAIN_WHITELIST_ENABLED=1" >> $CONFIG_FILE
    
    echo -e "${GREEN}安装完成!${NC}"
    echo -e "当前模式: $([ -f "$DOMAIN_WHITELIST" ] && grep -q "^\\*$" "$DOMAIN_WHITELIST" && echo "全局IPv6模式" || echo "白名单模式")"
}

# 卸载服务
uninstall_service() {
    check_root
    
    echo -e "${YELLOW}=== 开始卸载服务 ===${NC}"
    
    # 清除iptables规则
    iptables -t mangle -F FORCE_IPV6 2>/dev/null || true
    iptables -t mangle -X FORCE_IPV6 2>/dev/null || true
    
    # 清除IPset
    ipset destroy IPV6_WHITELIST 2>/dev/null || true
    
    # 清除路由规则
    ip -6 rule del fwmark 0x1 2>/dev/null || true
    
    # 删除定时任务
    rm -f /etc/cron.d/ipv6_whitelist_update
    
    # 恢复DNS配置
    apt purge -y dnsmasq ipset
    rm -f $DOMAIN_WHITELIST $IPSET_SCRIPT
    
    echo -e "${GREEN}卸载完成!${NC}"
}

# 显示状态
show_status() {
    echo -e "${GREEN}=== 服务状态 ===${NC}"
    
    # 检查运行状态
    echo -e "DNS服务: $(systemctl is-active dnsmasq)"
    echo -e "IPset规则: $(ipset list IPV6_WHITELIST 2>/dev/null | grep -c '^[0-9]') 条"
    
    # 显示当前模式
    if [ -f "$DOMAIN_WHITELIST" ] && grep -q "^\\*$" "$DOMAIN_WHITELIST"; then
        echo -e "当前模式: ${RED}全局IPv6模式(所有流量)${NC}"
    else
        echo -e "当前模式: ${GREEN}白名单模式${NC}"
        echo -e "白名单域名:"
        grep -v '^#' "$DOMAIN_WHITELIST" 2>/dev/null || echo "无"
    fi
    
    # 显示路由规则
    echo -e "\n${YELLOW}=== 路由规则 ===${NC}"
    ip -6 rule show | grep "lookup ipv6_whitelist"
    ip -6 route show table ipv6_whitelist
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=== 智能IPv6出口管理 v$VERSION ===${NC}"
        echo
        echo "1. 安装服务"
        echo "2. 卸载服务"
        echo "3. 查看状态"
        echo "4. 管理域名白名单"
        echo "5. 退出"
        echo
        
        # 检查是否已安装
        if [ -f "$CONFIG_FILE" ]; then
            echo -e "当前状态: ${GREEN}已安装${NC}"
        else
            echo -e "当前状态: ${YELLOW}未安装${NC}"
        fi
        
        read -p "请选择[1-5]: " OPTION
        
        case $OPTION in
            1)
                install_service
                ;;
            2)
                uninstall_service
                ;;
            3)
                show_status
                ;;
            4)
                manage_domains
                ;;
            5)
                echo -e "${GREEN}退出脚本${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项!${NC}"
                ;;
        esac
        
        read -p "按Enter键继续..."
    done
}

# 启动脚本
main_menu
