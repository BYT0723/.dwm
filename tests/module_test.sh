#!/usr/bin/env bash
# rofi/scripts/module.sh 回归测试 (Proxy 入口):
#   A. 注册表: proxy 行标签为 Proxy, 状态走 toggle-raw:proxy_status, 不再有 sing-box 键
#   B. proxy_daemon: dae 优先, 否则 sing-box, 都没有返回非 0
#   C. proxy_status: 任一守护进程在跑 → 1, 都没有 → 0
#   D. handle_proxy: dae 在跑走 dae.sh, 否则走 sing-box.sh
#
# 运行: bash tests/module_test.sh

set -uo pipefail

DWM=${DWM:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}
SCRIPT="$DWM/rofi/scripts/module.sh"
fail=0
pass=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

# 以 module.sh 为 $0 载入 (脚本用 $0 推算 ROFI_DIR), rofi/pgrep 用函数 mock,
# MOCK_RUNNING 模拟在跑的守护进程名。$1=在跑的进程名, $2=载入后要执行的代码。
run_scenario() {
    local running=$1 code=$2
    MOCK_RUNNING="$running" bash -c '
        MOCK_RUNNING=${MOCK_RUNNING:-}
        rofi() { :; }
        pgrep() {
            [[ "${1:-}" == "-x" ]] || return 1
            case " $MOCK_RUNNING " in *" ${2:-} "*) return 0 ;; esac
            return 1
        }
        source "$0" >/dev/null 2>&1
        eval "$1"
    ' "$SCRIPT" "$code"
}

# ---------------- A: 注册表 ----------------

out=$(run_scenario "" 'printf %s "${MODULE_LABEL[proxy]:-}"')
check "A1 标签改为 Proxy" '[[ "$out" == Proxy ]]'

out=$(run_scenario "" 'printf %s "${MODULE_STATUS[proxy]:-}"')
check "A2 状态走 active-raw:proxy_status" '[[ "$out" == active-raw:proxy_status ]]'

out=$(run_scenario "" 'printf %s "${MODULE_ICON[proxy]:-}"')
check "A2b 图标为 󰖟" '[[ "$out" == 󰖟 ]]'

out=$(run_scenario "" 'printf %s "${MODULE_LABEL[sing-box]:-}"')
check "A3 不再有 sing-box 键" '[[ -z "$out" ]]'

out=$(run_scenario "" 'declare -F handle_sing_box')
check "A4 不再有 handle_sing_box" '[[ -z "$out" ]]'

# ---------------- B: proxy_daemon ----------------

out=$(run_scenario dae proxy_daemon)
check "B1 dae 在跑 → dae" '[[ "$out" == dae ]]'

out=$(run_scenario sing-box proxy_daemon)
check "B2 仅 sing-box 在跑 → sing-box" '[[ "$out" == sing-box ]]'

out=$(run_scenario "" 'proxy_daemon || echo "rc=$?"')
check "B3 都没有 → 空输出且非 0" '[[ "$out" == "rc=1" ]]'

# ---------------- C: proxy_status 图标索引 ----------------

out=$(run_scenario dae proxy_status)
check "C1 dae 在跑 → 1" '[[ "$out" == 1 ]]'

out=$(run_scenario sing-box proxy_status)
check "C2 sing-box 在跑 → 1" '[[ "$out" == 1 ]]'

out=$(run_scenario "" proxy_status)
check "C3 都没有 → 0" '[[ "$out" == 0 ]]'

# active-raw 用 active 图标组 (与 icon active raw 等价), 不能用 toggle 图标
out=$(run_scenario dae '_module_status proxy active-raw:proxy_status')
expected=$(run_scenario dae 'icon active raw proxy_status')
check "C4 active-raw 在跑 → active 图标" '[[ "$out" == "$expected" ]]'

out=$(run_scenario "" '_module_status proxy active-raw:proxy_status')
expected=$(run_scenario "" 'icon active raw proxy_status')
check "C5 active-raw 未跑 → active 灰图标" '[[ "$out" == "$expected" ]]'

# ---------------- D: handle_proxy 分派 ----------------

# 把函数体里的 /bin/bash 换成 mock, 避免真的执行目标脚本
dispatch='_src=$(declare -f handle_proxy)
_src=${_src//\/bin\/bash/mock_run}
eval "$_src"
mock_run() { printf "RUN:%s\n" "$1"; }
handle_proxy'

out=$(run_scenario dae "$dispatch")
check "D1 dae 在跑 → dae.sh" '[[ "$out" == */rofi/scripts/dae.sh ]]'

out=$(run_scenario sing-box "$dispatch")
check "D2 仅 sing-box 在跑 → sing-box.sh" '[[ "$out" == */rofi/scripts/sing-box.sh ]]'

out=$(run_scenario "" "$dispatch")
check "D3 都没跑 → 回落 sing-box.sh" '[[ "$out" == */rofi/scripts/sing-box.sh ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
