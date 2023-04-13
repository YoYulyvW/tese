#!/bin/bash

# Install logrotate if not already installed
if ! command -v logrotate &> /dev/null
then
    apt-get install logrotate
fi

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

