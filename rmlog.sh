#!/bin/bash

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