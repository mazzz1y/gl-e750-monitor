#!/bin/bash

# Check if the current script is already running or if it's being executed with the "debug" argument.
# If the script is already running (and not in debug mode), exit to avoid running multiple instances.
[[ "$(pidof "$(basename "$0")")" != "$$" ]] && [[ "$1" != "debug" ]] && exit

# The temperature threshold (in Celsius) at which a high-temperature warning alert is triggered.
WARNING_TEMP=60
#  The battery percentage threshold at which a full battery alert is triggered.
FULL_BAT=85
# The battery percentage threshold at which a low battery warning alert is triggered.
WARNING_BAT=25
# The battery percentage threshold at which a critical low battery alert is triggered.
CRITICAL_BAT=15
# The battery percentage threshold at which the router will be shut down due to low battery.
SHUTDOWN_BAT=10
# The time duration (in minutes) after which the router will shut down if there are no active clients.
CLIENTS_SHUTDOWN_TIME=20
# This value should be a bit larger than the cron schedule interval to ensure proper handling of time-based logic in the script.
MAX_TIME_DRIFT=2

temperature_lock="/tmp/monitor_temp.lock"
full_battery_lock="/tmp/monitor_full_battery.lock"
warning_battery_lock="/tmp/monitor_warn_battery.lock"
critical_battery_lock="/tmp/monitor_crit_battery.lock"
client_lock="/tmp/monitor_client.lock"
time_drift_lock="/tmp/monitor_time.lock"

sms_incoming_dir=/etc/spool/sms/incoming
sms_storage_dir=/etc/spool/sms/storage

{
    read -r temp
    read -r bat
    read -r charge
} < <(jsonfilter -i /tmp/mcu_data -e '@.T' -e '@.P' -e '@.C' | cut -d '.' -f 1)

is_lock_stale() {
    local file_name=$1
    local stale_time=$2
    [[ "$(($(date +%s) - $(date -r "$file_name" +%s)))" -gt $((stale_time * 60)) ]]
}

is_lock_enabled() {
    [[ -f $1 ]]
}

is_lan_up() {
    [[ $(<"/sys/class/net/br-lan/operstate") == up ]]
}

is_modem_up() {
    [[ $(<"/tmp/run/mwan3track/modem_1_1_2/STATUS") == online ]]
}

is_clients_exists() {
    is_lan_up || return 1
    [[ $(grep -c 1 <(awk '{print $15}' /tmp/tertf/tertfinfo 2>/dev/null)) -gt 0 ]]
}

is_charging() {
    [[ $charge -eq 1 ]]
}

alert() {
    ! is_modem_up && return 1
    # Replace this comment with your alert script.
    ## Example: Sending an alert using curl with a custom webhook URL
    ## message="$1"
    ## webhook_url="https://your-webhook-url.com"
    ## curl -X POST -H 'Content-Type: application/json' -d '{"text": "'"${message}"'"}' "$webhook_url"
}

shutdown() {
    echo "{\"poweroff\": \"1\"}" >/tmp/mcu_message && sleep 0.5 && killall -17 e750-mcu && exit 0
}

lock_create() {
    touch "$1"
}

lock_remove() {
    rm -f "$1"
}

escape_string() {
    local msg="$1"
    # remove hidden symbols
    msg="$(echo -e "$msg" | sed -e 's/[[:cntrl:]]//g')"
    # json escape
    msg="${msg//\\/\\\\}"
    msg="${msg//\"/\\\"}"
    msg="${msg//$'\n'/\\n}"
    msg="${msg//$'\t'/\\t}"
    msg="${msg//$'\r'/\\r}"
    msg="${msg//$'\f'/\\f}"
    # markdown escape
    msg="${msg//\*/\\\\*}"
    echo "$msg"
}

sms_handle() {
    local file=$1
    local encoding
    local from
    local message
    encoding=$(grep "Alphabet:" "$file" | cut -d ' ' -f 2-)
    from=$(grep "From:" "$file" | cut -d ' ' -f 2-)
    case $encoding in
    "UCS2")
        message=$(sed '1,/^$/d' "$file" | iconv -f UCS-2 2>/dev/null || echo "⚠️ Parse error")
        ;;
    "UTF-8")
        message=$(sed '1,/^$/d' "$file")
        ;;
    *)
        message="⚠️ Unknown encoding: $encoding"
        ;;
    esac
    alert "$(escape_string "✉️ SMS from $from: $message")" && mv "$file" $sms_storage_dir/
}

# Check if the time drift lock is enabled and if it's stale based on the $MAX_TIME_DRIFT value.
# If the lock is stale, it means that the time has been adjusted by the NTP to a degree that could
# cause issues with time-based logic in the script.
if is_lock_enabled "$time_drift_lock" && is_lock_stale "$time_drift_lock" $MAX_TIME_DRIFT; then
    lock_remove $client_lock
fi
lock_create "$time_drift_lock"

if is_modem_up; then
    while IFS= read -r file; do
        sms_handle "$file"
    done < <(find $sms_incoming_dir -type f ! -name '*-concatenated' -printf "%T+ %p\n" | sort | cut -d ' ' -f 2-)
fi

if ((temp < WARNING_TEMP)); then
    lock_remove $temperature_lock
elif ! is_lock_enabled $temperature_lock; then
    alert "🌡 High Temperature: $temp°C" && lock_create $temperature_lock
fi

if ((bat < FULL_BAT)); then
    lock_remove $full_battery_lock
elif is_charging && ! is_lock_enabled $full_battery_lock; then
    alert "🔋 Full Battery: $bat%" && lock_create $full_battery_lock
fi

if ((bat > WARNING_BAT)) || is_charging; then
    lock_remove $critical_battery_lock
    lock_remove $warning_battery_lock
elif ! is_charging; then
    if ((bat <= SHUTDOWN_BAT)); then
        alert "🪫 Low Battery: $bat%, shutting down"
        shutdown
    elif ((bat <= CRITICAL_BAT)) && ! is_lock_enabled $critical_battery_lock; then
        alert "🪫 Low Battery: $bat%" && lock_create $critical_battery_lock
    elif ((bat <= WARNING_BAT)) && ! is_lock_enabled $warning_battery_lock; then
        alert "🪫 Low Battery: $bat%" && lock_create $warning_battery_lock
    fi
fi

if (is_charging && is_lan_up) || is_clients_exists; then
    lock_remove $client_lock
else
    if ! is_lock_enabled $client_lock; then
        lock_create $client_lock
    elif is_lock_stale $client_lock $CLIENTS_SHUTDOWN_TIME; then
        alert "💤 No active clients for $CLIENTS_SHUTDOWN_TIME min, shutting down"
        shutdown
    fi
fi
