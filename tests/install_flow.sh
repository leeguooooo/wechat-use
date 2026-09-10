#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export WECHAT_FLOW_TEST_ROOT="$TEST_ROOT"
export WECHAT_USE_INSTALL_LIB_ONLY=1
export INSTALL_DIR="$TEST_ROOT/bin"
export WECHAT_INSTALL_LOG_DIR="$TEST_ROOT/logs"
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
  MOCK_SERVICE_PATH="$INSTALL_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
  MOCK_DAEMON_PATH="$INSTALL_DIR/wechatd"
  HEALTH="$GOOD_HEALTH"
  printf '%s' "$GOOD_REPORT" > "$TEST_ROOT/doctor.json"
  printf '剩余 30 天 · ✓ 有效\n' > "$TEST_ROOT/auth.txt"
  : > "$TEST_ROOT/actions"
}
launchctl() {
  [[ "$1" == print && "$MOCK_REGISTERED" == 1 ]] || return 1
  printf '\tprogram = %s\n\tpid = 42\n\tenvironment = {\n\t\tPATH => %s\n\t}\n' "$MOCK_PROGRAM" "$MOCK_SERVICE_PATH"
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
for failure in service_path bytes selection registration program network old_bridge old_daemon missing dead path parent ax malformed; do
  reset_fixture
  case "$failure" in
    service_path) MOCK_SERVICE_PATH=/usr/bin:/bin ;;
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
NEW_REPORT='{"status":"needs_init","query_ready":false,"send_ready":false,"checks":[{"name":"wechat_running","ok":false},{"name":"daemon_accessibility","ok":false,"detail":"FAIL ax_trusted=false process_path=/fixture/wechatd"},{"name":"config_present","ok":false},{"name":"key_file_present","ok":false}]}'
print_install_next_steps "$NEW_REPORT" missing 0 > "$TEST_ROOT/new"
for step in 'auth activate' '按提示完成登录' 'wechat-use init --fix-tcc' 'wechat-use init'; do grep -F "$step" "$TEST_ROOT/new" >/dev/null; done
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
  WECHAT_USE_PREFER_419=ask choose_preferred_wechat_419 >/dev/null 2>&1
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
  service_path=$(plutil -extract EnvironmentVariables.PATH raw -o - "$TEST_ROOT/agents/ai.wechat.bridge.plist")
  [[ ":$service_path:" == *":/usr/sbin:"* && ":$service_path:" == *":/sbin:"* ]]
  [[ "$(grep -c '^bootstrap ' "$TEST_ROOT/fresh-actions")" == 1 ]]
  if grep -E 'kickstart|bootout' "$TEST_ROOT/fresh-actions"; then exit 1; fi
)
echo 'PASS: first install creates its LaunchAgent and starts it once, without an immediate second restart'

# Missing permissions must not open windows, reset grants, or block for input.
open() { printf 'open\n' >> "$TEST_ROOT/actions"; }
osascript() { printf 'osascript\n' >> "$TEST_ROOT/actions"; }
tccutil() { printf 'tccutil\n' >> "$TEST_ROOT/actions"; }
: > "$TEST_ROOT/actions"
WECHAT_USE_PERMISSION_GUIDE=no remediate_tcc_grant > "$TEST_ROOT/permission-guidance" 2>&1
[[ ! -s "$TEST_ROOT/actions" ]]
grep -F '一次系统授权' "$TEST_ROOT/permission-guidance" >/dev/null
echo 'PASS: missing permissions report explicit recovery without GUI, resets, or automatic sends'

# Unknown service state must never become a permission diagnosis or test send.
UNKNOWN_SERVICE='{"status":"needs_init","query_ready":true,"send_ready":false,"checks":[{"name":"wechat_running","ok":true},{"name":"daemon_accessibility","ok":false,"detail":"daemon not running"},{"name":"config_present","ok":true},{"name":"key_file_present","ok":true}]}'
bridge_log_says_tcc_missing() { return 1; }
print_install_next_steps "$UNKNOWN_SERVICE" active 0 > "$TEST_ROOT/unavailable-service"
if grep -E 'fix-tcc|安装验证|辅助功能授权' "$TEST_ROOT/unavailable-service"; then exit 1; fi
grep -F '后台服务尚未就绪' "$TEST_ROOT/unavailable-service" >/dev/null
[[ "$(installer_permission_state "$UNKNOWN_SERVICE")" == unknown ]]
[[ "$(installer_permission_state "$NEW_REPORT")" == denied ]]
echo 'PASS: unavailable service does not trigger permission or send instructions'

# Existing configs are migrated without losing custom runtime settings.
python3 - "$TEST_ROOT/migrate.plist" <<'PYFIXTURE'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'Label':'old-label','Disabled':True,'ProgramArguments':['/old/bin/wechat-bridge','--port','18400'],'EnvironmentVariables':{'CUSTOM_FIXTURE':'preserve','PATH':'/custom/bin'},'StandardErrorPath':'/missing/path/old.err'},f)
PYFIXTURE
prepare_bridge_launchagent "$TEST_ROOT/migrate.plist"
LAUNCHAGENT_PLIST="$TEST_ROOT/migrate.plist"
[[ "$(bridge_error_log)" == "$TEST_ROOT/logs/bridge.err" ]]
python3 - "$TEST_ROOT/migrate.plist" "$INSTALL_DIR" <<'PYASSERT'
import plistlib,sys
with open(sys.argv[1],'rb') as f:d=plistlib.load(f)
assert d['Disabled'] is False
assert d['ProgramArguments']==[sys.argv[2]+'/wechat-bridge','--port','18400']
assert d['EnvironmentVariables']['CUSTOM_FIXTURE']=='preserve'
assert '/custom/bin' in d['EnvironmentVariables']['PATH'].split(':')
assert '/usr/sbin' in d['EnvironmentVariables']['PATH'].split(':')
PYASSERT
printf 'invalid-plist' > "$TEST_ROOT/invalid.plist"
if prepare_bridge_launchagent "$TEST_ROOT/invalid.plist" 2>/dev/null; then exit 1; fi
[[ "$(cat "$TEST_ROOT/invalid.plist")" == invalid-plist ]]
echo 'PASS: migrates binary/log/PATH settings, retains custom values and invalid original files'

# Disabled service is enabled first; bootstrap errors retain the actual cause.
(
 launchctl() { printf '%s\n' "$*" >> "$TEST_ROOT/bootstrap-actions"; if [[ "$1" == bootstrap ]]; then echo 'Bootstrap failed: 5: Input/output error' >&2; return 5; fi; }
 if bootstrap_bridge_launchagent "$TEST_ROOT/migrate.plist" > "$TEST_ROOT/bootstrap-output" 2>&1; then exit 1; fi
 grep -F 'Bootstrap failed: 5: Input/output error' "$TEST_ROOT/bootstrap-output" >/dev/null
 [[ "$(head -1 "$TEST_ROOT/bootstrap-actions")" == enable* ]]
)
echo 'PASS: enables owned service and preserves bootstrap failure diagnostics'

# Authorization originates from launchd, then the real service is refreshed.
(
 open_install_tty() { exec 3<>"$TEST_ROOT/fake-terminal"; }
 request_background_permission() { printf 'request %s\n' "$1" >> "$TEST_ROOT/actions"; }
 wait_for_bridge_health_retry() { return 0; }
 wechatd_ax_trusted() { return 0; }
 : > "$TEST_ROOT/actions"
 WECHAT_USE_PERMISSION_GUIDE=yes remediate_tcc_grant > "$TEST_ROOT/guide-output" 2>&1
 grep -Fx 'request wechat-bridge' "$TEST_ROOT/actions" >/dev/null
 [[ "$(grep -c '^reset$' "$TEST_ROOT/actions")" == 1 ]]
 if grep -E '^init|^send|^tccutil' "$TEST_ROOT/actions"; then exit 1; fi
)
echo 'PASS: requests bridge identity, refreshes service, never spawns init from Terminal'

# Bridge permission alone is insufficient if the actual daemon is still denied.
(
 open_install_tty() { exec 3<>"$TEST_ROOT/fake-terminal"; }
 request_background_permission() { printf 'request %s\n' "$1" >> "$TEST_ROOT/actions"; }
 wait_for_bridge_health_retry() { return 0; }
 ax_polls=0
 wechatd_ax_trusted() { ax_polls=$((ax_polls+1)); [[ "$ax_polls" -gt 1 ]]; }
 printf '%s' "$NEW_REPORT" > "$TEST_ROOT/doctor.json"
 : > "$TEST_ROOT/actions"
 WECHAT_USE_PERMISSION_GUIDE=yes remediate_tcc_grant > "$TEST_ROOT/two-identities-output" 2>&1
 grep -Fx 'request wechatd' "$TEST_ROOT/actions" >/dev/null
 [[ "$(grep -c '^reset$' "$TEST_ROOT/actions")" == 2 ]]
 [[ "$ax_polls" == 2 ]]
)
echo 'PASS: verifies both identities instead of treating one grant as completion'

# Actual job creation and completion parsing, with only launchctl mocked.
(
 launchctl() {
   printf '%s\n' "$*" >> "$TEST_ROOT/job-actions"
   case "$1" in
     bootstrap) cp "$3" "$TEST_ROOT/request-job.plist" ;;
     print) printf '\tstate = not running\n\tlast exit code = %s\n' "$MOCK_PERMISSION_EXIT" ;;
   esac
 }
 open_permission_windows() { printf 'reveal\n' >> "$TEST_ROOT/job-actions"; }
 MOCK_PERMISSION_EXIT=0
 request_background_permission wechat-bridge
 [[ -z "$PERMISSION_JOB_DOMAIN" && -z "$PERMISSION_JOB_DIR" ]]
 python3 - "$TEST_ROOT/request-job.plist" "$INSTALL_DIR" <<'PYJOB'
import plistlib,sys
with open(sys.argv[1],'rb') as f:d=plistlib.load(f)
assert d['ProgramArguments']==[sys.argv[2]+'/wechat-bridge','--request-trust']
assert d['KeepAlive'] is False and d['RunAtLoad'] is True
PYJOB
 MOCK_PERMISSION_EXIT=1
 if request_background_permission wechatd; then exit 1; fi
 [[ -z "$PERMISSION_JOB_DOMAIN" && -z "$PERMISSION_JOB_DIR" ]]
 [[ "$(grep -c '^bootout gui/.*/ai.wechat.permission.' "$TEST_ROOT/job-actions")" == 2 ]]
 if grep -Fx reveal "$TEST_ROOT/job-actions"; then exit 1; fi
)
echo 'PASS: one-shot launchd request uses installed identity and cleans up success/failure'

# Do not relay the obsolete binary's terminal-command recipe to the user.
(
 printf 'Accessibility TCC not granted\nFix in 30 seconds: open Settings; launchctl kickstart\n' > "$TEST_ROOT/logs/bridge.err"
 dump_bridge_diag > "$TEST_ROOT/short-permission-error" 2>&1
 grep -F '安装器将自动引导' "$TEST_ROOT/short-permission-error" >/dev/null
 if grep -E 'Fix in 30|kickstart' "$TEST_ROOT/short-permission-error"; then exit 1; fi
)
echo 'PASS: permission diagnostics suppress obsolete manual command instructions'

# Allow an already valid grant to finish before revealing Settings/Finder.
(
 launchctl() {
   case "$1" in
     print)
       n=$(cat "$TEST_ROOT/permission-polls"); n=$((n+1)); printf '%s' "$n" > "$TEST_ROOT/permission-polls"
       if [[ "$n" -lt 3 ]]; then printf '\tstate = running\n'; else printf '\tstate = not running\n\tlast exit code = 0\n'; fi ;;
   esac
 }
 sleep() { :; }
 open_permission_windows() { printf 'reveal\n' >> "$TEST_ROOT/delayed-reveal"; }
 printf 0 > "$TEST_ROOT/permission-polls"
 request_background_permission wechat-bridge
 [[ "$(grep -c '^reveal$' "$TEST_ROOT/delayed-reveal")" == 1 ]]
)
echo 'PASS: existing grants skip Finder; a pending system grant gets one reveal only'

# The native window and versioned service helper install without touching real apps.
(
 STAGE="$TEST_ROOT/setup-stage"
 mkdir -p "$STAGE/WechatUseSetup.app/Contents/MacOS"
 printf '#!/bin/bash\nexit 0\n' > "$STAGE/wechat-setup-service"
 printf 'fixture' > "$STAGE/WechatUseSetup.app/Contents/MacOS/wechat-setup-ui"
 printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.wechatskill.setup</string></dict></plist>' > "$STAGE/WechatUseSetup.app/Contents/Info.plist"
 setup_app_path() { printf '%s/apps/WechatUseSetup.app\n' "$TEST_ROOT"; }
 setup_state_dir() { printf '%s/state\n' "$TEST_ROOT"; }
 codesign() { [[ "$1" != -dvv ]] || printf 'Identifier=ai.wechatskill.setup\nTeamIdentifier=6ZPXG4KVVS\n'; }
 install_destination_command() { printf '%s\n' "$1" >> "$TEST_ROOT/setup-install-destinations"; shift; "$@"; }
 install_setup_window
 [[ "$SETUP_WINDOW_AVAILABLE" == 1 ]]
 cmp "$STAGE/wechat-setup-service" "$INSTALL_DIR/wechat-setup-service"
 [[ -f "$TEST_ROOT/state/installation.json" ]]
 [[ "$(wc -l < "$TEST_ROOT/setup-install-destinations" | tr -d ' ')" == 3 ]]
 # A repeat installation preserves matching files and remains usable.
 install_setup_window
 [[ "$(wc -l < "$TEST_ROOT/setup-install-destinations" | tr -d ' ')" == 3 ]]
 /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier unrelated.app' "$TEST_ROOT/apps/WechatUseSetup.app/Contents/Info.plist"
 if install_setup_window 2>/dev/null; then exit 1; fi
 [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TEST_ROOT/apps/WechatUseSetup.app/Contents/Info.plist")" == unrelated.app ]]
)
echo 'PASS: setup app/helper install is repeatable and preserves an unrelated destination'
