#!/bin/bash

# 判断crontab中是否已经存在相同的任务
if grep -q "cat /dev/null > /var/log/daemon.log && cat /dev/null > /var/log/syslog" /etc/crontab; then
    echo "crontab中已存在相同的任务
    exit 1
fi

# 添加crontab定时任务，每10分钟清空/var/log/daemon.log和/var/log/syslog文件
echo "*/10 * * * * root cat /dev/null > /var/log/daemon.log && cat /dev/null > /var/log/syslog" >> /etc/crontab

echo "已添加crontab定时任务，每10分钟清空/var/log/daemon.log和/var/log/syslog文件。"

# 重启cron服务，使修改生效
systemctl restart cron

echo "已重启cron服务，使修改生效。"
