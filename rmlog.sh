#!/bin/bash

# 检查当前系统是否是Armbian
if [ $(grep -c "Armbian" /etc/os-release) -eq 0 ]; then
    echo "该脚本仅适用于Armbian系统。"
    exit 1
fi

# 清空原始文件
> /var/log/daemon.log
> /var/log/syslog

# 备份原始文件
cp /etc/rsyslog.conf /etc/rsyslog.conf.bak

# 修改rsyslog.conf文件，屏蔽/var/log/daemon.log和/var/log/syslog文件的写入日志
sed -i '/^daemon\.log/ s/^/#/' /etc/rsyslog.conf
sed -i '/^syslog/ s/^/#/' /etc/rsyslog.conf

# 重启rsyslog服务
systemctl restart rsyslog

echo "已修改/etc/rsyslog.conf文件，屏蔽了/var/log/daemon.log和/var/log/syslog文件的写入日志。"
