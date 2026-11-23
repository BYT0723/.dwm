#!/usr/bin/env bash
# rofi/scripts/launcher 主题参数回归测试:
#   首个位置参数 `<type>-<style>`（如 1-2）→ 选用 type-N/style-M.rasi;
#   缺失/格式非法/样式文件不存在 → 静默回退默认 type-2/style-1。
# 运行: bash tests/rofi-launcher_test.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$REPO/rofi/scripts/launcher"
TEST_DIR=$(mktemp -d)
export HOME="$TEST_DIR/home"
BIN="$TEST_DIR/bin"
ROFI_ARGS="$TEST_DIR/args"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$BIN" "$HOME/.dwm/rofi/launchers"
# 假主题树: 只造出测试需要的几个 .rasi
for f in type-1/style-2 type-2/style-1 type-3/style-5 type-5/style-5; do
    mkdir -p "$HOME/.dwm/rofi/launchers/${f%%/*}"
    : >"$HOME/.dwm/rofi/launchers/${f}.rasi"
done

cat >"$BIN/rofi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ROFI_ARGS"
exit "${ROFI_EXIT:-0}"
EOF
chmod +x "$BIN/rofi"

run_launcher() {
    : >"$ROFI_ARGS"
    ROFI_ARGS="$ROFI_ARGS" PATH="$BIN:$PATH" \
        bash "$LAUNCHER" "$@" >/dev/null 2>&1
}

last_theme() { awk '/^-theme$/{getline; print; exit}' "$ROFI_ARGS"; }
has_pair() { awk -v a="$1" -v b="$2" 'p==a && $0==b{f=1} {p=$0} END{exit !f}' "$ROFI_ARGS"; }

fail=0
check() {
    if eval "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1"
        fail=1
    fi
}

# ---- A: 无参数 = 现有默认行为 ----
run_launcher
check "无参数回退 type-2/style-1" \
    '[ "$(last_theme)" = "$HOME/.dwm/rofi/launchers/type-2/style-1.rasi" ]'

# ---- B/C/D: 合法参数 ----
run_launcher 1-2
check "1-2 → type-1/style-2" \
    '[ "$(last_theme)" = "$HOME/.dwm/rofi/launchers/type-1/style-2.rasi" ]'

run_launcher 3-5
check "3-5 → type-3/style-5" \
    '[ "$(last_theme)" = "$HOME/.dwm/rofi/launchers/type-3/style-5.rasi" ]'

run_launcher 5-5
check "5-5 → type-5/style-5" \
    '[ "$(last_theme)" = "$HOME/.dwm/rofi/launchers/type-5/style-5.rasi" ]'

# ---- E/F/G/H/I: 非法/不存在一律回退默认 ----
for arg in 5-9 9-1 2 abc 1-2-3; do
    run_launcher "$arg"
    check "非法参数 $arg 回退默认" \
        '[ "$(last_theme)" = "$HOME/.dwm/rofi/launchers/type-2/style-1.rasi" ]'
done

# ---- J: rofi 退出码原样透传 ----
ROFI_EXIT=7 run_launcher 1-2
rc=$?
check "rofi 退出码透传" '[ "$rc" = 7 ]'

# ---- K: 其它命令行参数不受影响 ----
run_launcher 1-2
check "combi 模式仍启用" 'grep -q "combi,quicklinks:" "$ROFI_ARGS"'
check "-show combi 仍存在" 'has_pair -show combi'

# ---- L: 真实仓库里的主题文件存在（只读断言，防止假 HOME 与实物脱节） ----
check "仓库存在 type-1/style-2 与 type-3/style-5" \
    '[ -f "$REPO/rofi/launchers/type-1/style-2.rasi" ] && [ -f "$REPO/rofi/launchers/type-3/style-5.rasi" ]'

exit $fail
