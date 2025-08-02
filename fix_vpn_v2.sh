#!/bin/bash
# OpenVPN 终极修复脚本 v2.0

# 1. 检查容器环境
if grep -q docker /proc/1/cgroup || grep -q kubepods /proc/1/cgroup; then
    echo "检测到容器环境，请确保已添加 --privileged 参数启动容器"
    exit 1
fi

# 2. 强制卸载冲突模块
rmmod tun 2>/dev/null
rmmod tap 2>/dev/null

# 3. 使用设备预创建方式
mkdir -p /dev/net
[ -c /dev/net/tun ] || {
    mknod /dev/net/tun c 10 200
    chmod 0666 /dev/net/tun
}

# 4. 内核模块强制加载
/sbin/modprobe tun
echo tun >> /etc/modules-load.d/tun.conf

# 5. 系统级设备管理
cat > /etc/udev/rules.d/90-tun.rules <<EOF
KERNEL=="tun", NAME="net/tun", MODE="0666", GROUP="nogroup"
EOF
udevadm control --reload-rules
udevadm trigger

# 6. 修复systemd服务配置
mkdir -p /etc/systemd/system/openvpn@.service.d
cat > /etc/systemd/system/openvpn@.service.d/10-tun.conf <<EOF
[Service]
DeviceAllow=/dev/net/tun rw
DevicePolicy=auto
ExecStartPre=-/bin/rm -f /dev/net/tun
ExecStartPre=/bin/mkdir -p /dev/net
ExecStartPre=/bin/mknod /dev/net/tun c 10 200
ExecStartPre=/bin/chmod 666 /dev/net/tun
RestartSec=5
Restart=on-failure
EOF

# 7. 重载并重启服务
systemctl daemon-reload
systemctl reset-failed openvpn@server
systemctl restart openvpn@server

# 8. 最终状态检查
echo -e "\n=== 修复结果验证 ==="
if ls /dev/net/tun >/dev/null 2>&1 && systemctl is-active --quiet openvpn@server; then
    echo "✓ 修复成功！OpenVPN 正在运行"
    echo "设备状态:"
    ls -l /dev/net/tun
    echo -e "\n服务状态:"
    systemctl status openvpn@server --no-pager | head -n 10
else
    echo "✗ 修复失败！请检查以下项目："
    echo "1. 系统是否支持 TUN/TAP (检查: cat /dev/net/tun)"
    echo "2. 是否在特权模式下运行 (非容器或已加 --privileged)"
    echo "3. 查看详细日志: journalctl -u openvpn@server -n 50"
fi
