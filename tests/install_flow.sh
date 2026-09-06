#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export WECHAT_FLOW_TEST_ROOT="$TEST_ROOT"
export WECHAT_USE_INSTALL_LIB_ONLY=1
export INSTALL_DIR="$TEST_ROOT/bin"
mkdir -p "$INSTALL_DIR"
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"
cat > "$INSTALL_DIR/wechat" <<'MOCK'
#!/usr/bin/env bash
case "$1 $2" in
  'doctor --json') cat "$WECHAT_FLOW_TEST_ROOT/doctor.json" ;;
  'auth status') cat "$WECHAT_FLOW_TEST_ROOT/auth.txt"; exit "${MOCK_AUTH_EXIT:-0}" ;;
  *) printf '%s\n' "$*" >> "$WECHAT_FLOW_TEST_ROOT/actions" ;;
esac
MOCK
chmod +x "$INSTALL_DIR/wechat"
LAUNCHAGENT_PLIST="$TEST_ROOT/bridge.plist"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>ProgramArguments</key><array><string>%s/wechat-bridge</string></array></dict></plist>\n' "$INSTALL_DIR" > "$LAUNCHAGENT_PLIST"
LATEST_TAG=v1.18.2
GOOD_REPORT='{"status":"ok","query_ready":true,"send_ready":true,"checks":[{"name":"wechat_running","ok":true},{"name":"daemon_accessibility","ok":true},{"name":"config_present","ok":true},{"name":"key_file_present","ok":true}]}'
GOOD_HEALTH='{"bridge_version":"1.18.2","daemon":{"version":"1.18.2","alive":true,"pid":43}}'
reset_fixture() {
  BINARIES_CHANGED=0 CLONE_SELECTION_UNCHANGED=1 MOCK_REGISTERED=1 MOCK_NETWORK=1 MOCK_PARENT=42
  MOCK_PROGRAM="$INSTALL_DIR/wechat-bridge"
  MOCK_DAEMON_PATH="$INSTALL_DIR/wechatd"
  HEALTH="$GOOD_HEALTH"
  printf '%s' "$GOOD_REPORT" > "$TEST_ROOT/doctor.json"
  printf '剩余 30 天 · ✓ 有效\n' > "$TEST_ROOT/auth.txt"
  : > "$TEST_ROOT/actions"
}
launchctl() {
  [[ "$1" == print && "$MOCK_REGISTERED" == 1 ]] || return 1
  printf '\tprogram = %s\n\tpid = 42\n' "$MOCK_PROGRAM"
}
curl() { [[ "$MOCK_NETWORK" == 1 ]] && printf '%s' "$HEALTH"; }
ps() {
  case "$*" in
    '-p 42 -o comm=') printf '%s\n' "$INSTALL_DIR/wechat-bridge" ;;
    '-p 43 -o comm=') printf '%s\n' "$MOCK_DAEMON_PATH" ;;
    '-p 43 -o ppid=') printf '  %s\n' "$MOCK_PARENT" ;;
    *) return 1 ;;
  esac
}
reset_wechat_services() { printf 'reset\n' >> "$TEST_ROOT/actions"; }
reset_fixture
run_service_phase >/dev/null
[[ "$SERVICES_REUSED" == 1 && ! -s "$TEST_ROOT/actions" ]]
maybe_smoke_send >/dev/null
[[ ! -s "$TEST_ROOT/actions" ]]
for failure in bytes selection registration program network old_bridge old_daemon missing dead path parent ax malformed; do
  reset_fixture
  case "$failure" in
    bytes) BINARIES_CHANGED=1 ;;
    selection) CLONE_SELECTION_UNCHANGED=0 ;;
    registration) MOCK_REGISTERED=0 ;;
    program) MOCK_PROGRAM=/another/bridge ;;
    network) MOCK_NETWORK=0 ;;
    old_bridge) HEALTH='{"bridge_version":"1.17.9","daemon":{"version":"1.18.2","alive":true,"pid":43}}' ;;
    old_daemon) HEALTH='{"bridge_version":"1.18.2","daemon":{"version":"1.17.9","alive":true,"pid":43}}' ;;
    missing) HEALTH='{}' ;;
    dead) HEALTH='{"bridge_version":"1.18.2","daemon":{"version":"1.18.2","alive":false,"pid":43}}' ;;
    path) MOCK_DAEMON_PATH=/another/wechatd ;;
    parent) MOCK_PARENT=1 ;;
    ax) printf '%s' '{"checks":[{"name":"daemon_accessibility","ok":false,"detail":"ax_trusted=true"}]}' > "$TEST_ROOT/doctor.json" ;;
    malformed) printf 'invalid JSON' > "$TEST_ROOT/doctor.json" ;;
  esac
  run_service_phase >/dev/null
  [[ "$SERVICES_REUSED" == 0 && "$(cat "$TEST_ROOT/actions")" == reset ]] || { echo "FAIL: $failure reused"; exit 1; }
done
echo 'PASS: no-op preserves services and sends nothing; changed bytes, stale/wrong/missing services, denied/invalid AX all require repair'

reset_fixture
print_install_next_steps "$GOOD_REPORT" active 1 > "$TEST_ROOT/ready"
grep -F '已就绪' "$TEST_ROOT/ready" >/dev/null
if grep -E 'auth activate|wechat-use init|fix-tcc|安装验证' "$TEST_ROOT/ready"; then exit 1; fi
NEW_REPORT='{"status":"needs_init","query_ready":false,"send_ready":false,"checks":[{"name":"wechat_running","ok":false},{"name":"daemon_accessibility","ok":false},{"name":"config_present","ok":false},{"name":"key_file_present","ok":false}]}'
print_install_next_steps "$NEW_REPORT" missing 0 > "$TEST_ROOT/new"
for step in 'auth activate' '按提示完成登录' 'fix-tcc' 'wechat-use init'; do grep -F "$step" "$TEST_ROOT/new" >/dev/null; done
print_install_next_steps "$GOOD_REPORT" inactive 1 > "$TEST_ROOT/expired"
grep -F 'auth renew' "$TEST_ROOT/expired" >/dev/null
if grep -F 'auth activate' "$TEST_ROOT/expired"; then exit 1; fi
print_install_next_steps '{}' active 1 > "$TEST_ROOT/unknown"
grep -F '未能读取体检结果' "$TEST_ROOT/unknown" >/dev/null
[[ "$(installer_subscription_state)" == active ]]
printf '尚未激活订阅。\n' > "$TEST_ROOT/auth.txt"
[[ "$(installer_subscription_state)" == missing ]]
printf '剩余 0 天 · ✗ 已过期\n' > "$TEST_ROOT/auth.txt"
[[ "$(installer_subscription_state)" == inactive ]]
export MOCK_AUTH_EXIT=1
[[ "$(installer_subscription_state)" == unknown ]]
unset MOCK_AUTH_EXIT
if installer_check_ok '{"checks":[{"name":"x","ok":true},{"name":"x","ok":true}]}' x; then exit 1; fi
echo 'PASS: ready users skip onboarding; new installs get missing steps; expired/unknown subscriptions never trigger reactivation advice'

PREFERRED_WECHAT_TARGET="$TEST_ROOT/clone.app"
mkdir -p "$PREFERRED_WECHAT_TARGET/Contents"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.tencent.xinWeChat419WechatUse</string><key>CFBundleShortVersionString</key><string>4.1.9</string><key>CFBundleVersion</key><string>268602</string></dict></plist>\n' > "$PREFERRED_WECHAT_TARGET/Contents/Info.plist"
canonical=$(cd "$PREFERRED_WECHAT_TARGET" && pwd -P)
printf '{"app_path":"%s","bundle_id":"com.tencent.xinWeChat419WechatUse","version":"4.1.9","build":"268602"}' "$canonical" > "$TEST_ROOT/managed.json"
previous_clone_choice_is_valid "$TEST_ROOT/managed.json"
plutil -replace build -string 999 "$TEST_ROOT/managed.json"
if previous_clone_choice_is_valid "$TEST_ROOT/managed.json"; then exit 1; fi
(
  previous_clone_choice_is_valid() { return 0; }
  open_install_tty() { echo 'FAIL: reused clone prompted' >&2; return 1; }
  WECHAT_USE_PREFER_419=ask choose_preferred_wechat_419 >/dev/null
  if WECHAT_USE_PREFER_419=no choose_preferred_wechat_419 >/dev/null; then exit 1; fi
)
(
  previous_clone_choice_is_valid() { return 1; }
  open_install_tty() { return 1; }
  if WECHAT_USE_PREFER_419=ask choose_preferred_wechat_419 >/dev/null 2>&1; then exit 1; fi
)
echo 'PASS: confirmed matching clone reuses consent; mismatched metadata and explicit refusal stay protected'

printf same > "$TEST_ROOT/source"
cp "$TEST_ROOT/source" "$TEST_ROOT/dest"
chmod +x "$TEST_ROOT/dest"
installed_binary_matches_staged "$TEST_ROOT/source" "$TEST_ROOT/dest"
printf changed > "$TEST_ROOT/dest"
if installed_binary_matches_staged "$TEST_ROOT/source" "$TEST_ROOT/dest"; then exit 1; fi
read_optional_install_choice() { printf 'FAIL: headless prompt called\n' >> "$TEST_ROOT/actions"; return 1; }
npx() { printf 'skill\n' >> "$TEST_ROOT/actions"; }
: > "$TEST_ROOT/actions"
WECHAT_USE_INSTALL_SKILL=no offer_agent_skill_install > "$TEST_ROOT/skill-no"
[[ ! -s "$TEST_ROOT/actions" ]]
WECHAT_USE_INSTALL_SKILL=ask offer_agent_skill_install > "$TEST_ROOT/skill-auto"
[[ ! -s "$TEST_ROOT/actions" ]]
WECHAT_USE_INSTALL_SKILL=yes offer_agent_skill_install > "$TEST_ROOT/skill-yes"
[[ "$(cat "$TEST_ROOT/actions")" == skill ]]
echo 'PASS: byte comparison and optional skill opt-in; no headless tty access or automatic npx'

# Exercise the real first-install service body with process control mocked.
# The library-only entry returns before its definition, so load just that
# function. This must never create files in the user's LaunchAgents directory.
(
  eval "$(sed -n '/^reset_wechat_services() {/,/^}$/p' "$(cd "$(dirname "$0")/.." && pwd)/install.sh")"
  install_launchagent_dir() { printf '%s/agents\n' "$TEST_ROOT"; }
  launchctl() { printf '%s\n' "$*" >> "$TEST_ROOT/fresh-actions"; [[ "$1" != list ]] || printf 'ai.wechat.bridge\n'; }
  pgrep() { return 1; }
  sleep() { :; }
  curl() { return 0; }
  reset_wechat_services > "$TEST_ROOT/fresh-output"
  [[ -f "$TEST_ROOT/agents/ai.wechat.bridge.plist" ]]
  [[ "$(grep -c '^bootstrap ' "$TEST_ROOT/fresh-actions")" == 1 ]]
  if grep -E 'kickstart|bootout' "$TEST_ROOT/fresh-actions"; then exit 1; fi
)
echo 'PASS: first install creates its LaunchAgent and starts it once, without an immediate second restart'

# Missing permissions must not open windows, reset grants, or block for input.
open() { printf 'open\n' >> "$TEST_ROOT/actions"; }
osascript() { printf 'osascript\n' >> "$TEST_ROOT/actions"; }
tccutil() { printf 'tccutil\n' >> "$TEST_ROOT/actions"; }
: > "$TEST_ROOT/actions"
remediate_tcc_grant > "$TEST_ROOT/permission-guidance" 2>&1
[[ ! -s "$TEST_ROOT/actions" ]]
grep -F 'doctor --fix-tcc' "$TEST_ROOT/permission-guidance" >/dev/null
echo 'PASS: missing permissions report explicit recovery without GUI, resets, or automatic sends'
