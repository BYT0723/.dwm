#!/usr/bin/env bash
# print_notification 抗阻塞 / 脏输出回归测试:
#   A. dunstctl 返回未读数 → 输出铃铛图标 (黄色)
#   B. 未读数为 0 → 空输出
#   C. dunst 卡死 (dunstctl 不返回) → 必须限时返回, 不得拖停 refresh 循环
#   D. dunstctl 失败 / 无输出 → 静默返回, 不得漏 stderr
#   E. 非纯数字输出 → 静默返回, 不得让 (( )) 报 syntax error
#
# 背景: launch_refresh 是串行 `panes(); sleep 1`, 一个 block 阻塞就冻结整条
# 状态栏 (amixer 已踩过, 见 status-volume-hang_test.sh). dunstctl 走 D-Bus,
# dunst 卡住时默认要等到 D-Bus 超时; 旧代码没有 timeout, 也没有输出校验.
# 运行: bash tests/status-notification_test.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/dwm-status-print.sh"

yellow=Y black=B
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

TMPBIN=$(mktemp -d)
trap 'rm -rf "$TMPBIN"' EXIT
PATH="$TMPBIN:$PATH"

# MOCK_DUNSTCTL_HANG: 不返回 (exec 保证 timeout 杀的就是持有管道的进程)
# MOCK_DUNSTCTL_COUNT: 正常输出; 未设置且未 HANG: 模拟 dunstctl 失败
cat >"$TMPBIN/dunstctl" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${MOCK_DUNSTCTL_HANG:-} ]]; then
    exec sleep "$MOCK_DUNSTCTL_HANG"
fi
[[ -n ${MOCK_DUNSTCTL_COUNT:-} ]] || exit 1
printf '%s\n' "$MOCK_DUNSTCTL_COUNT"
EOF
chmod +x "$TMPBIN/dunstctl"

echo "== A: 有未读 =="
out=$(MOCK_DUNSTCTL_COUNT=3 print_notification)
[[ $out == *"${icons[notification]}"* && $out == *"^c$yellow^"* ]] && ok "bell icon + yellow" || no "bell icon + yellow ($out)"

echo "== B: 未读为 0 =="
out=$(MOCK_DUNSTCTL_COUNT=0 print_notification)
[[ -z $out ]] && ok "no output" || no "no output ($out)"

echo "== C: dunst 卡死必须限时返回 =="
start=$(date +%s%N)
out=$(MOCK_DUNSTCTL_HANG=8 print_notification 2>/dev/null)
elapsed=$((( $(date +%s%N) - start) / 1000000))
((elapsed < 3000)) && ok "returns in ${elapsed}ms (< 3000ms)" || no "stalled ${elapsed}ms"
[[ -z $out ]] && ok "no partial output" || no "no partial output ($out)"

echo "== D: dunstctl 失败静默 =="
err=$(print_notification 2>&1 >/dev/null)
[[ -z $err ]] && ok "no stderr noise" || no "no stderr noise ($err)"
out=$(print_notification)
[[ -z $out ]] && ok "empty output" || no "empty output ($out)"

echo "== E: 非数字输出静默 =="
err=$(MOCK_DUNSTCTL_COUNT='3 4' print_notification 2>&1 >/dev/null)
[[ -z $err ]] && ok "no arithmetic error" || no "no arithmetic error ($err)"
out=$(MOCK_DUNSTCTL_COUNT='3 4' print_notification)
[[ -z $out ]] && ok "empty output" || no "empty output ($out)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
