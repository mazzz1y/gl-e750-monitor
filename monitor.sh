#!/bin/bash
# shellcheck disable=SC2059
#
# opkg install bash findutils curl
# * * * * * nice -n 19 /root/monitor.sh > /dev/null 2>&1

[[ "$(pidof "$(basename "$0")")" != "$$" ]] && [[ "$1" != "debug" ]] && exit

readonly WARNING_TEMP="${WARNING_TEMP:-65}"
readonly FULL_BAT="${FULL_BAT:-85}"
readonly WARNING_BAT="${WARNING_BAT:-25}"
readonly CRITICAL_BAT="${CRITICAL_BAT:-15}"
readonly SHUTDOWN_BAT="${SHUTDOWN_BAT:-10}"
readonly CLIENTS_SHUTDOWN_TIME="${CLIENTS_SHUTDOWN_TIME:-20}"
readonly MAX_CLOCK_DRIFT="${MAX_CLOCK_DRIFT:-2}"
readonly ALERT_SCRIPT="${ALERT_SCRIPT:-"$(dirname "$0")/alert.sh"}"

readonly TEMP_LOCK="/tmp/monitor_temp.lock"
readonly FULL_BAT_LOCK="/tmp/monitor_full_battery.lock"
readonly WARN_BAT_LOCK="/tmp/monitor_warn_battery.lock"
readonly CRIT_BAT_LOCK="/tmp/monitor_crit_battery.lock"
readonly CLIENT_LOCK="/tmp/monitor_client.lock"
readonly CLOCK_DRIFT_LOCK="/tmp/monitor_clock.lock"

readonly SMS_IN_DIR="/etc/spool/sms/incoming"
readonly SMS_STORAGE_DIR="/etc/spool/sms/storage"

readonly MSG_LOW_BAT="🪫 Low Battery: %d%%"
readonly MSG_LOW_BAT_SHUTDOWN="🪫 Low Battery: %d%%, shutting down"
readonly MSG_FULL_BAT="🔋 Full Battery: %d%%"
readonly MSG_HIGH_TEMP="🌡 High Temperature: %d°C"
readonly MSG_CLIENTS_SHUTDOWN="💤 No active clients for %d min, shutting down"
readonly MSG_NEW_SMS="✉️ SMS from %s: %s"

{
    read -r TEMP
    read -r BAT
    read -r CHARGE
} < <(jsonfilter -i /tmp/mcu_data -e '@.T' -e '@.P' -e '@.C' | cut -d '.' -f 1)
readonly TEMP BAT CHARGE

is_lock_stale() {
    local file_name=$1
    local stale_time=$2
    [[ $(($(date +%s) - $(date -r "$file_name" +%s))) -gt $((stale_time * 60)) ]]
}

is_lock_enabled() {
    [[ -f $1 ]]
}

is_clock_adjusted() {
    is_lock_enabled "$CLOCK_DRIFT_LOCK" && is_lock_stale "$CLOCK_DRIFT_LOCK" "$MAX_CLOCK_DRIFT"
}

is_lan_up() {
    local file_name=/sys/class/net/br-lan/operstate
    [[ -f $file_name && $(<$file_name) == up ]]
}

is_modem_up() {
    local file_name=/tmp/run/mwan3track/modem_1_1_2/STATUS
    [[ -f $file_name && $(<$file_name) == online ]]
}

is_clients_exist() {
    is_lan_up || return 1
    awk '$15 == 1 {count++} END {if (count > 0) exit 0; else exit 1}' /tmp/tertf/tertfinfo
}

is_charging() {
    [[ $CHARGE -eq 1 ]]
}

lock_create() {
    touch "$1"
}

lock_remove() {
    rm -f "$1"
}

alert() {
    ! is_modem_up && return 1
    $ALERT_SCRIPT "$(printf "$@" | sed -e 's/[[:cntrl:]]//g')"
}

shutdown() {
    echo "{\"poweroff\": \"1\"}" >/tmp/mcu_message && sleep 0.5 && killall -17 e750-mcu && exit 0
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

    alert "$MSG_NEW_SMS" "$from" "$message" && mv "$file" $SMS_STORAGE_DIR/
}

if is_modem_up; then
    while IFS= read -r file; do
        sms_handle "$file"
    done < <(find $SMS_IN_DIR \
        -type f ! -name '*-concatenated' \
        -exec awk '/^Sent:/ { print $2 " " $3 " " FILENAME }' {} \; | sort | cut -d ' ' -f 3-)
fi

if ((TEMP < WARNING_TEMP)); then
    lock_remove $TEMP_LOCK
elif ! is_lock_enabled $TEMP_LOCK; then
    alert "$MSG_HIGH_TEMP" "$TEMP" && lock_create $TEMP_LOCK
fi

if ((BAT < FULL_BAT)); then
    lock_remove $FULL_BAT_LOCK
elif is_charging && ! is_lock_enabled $FULL_BAT_LOCK; then
    alert "$MSG_FULL_BAT" "$BAT" && lock_create $FULL_BAT_LOCK
fi

if ((BAT > WARNING_BAT)) || is_charging; then
    lock_remove $CRIT_BAT_LOCK
    lock_remove $WARN_BAT_LOCK
elif ! is_charging; then
    if ((BAT <= SHUTDOWN_BAT)); then
        alert "$MSG_LOW_BAT_SHUTDOWN" "$BAT"
        shutdown
    elif ((BAT <= CRITICAL_BAT)) && ! is_lock_enabled $CRIT_BAT_LOCK; then
        alert "$MSG_LOW_BAT" "$BAT" && lock_create $CRIT_BAT_LOCK
    elif ! is_lock_enabled $WARN_BAT_LOCK; then
        alert "$MSG_LOW_BAT" "$BAT" && lock_create $WARN_BAT_LOCK
    fi
fi

if is_clients_exist || is_clock_adjusted || (is_charging && is_lan_up); then
    lock_remove $CLIENT_LOCK
elif ! is_lock_enabled $CLIENT_LOCK; then
    lock_create $CLIENT_LOCK
elif is_lock_stale $CLIENT_LOCK "$CLIENTS_SHUTDOWN_TIME"; then
    alert "$MSG_CLIENTS_SHUTDOWN" "$CLIENTS_SHUTDOWN_TIME"
    shutdown
fi

lock_create $CLOCK_DRIFT_LOCK
