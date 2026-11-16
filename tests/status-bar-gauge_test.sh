#!/usr/bin/env bash
# 状态栏进度条回归测试 (dwm-status-print.sh):
#   A. bar_gauge 横向 (电池): 端子 + 外框 + 内底 + 按比例填充 + ^d/^f, 全部按 fg 上色
#   B. bar_gauge 纵向 (VPS): 几何与旧内联实现逐字节一致
#   C. 边界: 0% 不填充 / 非零比例至少 1px / >100% 封顶
#   D. print_battery / print_vps_bandwidth 走共用函数 (不再自带 ^r)
#
# 运行: bash tests/status-bar-gauge_test.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
section() { printf '\n== %s ==\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"
PATH="$BIN:$PATH"

source "$REPO/dwm-status-print.sh"
white=W red=R yellow=Y blue=B cyan=C black=K green=G

section "A: 横向 (电池) 80%"
out=$(bar_gauge 8 11 18 10 80 W h 32 2)
[[ $out == *'^cW^^r8,13,2,6^'* ]] && ok "nub 2x6 vertically centred" || no "nub ($out)"
[[ $out == *'^cW^^r10,11,16,10^'* ]] && ok "frame starts after nub, fg coloured" || no "frame ($out)"
[[ $out == *"^cK^"*'^r11,12,14,8^'* ]] && ok "inner background black" || no "inner bg ($out)"
[[ $out == *'^r15,13,9,6^'* ]] && ok "80% fill = 9/12 px" || no "fill ($out)"
[[ $out == *'^d^^f32^' ]] && ok "reset + 32px advance" || no "tail ($out)"

section "B: 纵向 (VPS) 38%"
out=$(bar_gauge 0 4 10 24 38 Y v 20)
[[ $out == *'^r0,4,10,24^'* ]] && ok "frame 10x24" || no "frame ($out)"
[[ $out == *'^r1,5,8,22^'* ]] && ok "inner background" || no "inner bg ($out)"
[[ $out == *'^r2,19,6,7^'* ]] && ok "fill grows from the bottom" || no "fill ($out)"
[[ $out == *'^d^^f20^' ]] && ok "reset + 20px advance" || no "tail ($out)"

section "C: 边界"
out=$(bar_gauge 0 4 10 24 0 W v 20)
[[ $out != *'^r2,'* ]] && ok "0% draws no fill" || no "0% draws no fill ($out)"
[[ $out == *'^d^^f20^' ]] && ok "0% still advances" || no "0% advance ($out)"

out=$(bar_gauge 8 11 18 10 1 W h 32 2)
[[ $out == *'^r23,13,1,6^'* ]] && ok "1% keeps a 1px sliver" || no "1% sliver ($out)"

out=$(bar_gauge 8 11 18 10 150 W h 32 2)
[[ $out == *'^r12,13,12,6^'* ]] && ok ">100% clamped to full" || no "clamp ($out)"

section "D: 调用方"
fake_acpi() {
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$1" >"$BIN/acpi"
    chmod +x "$BIN/acpi"
}

fake_acpi 'Battery 0: Discharging, 15%, 01:20:00 remaining'
out=$(print_battery)
[[ $out == *'^cR^^r8,13,2,6^'* ]] && ok "battery below 20% is red (frame included)" || no "battery red ($out)"
[[ $out == *'^r23,13,1,6^'* ]] && ok "battery 15% fills 1px" || no "battery fill ($out)"

fake_acpi 'Battery 0: Charging, 80%, 00:20:00 until charged'
out=$(print_battery)
[[ $out == *'^cG^^r10,11,16,10^'* ]] && ok "charging is green" || no "charging green ($out)"

vpsbandwidth_cache="$TMP/vps-bandwidth"
printf '193.27|500|38.65|1700000000|0\n' >"$vpsbandwidth_cache"
out=$(print_vps_bandwidth)
[[ $out == *'usage:193G'*'^r2,14,6,12^'* ]] && ok "vps shows remainder gauge" || no "vps gauge ($out)"

section "E: 静态守卫"
for fn in print_battery print_vps_bandwidth; do
    body=$(awk "/^$fn\\(\\)/,/^}/" "$REPO/dwm-status-print.sh")
    [[ $body == *bar_gauge* ]] && ok "$fn delegates to bar_gauge" || no "$fn delegates to bar_gauge"
    [[ $body != *"^r"* ]] && ok "$fn owns no rects" || no "$fn owns no rects"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
