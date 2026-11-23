#!/usr/bin/env bash
# print_mail / print_speed 空缓存回归测试:
#   A. mail-unread 不存在 → 静默返回, 不得报 read 错误/算术错误
#   B. mail-unread 是脏值 → 静默返回
#   C. network-traffic-rx 不存在 → print_speed 静默返回
#   D. network-traffic-rx 只有部分字段 → human_speed 收到空值也输出 0B/s
#   E. human_speed 空值/非法值 → 0B/s, 无 stderr
#
# 背景: 开机或 status daemon 重启后, refresh 的第一轮会先于缓存落盘执行;
# 旧代码对缺失文件直接 read, 空值再进 (( )) / printf, 于是每秒刷
# "/tmp/... no such file"、"arithmetic syntax error"、"invalid number".
# 不影响绘制, 但会刷满日志且是同类未校验输入的根源.
# 运行: bash tests/status-empty-cache_test.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/dwm-status-print.sh"

white=W red=R yellow=Y black=B
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.local/state/dwm/status"

mail_unread_path="$TMP/missing-mail"
network_traffic_path="$TMP/missing-net"

echo "== A: 缺 mail 缓存 =="
err=$(print_mail 2>&1 >/dev/null)
out=$(print_mail)
[[ -z $err ]] && ok "no stderr" || no "no stderr ($err)"
[[ -z $out ]] && ok "empty output" || no "empty output ($out)"

echo "== B: 脏 mail 缓存 =="
printf '3 4\n' >"$TMP/mail-dirty"
mail_unread_path="$TMP/mail-dirty"
err=$(print_mail 2>&1 >/dev/null)
out=$(print_mail)
[[ -z $err ]] && ok "dirty value: no stderr" || no "dirty value: no stderr ($err)"
[[ -z $out ]] && ok "dirty value: empty output" || no "dirty value: empty output ($out)"
printf '0\n' >"$TMP/mail-zero"
mail_unread_path="$TMP/mail-zero"
out=$(print_mail)
[[ -z $out ]] && ok "0 unread: empty output" || no "0 unread: empty output ($out)"
printf '3\n' >"$TMP/mail-three"
mail_unread_path="$TMP/mail-three"
out=$(print_mail)
[[ $out == *"${icons[mail]}"* && $out == *"^c$yellow^"* ]] && ok "3 unread: mail icon" || no "3 unread: mail icon ($out)"

echo "== C: 缺网络缓存 =="
err=$(print_speed 2>&1 >/dev/null)
out=$(print_speed)
[[ -z $err ]] && ok "no stderr" || no "no stderr ($err)"
[[ -z $out ]] && ok "empty output" || no "empty output ($out)"

echo "== D: 网络缓存只有部分字段 =="
printf 'eth0 ethernet 192.0.2.1\n' >"$TMP/net-partial"
network_traffic_path="$TMP/net-partial"
out=$(print_speed 2>&1)
[[ $out != *"无效"* && $out != *"invalid"* && $out != *"语法"* ]] &&
    ok "no printf/arithmetic error" || no "no printf/arithmetic error ($out)"
[[ $out == *"0B/s"* ]] && ok "missing rx/tx renders 0B/s" || no "missing rx/tx renders 0B/s ($out)"

echo "== E: human_speed 空值/非法值 =="
out=$(human_speed 2>&1)
[[ $out == *"0B/s"* && $out != *"无效"* && $out != *"invalid"* ]] &&
    ok "no argument -> 0B/s" || no "no argument -> 0B/s ($out)"
out=$(human_speed 'abc' 2>&1)
[[ $out == *"0B/s"* && $out != *"无效"* && $out != *"invalid"* ]] &&
    ok "dirty argument -> 0B/s" || no "dirty argument -> 0B/s ($out)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
