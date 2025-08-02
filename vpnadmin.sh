#!/bin/bash
# OpenVPN终极管理脚本
# 功能：证书认证 | 自动IP分配 | 多用户管理 | 状态监控
# 版本：6.0

# 配置目录
OVPN_DIR="/etc/openvpn"
EASY_RSA="$OVPN_DIR/easy-rsa"
CLIENT_DIR="$OVPN_DIR/client-configs"
CCD_DIR="$OVPN_DIR/ccd"
LOG_FILE="/var/log/vpnadmin.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化环境
init() {
    mkdir -p {$CLIENT_DIR,$CCD_DIR}
    touch $LOG_FILE
    chmod 600 $OVPN_DIR/*.key 2>/dev/null
}

# 日志记录
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# 获取可用IP
get_ip() {
    # 从Squid配置提取IP池
    IP_POOL=($(grep -oP 'acl ip_\d+ myip \K[\d.]+' /etc/squid/squid.conf | sort -t. -k4n))
    [ ${#IP_POOL[@]} -eq 0 ] && { log "${RED}错误：未找到IP池${NC}"; exit 1; }

    # 排除已用IP和代理IP
    EXCLUDE=("10.0.2.2" "10.0.3.1" "10.0.3.2")
    USED=($(grep -hoP 'ifconfig-push \K[\d.]+' $CCD_DIR/* 2>/dev/null))
    ALL_EXCLUDE=("${EXCLUDE[@]}" "${USED[@]}")

    for ip in "${IP_POOL[@]}"; do
        if ! printf '%s\n' "${ALL_EXCLUDE[@]}" | grep -q "^$ip$"; then
            echo $ip && return 0
        fi
    done

    log "${RED}错误：无可用IP地址${NC}"
    exit 1
}

# 安装服务
install() {
    log "${GREEN}正在安装OpenVPN...${NC}"
    apt update && apt install -y openvpn easy-rsa
    
    # 初始化PKI
    rm -rf $EASY_RSA
    make-cadir $EASY_RSA
    cd $EASY_RSA || exit

    cat > vars <<EOF
set_var EASYRSA_BATCH   "yes"
set_var EASYRSA_REQ_CN  "VPN_CA"
EOF

    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-dh
    ./easyrsa build-server-full server nopass
    ./easyrsa gen-crl
    openvpn --genkey --secret $OVPN_DIR/tls-crypt.key

    # 复制证书
    cp pki/{ca.crt,issued/server.crt,private/{ca,server}.key,dh.pem,crl.pem} $OVPN_DIR/

    # 创建服务配置
    cat > $OVPN_DIR/server.conf <<EOF
port 1194
proto udp
dev tun
ca $OVPN_DIR/ca.crt
cert $OVPN_DIR/server.crt
key $OVPN_DIR/server.key
dh $OVPN_DIR/dh.pem
server 10.8.0.0 255.255.255.0
topology subnet
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
tls-crypt $OVPN_DIR/tls-crypt.key
cipher AES-256-GCM
user nobody
group nogroup
persist-key
persist-tun
status $OVPN_DIR/openvpn-status.log
verb 3
crl-verify $OVPN_DIR/crl.pem
client-config-dir $CCD_DIR
EOF

    systemctl enable --now openvpn@server
    log "${GREEN}安装完成！服务已启动${NC}"
}

# 添加用户
add() {
    [ -z "$1" ] && { log "${RED}用法: $0 add <用户名>${NC}"; exit 1; }
    local user=$1
    local ip=$(get_ip)
    
    # 清理旧配置
    rm -f $CLIENT_DIR/$user.ovpn $CCD_DIR/$user 2>/dev/null

    # 签发证书
    cd $EASY_RSA || exit
    ./easyrsa build-client-full $user nopass >>$LOG_FILE 2>&1 || {
        log "${RED}证书签发失败${NC}"; exit 1
    }

    # 分配IP
    echo "ifconfig-push $ip 255.255.255.0" > $CCD_DIR/$user

    # 生成客户端配置
    cat > $CLIENT_DIR/$user.ovpn <<EOF
client
dev tun
proto udp
remote $(curl -s ifconfig.me) 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
verb 3
<ca>
$(cat $OVPN_DIR/ca.crt)
</ca>
<cert>
$(cat $EASY_RSA/pki/issued/$user.crt)
</cert>
<key>
$(cat $EASY_RSA/pki/private/$user.key)
</key>
<tls-crypt>
$(cat $OVPN_DIR/tls-crypt.key)
</tls-crypt>
EOF

    log "${GREEN}用户添加成功${NC}"
    echo -e "${YELLOW}=== 连接信息 ===${NC}"
    echo -e "用户名: ${GREEN}$user${NC}"
    echo -e "分配IP: ${GREEN}$ip${NC}"
    echo -e "配置文件: ${GREEN}$CLIENT_DIR/$user.ovpn${NC}"
    echo -e "下载命令: ${YELLOW}scp root@$(hostname -I | awk '{print $1}'):$CLIENT_DIR/$user.ovpn .${NC}"
}

# 删除用户
del() {
    [ -z "$1" ] && { log "${RED}用法: $0 del <用户名>${NC}"; exit 1; }
    local user=$1
    
    cd $EASY_RSA || exit
    ./easyrsa revoke $user >>$LOG_FILE 2>&1
    ./easyrsa gen-crl >>$LOG_FILE 2>&1
    
    rm -f \
        $EASY_RSA/pki/issued/$user.crt \
        $EASY_RSA/pki/private/$user.key \
        $EASY_RSA/pki/reqs/$user.req \
        $CLIENT_DIR/$user.ovpn \
        $CCD_DIR/$user
    
    log "${GREEN}用户 $user 已删除${NC}"
}

# 用户列表
list() {
    echo -e "${YELLOW}=== VPN用户列表 ===${NC}"
    printf "%-15s %-15s %s\n" "用户名" "分配IP" "状态"
    echo "----------------------------------"
    
    # 获取吊销列表
    declare -A revoked
    while read -r line; do
        if [[ $line =~ ^R.*CN=([^/]+) ]]; then
            revoked[${BASH_REMATCH[1]}]=1
        fi
    done < <(cd $EASY_RSA; ./easyrsa list-crl 2>/dev/null)
    
    # 列出用户
    for ccd in $CCD_DIR/*; do
        [ -f "$ccd" ] || continue
        user=$(basename $ccd)
        ip=$(grep -oP 'ifconfig-push \K[\d.]+' $ccd)
        status="正常"
        [ -n "${revoked[$user]}" ] && status="${RED}已吊销${NC}"
        printf "%-15s %-15s %b\n" "$user" "$ip" "$status"
    done
}

# 连接状态
status() {
    echo -e "${YELLOW}=== 当前连接状态 ===${NC}"
    if [ -f $OVPN_DIR/openvpn-status.log ]; then
        awk '
            /^CLIENT_LIST/ {printf "用户: %-10s 远端IP: %-15s 连接: %s\n", $2,$3,$8}
            /^ROUTING_TABLE/ {printf "路由: %-15s => %s\n", $3,$2}
        ' $OVPN_DIR/openvpn-status.log
    else
        echo -e "${RED}没有活跃连接${NC}"
    fi
}

# 主菜单
case "$1" in
    install)
        init; install
        ;;
    add)
        init; add "$2"
        ;;
    del)
        init; del "$2"
        ;;
    list)
        init; list
        ;;
    status)
        init; status
        ;;
    *)
        echo -e "${YELLOW}OpenVPN终极管理脚本${NC}"
        echo -e "用法: $0 {install|add|del|list|status}"
        echo -e "  install\t- 安装OpenVPN服务"
        echo -e "  add <用户名>\t- 添加VPN用户"
        echo -e "  del <用户名>\t- 删除VPN用户"
        echo -e "  list\t\t- 列出所有用户"
        echo -e "  status\t- 查看连接状态"
        exit 1
        ;;
esac
