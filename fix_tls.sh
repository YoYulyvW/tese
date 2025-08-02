#!/bin/bash
# OpenVPN终极修复脚本（兼容2.5+）
# 版本：7.0

OVPN_DIR="/etc/openvpn"
CLIENT_DIR="$OVPN_DIR/client-configs"
LOG_FILE="/var/log/vpnadmin.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 记录日志
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# 修复tls-crypt密钥
fix_tls_key() {
    log "${GREEN}正在更新tls-crypt密钥...${NC}"
    
    # 新版本兼容写法
    openvpn --genkey secret "$OVPN_DIR/tls-crypt.key" || {
        log "${RED}密钥生成失败${NC}"
        exit 1
    }
    chmod 600 "$OVPN_DIR/tls-crypt.key"

    # 安全更新客户端配置
    tmpfile=$(mktemp)
    for conf in "$CLIENT_DIR"/*.ovpn; do
        [ -f "$conf" ] || continue
        
        awk -v key="$(cat $OVPN_DIR/tls-crypt.key)" '
            /<tls-crypt>/{print; skip=1; print key; next}
            /<\/tls-crypt>/{skip=0}
            !skip' "$conf" > "$tmpfile" && mv "$tmpfile" "$conf"
        
        log "已更新: $conf"
    done
    rm -f "$tmpfile"
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

# 验证配置
verify_config() {
    log "${GREEN}验证服务器配置...${NC}"
    if ! openvpn --config "$OVPN_DIR/server.conf" --verb 3 --test; then
        log "${RED}配置验证失败，请检查日志${NC}"
        exit 1
    fi
}

main() {
    fix_tls_key
    optimize_mtu
    systemctl restart openvpn@server
    verify_config
    
    log "${GREEN}修复完成！请执行以下操作：${NC}"
    echo -e "1. 重新分发所有客户端配置文件"
    echo -e "2. 客户端重启OpenVPN连接"
    echo -e "3. 检查防火墙规则: ${YELLOW}sudo ufw allow 1194/udp${NC}"
}

main
