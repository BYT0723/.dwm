#!/usr/bin/env bash
# ST_PROXY 右键回归测试:
#   A. dae 在跑 → GET /api/v1/runtime, 通知展示 state/uptime/connections/rate/total/cpu
#   B. dae 不在、sing-box 在 → 打开 Clash UI (不通知)
#   C. 都不在 → 通知 not running
#   D. dae 在但 API 不可达/响应无效 → 通知错误
#   E. 静态守卫: 右键指向 _proxy_right_click
#
# dwm-statuscmd.sh 顶层按 $1 分发, 传不存在的 cmdIndex (999) 空转;
# 在仓库根目录下用 bash -c source (使 $0=bash, WORK_DIR=".")。
# 运行: bash tests/statuscmd-proxy-status_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
LOG="$TMPD/notify"
OPEN_LOG="$TMPD/open"
export LOG OPEN_LOG

RUNTIME='{"lifecycle":{"state":"running","uptime_seconds":"3159"},
 "traffic":{"connections":{"tcp":13,"udp":7,"total":20},
  "bytes":{"upload":"153573432","download":"12222688"},
  "rates":{"upload_bytes_per_second":"0","download_bytes_per_second":"8204"}},
 "process":{"cpu_percent":0}}'

fail=0
pass=0
ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}
no() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
}
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

run_right() { # env: MOCK_DAE_RUNNING MOCK_SINGBOX_RUNNING MOCK_CURL_FAIL MOCK_CURL_BODY
    : >"$LOG"
    : >"$OPEN_LOG"
    (
        cd "$ROOT" &&
            MOCK_DAE_RUNNING="${MOCK_DAE_RUNNING:-1}" \
                MOCK_SINGBOX_RUNNING="${MOCK_SINGBOX_RUNNING:-1}" \
                MOCK_CURL_FAIL="${MOCK_CURL_FAIL:-}" \
                MOCK_CURL_BODY="${MOCK_CURL_BODY:-$RUNTIME}" \
                bash -c '
                    notify-send() {
                        local -a a=("$@")
                        printf "%s\n" "${a[-2]}" "${a[-1]}" >"$LOG"
                    }
                    xdg-open() { printf "%s\n" "$@" >"$OPEN_LOG"; }
                    curl() {
                        [[ -n ${MOCK_CURL_FAIL:-} ]] && return 7
                        printf "%s\n" "$MOCK_CURL_BODY"
                    }
                    pgrep() {
                        local name=${!#}
                        case "$name" in
                        dae) return "${MOCK_DAE_RUNNING:-1}" ;;
                        sing-box) return "${MOCK_SINGBOX_RUNNING:-1}" ;;
                        esac
                        return 1
                    }
                    source ./dwm-statuscmd.sh 999 1
                    _proxy_right_click
                '
    ) >/dev/null 2>&1
    if [[ -s "$LOG" ]]; then cat "$LOG"; elif [[ -s "$OPEN_LOG" ]]; then cat "$OPEN_LOG"; fi
}

# ---------------- A: dae runtime metrics ----------------

MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=1
out=$(run_right)
check "A1 state" '[[ $out == *"state: running"* ]]'
check "A2 uptime" '[[ $out == *"uptime: 52m"* ]]'
check "A3 connections" '[[ $out == *"connections: 20 (tcp 13 / udp 7)"* ]]'
check "A4 rate 人读" '[[ $out == *"rate: ↑ 0 B/s  ↓ 8.0 KiB/s"* ]]'
check "A5 total 人读" '[[ $out == *"total: ↑ 146.5 MiB  ↓ 11.7 MiB"* ]]'
check "A6 cpu" '[[ $out == *"cpu: 0%"* ]]'
check "A7 dae 在时不打开 Clash UI" '[[ ! -s $OPEN_LOG ]]'

MOCK_CURL_BODY='{"lifecycle":{"state":"suspended","uptime_seconds":"60"},"traffic":{"connections":{"tcp":0,"udp":0,"total":0},"bytes":{"upload":"0","download":"0"},"rates":{"upload_bytes_per_second":"0","download_bytes_per_second":"0"}},"process":{"cpu_percent":0}}'
out=$(run_right)
check "A8 suspended" '[[ $out == *"state: suspended"* ]]'

# ---------------- B/C: 分流 ----------------

MOCK_DAE_RUNNING=1 MOCK_SINGBOX_RUNNING=0
out=$(run_right)
check "B1 sing-box 在 → 打开 Clash UI" '[[ $out == *"http://127.0.0.1:9090/ui"* ]]'
check "B2 sing-box 时无通知" '[[ ! -s $LOG ]]'

MOCK_DAE_RUNNING=1 MOCK_SINGBOX_RUNNING=1
out=$(run_right)
check "C1 都不在 → 通知 not running" '[[ $out == *"not running"* ]]'

# ---------------- D: API 错误 ----------------

MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=1 MOCK_CURL_FAIL=1
out=$(run_right)
check "D1 API 不可达" '[[ $out == *"API unreachable"* ]]'

MOCK_CURL_FAIL= MOCK_CURL_BODY='not json'
out=$(run_right)
check "D2 响应无效" '[[ $out == *"invalid response"* ]]'

# ---------------- E: wiring ----------------

action=$(cd "$ROOT" && bash -c 'source ./dwm-statuscmd.sh 999 1; printf "%s" "${actions[$ST_PROXY,$right]}"')
check "E1 右键走 _proxy_right_click" '[[ $action == _proxy_right_click ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
