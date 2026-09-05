#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export WECHAT_USE_INSTALL_LIB_ONLY=1
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"
printf 'old binary\n' > "$TEST_ROOT/wechatd"
printf 'new binary\n' > "$TEST_ROOT/new"
old_inode=$(stat -f %i "$TEST_ROOT/wechatd")
exec 3< "$TEST_ROOT/wechatd"
install_binary_atomically "$TEST_ROOT/new" "$TEST_ROOT/wechatd"
[[ "$(stat -f %i "$TEST_ROOT/wechatd")" != "$old_inode" ]]
[[ "$(cat <&3)" == 'old binary' ]]
[[ "$(cat "$TEST_ROOT/wechatd")" == 'new binary' ]]
exec 3<&-
install() { return 17; }
if install_binary_atomically "$TEST_ROOT/new" "$TEST_ROOT/wechatd"; then
  echo 'FAIL: failed staging reported success'; exit 1
fi
[[ "$(cat "$TEST_ROOT/wechatd")" == 'new binary' ]]
unset -f install
PREFERRED_WECHAT_TARGET="$TEST_ROOT/clone.app"
mkdir -p "$PREFERRED_WECHAT_TARGET/Contents/MacOS"
touch "$PREFERRED_WECHAT_TARGET/Contents/MacOS/WeChat"
chmod +x "$PREFERRED_WECHAT_TARGET/Contents/MacOS/WeChat"
codesign() { printf '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><%s/></dict></plist>\n' "$ALLOW"; }
ALLOW=true
[[ "$(wechat_get_task_allow_state)" == true ]]
ALLOW=false
[[ "$(wechat_get_task_allow_state)" == false ]]
if warn_if_wechat_lacks_get_task_allow > "$TEST_ROOT/warning" 2>&1; then exit 1; fi
grep -F 'wechat-use init' "$TEST_ROOT/warning" >/dev/null
if grep -E 'osascript|sudo codesign|open -a WeChat' "$TEST_ROOT/warning"; then exit 1; fi
echo 'PASS: atomic inode replacement, old reader intact, failed staging preserves binary, literal entitlement key, clone-only repair'
