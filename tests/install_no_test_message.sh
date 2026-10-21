#!/usr/bin/env bash
# WECHAT_USE_NO_TEST_MESSAGE=1 (set by `wechat-use upgrade`) prevents every
# installer-initiated WeChat message; without it, the README install is unchanged.
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export WECHAT_USE_INSTALL_LIB_ONLY=1
unset WECHAT_USE_NO_TEST_MESSAGE
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"
INSTALL_DIR="$TEST_ROOT/bin"
LOG="$TEST_ROOT/calls"
mkdir -p "$INSTALL_DIR" "$HOME/.wx-rs/com_tencent_xinWeChat419WechatUse"
touch "$HOME/.wx-rs/com_tencent_xinWeChat419WechatUse/config.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$LOG" > "$INSTALL_DIR/wechat"
chmod +x "$INSTALL_DIR/wechat"
# Every smoke-send precondition holds.
installer_subscription_state() { echo active; }
wechat_get_task_allow_state() { echo true; }
ps() { printf '%s\n' "$PREFERRED_WECHAT_TARGET/Contents/MacOS/WeChat"; }

# Default (README install): unchanged.
: > "$LOG"
maybe_smoke_send > /dev/null
run_setup_step
grep -q '^send .* filehelper$' "$LOG"
grep -Fqx 'setup' "$LOG"

# Upgrade: setup still runs (services, permissions, clone) but sends nothing.
: > "$LOG"
export WECHAT_USE_NO_TEST_MESSAGE=1
maybe_smoke_send > /dev/null
run_setup_step
[[ "$(cat "$LOG")" == 'setup --skip-verify' ]]
echo 'PASS: upgrade mode skips the smoke send and runs setup --skip-verify; default install unchanged'
