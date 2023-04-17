#!/bin/bash

# 添加crontab定时任务，每10分钟清空/var/log/daemon.log和/var/log/syslog文件
echo "*/10 * * * * root cat /dev/null > /var/log/daemon.log && cat /dev/null > /var/log/syslog" >> /etc/crontab

echo "已添加crontab定时任务，每10分钟清空/var/log/daemon.log和/var/log/syslog文件。"
