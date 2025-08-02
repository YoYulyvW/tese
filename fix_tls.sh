#!/bin/bash
# OpenVPN终极修复脚本（兼容2.5.1）
# 版本：7.1

OVPN_DIR="/etc/openvpn"
CLIENT_DIR="$OVPN_DIR/client-configs"
LOG_FILE="/var/log/vpnadmin.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 记录日志
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 修复tls-crypt密钥
fix_tls_key() {
    log "${GREEN}正在更新tls-crypt密钥...${NC}"
    
    # 生成新密钥（兼容写法）
    if ! openvpn --genkey secret "$OVPN_DIR/tls-crypt.key"; then
        log "${RED}密钥生成失败，尝试旧语法...${NC}"
        openvpn --genkey --secret "$OVPN_DIR/tls-crypt.key" || {
            log "${RED}密钥生成彻底失败${NC}"
            exit 1
        }
    fi
    
    chmod 600 "$OVPN_DIR/tls-crypt.key"

    # 使用awk安全更新客户端配置
    for conf in "$CLIENT_DIR"/*.ovpn; do
        [ -f "$conf" ] || continue
        
        awk -v newkey="$(cat $OVPN_DIR/tls-crypt.key)" '
            BEGIN { RS="\n"; ORS="\n"; in_tls=0 }
            /<tls-crypt>/ { in_tls=1; print; next }
            /<\/tls-crypt>/ { in_tls=0; print newkey; print; next }
            !in_tls { print }
        ' "$conf" > "$conf.tmp" && mv "$conf.tmp" "$conf"
        
        log "已更新: $conf"
    done
}

# 优化MTU设置
optimize_mtu() {
    log "${GREEN}配置MTU优化...${NC}"
    
    # 清理旧配置
    sed -i '/^mssfix/d; /^fragment/d' "$OVPN_DIR/server.conf"
    
    # 添加新配置
    cat >> "$OVPN_DIR/server.conf" <<EOF
mssfix 1200
fragment 1300
EOF

    # 更新客户端配置
    for conf in "$CLIENT_DIR"/*.ovpn; do
        [ -f "$conf" ] || continue
        grep -q "mssfix" "$conf" || echo "mssfix 1200" >> "$conf"
    done
}

# 新版配置验证方法
verify_config() {
    log "${GREEN}验证服务器配置...${NC}"
    
    # 2.5.1版本使用--test已弃用，改用语法检查
    if ! openvpn --config "$OVPN_DIR/server.conf" --verb 3 --show-valid-subnets; then
        log "${RED}配置语法检查失败${NC}"
        exit 1
    fi
    
    # 额外检查密钥有效性
    if ! grep -q "BEGIN OpenVPN Static key" "$OVPN_DIR/tls-crypt.key"; then
        log "${RED}tls-crypt密钥格式错误${NC}"
        exit 1
    fi
}

# 防火墙检查
check_firewall() {
    if ! ufw status | grep -q "1194/udp.*ALLOW"; then
        log "${YELLOW}警告：防火墙未放行1194/udp端口${NC}"
        echo -e "执行以下命令开放端口："
        echo -e "  ${YELLOW}sudo ufw allow 1194/udp${NC}"
        echo -e "  ${YELLOW}sudo ufw enable${NC}"
    fi
}

main() {
    fix_tls_key
    optimize_mtu
    systemctl restart openvpn@server
    verify_config
    check_firewall
    
    log "${GREEN}修复完成！请执行：${NC}"
    echo -e "1. 重新分发所有客户端配置"
    echo -e "2. 客户端执行：${YELLOW}sudo systemctl restart openvpn-client@config${NC}"
    echo -e "3. 服务端日志监控：${YELLOW}journalctl -u openvpn@server -f${NC}"
}

main
