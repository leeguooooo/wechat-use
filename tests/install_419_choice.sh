#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export INSTALL_DIR="$TEST_ROOT/bin"
export WECHAT_419_SOURCE="$TEST_ROOT/source.app"
export WECHAT_419_TARGET="$TEST_ROOT/clone.app"
export WECHAT_USE_INSTALL_LIB_ONLY=1
mkdir -p "$INSTALL_DIR" "$WECHAT_419_SOURCE/Contents" "$TEST_ROOT/fake-bin"
cat > "$WECHAT_419_SOURCE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.tencent.xinWeChat419</string>
<key>CFBundleShortVersionString</key><string>4.1.9</string>
<key>CFBundleVersion</key><string>268596</string>
</dict></plist>
PLIST
export WECHAT_CLONE_ARGS_LOG="$TEST_ROOT/commands.log"
cat > "$INSTALL_DIR/wechat" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WECHAT_CLONE_ARGS_LOG"
if [[ "$1 $2" == "clone install" ]]; then
  while (($#)); do
    case "$1" in
      --source) src="$2"; shift 2 ;;
      --target) dst="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cp -R "$src" "$dst"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.tencent.xinWeChat419WechatUse' "$dst/Contents/Info.plist"
fi
FAKE
cat > "$TEST_ROOT/fake-bin/defaults" <<'FAKE'
#!/usr/bin/env bash
printf 'defaults %s\n' "$*" >> "$WECHAT_CLONE_ARGS_LOG"
FAKE
chmod +x "$INSTALL_DIR/wechat" "$TEST_ROOT/fake-bin/defaults"
export PATH="$TEST_ROOT/fake-bin:$PATH"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"
export WECHAT_USE_PREFER_419=yes
choose_preferred_wechat_419 >/dev/null
maybe_offer_preferred_wechat_419 >/dev/null
grep -F -- '--make-default' "$WECHAT_CLONE_ARGS_LOG" >/dev/null
grep -F 'update-guard disable' "$WECHAT_CLONE_ARGS_LOG" >/dev/null
grep -F 'defaults write com.tencent.xinWeChat419WechatUse ' "$WECHAT_CLONE_ARGS_LOG" >/dev/null
[[ "$(wechat_app_bundle_id "$WECHAT_419_SOURCE")" == com.tencent.xinWeChat419 ]]
before=$(shasum "$WECHAT_419_TARGET/Contents/Info.plist")
maybe_offer_preferred_wechat_419 >/dev/null
[[ "$before" == "$(shasum "$WECHAT_419_TARGET/Contents/Info.plist")" ]]
grep -F "clone use $WECHAT_419_TARGET" "$WECHAT_CLONE_ARGS_LOG" >/dev/null
export WECHAT_USE_PREFER_419=no
if choose_preferred_wechat_419 >/dev/null; then echo 'FAIL: refusal accepted'; exit 1; fi
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 4.1.11' "$WECHAT_419_TARGET/Contents/Info.plist"
if maybe_offer_preferred_wechat_419 >/dev/null 2>&1; then echo 'FAIL: wrong target accepted'; exit 1; fi
mv "$WECHAT_419_TARGET" "$TEST_ROOT/occupied.app"
PREFERRED_WECHAT_SOURCE=""
unset WECHAT_419_SOURCE
downloaded=0
find_preferred_wechat_source() { return 1; }
download_preferred_wechat_source() { downloaded=1; PREFERRED_WECHAT_SOURCE="$TEST_ROOT/source.app"; }
maybe_offer_preferred_wechat_419 >/dev/null
[[ "$downloaded" == 1 ]]
echo 'PASS: local source, fresh download, default binding, update scope, refusal, reuse, occupied target'
