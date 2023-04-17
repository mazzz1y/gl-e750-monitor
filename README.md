# gl-e750-monitor

This script is designed for GL-Inet Mudi E750 LTE Router.

It was originally created for personal use, but it may be helpful for others who want to customize their router's behavior.

## Features

1. Incoming SMS message alerting
2. Temperature alerting
3. Battery level alerting
4. Shutdown router when there are no clients for a specified time

## Requirements
```bash
opkg update
opkg install bash findutils
```

## Usage

To use this script, follow these steps:

1. Place the script in the appropriate location on your router, such as `/root/monitor.sh`.
2. Configure the script variables according to your requirements. Add your notifications method to `alert()` function inside the script.
3. Add the script to the router's crontab to run it periodically.
```bash
echo "* * * * * nice -n 19 /root/monitor.sh >> /dev/null 2>&1" >> /etc/crontabs/root
/etc/init.d/cron restart
```