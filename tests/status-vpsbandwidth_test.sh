#!/usr/bin/env bash
# VPSBandwidth 模块回归测试（零真实网络、零真实浏览器库）:
#   A. core/provider 解耦: 假 provider 即可写缓存; 未知 provider 保留旧值并置 stale
#   B. provider 契约校验: 非数字 / 字段数不对 / 多行 / 空 → 视同失败
#   C. dedione provider: 两步抓取 (页面 vtoken + 会话 cookie → API)、token 优先级
#   D. 展示: 193/500G 39% + 阈值配色 + stale "!" + 无缓存不输出 (竖条为余量 100-已用%)
#   E. 静态守卫: core 不认识 WHMCS/vtoken/cookie; print 不联网
#   F. 阈值首超通知: 缓存旧档位 vs 新值档位, 跨档升级才通知 (80 normal / 90 critical)
#
# 运行: bash tests/status-vpsbandwidth_test.sh

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

if [[ ! -f $REPO/utils/vpsbandwidth.sh ]]; then
    echo "missing utils/vpsbandwidth.sh" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home"
PATH="$BIN:$PATH"

export HOME="$TMP/home"
export VPSBANDWIDTH_CONFIG="$TMP/vpsbandwidth.json"
export VPSBANDWIDTH_CACHE="$TMP/cache"
export VPSBANDWIDTH_STAMP="$TMP/stamp"
export VPSBANDWIDTH_FF_PROFILES="$TMP/profiles.ini"
export NOTIFY_LOG="$TMP/notify.log"
export CURL_LOG="$TMP/curl.log"
export SQLITE_LOG="$TMP/sqlite.log"

: >"$NOTIFY_LOG"

system-notify() { printf '%s\n' "$*" >>"$NOTIFY_LOG"; }

# ---- mocks ----
# curl: 记录参数, 按 URL 回放 PAGE_HTML / API_JSON; -c 写一个假 cookie jar
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_LOG"
jar_out="" url=""
while (($# > 0)); do
    case "$1" in
    -c)
        jar_out=$2
        shift 2
        ;;
    -b | -A | -H | -m)
        shift 2
        ;;
    -sS | --compressed)
        shift
        ;;
    http*)
        url=$1
        shift
        ;;
    *)
        shift
        ;;
    esac
done
if [[ -n $jar_out ]]; then
    printf '# Netscape HTTP Cookie File\n.dedione.com\tTRUE\t/\tTRUE\t0\tWHMCSjQRtest\tsess\n' >"$jar_out"
fi
case "$url" in
*api=json*) printf '%s' "${API_JSON-}" ;;
*) printf '%s' "${PAGE_HTML-}" ;;
esac
EOF

cat >"$BIN/sqlite3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SQLITE_LOG"
printf '%s' "${SQLITE_TOKEN-}"
EOF
chmod +x "$BIN/curl" "$BIN/sqlite3"

source "$REPO/utils/vpsbandwidth.sh"

write_config() {
    cat >"$VPSBANDWIDTH_CONFIG"
}

seed_cache() {
    printf '%s\n' "$1" >"$VPSBANDWIDTH_CACHE"
}

cache_is() {
    local u l p t s
    IFS='|' read -r u l p t s <"$VPSBANDWIDTH_CACHE" 2>/dev/null || return 1
    [[ $u == "$1" && $l == "$2" && $p == "$3" && $s == "$4" ]]
}

section "A: core / provider 解耦"
write_config <<'JSON'
{"provider": "fake"}
JSON
vpsbandwidth_fetch_fake() { printf '12.5|100|12.5\n'; }
rm -f "$VPSBANDWIDTH_CACHE" "$VPSBANDWIDTH_STAMP"
update_vps_bandwidth
rc=$?
cache_is 12.5 100 12.5 0 && ok "fake provider feeds cache" || no "fake provider feeds cache (rc=$rc)"
((rc == 0)) && ok "core returns 0 on success" || no "core returns 0 on success (rc=$rc)"

seed_cache '5|50|10|123|0'
write_config <<'JSON'
{"provider": "not-installed"}
JSON
: >"$NOTIFY_LOG"
rm -f "$VPSBANDWIDTH_STAMP"
update_vps_bandwidth
rc=$?
cache_is 5 50 10 1 && ok "unknown provider keeps old values + stale" || no "unknown provider keeps old values + stale"
((rc == 0)) && ok "unknown provider returns 0 (no critical spam)" || no "unknown provider returns 0 (rc=$rc)"
[[ -f $VPSBANDWIDTH_STAMP ]] && ok "stamp written on failure" || no "stamp written on failure"
(( $(wc -l <"$NOTIFY_LOG") == 1 )) && ok "first failure notifies once" || no "first failure notifies once ($(wc -l <"$NOTIFY_LOG"))"
update_vps_bandwidth
(( $(wc -l <"$NOTIFY_LOG") == 1 )) && ok "second failure stays silent" || no "second failure stays silent ($(wc -l <"$NOTIFY_LOG"))"

section "B: provider 契约校验"
write_config <<'JSON'
{"provider": "bad"}
JSON
for bad in 'hello' '1|2' '1|2|3|4' 'a|b|c' '' $'1|2|3\nextra'; do
    vpsbandwidth_fetch_bad() { printf '%s' "$1"; }
    seed_cache '7|70|10|123|0'
    update_vps_bandwidth
    cache_is 7 70 10 1 && ok "reject $(printf '%q' "$bad")" || no "reject $(printf '%q' "$bad")"
done

section "C: dedione provider"
PAGE_HTML='<html>... vtoken=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ...</html>'
API_JSON='{"bandwidth":{"used_gb":193.27,"limit_gb":500,"percent":38.65}}'
export PAGE_HTML API_JSON

write_config <<'JSON'
{
  "provider": "dedione",
  "dedione": {"product_id": 11239, "svs": 4442, "auth_token": "TOK123"}
}
JSON
: >"$CURL_LOG"
rm -f "$SQLITE_LOG"
out=$(vpsbandwidth_fetch_dedione 2>/dev/null)
rc=$?
[[ $out == '193.27|500|38.65' ]] && ok "two-step fetch returns contract line" || no "two-step fetch ($out)"
((rc == 0)) && ok "provider returns 0" || no "provider returns 0 (rc=$rc)"
[[ -z $(cat "$SQLITE_LOG" 2>/dev/null) ]] && ok "config token wins (no sqlite3)" || no "config token wins (sqlite3 called)"
first=$(sed -n 1p "$CURL_LOG")
second=$(sed -n 2p "$CURL_LOG")
[[ $first == *'action=productdetails'* && $first == *'WHMCSlogin_auth_tk=TOK123'* && $first == *' -c '* ]] \
    && ok "step 1: page + auth cookie + jar" || no "step 1 args ($first)"
[[ $second == *'vtoken=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'* && $second == *'api=json'* && $second == *' -b '* ]] \
    && ok "step 2: fresh vtoken + session jar" || no "step 2 args ($second)"

PAGE_HTML='<html>login page, no token</html>'
out=$(vpsbandwidth_fetch_dedione 2>/dev/null)
rc=$?
[[ -z $out ]] && ((rc != 0)) && ok "missing vtoken -> failure, clean stdout" || no "missing vtoken (rc=$rc out=$out)"

PAGE_HTML='<html>vtoken=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</html>'
API_JSON='The csrf tokens do not match!!'
out=$(vpsbandwidth_fetch_dedione 2>/dev/null)
rc=$?
[[ -z $out ]] && ((rc != 0)) && ok "csrf text -> failure, clean stdout" || no "csrf text (rc=$rc out=$out)"

API_JSON='{"bandwidth":{"used_gb":193.27,"limit_gb":500,"percent":38.65}}'
write_config <<'JSON'
{
  "provider": "dedione",
  "dedione": {"product_id": 11239, "svs": 4442, "auth_token": ""}
}
JSON
mkdir -p "$TMP/ffprofile"
: >"$TMP/ffprofile/cookies.sqlite"
printf '[Install4F96D1932A9F858E]\nDefault=%s\nLocked=1\n' "$TMP/ffprofile" >"$VPSBANDWIDTH_FF_PROFILES"
export SQLITE_TOKEN='FFTOK456'
: >"$CURL_LOG"
: >"$SQLITE_LOG"
out=$(vpsbandwidth_fetch_dedione 2>/dev/null)
rc=$?
[[ $out == '193.27|500|38.65' ]] && ((rc == 0)) && ok "firefox token fallback works" || no "firefox token fallback (rc=$rc out=$out)"
[[ -s $SQLITE_LOG ]] && ok "sqlite3 consulted when config token empty" || no "sqlite3 consulted when config token empty"
[[ $(sed -n 1p "$CURL_LOG") == *'WHMCSlogin_auth_tk=FFTOK456'* ]] \
    && ok "firefox token used in request" || no "firefox token used in request"

section "D: 展示"
source "$REPO/dwm-status-print.sh"
white=W red=R yellow=Y blue=B cyan=C black=K

seed_cache '193.27|500|38.65|1700000000|0'
out=$(print_vps_bandwidth)
[[ $out == *'usage:193G'* && $out == *'^s^'* && $out == *'limit:500G'* ]] \
    && ok "two-row usage/limit" || no "two-row usage/limit ($out)"
[[ $out == *'^r0,4,10,24^'* ]] && ok "gauge frame 10x24" || no "gauge frame ($out)"
[[ $out == *'^r2,14,6,12^'* ]] && ok "38% used -> 62% remain = 12px" || no "38% used -> remain fill ($out)"

seed_cache '400|500|85.2|1700000000|0'
out=$(print_vps_bandwidth)
[[ $out == *"^c$yellow^"* ]] && ok ">=80% yellow" || no ">=80% yellow ($out)"

seed_cache '480|500|95|1700000000|0'
out=$(print_vps_bandwidth)
[[ $out == *"^c$red^"* ]] && ok ">=90% red" || no ">=90% red ($out)"
[[ $out == *'^r2,25,6,1^'* ]] && ok "95% used -> 5% remain = 1px sliver" || no "95% remain sliver ($out)"

seed_cache '193|500|38|1700000000|1'
out=$(print_vps_bandwidth)
[[ $out == *'limit:500G!'* ]] && ok "stale marker" || no "stale marker ($out)"

seed_cache '1000|500|200|1700000000|0'
out=$(print_vps_bandwidth)
[[ $out != *'^r2,'* ]] && ok "over quota -> remain empty, no fill" || no "over quota empty ($out)"

seed_cache '10|0|0|1700000000|0'
err=$(print_vps_bandwidth 2>&1 >/dev/null)
[[ -z $err ]] && ok "zero limit: no stderr" || no "zero limit stderr ($err)"
out=$(print_vps_bandwidth)
[[ $out == *'limit:0G'* ]] && ok "zero limit still renders text" || no "zero limit text ($out)"

rm -f "$VPSBANDWIDTH_CACHE"
out=$(print_vps_bandwidth)
[[ -z $out ]] && ok "no cache -> no output" || no "no cache -> no output ($out)"

section "E: 静态守卫"
core=$(awk '/^update_vps_bandwidth\(\)/,/^}/' "$REPO/utils/vpsbandwidth.sh")
for word in whmcs vtoken cookie curl; do
    [[ ${core,,} != *"$word"* ]] && ok "core has no $word" || no "core has no $word"
done
printer=$(awk '/^print_vps_bandwidth\(\)/,/^}/' "$REPO/dwm-status-print.sh")
[[ $printer != *curl* ]] && ok "print does not fetch" || no "print does not fetch"

section "F: 阈值首超通知"
# 阈值语义: 旧缓存 percent 档位 vs 新值档位, 只在跨档升级时通知一次;
# 降档/同档静默, 回落 <80% 后下次跨档可再次提醒。无新增状态文件。
vpsbandwidth_fetch_pct() { printf '%s\n' "$PCT_LINE"; }
write_config <<'JSON'
{"provider": "pct"}
JSON
alert_count() { wc -l <"$NOTIFY_LOG"; }

# 冷启动无缓存: 视为档位 0, 已超标补发一次 (方案 A)
rm -f "$VPSBANDWIDTH_CACHE" "$VPSBANDWIDTH_STAMP"
: >"$NOTIFY_LOG"
PCT_LINE='85|500|85'
update_vps_bandwidth
rc=$?
(( $(alert_count) == 1 )) && ok "cold start >=80% notifies once" || no "cold start >=80% notifies once ($(alert_count))"
grep -q '^normal' "$NOTIFY_LOG" && ok "80 band is normal" || no "80 band is normal ($(cat "$NOTIFY_LOG"))"
grep -q '80% threshold' "$NOTIFY_LOG" && ok "80 band message" || no "80 band message ($(cat "$NOTIFY_LOG"))"
cache_is 85 500 85 0 && ((rc == 0)) && ok "cold start writes cache + rc 0" || no "cold start writes cache + rc 0 (rc=$rc)"

# 79.9% 不触发, 且写入缓存
rm -f "$VPSBANDWIDTH_CACHE"
: >"$NOTIFY_LOG"
PCT_LINE='79.9|500|79.9'
update_vps_bandwidth
(( $(alert_count) == 0 )) && ok "79.9% below threshold silent" || no "79.9% below threshold silent ($(alert_count))"
cache_is 79.9 500 79.9 0 && ok "79.9% cached" || no "79.9% cached"

# 79.9 -> 82 跨 80 档: 一条 normal
PCT_LINE='82|500|82'
update_vps_bandwidth
(( $(alert_count) == 1 )) && ok "79.9 -> 82 crosses 80, notifies" || no "79.9 -> 82 crosses 80 ($(alert_count))"

# 82 -> 86 同档: 静默
PCT_LINE='86|500|86'
update_vps_bandwidth
(( $(alert_count) == 1 )) && ok "82 -> 86 same band silent" || no "82 -> 86 same band silent ($(alert_count))"

# 86 -> 91 跨 90 档: 第二条 critical
PCT_LINE='91|500|91'
update_vps_bandwidth
(( $(alert_count) == 2 )) && ok "86 -> 91 crosses 90, notifies" || no "86 -> 91 crosses 90 ($(alert_count))"
sed -n 2p "$NOTIFY_LOG" | grep -q '^critical' && ok "90 band is critical" || no "90 band is critical ($(sed -n 2p "$NOTIFY_LOG"))"
grep -q '90% threshold' "$NOTIFY_LOG" && ok "90 band message" || no "90 band message ($(cat "$NOTIFY_LOG"))"

# 91 -> 95 同档: 静默
PCT_LINE='95|500|95'
update_vps_bandwidth
(( $(alert_count) == 2 )) && ok "91 -> 95 same band silent" || no "91 -> 95 same band silent ($(alert_count))"

# 95 -> 85 降档: 静默, 不回退通知
PCT_LINE='85|500|85'
update_vps_bandwidth
(( $(alert_count) == 2 )) && ok "95 -> 85 downgrade silent" || no "95 -> 85 downgrade silent ($(alert_count))"

# 85 -> 92 再次跨 90 档: 再提醒
PCT_LINE='92|500|92'
update_vps_bandwidth
(( $(alert_count) == 3 )) && ok "85 -> 92 crosses 90 again" || no "85 -> 92 crosses 90 again ($(alert_count))"

# 92 -> 12 月度重置: 静默
PCT_LINE='12|500|12'
update_vps_bandwidth
(( $(alert_count) == 3 )) && ok "quota reset silent" || no "quota reset silent ($(alert_count))"

# 12 -> 81 重置后再跨 80 档: 再提醒
PCT_LINE='81|500|81'
update_vps_bandwidth
(( $(alert_count) == 4 )) && ok "after reset crosses 80 again" || no "after reset crosses 80 again ($(alert_count))"

# 刷新失败: 不评估阈值 (只走既有失败告警)、档位不变
write_config <<'JSON'
{"provider": "not-installed"}
JSON
seed_cache '81|500|81|1700000000|0'
: >"$NOTIFY_LOG"
update_vps_bandwidth
grep -q 'threshold' "$NOTIFY_LOG" && no "failed refresh alerts threshold" || ok "failed refresh does not alert threshold"
cache_is 81 500 81 1 && ok "failed refresh keeps stale" || no "failed refresh keeps stale"

# 旧缓存 percent 损坏: 按档位 0 处理, 不报错
write_config <<'JSON'
{"provider": "pct"}
JSON
seed_cache '1|500|abc|1700000000|0'
: >"$NOTIFY_LOG"
PCT_LINE='85|500|85'
update_vps_bandwidth
rc=$?
(( $(alert_count) == 1 )) && ((rc == 0)) && ok "corrupt old percent treated as 0" || no "corrupt old percent treated as 0 (rc=$rc, $(alert_count))"

# 无 system-notify: 静默不崩, 仍写缓存
out=$( (
    unset -f system-notify
    rm -f "$VPSBANDWIDTH_CACHE"
    PCT_LINE='91|500|91'
    update_vps_bandwidth
) 2>&1)
rc=$?
[[ -z $out ]] && ((rc == 0)) && ok "missing system-notify is silent" || no "missing system-notify (rc=$rc out=$out)"
cache_is 91 500 91 0 && ok "missing system-notify still caches" || no "missing system-notify still caches"

# 静态守卫: 展示层保持纯读; core 不引入新状态文件
printer=$(awk '/^print_vps_bandwidth\(\)/,/^}/' "$REPO/dwm-status-print.sh")
[[ $printer != *notify* ]] && ok "print stays notify-free" || no "print stays notify-free"
core=$(awk '/^update_vps_bandwidth\(\)/,/^}/' "$REPO/utils/vpsbandwidth.sh")
[[ $core != *vpsbandwidth-level* ]] && ok "no extra alert state file" || no "no extra alert state file"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
