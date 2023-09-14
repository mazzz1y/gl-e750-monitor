#!/bin/bash
# shellcheck disable=SC2059

[[ "$(pidof "$(basename "$0")")" != "$$" ]] && [[ "$1" != "debug" ]] && exit

readonly WARNING_TEMP="${WARNING_TEMP:-65}"
readonly FULL_BAT="${FULL_BAT:-85}"
readonly WARNING_BAT="${WARNING_BAT:-25}"
readonly CRITICAL_BAT="${CRITICAL_BAT:-15}"
readonly SHUTDOWN_BAT="${SHUTDOWN_BAT:-10}"
readonly CLIENTS_SHUTDOWN_TIME="${CLIENTS_SHUTDOWN_TIME:-20}"
readonly MAX_CLOCK_DRIFT="${MAX_CLOCK_DRIFT:-2}"
readonly ALERT_SCRIPT="${ALERT_SCRIPT:-"$(dirname "$0")/alert.sh"}"
readonly TX_POWER_ON_AC="${TX_POWER_ON_AC:-20}"

readonly TEMP_LOCK="/tmp/monitor_temp.lock"
readonly FULL_BAT_LOCK="/tmp/monitor_full_battery.lock"
readonly WARN_BAT_LOCK="/tmp/monitor_warn_battery.lock"
readonly CRIT_BAT_LOCK="/tmp/monitor_crit_battery.lock"
readonly CLIENT_LOCK="/tmp/monitor_client.lock"
readonly CLOCK_DRIFT_LOCK="/tmp/monitor_clock.lock"
readonly TX_POWER_LOCK="/tmp/txpower-%s.lock"

readonly SMS_IN_DIR="/etc/spool/sms/incoming"
readonly SMS_STORAGE_DIR="/etc/spool/sms/storage"

readonly MSG_LOW_BAT="🪫 Low Battery: %d%%"
readonly MSG_LOW_BAT_SHUTDOWN="🪫 Low Battery: %d%%, shutting down"
readonly MSG_FULL_BAT="🔋 Full Battery: %d%%"
readonly MSG_HIGH_TEMP="🌡 High Temperature: %d°C"
readonly MSG_CLIENTS_SHUTDOWN="💤 No active clients for %d min, shutting down"
readonly MSG_NEW_SMS="✉️ %s: %s"

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

is_clock_adjusted() {
    [[ -f $CLOCK_DRIFT_LOCK ]] && is_lock_stale "$CLOCK_DRIFT_LOCK" "$MAX_CLOCK_DRIFT"
}

is_lan_up() {
    local file=/sys/class/net/br-lan/operstate
    [[ -f $file && $(<$file) == up ]]
}

is_connected() {
    local file
    for file in /tmp/run/mwan3track/*/STATUS; do
        [[ $(<"$file") == online ]] && return 0
    done
    return 1
}

is_clients_exist() {
    is_lan_up || return 1
    awk '$15 == 1 {count++} END {if (count > 0) exit 0; else exit 1}' /tmp/tertf/tertfinfo
}

is_charging() {
    [[ $CHARGE -eq 1 ]]
}

get_current_txpower() {
    iwinfo "$1" info | grep 'Tx-Power' | awk '{print $2}'
}

get_wlan_interfaces() {
    local interface
    for interface in /sys/class/net/wlan*; do
        if [[ -d "$interface" ]]; then
            basename "$interface"
        fi
    done
}

alert() {
    ! is_connected && return 1
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

if [[ -n "$TX_POWER_ON_AC" ]]; then
    for interface in $(get_wlan_interfaces); do
        tx_power_lock="$(printf $TX_POWER_LOCK "$interface")"
        if is_charging && [[ ! -f $tx_power_lock ]]; then
            current_txpower=$(get_current_txpower "$interface")
            echo "$current_txpower" > "$tx_power_lock"
            if [[ "$TX_POWER_ON_AC" != "$current_txpower" ]]; then
              iw dev "$interface" set txpower fixed "$TX_POWER_ON_AC"00
            fi
        elif ! is_charging && [[ -f $tx_power_lock ]] ; then
            iw dev "$interface" set txpower fixed "$(cat "$tx_power_lock")"00
            rm -f "$tx_power_lock"
        fi
    done
fi

if is_connected; then
    while IFS= read -r sms_file; do
        sms_handle "$sms_file"
    done < <(find $SMS_IN_DIR \
        -type f ! -name '*-concatenated' \
        -exec awk '/^Sent:/ { print $2 " " $3 " " FILENAME }' {} \; | sort | cut -d ' ' -f 3-)
fi

if ((TEMP < WARNING_TEMP)); then
    rm -f $TEMP_LOCK
elif [[ ! -f $TEMP_LOCK ]]; then
    alert "$MSG_HIGH_TEMP" "$TEMP" && touch $TEMP_LOCK
fi

if ((BAT < FULL_BAT)); then
    rm -f $FULL_BAT_LOCK
elif is_charging && [[ ! -f $FULL_BAT_LOCK ]]; then
    alert "$MSG_FULL_BAT" "$BAT" && touch $FULL_BAT_LOCK
fi

if ((BAT > WARNING_BAT)) || is_charging; then
    rm -f $CRIT_BAT_LOCK
    rm -f $WARN_BAT_LOCK
elif ! is_charging; then
    if ((BAT <= SHUTDOWN_BAT)); then
        alert "$MSG_LOW_BAT_SHUTDOWN" "$BAT"
        shutdown
    elif ((BAT <= CRITICAL_BAT)) && [[ ! -f $CRIT_BAT_LOCK ]]; then
        alert "$MSG_LOW_BAT" "$BAT" && touch $CRIT_BAT_LOCK
    elif [[ ! -f $WARN_BAT_LOCK ]]; then
        alert "$MSG_LOW_BAT" "$BAT" && touch $WARN_BAT_LOCK
    fi
fi

if is_clients_exist || is_clock_adjusted || (is_charging && is_lan_up); then
    rm -f $CLIENT_LOCK
elif [[ ! -f $CLIENT_LOCK ]]; then
    touch $CLIENT_LOCK
elif is_lock_stale $CLIENT_LOCK "$CLIENTS_SHUTDOWN_TIME"; then
    alert "$MSG_CLIENTS_SHUTDOWN" "$CLIENTS_SHUTDOWN_TIME"
    shutdown
fi

touch $CLOCK_DRIFT_LOCK
