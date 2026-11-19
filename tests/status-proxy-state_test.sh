#!/usr/bin/env bash
# dae 状态块回归测试:
#   A. print_proxy 读 daemon 缓存: dae running/unknown 白色, suspended 黄色,
#      sing-box 运行白色; 缓存确认都没运行 → 空输出
#   B. 无缓存时保留旧行为 (pgrep sing-box/dae 任一存在 → 白色 icon)
#   C. update_proxy_status_daemon: dae 写 lifecycle.state; sing-box 写 running;
#      进程消失时不写对应行; API 读不到但 dae 存在写 unknown
#   D. 静态守卫: dwm-status.sh 启动 update_proxy_status_daemon
#
# 背景: dae suspend 后进程仍在但不再代理, 旧 print_proxy 只看 pgrep 无法区分。
# 运行: bash tests/status-proxy-state_test.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# dwm-status-tools.sh 加载时读 xrdb, 用空输出隔离真实主题
TMPBIN=$(mktemp -d)
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPBIN" "$TMPD"' EXIT
printf '#!/bin/sh\n' >"$TMPBIN/xrdb"
chmod +x "$TMPBIN/xrdb"
PATH="$TMPBIN:$PATH"

source "$REPO/dwm-status-tools.sh"

white=W yellow=Y
proxy_state_path="$TMPD/proxy-state"

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

# ---------------- mocks ----------------

pgrep() {
    local name=${!#}
    case "$name" in
    dae) return "${MOCK_DAE_RUNNING:-1}" ;;
    sing-box) return "${MOCK_SINGBOX_RUNNING:-1}" ;;
    esac
    return 1
}

curl() {
    [[ -n ${MOCK_CURL_FAIL:-} ]] && return 7
    printf '%s\n' "$MOCK_CURL_BODY"
}

# ---------------- A/B: print_proxy ----------------

printf 'dae=running\n' >"$proxy_state_path"
check "A1 dae running → 白色 icon" '[[ $(print_proxy) == "^cW^${icons[proxy]}" ]]'

printf 'dae=suspended\n' >"$proxy_state_path"
check "A2 dae suspended → 黄色 icon" '[[ $(print_proxy) == "^cY^${icons[proxy]}" ]]'

printf 'dae=unknown\n' >"$proxy_state_path"
check "A3 dae unknown → 白色 icon" '[[ $(print_proxy) == "^cW^${icons[proxy]}" ]]'

printf 'sing-box=running\n' >"$proxy_state_path"
check "A4 sing-box running → 白色 icon" '[[ $(print_proxy) == "^cW^${icons[proxy]}" ]]'

printf 'dae=suspended\nsing-box=running\n' >"$proxy_state_path"
check "A5 dae suspended 优先于 sing-box → 黄色" '[[ $(print_proxy) == "^cY^${icons[proxy]}" ]]'

: >"$proxy_state_path"
MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=0
check "A6 缓存确认都没运行 → 空输出 (不回退 pgrep)" '[[ -z $(print_proxy) ]]'

rm -f "$proxy_state_path"
MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=1
check "B1 无缓存且 dae 在跑 → 白色 icon (旧行为)" \
    '[[ $(print_proxy) == "^cW^${icons[proxy]}" ]]'

MOCK_DAE_RUNNING=1 MOCK_SINGBOX_RUNNING=1
check "B2 无缓存且都没跑 → 空输出" '[[ -z $(print_proxy) ]]'

# ---------------- C: update_proxy_status_daemon ----------------

wait_line() { # exact line
    local _
    for _ in {1..40}; do
        [[ -f "$proxy_state_path" ]] && grep -qx "$1" "$proxy_state_path" && return 0
        sleep 0.05
    done
    return 1
}

start_daemon() {
    update_proxy_status_daemon 1 &
    DPID=$!
}

stop_daemon() {
    kill "$DPID" 2>/dev/null
    wait "$DPID" 2>/dev/null
}

MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=1 MOCK_CURL_BODY='{"lifecycle":{"state":"suspended"}}'
rm -f "$proxy_state_path"
start_daemon
wait_line 'dae=suspended' && ok "C1 dae 存在 → 写 suspended" || no "C1 dae 存在 → 写 suspended"
stop_daemon

printf 'dae=running\n' >"$proxy_state_path"
MOCK_DAE_RUNNING=1 MOCK_SINGBOX_RUNNING=0
start_daemon
wait_line 'sing-box=running' && ok "C2 dae 消失 → 不写 dae 行" || no "C2 dae 消失 → 不写 dae 行"
grep -q '^dae=' "$proxy_state_path" && no "C2b 旧 dae 行已清除" || ok "C2b 旧 dae 行已清除"
stop_daemon

printf 'dae=suspended\n' >"$proxy_state_path"
MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=1 MOCK_CURL_FAIL=1
start_daemon
wait_line 'dae=unknown' && ok "C3 API 失败但 dae 在 → unknown" || no "C3 API 失败但 dae 在 → unknown"
stop_daemon

unset MOCK_CURL_FAIL
MOCK_DAE_RUNNING=0 MOCK_SINGBOX_RUNNING=0 MOCK_CURL_BODY='{"lifecycle":{"state":"suspended"}}'
rm -f "$proxy_state_path"
start_daemon
wait_line 'dae=suspended' && ok "C4 dae + sing-box 同时写" || no "C4 dae + sing-box 同时写"
wait_line 'sing-box=running' && ok "C4b sing-box 行存在" || no "C4b sing-box 行存在"
stop_daemon

MOCK_DAE_RUNNING=1 MOCK_SINGBOX_RUNNING=1
rm -f "$proxy_state_path"
start_daemon
for _ in {1..40}; do
    [[ -f "$proxy_state_path" ]] && break
    sleep 0.05
done
[[ -f "$proxy_state_path" && ! -s "$proxy_state_path" ]] && ok "C5 都没运行 → 空缓存" || no "C5 都没运行 → 空缓存"
stop_daemon

# ---------------- D: wiring ----------------

check "D1 launch_daemon 启动 update_proxy_status_daemon" \
    'grep -q "update_proxy_status_daemon &" "$REPO/dwm-status.sh"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
