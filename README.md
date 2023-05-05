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
opkg install bash findutils iconv
```

## Usage

### Variables

| Variable Name          | Default Value | Description                                             |
| ---------------------- | ------------- | ------------------------------------------------------- |
| `WARNING_TEMP`         | `65`          | Temperature threshold (in Celsius) for warning message  |
| `FULL_BAT`             | `85`          | Battery level threshold (in percentage) for full charge |
| `WARNING_BAT`          | `25`          | Battery level threshold (in percentage) for warning     |
| `CRITICAL_BAT`         | `15`          | Battery level threshold (in percentage) for critical    |
| `SHUTDOWN_BAT`         | `10`          | Battery level threshold (in percentage) for shutdown    |
| `CLIENTS_SHUTDOWN_TIME`| `20`          | Time (in minutes) before shutdown when battery level is at `SHUTDOWN_BAT`  |
| `MAX_CLOCK_DRIFT`      | `2`           | Maximum allowed clock drift (in minutes), if the clock has changed by more than the value specified in the variable, the time-based alerts will be reset |
| `ALERT_SCRIPT`         | `$(dirname "$0")/alert.sh` | Path to the script that sends alert messages  |

To use this script, follow these steps:

1. Place the monitor.sh script in a suitable location on your router, such as /root/monitor/monitor.sh.
2. Place the alert.sh script in the same directory as monitor.sh. The alert.sh script should accept a message as an argument.
3. Add the script to the router's crontab to run it periodically:
```bash
echo "* * * * * nice -n 19 /root/monitor/monitor.sh >> /dev/null 2>&1" >> /etc/crontabs/root
/etc/init.d/cron restart
```