#!/bin/bash

# 检查当前用户是否为 root
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户运行此脚本！"
    exit 1
fi

# 设置基础网络接口
BASE_INTERFACE="eth0"
VIRTUAL_INTERFACE="$BASE_INTERFACE:1"
NEW_LAST_OCTET="223"
NETMASK="255.255.255.0"

# 获取当前网卡的 IP 地址
CURRENT_IP=$(ip -4 addr show $BASE_INTERFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$CURRENT_IP" ]; then
    echo "未能找到 $BASE_INTERFACE 的当前 IP 地址，请确保接口已激活。"
    exit 1
fi

echo "当前 $BASE_INTERFACE 的 IP 地址是: $CURRENT_IP"

# 提取网段，并构建新的虚拟 IP 地址
IFS='.' read -r i1 i2 i3 _ <<< "$CURRENT_IP"
NEW_IP="$i1.$i2.$i3.$NEW_LAST_OCTET"

echo "将为虚拟网卡 $VIRTUAL_INTERFACE 使用新的 IP 地址: $NEW_IP"

# 检测发行版并写入相应的配置文件
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu 系统
    echo "检测到 Debian/Ubuntu 系统，正在写入 /etc/network/interfaces"

    # 检查是否已存在对应配置
    if ! grep -q "$VIRTUAL_INTERFACE" /etc/network/interfaces; then
        echo -e "\nauto $VIRTUAL_INTERFACE\niface $VIRTUAL_INTERFACE inet static\n    address $NEW_IP\n    netmask $NETMASK" >> /etc/network/interfaces
        echo "配置已添加到 /etc/network/interfaces"
    else
        echo "$VIRTUAL_INTERFACE 的配置已存在于 /etc/network/interfaces"
    fi

elif [ -f /etc/redhat-release ]; then
    # CentOS/RHEL 系统
    echo "检测到 CentOS/RHEL 系统，正在写入 /etc/sysconfig/network-scripts/ifcfg-$VIRTUAL_INTERFACE"

    # 创建配置文件
    cat <<EOL > /etc/sysconfig/network-scripts/ifcfg-$VIRTUAL_INTERFACE
DEVICE=$VIRTUAL_INTERFACE
BOOTPROTO=none
ONBOOT=yes
IPADDR=$NEW_IP
NETMASK=$NETMASK
EOL

    echo "配置已添加到 /etc/sysconfig/network-scripts/ifcfg-$VIRTUAL_INTERFACE"
else
    echo "不支持的发行版"
    exit 1
fi

# 启动网络接口
ifup $VIRTUAL_INTERFACE || ifconfig $VIRTUAL_INTERFACE up

echo "虚拟网卡 $VIRTUAL_INTERFACE 已启动，IP 地址为 $NEW_IP"
