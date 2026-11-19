#!/usr/bin/env bash
# rofi/scripts/dae.sh 回归测试:
#   A. 主菜单行: 组名 / id / policy / tcp data ipv4 延迟 (不显示当前节点名)
#   B. 成员行: ✓(tcp) / ~(仅 udp) 标记, 延迟取 sorting/moving_avg/latency 优先,
#      unavailable → ✗, pinned (source=override) 时多出 Auto 行
#   C. PUT selection 请求体固定 {member_id, network:"both"}; DELETE 带 network=both
#   D. suspend/resume 按 lifecycle.state 选择 operation, 并轮询到 succeeded
#   E. API 失败: 非 2xx 的 error.message 带进 API_ERR; 连不上也返回非 0
#   F. 静态守卫: ST_PROXY 左键只认 dae (不回落 sing-box)
#
# 运行: bash tests/dae_test.sh

set -uo pipefail

DWM=${DWM:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}
SCRIPT="$DWM/rofi/scripts/dae.sh"
STATUSCMD="$DWM/dwm-statuscmd.sh"
DAE_API="http://127.0.0.1:9527"
export DAE_API
fail=0
pass=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

DAE_NO_DISPATCH=1 source "$SCRIPT" 2>/dev/null || {
    echo "FAIL cannot source $SCRIPT"
    exit 1
}

system-notify() { NOTIFY="$1|$2|$3"; }
sleep() { :; }

# ---------------- fixtures ----------------

GROUPS_JSON='[
 {"id":"g_proxy","name":"proxy","policy":{"kind":"urltest","native":"min_moving_avg"},
  "selection":{"tcp_member_id":"n_any","udp_member_id":"n_hy2"}},
 {"id":"g_dns","name":"dns_group","policy":{"kind":"urltest","native":"min_moving_avg"},
  "selection":{"tcp_member_id":"n_dns","udp_member_id":"n_dns"}}
]'

NODES_JSON='{"nodes":[
 {"id":"n_any","name":"anytls","health":[
   {"transport":"tcp","purpose":"data","ip_version":"ipv4","state":"healthy","sorting_latency_ms":149.35}]},
 {"id":"n_hy2","name":"hy2","health":[
   {"transport":"tcp","purpose":"data","ip_version":"ipv4","state":"healthy","sorting_latency_ms":192.6}]},
 {"id":"n_dns","name":"vless_dns","health":[
   {"transport":"tcp","purpose":"data","ip_version":"ipv4","state":"healthy","latency_ms":463.2}]}
]}'

GROUP_PINNED='{"id":"g_proxy","name":"proxy","policy":{"kind":"urltest","native":"min_moving_avg"},
 "capabilities":{"can_override":true,"can_select":false},
 "members":[{"id":"n_hy2","name":"hy2"},{"id":"n_any","name":"anytls"}],
 "runtime":{"selection":{
    "tcp":{"member_id":"n_any","source":"override"},
    "udp":{"member_id":"n_any","source":"override"}},
  "health":[
   {"member_id":"n_hy2","transport":"tcp","purpose":"data","ip_version":"ipv4","state":"unavailable"},
   {"member_id":"n_any","transport":"tcp","purpose":"data","ip_version":"ipv4","state":"healthy","sorting_latency_ms":149.35}]}}'

GROUP_AUTO='{"id":"g_proxy","name":"proxy","policy":{"kind":"urltest","native":"min_moving_avg"},
 "capabilities":{"can_override":true,"can_select":false},
 "members":[{"id":"n_hy2","name":"hy2"},{"id":"n_any","name":"anytls"}],
 "runtime":{"selection":{
    "tcp":{"member_id":"n_any","source":"runtime"},
    "udp":{"member_id":"n_hy2","source":"runtime"}},
  "health":[
   {"member_id":"n_hy2","transport":"tcp","purpose":"data","ip_version":"ipv4","state":"healthy","moving_avg_ms":190.4},
   {"member_id":"n_any","transport":"tcp","purpose":"data","ip_version":"ipv4","state":"healthy","sorting_latency_ms":149.35}]}}'

# ---------------- A: group rows ----------------

out=$(group_rows "$GROUPS_JSON" "$NODES_JSON")
check "A1 组行: 名称/id/policy/延迟" \
    '[[ $out == *$'"'"'proxy\tg_proxy\tmin_moving_avg\t149ms'"'"'* ]]'
check "A2 第二组行正常输出" \
    '[[ $out == *$'"'"'dns_group\tg_dns\tmin_moving_avg\t463ms'"'"'* ]]'
check "A3 不输出 Auto 行动作" '[[ $out != *"Auto"* ]]'
check "A3b 组行不显示当前节点名" '[[ $out != *anytls* && $out != *vless_dns* ]]'
load_group_menu "$GROUPS_JSON" "$NODES_JSON"
check "A4 column 对齐后两行等长" '[[ ${#GROUP_LABELS[0]} -eq ${#GROUP_LABELS[1]} ]]'
check "A5 组行 id 映射" '[[ ${GROUP_IDS[0]} == g_proxy && ${GROUP_IDS[1]} == g_dns ]]'

# ---------------- B: member rows ----------------

out=$(member_rows "$GROUP_PINNED")
check "B1 pin 时首行是 Auto" '[[ ${out%%$'"'"'\n'"'"'*} == "↺ Auto"$'"'"'\t__auto__\tAuto\t-'"'"' ]]'
check "B2 当前节点打 ✓ 并带延迟" '[[ $out == *$'"'"'✓ anytls\tn_any\tanytls\t149ms'"'"'* ]]'
check "B3 unavailable 显 ✗" '[[ $out == *$'"'"'  hy2\tn_hy2\thy2\t✗'"'"'* ]]'

out=$(member_rows "$GROUP_AUTO")
check "B4 未 pin 时无 Auto 行" '[[ $out != *"Auto"* ]]'
check "B5 仅 udp 选中打 ~" '[[ $out == *$'"'"'~ hy2\tn_hy2\thy2\t190ms'"'"'* ]]'
load_member_menu "$GROUP_PINNED"
check "B6 成员行 id 映射 (Auto 在前)" \
    '[[ ${MEMBER_IDS[0]} == __auto__ && ${MEMBER_IDS[1]} == n_hy2 && ${MEMBER_IDS[2]} == n_any ]]'

# ---------------- C: write requests ----------------

CURL_LOG=$(mktemp)
trap 'rm -f "$CURL_LOG"' EXIT

curl() {
    local method=GET url="" data="" code="200"
    while (($#)); do
        case "$1" in
        -X) method=$2; shift 2 ;;
        -H | -m | -w) shift 2 ;;
        --data-binary) data=$2; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
        esac
    done
    printf '%s %s %s\n' "$method" "$url" "$data" >>"$CURL_LOG"
    if [[ -n ${MOCK_FAIL:-} ]]; then return 7; fi
    case "$method $url" in
    "POST $DAE_API/api/v1/operations/suspend") code=202; printf '{"operation_id":"op1"}' ;;
    "POST $DAE_API/api/v1/operations/resume") code=202; printf '{"operation_id":"op2"}' ;;
    "GET $DAE_API/api/v1/operations/op1" | "GET $DAE_API/api/v1/operations/op2")
        printf '{"status":"succeeded"}' ;;
    "PUT $DAE_API/api/v1/groups/g_proxy/selection") printf '{"source":"override"}' ;;
    "DELETE $DAE_API/api/v1/groups/g_proxy/selection?network=both") printf '{}' ;;
    *)
        if [[ -n ${MOCK_BODY:-} ]]; then
            code=${MOCK_CODE:-200}
            printf '%s' "$MOCK_BODY"
        fi
        ;;
    esac
    printf '\n%s' "$code"
}

: >"$CURL_LOG"
switch_node g_proxy n_any
expected="PUT $DAE_API/api/v1/groups/g_proxy/selection {\"member_id\":\"n_any\",\"network\":\"both\"}"
if grep -qxF "$expected" "$CURL_LOG"; then
    ok "C1 PUT 到 selection 端点"
else
    no "C1 PUT 到 selection 端点"
fi

: >"$CURL_LOG"
clear_pin g_proxy
if grep -qxF "DELETE $DAE_API/api/v1/groups/g_proxy/selection?network=both " "$CURL_LOG"; then
    ok "C2 DELETE 清 pin 带 network=both"
else
    no "C2 DELETE 清 pin 带 network=both"
fi

# ---------------- D: suspend / resume ----------------

: >"$CURL_LOG"
toggle_suspend running
check "D1 running → suspend" 'grep -q "^POST $DAE_API/api/v1/operations/suspend " "$CURL_LOG"'
check "D2 轮询 operation 状态" 'grep -q "^GET $DAE_API/api/v1/operations/op1 " "$CURL_LOG"'
check "D3 成功后通知" '[[ $NOTIFY == low* ]]'

: >"$CURL_LOG"
toggle_suspend suspended
check "D4 suspended → resume" 'grep -q "^POST $DAE_API/api/v1/operations/resume " "$CURL_LOG"'

# ---------------- E: API errors ----------------

MOCK_CODE=422 MOCK_BODY='{"error":{"message":"group has no dialer alive"}}'
api_call PUT "/api/v1/groups/g_bad/selection" '{"member_id":"n_x","network":"both"}'
rc=$?
check "E1 非 2xx 返回非 0" '[[ $rc -ne 0 ]]'
check "E2 错误信息带进 API_ERR" '[[ $API_ERR == *"no dialer alive"* ]]'
unset MOCK_CODE MOCK_BODY

MOCK_FAIL=1
api_call GET /api/v1/groups
rc=$?
check "E3 连不上返回非 0" '[[ $rc -ne 0 && $API_ERR == *"无法连接"* ]]'
unset MOCK_FAIL

# ---------------- F: static wiring ----------------

check "F1 ST_PROXY 左键走 dae.sh" \
    'grep -q "\[\$ST_PROXY,\$left\]=.*dae.sh" "$STATUSCMD"'
check "F2 左键不再回落 sing-box" \
    '! grep -q "\[\$ST_PROXY,\$left\]=.*sing-box" "$STATUSCMD"'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
