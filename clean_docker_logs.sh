#!/bin/bash

# 设置日志文件大小阈值（单位为MB）
LOG_SIZE_THRESHOLD=10  # 例如，设置为100MB

# 找到超过阈值的日志文件
LARGE_LOGS=$(find /var/lib/docker/containers/ -name '*-json.log' -type f -size +${LOG_SIZE_THRESHOLD}M)

if [ -z "$LARGE_LOGS" ]; then
  echo "没有找到超过 ${LOG_SIZE_THRESHOLD}MB 的日志文件。"
  exit 0
fi

echo "以下日志文件超过了 ${LOG_SIZE_THRESHOLD}MB："
echo "$LARGE_LOGS"

# 提供选项让用户选择是清空还是删除
read -p "你想清空这些日志文件吗？(y/n) " answer
if [[ $answer == [Yy] ]]; then
  for log in $LARGE_LOGS; do
    echo "清空 $log"
    truncate -s 0 "$log"
  done
  should_restart=true
else
  read -p "你想删除这些日志文件吗？(y/n) " answer
  if [[ $answer == [Yy] ]]; then
    for log in $LARGE_LOGS; do
      echo "删除 $log"
      rm "$log"
    done
    should_restart=true
  else
    echo "操作已取消。"
    should_restart=false
  fi
fi

# 检查磁盘空间
df -h

# 如果进行了清空或删除操作，则重启或启动Docker服务
if [ "$should_restart" = true ]; then
  if systemctl is-active --quiet docker; then
    echo "正在重启Docker服务..."
    systemctl restart docker
  else
    echo "Docker服务未运行，正在启动Docker服务..."
    systemctl start docker
  fi

  # 检查Docker服务状态
  systemctl status docker
fi