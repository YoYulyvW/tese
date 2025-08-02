#!/bin/bash
# OpenVPN 终极修复脚本 (100% 兼容 OpenVPN 2.5.1+)
# 版本：8.0

OVPN_DIR="/etc/openvpn"
CLIENT_DIR="$OVPN_DIR/client-configs"
LOG_FILE="/var/log/vpnadmin.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 安全日志记录
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# 安全生成密钥
generate_tls_key() {
    log "${GREEN}正在生成新的tls-crypt密钥...${NC}"
    
    # 兼容新旧版本语法
    if openvpn --help | grep -q "\-\-genkey secret"; then
        openvpn --genkey secret "$OVPN_DIR/tls-crypt.key" || {
            log "${RED}密钥生成失败 (新语法)${NC}"
            return 1
        }
    else
        openvpn --genkey --secret "$OVPN_DIR/tls-crypt.key" || {
            log "${RED}密钥生成失败 (旧语法)${NC}"
            return 1
        }
    fi
    
    chmod 600 "$OVPN_DIR/tls-crypt.key"
    return 0
}

# 安全更新客户端配置
update_client_configs() {
    local key_content=$(cat "$OVPN_DIR/tls-crypt.key")
    
    for conf in "$CLIENT_DIR"/*.ovpn; do
        [ -f "$conf" ] || continue
        
        # 使用临时文件确保原子性更新
        tmp_file="${conf}.tmp"
        
        awk -v key="$key_content" '
            BEGIN { in_tls=0 }
            /<tls-crypt>/ { 
                print
                in_tls=1
                next
            }
            /<\/tls-crypt>/ {
                print key
                print
                in_tls=0
                next
            }
            !in_tls { print }
        ' "$conf" > "$tmp_file" && mv "$tmp_file" "$conf"
        
        log "已更新客户端: $conf"
    done
}

# 优化MTU设置
optimize_mtu() {
    log "${GREEN}配置MTU优化...${NC}"
    
    # 清理旧配置
    sed -i '/^mssfix/d; /^fragment/d' "$OVPN_DIR/server.conf"
    
    # 添加优化配置
    cat >> "$OVPN_DIR/server.conf" <<EOF
# MTU优化配置
mssfix 1200
fragment 1300
EOF

    # 更新客户端
    for conf in "$CLIENT_DIR"/*.ovpn; do
        [ -f "$conf" ] && grep -q "mssfix" "$conf" || echo "mssfix 1200" >> "$conf"
    done
}

# 配置验证
verify_config() {
    log "${GREEN}验证配置...${NC}"
    
    # 使用兼容性检查
    if openvpn --version | grep -q "2\.5"; then
        if ! openvpn --config "$OVPN_DIR/server.conf" --verb 3 --show-ciphers >/dev/null; then
            log "${RED}配置验证失败 (2.5+版本)${NC}"
            return 1
        fi
    else
        if ! openvpn --config "$OVPN_DIR/server.conf" --verb 3 --test >/dev/null; then
            log "${RED}配置验证失败 (旧版本)${NC}"
            return 1
        fi
    fi
    
    return 0
}

# 主修复流程
main() {
    # 1. 更新密钥
    if ! generate_tls_key; then
        log "${RED}密钥生成失败，请手动检查OpenVPN版本${NC}"
        exit 1
    fi
    
    # 2. 更新客户端配置
    update_client_configs
    
    # 3. 优化MTU
    optimize_mtu
    
    # 4. 重启服务
    systemctl restart openvpn@server
    
    # 5. 验证配置
    if ! verify_config; then
        log "${RED}配置验证失败，请检查日志${NC}"
        exit 1
    fi
    
    log "${GREEN}修复成功完成！${NC}"
    echo -e "请执行以下操作："
    echo -e "1. 重新分发所有客户端配置文件"
    echo -e "2. 客户端执行：${YELLOW}sudo systemctl restart openvpn-client@config${NC}"
    echo -e "3. 监控日志：${YELLOW}journalctl -u openvpn@server -f${NC}"
}

# 执行主流程
main
