#!/bin/bash

# 桥接接口名称的基础名称
base_interface_name="veth"

# 获取物理网卡名称
physical_interface=$(ip -o link show | awk -F': ' '!/lo/ && !/veth/ && !/\<(br|docker|virbr)\d+\>/ {print $2; exit}')


# 清理旧的虚拟网卡
for i in {1..100}; do
    interface_name="${base_interface_name}${i}"
    peer_interface_name="${interface_name}p"

    if ip link show "${interface_name}" >/dev/null 2>&1; then
        ip link delete "${interface_name}"
    fi

    if ip link show "${peer_interface_name}" >/dev/null 2>&1; then
        ip link delete "${peer_interface_name}"
    fi
done

# 创建桥接接口
ip link add name br0 type bridge
ip link set br0 up

# 连接物理网卡到桥接接口
ip link set dev "${physical_interface}" master br0
ip link set dev "${physical_interface}" up

# 创建虚拟网卡并连接到桥接接口
for i in {1..100}; do
    # 构建虚拟网卡名称
    interface_name="${base_interface_name}${i}"
    peer_interface_name="${interface_name}p"

    # 创建虚拟网卡对
    ip link add name "${interface_name}" type veth peer name "${peer_interface_name}"

    # 将虚拟网卡连接到桥接接口
    ip link set dev "${interface_name}" master br0
    ip link set dev "${interface_name}" up
    ip link set dev "${peer_interface_name}" up

    # 分配静态IP地址
    ip addr add 192.168.2.$((100 + i))/24 dev "${interface_name}"
done