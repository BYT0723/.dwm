# Icons initial
declare -A icons
icons["cpu"]=""
icons["temp"]=""
icons["memory"]=""
icons["disk"]=""
icons["mail"]="󰇮"
icons["mpd"]=""
icons["notification"]=""
icons["rss"]=""
icons["proxy"]="󰖟"
icons["docker"]=""
icons["volume"]=""
icons["volume_off"]=""
icons["volume_mute"]=""
icons["traffic_rx"]=""
icons["traffic_tx"]=""
icons["screencast"]=""

STACKED_SPLIT="^s^"

print_date() {
    timeIcons=('' '' '' '' '' '' '' '' '' '' '' '')
    local hour=$(date '+%l')

    if [ -f "$HOME/.local/state/dwm/status/date-collapse" ]; then
        printf "%s$STACKED_SPLIT%s" "$(date '+%m/%d (%a)')" " ${timeIcons[$((hour % 12))]} $(date '+%R')"
    else
        printf "%s %s" "$(date '+%m/%d(%a)')" "${timeIcons[$((hour % 12))]} $(date '+%R')"
    fi
}

# 通用进度条: 外框(+可选端子) / 内底 / 按比例填充, 末尾 ^d^ 复位色 + ^fN^ 前移留白
# bar_gauge <x> <y> <w> <h> <pct> <fg> <h|v> <advance> [nub_w]
#   h: 横向, 从右向左填充 (电池); v: 纵向, 从下向上填充 (VPS 余量)
#   nub_w 为端子宽度 (电池正极), 缺省无端子
bar_gauge() {
    local x=$1 y=$2 w=$3 h=$4 pct=$5 fg=$6 axis=$7 adv=$8 nub=${9:-0}
    local border=1 padding=1

    # 超额/负值钳制, 不把矩形画出框外
    ((pct > 100)) && pct=100
    ((pct < 0)) && pct=0

    # 端子: 右侧, 60% 高, 垂直居中
    if ((nub > 0)); then
        local rh=$((h * 60 / 100))
        printf '^c%s^' "$fg"
        printf '^r%d,%d,%d,%d^' "$x" "$((y + (h - rh) / 2))" "$nub" "$rh"
        x=$((x + nub)) w=$((w - nub))
    fi

    # 外框
    printf '^c%s^' "$fg"
    printf '^r%d,%d,%d,%d^' "$x" "$y" "$w" "$h"

    # 内底
    printf '^c%s^' "$black"
    printf '^r%d,%d,%d,%d^' "$((x + border))" "$((y + border))" \
        "$((w - 2 * border))" "$((h - 2 * border))"

    # 填充只占边框内、padding 内的区域; 非零比例至少留 1px (低电量/低余量仍可见)
    local inner_w=$((w - 2 * border - 2 * padding))
    local inner_h=$((h - 2 * border - 2 * padding))
    if ((pct > 0)); then
        local fill
        printf '^c%s^' "$fg"
        if [[ $axis == h ]]; then
            fill=$((inner_w * pct / 100))
            ((fill < 1)) && fill=1
            printf '^r%d,%d,%d,%d^' "$((x + border + padding + inner_w - fill))" \
                "$((y + border + padding))" "$fill" "$inner_h"
        else
            fill=$((inner_h * pct / 100))
            ((fill < 1)) && fill=1
            printf '^r%d,%d,%d,%d^' "$((x + border + padding))" \
                "$((y + h - border - padding - fill))" "$inner_w" "$fill"
        fi
    fi

    printf '^d^^f%d^' "$adv"
}

print_battery() {
    [ -z "$(command -v acpi)" ] && {
        system-notify critical "Tool Not Found" "please install acpi"
        return
    }

    local status percent fg
    IFS='|' read -r status percent < <(acpi -b | awk -F': |, |%' 'NR==1 {print $2 "|" $3}')
    [ -z "$percent" ] && return

    if [[ "$status" == "Discharging" ]]; then
        ((percent >= 20)) && fg="$white" || fg="$red"
    else
        fg="$green"
    fi

    bar_gauge 8 11 18 10 "$percent" "$fg" h 32 2
}

print_volume() {
    [ -z "$(command -v amixer)" ] && system-notify critical "Tool Not Found" "please install alsa-utils" && return

    # amixer 走 ALSA default (本机是 pipewire-pulse 插件). 音频服务卡住时单次
    # 调用会阻塞 ~30s, 而 refresh 是串行循环, 一个慢 block 就会冻结整条状态栏.
    read volume status < <(timeout 1 amixer get Master 2>/dev/null | awk -F'[][]' 'END{gsub(/%/,"",$2); print $2, $4}')

    [ -n "$volume" ] || return

    if [ "$status" == "off" ]; then
        fg="$red"
        icon=${icons[volume_mute]}
    elif [ "$volume" -eq 0 ]; then
        fg="$yellow"
        icon=${icons[volume_off]}
    else
        fg="$white"
        icon=${icons[volume]}
    fi
    printf "^c$fg^$icon"
    # printf "%s %2d" $icon $volume
}

print_brightness() {
    # 获取第一个 backlight 设备
    local dev
    dev=$(ls /sys/class/backlight | head -n1) || return

    # 读取当前亮度和最大亮度
    local cur max percent
    cur=$(cat /sys/class/backlight/"$dev"/brightness)
    max=$(cat /sys/class/backlight/"$dev"/max_brightness)

    # 计算百分比
    percent=$((100 * cur / max))

    # 输出图标 + 百分比
    local icon="󰃟"
    printf "%s %2d%%" "$icon" "$percent"
}

print_wifi() {
    local wifi=$(iwgetid -r)
    local icon="󰖩"

    [ -z "$wifi" ] && icon="󰖪"

    printf "%s %s" $icon $wifi
}

# Disk free space size
print_disk() {
    local mountpoint=$1
    read avail usage < <(df -h "${mountpoint}" | awk 'NR==2 {gsub(/%/,"",$5);print $4" "$5}')
    local fg="$white"

    [ "$usage" -gt 90 ] && fg="$yellow"
    # output
    printf "^c$fg^${icons[disk]}  $avail"
}

# Memory usage
print_mem() {
    read mem_usage mem_used < <(
        awk '
        /MemTotal:/     {total=$2}
        /MemAvailable:/ {avail=$2}
        END {
            used = total - avail
            usage = 100 * used / total
            printf "%d %f", usage, used/1024/1024
        }' /proc/meminfo
    )
    fg="$white"

    [ "$mem_usage" -gt 90 ] && fg="$yellow"
    printf "^c$fg^${icons[memory]} %4.1fG" $mem_used
}

cpu_temperature_filepath=""

print_temperature() {
    if [ -z "$cpu_temperature_filepath" ]; then
        vendor=$(awk '$1=="vendor_id" {print $3;exit}' /proc/cpuinfo)
        case $vendor in
        "GenuineIntel")
            cpu_temperature_filepath=$(awk '$1=="x86_pkg_temp" {sub("/[^/]+$","",FILENAME); print FILENAME}' /sys/class/thermal/thermal_zone*/type)"/temp"
            ;;
        "AuthenticAMD")
            cpu_temperature_filepath=$(awk '$1=="k10temp" {sub("/[^/]+$","",FILENAME); print FILENAME}' /sys/class/hwmon/hwmon*/name)"/temp1_input"
            ;;
        *)
            system-notify critical "[DWM STATUS BAR] Unsupported Arch" "unsupported arch $vendor to get cpu temperature" && return
            ;;
        esac
    fi

    read temp <"$cpu_temperature_filepath"
    temp=$((temp / 1000))

    fg=$white

    [ $temp -ge 70 ] && fg="$yellow"

    printf "^c$fg^${icons["temp"]} ${temp}°C"
}

print_cpu() {
    read cpu_usage <"$cpu_usage_path"
    fg=$white

    ((cpu_usage >= 80)) && fg="$yellow"

    # output
    printf "^c$fg^${icons[cpu]} %3d%%" "$cpu_usage"
    [ -f "$HOME/.local/state/dwm/status/cpu-collapse" ] && printf "$STACKED_SPLIT" || true
    print_temperature
}

print_weather() {
    local emoji label temp
    IFS=$'\t' read -r emoji label temp <"$weather_path"
    [ -n "$emoji" ] || return

    if [ -f "$HOME/.local/state/dwm/status/weather-collapse" ]; then
        printf "%s^s^%s" "$emoji $label" "$temp"
    else
        printf "%s %s" "$emoji $label" "$temp"
    fi
}

# Music Player Daemon
print_mpd() {
    [ ! -f "$mpd_status_path" ] && return

    IFS='|' read songname state <"$mpd_status_path"

    local fg="$white"

    # mpd play status
    [[ $state == "playing" ]] && fg="$blue"

    printf "^c$fg^${icons[mpd]}"
}

human_speed() {
    local bytes=$1

    if ((bytes < 1024)); then
        printf "%5dB/s" "$bytes"
    elif ((bytes < 1048576)); then
        printf "%5.1fK/s" "$(bc -l <<<"$bytes/1024")"
    elif ((bytes < 1073741824)); then
        printf "%5.1fM/s" "$(bc -l <<<"$bytes/1048576")"
    else
        printf "%5.1fG/s" "$(bc -l <<<"$bytes/1073741824")"
    fi
}

# Network traffic
print_speed() {
    # interface_name / interface_type / interface_ipv4 / ifrxspeed / iftxspeed
    read iface iftype ipv4 rx tx <"$network_traffic_path"

    local tx_fg="$white" rx_fg="$white"
    ((tx >= 2097152)) && tx_fg="$yellow" # 2MiB/s 上行
    ((rx >= 5242880)) && rx_fg="$yellow" # 5MiB/s 下行

    printf "^c$tx_fg^"
    ((tx > 0)) && printf "${icons[traffic_tx]} " || printf "  "
    human_speed $tx
    [ -f "$HOME/.local/state/dwm/status/net-traffic-collapse" ] && printf "$STACKED_SPLIT" || printf " "
    printf "^c$rx_fg^"
    ((rx > 0)) && printf "${icons[traffic_rx]} " || printf "  "
    human_speed $rx
}

print_mail() {
    read unread <"$mail_unread_path"
    (($unread > 0)) && printf "^c$yellow^${icons[mail]}"
}

print_rss() {
    read unread <"$rss_unread_path"
    [ -z "$unread" ] && return
    (($unread > 0)) && printf "^c$yellow^${icons[rss]}"
}

print_proxy() {
    (pgrep -x sing-box >/dev/null || pgrep -x dae >/dev/null) && printf "^c$white^${icons["proxy"]}"
}

print_docker() {
    [ -f "$docker_count_path" ] || return
    local running total unhealthy restarting
    read running total unhealthy restarting <"$docker_count_path"
    [ -n "$running" ] || return

    local fg="$white"
    if ((unhealthy > 0)); then
        fg="$red"
    elif ((restarting > 0)); then
        fg="$yellow"
    elif ((running > 0)); then
        fg="$blue"
    fi
    printf "^c$fg^${icons[docker]}  $running"
    ((unhealthy > 0)) && printf " !%d" "$unhealthy"
}

print_notification() {
    unread=$(dunstctl count history)
    ((unread > 0)) && printf "^c$yellow^${icons[notification]}"
}

# VPS 流量额度: 只读 daemon 写好的缓存, 绝不联网
print_vps_bandwidth() {
    [ -f "$vpsbandwidth_cache" ] || return

    local used limit percent _ts stale
    IFS='|' read -r used limit percent _ts stale <"$vpsbandwidth_cache" 2>/dev/null
    [[ -n $used && -n $limit && -n $percent ]] || return

    # 10# 防 "08" 被算术当八进制
    local used_g=$((10#${used%.*})) limit_g=$((10#${limit%.*})) pct=$((10#${percent%.*}))

    local fg="$white"
    if ((pct >= 90)); then
        fg="$red"
    elif ((pct >= 80)); then
        fg="$yellow"
    fi

    printf "^c$fg^usage:%dG${STACKED_SPLIT}limit:%dG" "$used_g" "$limit_g"
    [[ $stale == 1 ]] && printf "!"

    # 右侧 10x24 竖条: 余量 (100 - 已用%), 从下向上填充; 耗尽/超额时 bar_gauge 钳制为空
    bar_gauge 0 4 10 24 "$((100 - pct))" "$fg" v 20
}

print_screencast() {
    local pid_f="/tmp/screencaster_pid"
    local pid
    [ ! -f "$pid_f" ] && return
    read -r pid </tmp/screencaster_pid 2>/dev/null || return
    kill -0 "$pid" 2>/dev/null && printf "^c$red^${icons[screencast]}"
}
