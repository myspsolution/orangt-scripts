#!/bin/bash

sudo journalctl --vacuum-size=200M

if [ -d /var/www/html ]; then
  sudo find /var/www/html -name "laravel*.log" -type f -delete
fi

sudo find /var/log -type f -name "*.gz" -delete
sudo find /var/log -type f -regex ".*\.[0-9]+" -delete
sudo find /var/log -type f -name "*.log.2025*" -delete

if which spstool &> /dev/null; then
  echo ""
  spstool sysinfo
fi
