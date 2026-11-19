#!/usr/bin/env bash

# Use dae's native HTTP API to manage proxy groups.
#
# dae has no Clash API: groups and members are listed through /api/v1/groups and
# switched with PUT /api/v1/groups/{id}/selection. The choice is an in-memory
# pin (source: "override"), cleared by `dae reload` or a restart.

SELF_DIR="$(dirname "${BASH_SOURCE[0]}")"
ROFI_DIR="$(dirname "$SELF_DIR")"
WORK_DIR="$(dirname "$ROFI_DIR")"

MODULE_THEME="$ROFI_DIR/applets/type-1/style-2.rasi"
MODULE_WIDTH=600

source "$SELF_DIR"/lib-module.sh
source "$WORK_DIR/utils/notify.sh"

API=${1:-${DAE_API:-http://127.0.0.1:9527}}
API=${API%/}
SECRET=${2:-${DAE_API_SECRET:-}}

ACTION_SUSPEND='󰏤 Suspend dae'
ACTION_RESUME='󰐊 Resume dae'

API_ERR=""
BODY=""

# -----------------------------
# Native API
# -----------------------------

api_call() { # method path [json body] -> BODY; failure sets API_ERR
    local method=$1 path=$2 data=${3:-}
    local -a args=(-sS -m 5 -X "$method" -H "Accept: application/json" -w $'\n%{http_code}')
    [[ -n "$SECRET" ]] && args+=(-H "Authorization: Bearer $SECRET")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data-binary "$data")

    local raw code msg
    raw=$(curl "${args[@]}" "$API$path" 2>/dev/null) || {
        API_ERR="无法连接 $API"
        return 1
    }
    code=${raw##*$'\n'}
    BODY=${raw%$'\n'*}
    if [[ "$code" != 2* ]]; then
        msg=$(jq -r '.error.message // .error.code // empty' <<<"$BODY" 2>/dev/null)
        API_ERR="HTTP $code${msg:+: $msg}"
        return 1
    fi
    return 0
}

# -----------------------------
# Menu rows
# -----------------------------

group_rows() { # groups_json nodes_json -> name \t id \t policy \t delay
    local groups=${1:-'[]'} nodes=${2:-'{"nodes":[]}'}
    jq -r --argjson nodes "$nodes" '
        def pick($a): if ($a | length) > 0 then $a[0] else null end;
        def nlat($id):
            pick([$nodes.nodes[]? | select(.id == $id) | (.health // [])[]?
                | select(.transport == "tcp" and .purpose == "data" and .ip_version == "ipv4")
                | (.sorting_latency_ms // .moving_avg_ms // .latency_ms)]);
        .[] as $g |
        (nlat($g.selection.tcp_member_id)) as $lat |
        [ $g.name, $g.id, $g.policy.native,
          (if $lat != null then "\($lat | round)ms" else "-" end)
        ] | @tsv
    ' <<<"$groups"
}

member_rows() { # group_json -> label \t id \t name \t delay, plus Auto when pinned
    local group=${1:-'{}'}
    jq -r '
        def pick($a): if ($a | length) > 0 then $a[0] else null end;
        def health($g; $id):
            [$g.runtime.health[]? | select(.member_id == $id
                and .transport == "tcp" and .purpose == "data" and .ip_version == "ipv4")];
        def lat($g; $id):
            pick([health($g; $id)[] | (.sorting_latency_ms // .moving_avg_ms // .latency_ms)]);
        def hstate($g; $id):
            pick([health($g; $id)[] | .state]);
        . as $g |
        ($g.runtime.selection.tcp.member_id) as $tcp |
        ($g.runtime.selection.udp.member_id) as $udp |
        (($g.capabilities.can_override // false) and
         (($g.runtime.selection.tcp.source // "") == "override" or
          ($g.runtime.selection.udp.source // "") == "override")) as $pinned |
        (if $pinned then (["↺ Auto", "__auto__", "Auto", "-"] | @tsv) else empty end),
        ($g.members[]? |
            . as $m |
            (if $m.id == $tcp then "✓ " elif $m.id == $udp then "~ " else "  " end) as $mark |
            (lat($g; $m.id)) as $l |
            (hstate($g; $m.id)) as $s |
            [ $mark + $m.name, $m.id, $m.name,
              (if $l != null then "\($l | round)ms"
               elif $s == "unavailable" then "✗"
               else "-" end)
            ] | @tsv)
    ' <<<"$group"
}

# Raw tab rows -> aligned display lines (column handles UTF-8 width; last col right-aligned)
load_group_menu() { # groups_json nodes_json -> GROUP_LABELS / GROUP_IDS / GROUP_NAMES
    GROUP_LABELS=() GROUP_IDS=() GROUP_NAMES=()
    local name id policy delay
    while IFS=$'\t' read -r name id policy delay; do
        [[ -z "$name" ]] && continue
        GROUP_LABELS+=("$name"$'\t'"$policy"$'\t'"$delay")
        GROUP_IDS+=("$id")
        GROUP_NAMES+=("$name")
    done < <(group_rows "$1" "$2")
    ((${#GROUP_LABELS[@]})) &&
        mapfile -t GROUP_LABELS < <(printf '%s\n' "${GROUP_LABELS[@]}" | column -t -s $'\t' -R 3)
}

load_member_menu() { # group_json -> MEMBER_LABELS / MEMBER_IDS / MEMBER_NAMES
    MEMBER_LABELS=() MEMBER_IDS=() MEMBER_NAMES=()
    local label id name delay
    while IFS=$'\t' read -r label id name delay; do
        [[ -z "$label" ]] && continue
        MEMBER_LABELS+=("$label"$'\t'"$delay")
        MEMBER_IDS+=("$id")
        MEMBER_NAMES+=("$name")
    done < <(member_rows "$1")
    ((${#MEMBER_LABELS[@]})) &&
        mapfile -t MEMBER_LABELS < <(printf '%s\n' "${MEMBER_LABELS[@]}" | column -t -s $'\t' -R 2)
}

row_index() { # needle array_name -> index
    local -n rows=$2
    local i
    for i in "${!rows[@]}"; do
        [[ "${rows[i]}" == "$1" ]] && {
            printf '%s' "$i"
            return 0
        }
    done
    return 1
}

# -----------------------------
# Actions
# -----------------------------

switch_node() { # group_id member_id
    local payload
    payload=$(jq -cn --arg m "$2" '{member_id: $m, network: "both"}')
    api_call PUT "/api/v1/groups/$1/selection" "$payload"
}

clear_pin() { # group_id
    api_call DELETE "/api/v1/groups/$1/selection?network=both"
}

toggle_suspend() { # current lifecycle state
    local op=suspend
    [[ "$1" == suspended ]] && op=resume

    if ! api_call POST "/api/v1/operations/$op"; then
        system-notify critical "dae" "$op 失败: $API_ERR"
        return 1
    fi

    local oid
    oid=$(jq -r '.operation_id // empty' <<<"$BODY")
    if [[ -z "$oid" ]]; then
        system-notify low "dae" "$op 已提交"
        return 0
    fi

    local i status
    for i in {1..20}; do
        sleep 0.1
        api_call GET "/api/v1/operations/$oid" || break
        status=$(jq -r '.status // empty' <<<"$BODY")
        if [[ "$status" == succeeded ]]; then
            system-notify low "dae" "$op 完成"
            return 0
        fi
        if [[ "$status" == failed ]]; then
            local msg
            msg=$(jq -r '.error.message // "unknown error"' <<<"$BODY")
            system-notify critical "dae" "$op 失败: $msg"
            return 1
        fi
    done

    system-notify low "dae" "$op 已提交"
    return 0
}

# -----------------------------
# Menus
# -----------------------------

group_menu() { # group_id group_name
    local gid=$1 gname=$2 group kind pinned mesg
    if ! api_call GET "/api/v1/groups/$gid"; then
        system-notify critical "dae" "读取 $gname 失败: $API_ERR"
        return 1
    fi
    group=$BODY
    kind=$(jq -r '.policy.kind // empty' <<<"$group")
    if [[ "$kind" == fixed ]]; then
        system-notify low "dae" "$gname: policy fixed，不支持运行时切换"
        return 1
    fi

    pinned=$(jq -r '((.runtime.selection.tcp.source // "") == "override" or
        (.runtime.selection.udp.source // "") == "override")' <<<"$group")
    mesg="policy: $(jq -r '.policy.native' <<<"$group")"
    [[ "$pinned" == true ]] && mesg+=" · pinned"

    local chosen idx mid
    load_member_menu "$group"
    chosen=$(printf '%s\n' "${MEMBER_LABELS[@]}" | module_sub_rofi "󰒓 $gname" "$mesg") || return 0
    [[ -z "$chosen" ]] && return 0

    idx=$(row_index "$chosen" MEMBER_LABELS) || return 0
    mid=${MEMBER_IDS[idx]}
    if [[ "$mid" == "__auto__" ]]; then
        clear_pin "$gid" || {
            system-notify critical "dae" "清除 pin 失败: $API_ERR"
            return 1
        }
        system-notify low "dae" "$gname: 恢复自动选择"
        return 0
    fi

    switch_node "$gid" "$mid" || {
        system-notify critical "dae" "切换失败: $API_ERR"
        return 1
    }
    system-notify low "dae" "$gname → ${MEMBER_NAMES[idx]}"
}

main_menu() {
    while :; do
        local state groups nodes action chosen idx gid count
        if ! api_call GET /api/v1/runtime; then
            system-notify critical "dae" "读取状态失败: $API_ERR"
            return 1
        fi
        state=$(jq -r '.lifecycle.state // "unknown"' <<<"$BODY")
        if [[ "$state" == suspended ]]; then
            action=$ACTION_RESUME
        else
            action=$ACTION_SUSPEND
        fi

        api_call GET /api/v1/groups || {
            system-notify critical "dae" "读取代理组失败: $API_ERR"
            return 1
        }
        groups=$BODY
        api_call GET '/api/v1/nodes?limit=1000' || {
            system-notify critical "dae" "读取节点失败: $API_ERR"
            return 1
        }
        nodes=$BODY

        count=$(jq 'length' <<<"$groups")
        load_group_menu "$groups" "$nodes"
        GROUP_LABELS+=("$action")
        GROUP_IDS+=("__action__")
        GROUP_NAMES+=("$action")

        chosen=$(printf '%s\n' "${GROUP_LABELS[@]}" |
            module_sub_rofi "󰖟 dae" "state: $state · $count groups") || return 0
        [[ -z "$chosen" ]] && return 0

        idx=$(row_index "$chosen" GROUP_LABELS) || continue
        gid=${GROUP_IDS[idx]}
        if [[ "$gid" == "__action__" ]]; then
            toggle_suspend "$state"
            continue
        fi
        group_menu "$gid" "${GROUP_NAMES[idx]}"
    done
}

main() {
    command -v jq >/dev/null || {
        system-notify critical "dae" "缺少 jq"
        exit 0
    }
    if ! pgrep -x dae >/dev/null; then
        system-notify critical "dae" "dae is not running!"
        exit 0
    fi
    if ! api_call GET /api/v1/groups; then
        system-notify critical "dae" "API 不可用: $API_ERR（确认 config.dae 已启用 api{}）"
        exit 0
    fi
    main_menu
}

[[ ${DAE_NO_DISPATCH:-0} == 1 ]] || main
