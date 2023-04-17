#!/bin/bash

# 判断crontab中是否已经存在相同的任务
if grep -q "cat /dev/null > /var/log/daemon.log && cat /dev/null > /var/log/syslog" /etc/crontab; then
    echo "crontab中已存在相同的任务"
else
    # 添加crontab定时任务，每10分钟清空/var/log/daemon.log和/var/log/syslog文件
    echo "*/10 * * * * root cat /dev/null > /var/log/daemon.log && cat /dev/null > /var/log/syslog" >> /etc/crontab
    echo "已添加crontab定时任务，每10分钟清空/var/log/daemon.log和/var/log/syslog文件。"
    # 重启cron服务，使修改生效
    service cron restart
    echo "已重启cron服务，使修改生效。"
fi




# 判断当前时区是否为国内
TIMEZONE=`timedatectl | grep "Time zone" | awk '{print $3}'`
if [[ $TIMEZONE != Asia/Shanghai ]] && [[ $TIMEZONE != Asia/Chongqing ]] && [[ $TIMEZONE != Asia/Harbin ]] && [[ $TIMEZONE != Asia/Urumqi ]] && [[ $TIMEZONE != Asia/Hong_Kong ]]; then
    echo "当前时区为$TIMEZONE，不是国内时区，将设置为国内时区"
    timedatectl set-timezone Asia/Shanghai
fi

# 关闭自动时间同步
timedatectl set-ntp false

# 时区设置
#dpkg-reconfigure tzdata

# 语言环境配置
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
sed -i 's/LANG="en_US.UTF-8"/LANG="zh_CN.UTF-8"/' /etc/default/locale
echo "LC_TIME=\"zh_CN.UTF-8\"" | tee -a /etc/environment

# 重启系统
reboot
