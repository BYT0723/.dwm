#!/bin/bash
# VPSBandwidth: 通用 core + 厂商 provider。
#
# core（update/缓存/失败语义）不认识任何厂商细节；每个厂商实现一个
# vpsbandwidth_fetch_<provider>，契约:
#   1. 成功时 stdout 恰好一行 "used_gb|limit_gb|percent"（数字）
#   2. 成功返回 0；失败返回非 0 且 stdout 为空
#   3. 诊断只走 stderr；不写缓存、不发通知、不读 interval
# 加厂商 = 加函数 + 配置加一段 + 改 provider，core/展示/点击零改动。
# 规格见 tasks/SPEC-vpsbandwidth.md。

vpsbandwidth_config=${VPSBANDWIDTH_CONFIG:-$HOME/.config/dwm/vpsbandwidth.json}
vpsbandwidth_cache=${VPSBANDWIDTH_CACHE:-/tmp/dwm-status/vps-bandwidth}
vpsbandwidth_stamp=${VPSBANDWIDTH_STAMP:-$HOME/.local/state/dwm/status/vpsbandwidth-alert}

_vpsbw_ua="Mozilla/5.0 (X11; Linux x86_64; rv:160.0) Gecko/20100101 Firefox/160.0"
_vpsbw_dedione_base="https://dedione.com/clientarea.php/clientarea.php"

vpsbandwidth_config_get() {
    command -v jq >/dev/null 2>&1 || return 1
    jq -r "$1 // empty" "$vpsbandwidth_config" 2>/dev/null
}

vpsbandwidth_interval() {
    local interval
    interval=$(vpsbandwidth_config_get '.interval')
    [[ $interval =~ ^[0-9]+$ ]] && ((interval >= 60)) || interval=1800
    printf '%s' "$interval"
}

# 失败: 保留旧值并置 stale=1；stamp 去重，只在首次失败时告警一次
_vpsbw_fail() {
    local reason=$1 used limit percent ts stale

    if [[ -f $vpsbandwidth_cache ]]; then
        IFS='|' read -r used limit percent ts stale <"$vpsbandwidth_cache"
        if [[ -n $used ]]; then
            printf '%s|%s|%s|%s|1\n' "$used" "$limit" "$percent" "$ts" >"$vpsbandwidth_cache.tmp" \
                && mv -f "$vpsbandwidth_cache.tmp" "$vpsbandwidth_cache"
        fi
    fi

    if [[ ! -f $vpsbandwidth_stamp ]]; then
        mkdir -p "$(dirname "$vpsbandwidth_stamp")" 2>/dev/null
        : >"$vpsbandwidth_stamp" 2>/dev/null
        declare -F system-notify >/dev/null 2>&1 \
            && system-notify normal "VPS Bandwidth" "refresh failed: $reason" 2>/dev/null
    fi
    return 0
}

# 阈值首超通知: 用缓存里的旧值算旧档位, 与本次新值档位比较。
# 只在跨档升级 (0→80, 80→90, 0→90) 时通知; 降档/同档静默。
# 不落额外状态文件: /tmp 缓存本身就是上一次成功刷新的结果; 重启后无旧值
# 按档位 0 处理, 开机后最多补发一次。
_vpsbw_alert() {
    local prev=$1 used=$2 limit=$3 percent=$4
    local prev_band=0 new_band=0 pct free urgency

    if [[ $prev =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        pct=$((10#${prev%.*}))
        if ((pct >= 90)); then
            prev_band=90
        elif ((pct >= 80)); then
            prev_band=80
        fi
    fi

    pct=$((10#${percent%.*}))
    if ((pct >= 90)); then
        new_band=90
    elif ((pct >= 80)); then
        new_band=80
    fi

    ((new_band > prev_band && new_band > 0)) || return 0

    free=$(awk -v l="$limit" -v u="$used" \
        'BEGIN { f = l - u; if (f < 0) f = 0; printf "%.1f", f }')
    urgency=normal
    ((new_band == 90)) && urgency=critical
    declare -F system-notify >/dev/null 2>&1 \
        && system-notify "$urgency" "VPS Bandwidth" \
            "used ${used} / ${limit} GB (${percent}%), ${free} GB left (${new_band}% threshold)" \
            2>/dev/null
    return 0
}

update_vps_bandwidth() {
    local provider fn out re num rc
    local prev_percent used limit percent
    provider=$(vpsbandwidth_config_get '.provider')
    provider=${provider:-dedione}
    fn="vpsbandwidth_fetch_$provider"

    if ! declare -F "$fn" >/dev/null 2>&1; then
        _vpsbw_fail "unknown provider: $provider"
        return 0
    fi

    out=$("$fn" 2>/dev/null)
    rc=$?
    num='[0-9]+(\.[0-9]+)?'
    re="^${num}\\|${num}\\|${num}$"
    if ((rc != 0)) || [[ ! $out =~ $re ]]; then
        _vpsbw_fail "provider $provider returned no usable data"
        return 0
    fi

    # 覆盖前取旧 percent 作档位基准 (缺失/损坏时为空, 由 _vpsbw_alert 按 0 处理)
    prev_percent=""
    [[ -f $vpsbandwidth_cache ]] \
        && IFS='|' read -r _ _ prev_percent _ _ <"$vpsbandwidth_cache" 2>/dev/null

    mkdir -p "$(dirname "$vpsbandwidth_cache")"
    if printf '%s|%s\n' "$out" "$(date +%s)|0" >"$vpsbandwidth_cache.tmp" \
        && mv -f "$vpsbandwidth_cache.tmp" "$vpsbandwidth_cache"; then
        rm -f "$vpsbandwidth_stamp"
        IFS='|' read -r used limit percent <<<"$out"
        _vpsbw_alert "$prev_percent" "$used" "$limit" "$percent"
    fi
    return 0
}

# ---- Firefox 只读令牌（默认凭证来源） ----

_vpsbw_ff_profile_dir() {
    local ini base def dir
    ini=${VPSBANDWIDTH_FF_PROFILES:-$HOME/.mozilla/firefox/profiles.ini}
    base=$(dirname "$ini")

    if [[ -f $ini ]]; then
        def=$(awk -F= '$1 == "Default" && $2 != "" && $2 != "1" { print $2; exit }' "$ini" 2>/dev/null)
        if [[ -z $def ]]; then
            def=$(awk -F= '
                /^\[Profile/ { insec = 1; next }
                /^\[/ { insec = 0 }
                insec && $1 == "Path" { print $2; exit }
            ' "$ini" 2>/dev/null)
        fi
        if [[ -n $def ]]; then
            [[ $def == /* ]] || def=$base/$def
            printf '%s' "$def"
            return 0
        fi
    fi

    for dir in "$base"/*.default-release; do
        [[ -d $dir ]] && {
            printf '%s' "$dir"
            return 0
        }
    done
    return 1
}

_vpsbw_ff_token() {
    local dir db
    command -v sqlite3 >/dev/null 2>&1 || return 1
    dir=$(_vpsbw_ff_profile_dir) || return 1
    db=$dir/cookies.sqlite
    [[ -f $db ]] || return 1
    sqlite3 -noheader "file:$db?immutable=1" \
        "select value from moz_cookies where host like '%dedione.com' and name='WHMCSlogin_auth_tk' limit 1;" \
        2>/dev/null
}

# ---- provider: dedione (WHMCS) ----
# 两步: 产品页下发会话 cookie + 本次会话的 vtoken，再带这两样请求 API。
# vtoken 与会话绑定，直接复用外部链接会 csrf 失败。

vpsbandwidth_fetch_dedione() {
    local pid svs token jar page vt json base
    pid=$(vpsbandwidth_config_get '.dedione.product_id')
    svs=$(vpsbandwidth_config_get '.dedione.svs')
    if [[ -z $pid || -z $svs ]]; then
        echo "dedione: product_id / svs missing" >&2
        return 1
    fi

    token=$(vpsbandwidth_config_get '.dedione.auth_token')
    if [[ -z $token ]]; then
        token=$(_vpsbw_ff_token) || token=""
    fi
    if [[ -z $token ]]; then
        echo "dedione: no auth token (browser login or auth_token)" >&2
        return 1
    fi

    jar=$(mktemp) || return 1
    base=$_vpsbw_dedione_base

    page=$(curl -sS -m 20 --compressed -A "$_vpsbw_ua" \
        -c "$jar" -b "WHMCSlogin_auth_tk=$token" \
        "$base?action=productdetails&id=$pid&svs=$svs") || {
        rm -f "$jar"
        return 1
    }

    vt=$(printf '%s' "$page" | grep -o 'vtoken=[0-9a-fA-F]\{32\}' | head -n 1 | cut -d= -f2)
    if [[ -z $vt ]]; then
        rm -f "$jar"
        echo "dedione: no vtoken (login expired?)" >&2
        return 1
    fi

    json=$(curl -sS -m 20 --compressed -A "$_vpsbw_ua" \
        -H 'X-Requested-With: XMLHttpRequest' -b "$jar" \
        "$base?action=productdetails&vtoken=$vt&id=$pid&api=json&act=bandwidth&svs=$svs&show=undefined") || {
        rm -f "$jar"
        return 1
    }
    rm -f "$jar"

    printf '%s' "$json" | jq -er '
        .bandwidth as $b
        | select(($b.used_gb | type) == "number"
                 and ($b.limit_gb | type) == "number"
                 and ($b.percent | type) == "number")
        | "\($b.used_gb)|\($b.limit_gb)|\($b.percent)"
    ' 2>/dev/null || return 1
}

vpsbandwidth_page_dedione() {
    local pid svs
    pid=$(vpsbandwidth_config_get '.dedione.product_id')
    svs=$(vpsbandwidth_config_get '.dedione.svs')
    [[ -n $pid && -n $svs ]] || return 1
    xdg-open "$_vpsbw_dedione_base?action=productdetails&id=$pid&svs=$svs" >/dev/null 2>&1 &
}

# 点击入口: 按当前 provider 打开对应产品页（没有页面实现的 provider 静默跳过）
vpsbandwidth_open_page() {
    local provider fn
    provider=$(vpsbandwidth_config_get '.provider')
    provider=${provider:-dedione}
    fn="vpsbandwidth_page_$provider"
    declare -F "$fn" >/dev/null 2>&1 || return 1
    "$fn"
}
