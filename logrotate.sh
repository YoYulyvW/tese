#!/bin/bash

# Install logrotate if not already installed
if ! command -v logrotate &> /dev/null
then
    apt-get install logrotate
fi

cat /dev/null > /var/log/daemon.log && cat /dev/null > /var/log/syslog

# Create configuration file
tee /etc/logrotate.d/daemon-syslog << EOF
/var/log/daemon.log /var/log/syslog {
    size 5M
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root adm
}
EOF

# Restart rsyslog service to apply changes
systemctl restart rsyslog



#chmod +x logrotate.sh
#./logrotate.sh


#设置要屏蔽的关键词
keywords=("systemd-logind: New session" "Created slice" "Starting Session" "Started Session" "Wi-Fi" "hostapd")

#将关键词转换为rsyslog配置格式
rules=""
for keyword in "${keywords[@]}"; do
  rules+=":msg, contains, \"$keyword\" ~"$'\n'
done

#添加屏蔽规则到rsyslog配置文件
sed -i "/# Log anything (except mail) of level info or higher./a $rules    daemon.*;mail.*;syslog;\
        news.err;\
        *.=debug;*.=info;\
        *.=notice;*.=warn   /dev/null" /etc/rsyslog.conf

#重启rsyslog服务
systemctl restart rsyslog
