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
cp /var/log/daemon.log /var/log/daemon.log.bak
cp /var/log/syslog /var/log/syslog.bak


# 创建新的空文件
touch /var/log/daemon.log
touch /var/log/syslog

# 设置新文件权限，只允许root和adm用户读取和写入
chown root:adm /var/log/daemon.log
chown root:adm /var/log/syslog
chmod 640 /var/log/daemon.log
chmod 640 /var/log/syslog

echo "已屏蔽/var/log/daemon.log和/var/log/syslog文件的写入日志，并清空了这两个文件。"
