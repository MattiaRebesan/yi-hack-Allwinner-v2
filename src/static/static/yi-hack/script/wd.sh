#!/bin/sh

CONF_FILE="etc/system.conf"
CAMERA_CONF_FILE="etc/camera.conf"

YI_HACK_PREFIX="/tmp/sd/yi-hack"
MODEL_SUFFIX=$(cat /tmp/sd/yi-hack/model_suffix)

START_STOP_SCRIPT=$YI_HACK_PREFIX/script/service.sh

#LOG_FILE="/tmp/sd/wd.log"
LOG_FILE="/dev/null"
LOGWIFI_FILE="/tmp/sd/hack_wififailsafe.log"

COUNTER=0
COUNTER_LIMIT=10
# 30, not upstream's 10. Every pass forks a couple of dozen short-lived
# processes on a single-core box; at 10s that alone kept the run queue
# permanently occupied (load ~1.2 with the CPU 55% idle). Nothing this
# watchdog looks for needs sub-minute detection.
INTERVAL=30
# Shorter interval once check_rtsp suspects a hang, so a genuinely locked
# rRTSPServer is still caught in under a minute.
SUSPECT_INTERVAL=5
WIFI_FAILSAFE_COUNTER=0
LAST_JIFFIES=""

get_camera_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CAMERA_CONF_FILE | cut -d "=" -f2-
}

get_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CONF_FILE | cut -d "=" -f2-
}

restart_rtsp()
{
    $START_STOP_SCRIPT rtsp start
}

check_rtsp()
{
    if [[ $(get_camera_config SWITCH_ON) == "yes" ]] ; then
        #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking RTSP process..." >> $LOG_FILE
        # One netstat, not two. Walking /proc/net/tcp is the expensive part,
        # so filter once and count the result twice.
        NETSTAT=`$YI_HACK_PREFIX/bin/netstat -an 2>&1 | grep ":$RTSP_PORT_NUMBER "`
        LISTEN=`echo "$NETSTAT" | grep -c LISTEN`
        SOCKET=`echo "$NETSTAT" | grep -c ESTABLISHED`

        # Upstream ran `top -b -n 2 -d 1` here purely to read one process's
        # CPU%. That blocks a full second on every pass and walks all of /proc
        # twice to do it - on this single-core camera it was the single largest
        # consumer on an otherwise idle system. utime+stime from
        # /proc/<pid>/stat is the same signal for three forks and no delay: if
        # the counter has not moved since the previous pass, that process
        # burned no CPU in the interval. Fields 14 and 15 are utime and stime;
        # the offsets are only unstable when comm contains a space, and this
        # one does not.
        RTSP_PID=`ps 2>/dev/null | awk '/rRTSPServer/ && $0 !~ /awk/ {print $1; exit}'`
        if [ -n "$RTSP_PID" ] && [ -r /proc/$RTSP_PID/stat ]; then
            JIFFIES=`awk '{print $14+$15}' /proc/$RTSP_PID/stat 2>/dev/null`
        else
            JIFFIES=""
        fi

        if [ $LISTEN -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
            killall -q rRTSPServer
            sleep 1
            restart_rtsp
        fi
        if [ -z "$JIFFIES" ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes, restarting..." >> $LOG_FILE
            killall -q rRTSPServer
            sleep 1
            restart_rtsp
            COUNTER=0
        fi
        if [ $SOCKET -gt 0 ]; then
            # A stream is connected but the process consumed no CPU since the
            # last pass: it is serving nothing. Same condition upstream tested
            # as CPU == "0.0".
            if [ -n "$JIFFIES" ] && [ "$JIFFIES" == "$LAST_JIFFIES" ]; then
                COUNTER=$((COUNTER+1))
                echo "$(date +'%Y-%m-%d %H:%M:%S') - Detected possible locked process ($COUNTER)" >> $LOG_FILE
                if [ $COUNTER -ge $COUNTER_LIMIT ]; then
                    echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
                    killall -q rRTSPServer
                    sleep 1
                    restart_rtsp
                    COUNTER=0
                fi
            else
                COUNTER=0
            fi
        fi
        LAST_JIFFIES=$JIFFIES
    else
        echo "Camera is swiched off no rtsp restart needed" >> $LOG_FILE
    fi
}

check_rmm()
{
    #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking rmm process..." >> $LOG_FILE

    # Method 1: Basic ps check (most reliable, avoids ps ww parsing issues).
    # One awk instead of grep|grep|grep - same test, two forks instead of four.
    PS_BASIC=`ps 2>/dev/null | awk '/\.\/rmm/ && $0 !~ /awk/ {n++} END {print n+0}'`
    if [ $PS_BASIC -gt 0 ]; then
        # Reset failure counter on successful detection
        rm -f /tmp/rmm_fail_count 2>/dev/null
        return 0
    fi

    # Method 2: Extended ps as fallback (original method)
    PS_WW=`ps ww | grep rmm | grep -v grep | grep -c ^`
    if [ $PS_WW -gt 0 ]; then
        # Reset failure counter on successful detection  
        rm -f /tmp/rmm_fail_count 2>/dev/null
        return 0
    fi

    # Failure handling with counter to prevent immediate reboots
    echo "$(date +'%Y-%m-%d %H:%M:%S') - rmm detection failed" >> $LOG_FILE

    # Read current failure count
    if [ -f /tmp/rmm_fail_count ]; then
        FAIL_COUNT=$(cat /tmp/rmm_fail_count)
    else
        FAIL_COUNT=0
    fi

    # Increment failure count
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo $FAIL_COUNT > /tmp/rmm_fail_count

    echo "$(date +'%Y-%m-%d %H:%M:%S') - rmm failure count: $FAIL_COUNT/5" >> $LOG_FILE

    # Only reboot after 5 consecutive failures (~50 seconds with 10s interval)
    if [ $FAIL_COUNT -ge 5 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - rmm failed 5 times consecutively, rebooting..." >> $LOG_FILE
        reboot
    fi
}

check_mqtt()
{
    #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking mqttv4 process..." >> $LOG_FILE

    # Upstream restarted mqttv4 whenever it was absent, without ever asking
    # whether MQTT was switched on. That resurrects a daemon the config says is
    # off - this camera was found running mqttv4 with MQTT=no in system.conf.
    if [[ $(get_config MQTT) != "yes" ]] ; then
        return
    fi

    PS=`ps ww 2>/dev/null | awk '/mqttv4/ && $0 !~ /awk/ {n++} END {print n+0}'`

    if [ $PS -eq 0 ]; then
        echo "check_mqtt failed, restart it!" >> $LOG_FILE
        $START_STOP_SCRIPT mqtt start
    fi
}

check_wifi()
{
    # Check WiFi connection using multiple methods for compatibility
    # Some camera models (e.g., r37gb) have broken wpa_cli that causes segfaults

    WIFI_CONNECTED=0

    # Method 1: does the interface hold an IP. Two forks, and upstream already
    # described it as "reliable on all models" - it was just sitting behind the
    # expensive check instead of in front of it. wpa_cli costs a subshell, a
    # `sleep 2` watchdog, a killall and a wait every single pass, and in the
    # normal case (wifi up) it tells us nothing this does not.
    if ifconfig wlan0 2>/dev/null | grep -q "inet addr:"; then
        WIFI_CONNECTED=1
    fi

    # Method 2: no IP - ask wpa_supplicant directly before declaring failure.
    # Some models (e.g. r37gb) have a wpa_cli that segfaults or hangs, hence
    # the auto-kill.
    if [ $WIFI_CONNECTED -eq 0 ] && [ -x /home/base/tools/wpa_cli ]; then
        (sleep 2 && killall -9 wpa_cli 2>/dev/null) &
        KILLER_PID=$!

        WPA_OUTPUT=$(/home/base/tools/wpa_cli -i wlan0 status 2>/dev/null)
        WPA_EXIT=$?

        kill $KILLER_PID 2>/dev/null
        wait $KILLER_PID 2>/dev/null

        if [ $WPA_EXIT -eq 0 ] && echo "$WPA_OUTPUT" | grep -q "wpa_state=COMPLETED"; then
            WIFI_CONNECTED=1
        fi
    fi

    # Method 3: Additional check - interface carrier state
    if [ $WIFI_CONNECTED -eq 0 ]; then
        if [ -f /sys/class/net/wlan0/carrier ]; then
            CARRIER=$(cat /sys/class/net/wlan0/carrier 2>/dev/null)
            if [ "$CARRIER" != "1" ]; then
                WIFI_CONNECTED=0
            fi
        fi
    fi

    # Handle WiFi disconnection
    if [ $WIFI_CONNECTED -eq 0 ]; then
        # Rotate log file to prevent it from growing too large
        if [ -e "$LOGWIFI_FILE" ]; then
            $YI_HACK_PREFIX/usr/bin/tail -n 145 "$LOGWIFI_FILE" > "$LOGWIFI_FILE.tmp" && mv "$LOGWIFI_FILE.tmp" "$LOGWIFI_FILE"
        fi

        echo -e "$(date): WiFi connection lost (failsafe attempt $((WIFI_FAILSAFE_COUNTER + 1))/6)" >> "$LOGWIFI_FILE"

        WIFI_FAILSAFE_COUNTER=$((WIFI_FAILSAFE_COUNTER + 1))

        if [ "$WIFI_FAILSAFE_COUNTER" -ge 6 ]; then
            echo -e "$(date): WiFi connection could not be restored after 6 attempts. Rebooting..." >> "$LOGWIFI_FILE"
            reboot
        else
            echo -e "$(date): Attempting WiFi reconnect..." >> "$LOGWIFI_FILE"

            # Try to reconnect
            sleep 2
            ifconfig wlan0 down
            sleep 1
            ifconfig wlan0 up
            sleep 1

            # Try wpa_cli reconfigure if available and working
            if [ -x /home/base/tools/wpa_cli ]; then
                (sleep 2 && killall -9 wpa_cli 2>/dev/null) &
                KILLER_PID=$!
                /home/base/tools/wpa_cli -i wlan0 reconfigure 2>/dev/null
                kill $KILLER_PID 2>/dev/null
                wait $KILLER_PID 2>/dev/null
            fi

            # Run wifidhcp.sh
            $YI_HACK_PREFIX/script/wifidhcp.sh
        fi
    else
        # WiFi is connected - reset failure counter
        if [ $WIFI_FAILSAFE_COUNTER -gt 0 ]; then
            echo -e "$(date): WiFi connection restored" >> "$LOGWIFI_FILE"
            WIFI_FAILSAFE_COUNTER=0
        fi
    fi
}

if [[ $(get_config RTSP) == "no" ]] ; then
    exit
fi

case $(get_config RTSP_PORT) in
    ''|*[!0-9]*) RTSP_PORT=554 ;;
    *) RTSP_PORT=$(get_config RTSP_PORT) ;;
esac

if [ ! -z $RTSP_PORT ]; then
    RTSP_PORT_NUMBER=$RTSP_PORT
fi

echo "$(date +'%Y-%m-%d %H:%M:%S') - Starting RTSP watchdog..." >> $LOG_FILE

while true
do
    check_rtsp
    check_rmm
    check_mqtt
    check_wifi

    echo 1500 > /sys/class/net/eth0/mtu
    echo 1500 > /sys/class/net/wlan0/mtu

    # Always sleep. Upstream skipped the sleep entirely while COUNTER > 0, and
    # got away with it only because `top -b -n 2 -d 1` inside check_rtsp
    # blocked for a second and paced the loop by accident. With that gone an
    # unslept branch is a genuine busy-loop, so the suspected-hang path gets
    # its own short interval instead of none.
    if [ $COUNTER -eq 0 ]; then
        sleep $INTERVAL
    else
        sleep $SUSPECT_INTERVAL
    fi
done
