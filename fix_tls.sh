#!/bin/bash
# OpenVPN TLS故障修复脚本
# 功能：密钥重置 | MTU优化 | 配置验证

OVPN_DIR="/etc/openvpn"
LOG_FILE="/var/log/vpnadmin.log"

# 重新生成tls-crypt密钥
reset_tls_key() {
    echo "重新生成tls-crypt密钥..."
    openvpn --genkey --secret $OVPN_DIR/tls-crypt.key
    chmod 600 $OVPN_DIR/tls-crypt.key
    
    # 更新所有客户端配置
    for conf in $OVPN_DIR/client-configs/*.ovpn; do
        sed -i '/<tls-crypt>/,/<\/tls-crypt>/c\<tls-crypt>\n'"$(cat $OVPN_DIR/tls-crypt.key)"'\n</tls-crypt>' $conf
    done
}

# 优化MTU设置
optimize_mtu() {
    echo "优化MTU设置..."
    sed -i '/^mssfix/d' $OVPN_DIR/server.conf
    sed -i '/^fragment/d' $OVPN_DIR/server.conf
    
    cat >> $OVPN_DIR/server.conf <<EOF
mssfix 1200
fragment 1300
EOF

    # 更新客户端配置
    for conf in $OVPN_DIR/client-configs/*.ovpn; do
        grep -q "mssfix" $conf || echo "mssfix 1200" >> $conf
    done
}

# 验证配置
verify_config() {
    echo "验证配置..."
    openvpn --config $OVPN_DIR/server.conf --verb 4 --verify-tls all
}

main() {
    reset_tls_key
    optimize_mtu
    systemctl restart openvpn@server
    verify_config
    echo "修复完成！请重新分发客户端配置" | tee -a $LOG_FILE
}

main
