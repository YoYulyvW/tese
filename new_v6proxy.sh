#!/bin/bash

# 开机清空Log日志
> /root/set_squid.log

# 初始化为空数组
ipv4_cidrs=()

# 生成多少个IP段
ipv4_count=1

# 生成IP数量
new_count=15

#存ikuai 生成的v6
arrv6add=()

#ikuai IPv6前缀
dhcp6_prefix1=""



# 定义函数来生成IPv4地址段
generate_ipv4_addresses() {
    local count=$1
    local start=3
    local current_ip=""
    
    for ((i=0; i<count; i++)); do
        local base_ip="10.0.$((start + i))"
        for ((j=1; j<=250; j++)); do
            current_ip="$base_ip.$j/20"
            ipv4_cidrs+=("$current_ip")
            
        done
    done
}

# 生成IPv4地址段
generate_ipv4_addresses $ipv4_count

# 默认网卡
physical_name="eth0"

# 用于存储上次检测到的IPv6地址
previous_ipv6=""





set_ikuai(){
  arrv6add=()
    # 目标URL
    login_url="http://192.168.1.1/Action/login"
    call_url="http://192.168.1.1/Action/call"
    
    # 登录
    login_json='{"username":"admin","passwd":"cf9aa02807d662d548e1a74c989168f9","pass":"c2FsdF8xMWEyNjgyNzIyMw==","remember_password":"true"}'
    login_response_headers=$(mktemp)
    curl -X POST -H "Content-Type: application/json" -d "$login_json" -D "$login_response_headers" "$login_url"
    set_cookie=$(grep -i '^Set-Cookie:' "$login_response_headers" | sed -n 's/^[Ss][Ee][Tt]-[Cc][Oo][Oo][Kk][Ii][Ee]: \(sess_key=[^;]*\).*$/\1/p')
    rm -f "$login_response_headers"
    
    # 使用 Cookie 进行请求
    call_json='{"func_name":"ipv6","action":"show","param":{"TYPE":"data,total","limit":"0,20","ORDER_BY":"","ORDER":""}}'
    cookie_data="login=1; $set_cookie; username=admin;"
    response=$(mktemp)
    curl -s -X POST -H "Content-Type: application/json" -d "$call_json" -b "$cookie_data" "$call_url" > "$response"
    dhcp6_prefix1=$(jq -r '.Data.data[0].dhcp6_prefix1' "$response")
    # Check if dhcp6_prefix1 is empty
    if [ -z "$dhcp6_prefix1" ]; then
        echo "dhcp6_prefix1 获取失败"
        return
    fi
    # 提取网络地址部分（不包括前缀长度）
    network_address=$(echo "$dhcp6_prefix1" | cut -d'/' -f1)
    rm -f "$response"
    field1=$(echo "$network_address" | awk -F: '{print $1}')
    field2=$(echo "$network_address" | awk -F: '{print $2}')
    field3=$(echo "$network_address" | awk -F: '{print $3}')
    field4=$(echo "$network_address" | awk -F: '{print $4}')
    arrAddress=''
    # 循环生成 IPv6 地址
    arrAddress=""

for ((i=1; i<=new_count; i++)); do
    # Convert field4 to integer and increment it
    field4_int=$((16#${field4}))
    field4_int=$((field4_int + i))
    field4_updated=$(printf "%X" "$field4_int")
    field4_updated=${field4_updated,,}

    # Update network address
    updated_network_address=$(echo "$network_address" | awk -F: -v field4="$field4_updated" '{OFS=":"; $4=field4; print}')
    
    # Generate and store multiple IPv6 addresses
    for ((j=1; j<=15; j++)); do
        ipv6_address="${field1}:${field2}:${field3}:${field4_updated}:$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)/64"
        arrv6add+=("$ipv6_address")
    done

    # Add only the updated network address (one per outer loop iteration)
    updated_network_address="${updated_network_address}1001/64"
    arrAddress="${arrAddress}${updated_network_address},"
done

# Remove the trailing comma from arrAddress
arrAddress="${arrAddress%,}"
    
#    for element in "${arrv6add[@]}"; do
#        echo "$element"
#    done
    
    # 使用 Cookie 进行请求
    call_json='{"func_name":"ipv6","action":"edit","param":{"use_dns6":1,"ipv6_dns1":"fe80::1094:cfff:fe1c:6e01","ipv6_dns2":"fe80::1094:cfff:fe1c:6e01","linkaddr":"fe80::62be:b4ff:fe12:b220/64","prefix_len":"auto","ra_flags":"2","id":1,"enabled":"yes","leasetime":"120","interface":"lan1","parent":"adsl_cmcc_02","ra_static":0,"internet":"static","ipv6_addr":"","dhcpv6":1}}'
    # call_json='{"func_name":"ipv6","action":"edit","param":{"interface":"lan1","parent":"adsl_cmcc_02","internet":"static","linkaddr":"fe80::62be:b4ff:fe12:b220/64","dhcpv6":1,"use_dns6":1,"ipv6_dns1":"2409:805c:2000:3001::1000","leasetime":"120","ipv6_dns2":"2409:805c:2000:3000::1000","ra_static":0,"prefix_len":"auto","ra_flags":"0","id":1,"enabled":"yes","ipv6_addr":""}}'
    updated_json=$(echo "$call_json" | jq --arg arrAddress "$arrAddress" '.param.ipv6_addr = $arrAddress')
    cookie_data="login=1; $set_cookie; username=admin;"
    ipv6_addrresponse=$(mktemp)
    curl -s -X POST -H "Content-Type: application/json" -d "$updated_json" -b "$cookie_data" "$call_url" > "$ipv6_addrresponse"
    errmsg=$(jq -r '.ErrMsg' "$ipv6_addrresponse")
    echo "添加ip6地址: $errmsg"
    rm -f "$ipv6_addrresponse"

}


# 定义函数
set_squid(){
    echo "-------------------squid 脚本开始执行[$(date '+%Y-%m-%d %H:%M:%S')]-----------------" >> /root/set_squid.log
    set_ikuai
    while [ -z "$dhcp6_prefix1" ]; do
        # 你的代码逻辑，可能是获取 $dhcp6_prefix1 的操作
       if [ -z "$dhcp6_prefix1" ]; then
            set_ikuai
            echo "ikuai IPv6前缀获取失败" >> /root/set_squid.log
       fi
       # 可以在这里添加一些等待时间，以免无限循环导致性能问题
       sleep 5
    done
    ifdown $physical_name && ifup $physical_name
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 重新获取网络，等待10秒..." >> /root/set_squid.log
    sleep 10
    # 获取IPv6前缀
    ipv6_prefix=""
    attempts=0
    while [ -z "$ipv6_prefix" ] || [ "${ipv6_prefix}" = ":::" ]; do
        # 查询物理网卡的IPv4地址并提取第一个
        ipv4_address=$(ip -4 addr show dev $physical_name | awk '/inet .* global/ {print $2}' | tail -n1)

        # 查询物理网卡的IPv6地址并提取第一个
        ipv6_address=$(ip -6 addr show dev $physical_name | awk '/inet6 .* global/ {print $2}' | tail -n1)

        # 提取IPv6前缀
        ipv6_prefix=$(echo "${ipv6_address}" | awk -F'::' '{print $1}' | awk -F':' '{print $1":"$2":"$3":"$4}')

        if [ "${ipv6_prefix}" = ":::" ]; then
            attempts=$((attempts + 1))
            if [ $attempts -eq 10 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 未能获取IPv6前缀，退出脚本." >> /root/set_squid.log
                exit 1
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 未能获取IPv6前缀，等待10秒，尝试次数：$attempts" >> /root/set_squid.log
                sleep 10
            fi
        fi
    done

    # 变量初始化
    acl="acl ip_0 myip ${ipv4_address%/*}\\n"
    tcp_outgoing_address="tcp_outgoing_address ${ipv6_address%/*} ip_0 dns_v6_first\\n"
    tcp_outgoing_address="${tcp_outgoing_address}tcp_outgoing_address ${ipv4_address%/*} ip_0\\n"
    tcp_outgoing_address="${tcp_outgoing_address}tcp_outgoing_address ${ipv6_address%/*} ip_0\\n"

    # 更新上次检测到的IPv6地址
    previous_ipv6=$(ip -6 addr show dev $physical_name | awk '/inet6 .* global/ {print $2}' | grep -oE '[0-9a-fA-F:]+' | head -n1)

    

    i=1  # 初始化 i 变量为 1
    # 循环取出IPV4地址
    
    for ipv6_addr in "${arrv6add[@]}"; do
        ipv4_addr=${ipv4_cidrs[$((i - 1))]}

        # Check if ipv4_addr is not empty before proceeding
        if [ -n "$ipv4_addr" ]; then
            # 添加IP地址
            ip addr add $ipv4_addr dev $physical_name
            ip -6 addr add $ipv6_addr dev $physical_name

        # squid 配置生成
            acl="${acl}acl ip_${i} myip ${ipv4_addr%/*}\\n"
            tcp_outgoing_address="${tcp_outgoing_address}tcp_outgoing_address ${ipv6_addr%/*} ip_${i}\\n"
            tcp_outgoing_address="${tcp_outgoing_address}tcp_outgoing_address ${ipv4_addr%/*} ip_${i}\\n"

            ((i++))
        fi
    done

    new_config=$(cat <<EOL
dns_nameservers 127.0.0.1
acl localnet src 0.0.0.1-0.255.255.255
acl localnet src 10.0.0.0/8
acl localnet src 100.64.0.0/10
acl localnet src 169.254.0.0/16
acl localnet src 172.16.0.0/12
acl localnet src 192.168.0.0/16
acl localnet src fc00::/7
acl localnet src fe80::/10

acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 21
acl Safe_ports port 443
acl Safe_ports port 70
acl Safe_ports port 210
acl Safe_ports port 1025-65535
acl Safe_ports port 280
acl Safe_ports port 488
acl Safe_ports port 591
acl Safe_ports port 777
acl CONNECT method CONNECT

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
include /etc/squid/conf.d/*
http_access allow localhost
http_access allow all

coredump_dir /var/spool/squid
refresh_pattern ^ftp:        1440    20%    10080
refresh_pattern ^gopher:    1440    0%    1440
refresh_pattern -i (/cgi-bin/|\?) 0    0%    0
refresh_pattern .        0    20%    4320

visible_hostname Squid
cache_mem 512 MB
connect_timeout 30 seconds
client_persistent_connections on
request_header_access From deny all
request_header_access Server deny all
request_header_access Via deny all
request_header_access X-Forwarded-For deny all
access_log none

#acl dns_v6_first dstdomain api.m.jd.com
# 通配所有，不局限api.m.jd.com
acl dns_v6_first dstdomain .

http_port 3128
$acl
$tcp_outgoing_address
EOL
)

    # 将新配置写入 /etc/squid/squid.conf
    echo -e "$new_config" > /etc/squid/squid.conf

    # 提示操作完成
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] squid 配置已更新..." >> /root/set_squid.log

    # 检查当前用户是否有执行 systemctl 命令的权限
    if [ "$(id -u)" -ne 0 ]; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 需要使用管理员权限执行此脚本..." >> /root/set_squid.log
      exit 1
    fi

    # 执行 systemctl 命令来重新启动 squid 服务
    systemctl restart squid
    systemctl restart haproxy
    #systemctl stop squid && systemctl start squid

    # 提示操作完成
    current_datetime=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] squid 重启完成..." >> /root/set_squid.log
    echo "-------------------squid 脚本执行完成[$(date '+%Y-%m-%d %H:%M:%S')]-----------------" >> /root/set_squid.log
   {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] IPv6 地址的数量: ${#arrv6add[@]}"
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 网络地址的数量: $(echo $arrAddress | tr -cd ',' | wc -c)"
  } >> /root/set_squid.log
  
  send_message "[$(date '+%Y-%m-%d %H:%M:%S')] \rIPv6 地址的数量: ${#arrv6add[@]}\r网络地址的数量: $(echo $arrAddress | tr -cd ',' | wc -c)\rV6服务器启用完毕..."
}

send_message() {
    local msg="$1"
    local formatted_msg=$(echo "$msg" | sed ':a;N;$!ba;s/\r\n/\r/g;s/\n/\r/g')

    curl -X POST 'http://192.168.1.126:33884/pp/ihttp' \
         -H 'Content-Type: application/json' \
         -d '{"event": "SendTextMsgList", "to_wxid": "wiexin01", "msg": "'"$formatted_msg"'"}'
}

monitor () {
    # 循环检测 IPv6 地址是否发生变化
    while true; do
        # 使用 ping 检查 IPv6 地址可达性
        if ping -c 1 -W 10 2400:3200::1 > /dev/null; then
            # 如果 IPv6 地址可达，继续检测
            sleep 60  # 每 60 秒检测一次
        else
            # 如果 IPv6 地址不可达，执行 set_squid 并将输出追加到日志文件
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] IPv6 不可达。执行 set_squid..." >> /root/set_squid.log

            # 重启 systemd-networkd 服务
            systemctl restart systemd-networkd
            echo -e "nameserver 223.5.5.5\nnameserver fe80::1094:cfff:fe1c:6e01%eth0" |  tee -a /etc/resolv.conf
            systemctl restart systemd-resolved

            # 检查服务重启的退出状态码
            if [ $? -eq 0 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] systemd-networkd 服务已成功重启。" >> /root/set_squid.log
                send_message "[$(date '+%Y-%m-%d %H:%M:%S')] \rIPv6 不可达...\nsystemd-networkd 服务已成功重启。\n开始尝试重新配置网络..."
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] systemd-networkd 服务重启失败。" >> /root/set_squid.log
                # 处理失败的情况，例如记录日志或发送警报
                send_message "[$(date '+%Y-%m-%d %H:%M:%S')] \rIPv6 不可达...\nsystemd-networkd 服务重启失败。\n开始尝试重新配置网络..."
            fi

            # 调用 set_squid 函数
            set_squid
        fi

        # 等待 1 秒后再进行下一轮检测
        sleep 1
    done
}



set_squid
monitor
