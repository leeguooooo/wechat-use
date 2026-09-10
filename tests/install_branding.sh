#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export WECHAT_USE_INSTALL_LIB_ONLY=1
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$REPO_ROOT/install.sh"
# Unit fixtures must not register a fake copy of the product with macOS.
refresh_branding_registration() { :; }
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/><key>com.apple.security.application-groups</key><array><string>5A4RE8SF68.com.tencent.xinWeChat419WechatUse</string></array><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>\n' > "$TEST_ROOT/entitlements.plist"
plutil -convert xml1 "$TEST_ROOT/entitlements.plist"
fixture() {
  PREFERRED_WECHAT_TARGET="$TEST_ROOT/$1.app"
  mkdir -p "$PREFERRED_WECHAT_TARGET/Contents/Resources" "$PREFERRED_WECHAT_TARGET/Contents/MacOS" "$PREFERRED_WECHAT_TARGET/Contents/Frameworks"
  printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.tencent.xinWeChat419WechatUse</string><key>CFBundleShortVersionString</key><string>4.1.9</string><key>CFBundleVersion</key><string>268602</string><key>CFBundleName</key><string>WeChat</string><key>CFBundleDisplayName</key><string>WeChat</string><key>CFBundleIconName</key><string>AppIcon</string></dict></plist>\n' > "$PREFERRED_WECHAT_TARGET/Contents/Info.plist"
  printf 'unchanged executable\n' > "$PREFERRED_WECHAT_TARGET/Contents/MacOS/WeChat"
  printf 'vendor dylib\n' > "$PREFERRED_WECHAT_TARGET/Contents/Resources/wechat.dylib"
  printf 'vendor loader\n' > "$PREFERRED_WECHAT_TARGET/Contents/Frameworks/wechat.dylib"
  for lang in zh-Hans zh-Hant en; do
    mkdir -p "$PREFERRED_WECHAT_TARGET/Contents/Resources/$lang.lproj"
    printf '{ CFBundleName = "WeChat"; CFBundleDisplayName = "WeChat"; NSCameraUsageDescription = "keep this prompt"; }\n' > "$PREFERRED_WECHAT_TARGET/Contents/Resources/$lang.lproj/InfoPlist.strings"
  done
}
curl() {
  local output=''
  while (($#)); do
    if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
  done
  printf 'download\n' >> "$TEST_ROOT/downloads"
  if [[ "${BAD_ICON:-0}" == 1 ]]; then printf bad > "$output"; else cp "$REPO_ROOT/assets/wechat-tool-419.icns" "$output"; fi
}
codesign() {
  case "$1" in
    -d) cat "$TEST_ROOT/entitlements.plist" ;;
    --force)
      [[ "$*" != *--deep* ]]
      [[ "$4" == --entitlements ]]
      cmp -s "$5" "$TEST_ROOT/entitlements.plist"
      [[ "${SIGN_FAIL:-0}" == 0 ]]
      ;;
    --verify) return 0 ;;
    *) return 1 ;;
  esac
}
fixture 'clone with spaces'
before_inode=$(stat -f %i "$PREFERRED_WECHAT_TARGET")
before_info=$(shasum -a 256 "$PREFERRED_WECHAT_TARGET/Contents/Info.plist" | awk '{print $1}')
exec 3< "$PREFERRED_WECHAT_TARGET/Contents/Info.plist"
brand_preferred_wechat_419 >/dev/null
[[ "$(stat -f %i "$PREFERRED_WECHAT_TARGET")" != "$before_inode" ]]
[[ "$(shasum -a 256 <&3 | awk '{print $1}')" == "$before_info" ]]
exec 3<&-
preferred_branding_is_current "$PREFERRED_WECHAT_TARGET"
[[ "$(plutil -extract CFBundleName raw -o - "$PREFERRED_WECHAT_TARGET/Contents/Info.plist")" == 'clone with spaces' ]]
[[ "$(plutil -extract CFBundleDisplayName raw -o - "$PREFERRED_WECHAT_TARGET/Contents/Resources/zh-Hans.lproj/InfoPlist.strings")" == "$PREFERRED_WECHAT_NAME" ]]
[[ "$(plutil -extract NSCameraUsageDescription raw -o - "$PREFERRED_WECHAT_TARGET/Contents/Resources/zh-Hans.lproj/InfoPlist.strings")" == 'keep this prompt' ]]
[[ "$(cat "$PREFERRED_WECHAT_TARGET/Contents/Resources/wechat.dylib")" == 'vendor dylib' ]]
current_inode=$(stat -f %i "$PREFERRED_WECHAT_TARGET")
brand_preferred_wechat_419 >/dev/null
[[ "$(stat -f %i "$PREFERRED_WECHAT_TARGET")" == "$current_inode" ]]
[[ "$(wc -l < "$TEST_ROOT/downloads" | tr -d ' ')" == 1 ]]
echo 'PASS: all locales, original prompts, vendor bytes, entitlements, atomic directory swap, open-reader preservation, idempotent reuse'

for failure in bad_icon sign swap wrong_bundle; do
  fixture "$failure"
  if [[ "$failure" == wrong_bundle ]]; then
    plutil -replace CFBundleIdentifier -string com.tencent.xinWeChat "$PREFERRED_WECHAT_TARGET/Contents/Info.plist"
  fi
  before_info=$(shasum -a 256 "$PREFERRED_WECHAT_TARGET/Contents/Info.plist")
  before_inode=$(stat -f %i "$PREFERRED_WECHAT_TARGET")
  if (
    case "$failure" in
      bad_icon) BAD_ICON=1 ;;
      sign) SIGN_FAIL=1 ;;
      swap) swap_branding_bundle() { return 1; } ;;
    esac
    brand_preferred_wechat_419 > "$TEST_ROOT/$failure.log" 2>&1
  ); then echo "FAIL: $failure accepted"; exit 1; fi
  [[ "$(shasum -a 256 "$PREFERRED_WECHAT_TARGET/Contents/Info.plist")" == "$before_info" ]]
  [[ "$(stat -f %i "$PREFERRED_WECHAT_TARGET")" == "$before_inode" ]]
done
echo 'PASS: bad hash, signing failure, swap failure, and primary bundle all preserve the original app'

fixture symlink
mv "$PREFERRED_WECHAT_TARGET/Contents/Resources/zh-Hans.lproj" "$TEST_ROOT/external.lproj"
ln -s "$TEST_ROOT/external.lproj" "$PREFERRED_WECHAT_TARGET/Contents/Resources/zh-Hans.lproj"
before_external=$(shasum -a 256 "$TEST_ROOT/external.lproj/InfoPlist.strings")
if brand_preferred_wechat_419 >/dev/null 2>&1; then echo 'FAIL: external locale link accepted'; exit 1; fi
[[ "$(shasum -a 256 "$TEST_ROOT/external.lproj/InfoPlist.strings")" == "$before_external" ]]
echo 'PASS: locale directory symlink cannot mutate content outside the staged bundle'

fixture optional_branding
BAD_ICON=1
maybe_brand_preferred_wechat_419 > "$TEST_ROOT/optional.log" 2>&1
grep -F '不影响独立微信功能' "$TEST_ROOT/optional.log" >/dev/null
echo 'PASS: cosmetic failure warns without aborting the functional installer'
