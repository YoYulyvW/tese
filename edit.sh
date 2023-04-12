#!/bin/bash

# 从命令行参数中获取需要查找和替换的IP地址
ip_addr="$1"

# 如果没有传递命令行参数，则使用默认值
if [ -z "$ip_addr" ]; then
    ip_addr="192.168.243"
    echo "没有传入ip, 将使用默认的:${ip_addr}"
fi

# 查找并替换/root/openvpn-install.sh文件中的IP地址
if [ -f "/root/openvpn-install.sh" ]; then
    sed -i "s/192\.168\.[0-9]\{1,3\}/${ip_addr}/g" /root/openvpn-install.sh
    echo "已经成功修改 /root/openvpn-install.sh 文件"
fi

# 查找并替换/root/openvpn-install-v6.sh文件中的IP地址
if [ -f "/root/openvpn-install-v6.sh" ]; then
    sed -i "s/192\.168\.[0-9]\{1,3\}/${ip_addr}/g" /root/openvpn-install-v6.sh
    echo "已经成功修改 /root/openvpn-install-v6.sh 文件"
fi

echo "已经修改ip为:${ip_addr}"
