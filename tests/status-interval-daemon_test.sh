#!/usr/bin/env bash
# interval_update_daemon 回归测试（无真实 sleep / 无真实网络）:
#   A. 冷启动 (无状态文件) 第一个 tick 立即执行
#   B. 热重启 (dwm SIGHUP → autostart → dwm-status.sh reboot) 在同一 interval
#      窗口内不再重复执行 —— 否则频繁重启会固定多发请求, 外部 API 限流/封控
#   C. 距上次执行满 interval 后重启 → 正常执行
#   D. 状态按任务名独立, 一个任务刚跑不影响另一个任务
#   E. 状态文件损坏/时间戳在未来 → fail-open (执行一次, 不自锁)
#
# 运行: bash tests/status-interval-daemon_test.sh

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
mkdir -p "$BIN" "$TMP/home"
# dwm-status-tools.sh 加载时读 xrdb
cat >"$BIN/xrdb" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN/xrdb"
PATH="$BIN:$PATH"
export HOME="$TMP/home"

export EPOCH_FILE="$TMP/epoch"
export RUN_LOG="$TMP/run.log"
export DWM_STATUS_INTERVAL_DIR="$TMP/interval"
export TICK_STEP=60
export MAX_TICKS=4
: >"$RUN_LOG"

# 虚拟时间: date 只服务 +%s; sleep 推进时钟并在第 MAX_TICKS 次后退出子 shell
date() {
    if [[ ${1-} == +%s ]]; then
        cat "$EPOCH_FILE"
        return 0
    fi
    command date "$@"
}

set_epoch() { printf '%s\n' "$1" >"$EPOCH_FILE"; }

sleep() {
    _ticks=$((_ticks + 1))
    set_epoch $(($(cat "$EPOCH_FILE") + TICK_STEP))
    ((_ticks >= MAX_TICKS)) && exit 0
    return 0
}

source "$REPO/dwm-status-tools.sh"

system-notify() { :; }

run_task() { printf 'run_task\n' >>"$RUN_LOG"; }
other_task() { printf 'other_task\n' >>"$RUN_LOG"; }
run_count() { grep -cx "$1" "$RUN_LOG" 2>/dev/null || true; }

# 模拟一次进程启动: 在子 shell 里跑固定 tick 数的 daemon
run_daemon() { (
    _ticks=0
    interval_update_daemon -i "$1" -c 60 "$2"
); }

section "A: 冷启动立即执行"
rm -rf "$DWM_STATUS_INTERVAL_DIR"
: >"$RUN_LOG"
set_epoch 1000000
run_daemon 600 run_task
[[ $(run_count run_task) == 1 ]] && ok "cold start runs once" || no "cold start runs once ($(run_count run_task))"
stamp="$DWM_STATUS_INTERVAL_DIR/interval-run_task.last"
[[ -f $stamp ]] && ok "state file written" || no "state file written"
[[ $(cat "$stamp" 2>/dev/null) == 1000000 ]] && ok "state stores run epoch" || no "state stores run epoch ($(cat "$stamp" 2>/dev/null))"

section "B: 热重启在窗口内不重复执行"
set_epoch 1000300
run_daemon 600 run_task
[[ $(run_count run_task) == 1 ]] && ok "restart within interval stays silent" || no "restart within interval stays silent ($(run_count run_task))"
set_epoch 1000599
MAX_TICKS=1
run_daemon 600 run_task
MAX_TICKS=4
[[ $(run_count run_task) == 1 ]] && ok "restart just before due stays silent" || no "restart just before due stays silent ($(run_count run_task))"

section "C: 满 interval 后重启正常执行"
set_epoch 1000600
run_daemon 600 run_task
[[ $(run_count run_task) == 2 ]] && ok "restart at due runs again" || no "restart at due runs again ($(run_count run_task))"
[[ $(cat "$stamp" 2>/dev/null) == 1000600 ]] && ok "state refreshed on run" || no "state refreshed on run ($(cat "$stamp" 2>/dev/null))"

section "D: 状态按任务独立"
set_epoch 1000700
run_daemon 600 other_task
[[ $(run_count other_task) == 1 ]] && ok "other task has own schedule" || no "other task has own schedule ($(run_count other_task))"
[[ -f $DWM_STATUS_INTERVAL_DIR/interval-other_task.last ]] && ok "other task own state file" || no "other task own state file"
[[ $(run_count run_task) == 2 ]] && ok "first task untouched by second" || no "first task untouched by second ($(run_count run_task))"

section "E: 损坏/未来时间戳 fail-open"
printf 'garbage\n' >"$stamp"
set_epoch 1000800
run_daemon 600 run_task
[[ $(run_count run_task) == 3 ]] && ok "corrupt state runs once" || no "corrupt state runs once ($(run_count run_task))"

printf '2000000\n' >"$stamp"
set_epoch 1000900
run_daemon 600 run_task
[[ $(run_count run_task) == 4 ]] && ok "future state runs once (clock skew)" || no "future state runs once ($(run_count run_task))"

section "F: 静态守卫"
body=$(awk '/^interval_update_daemon\(\)/,/^}/' "$REPO/dwm-status-tools.sh")
[[ $body == *DWM_STATUS_INTERVAL_DIR* ]] && ok "state dir overridable for tests" || no "state dir overridable for tests"
[[ $body != *'last_slot'* ]] && ok "no in-memory-only schedule" || no "no in-memory-only schedule"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
