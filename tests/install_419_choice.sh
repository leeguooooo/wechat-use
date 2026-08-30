#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wechat-install-419-test.XXXXXX")
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export INSTALL_DIR="${TEST_ROOT}/bin"
export WECHAT_419_SOURCE="${TEST_ROOT}/Applications/WeChat-4.1.9.app"
export WECHAT_419_TARGET="${TEST_ROOT}/Applications/WeChat-4.1.9-wechat-use.app"
export WECHAT_419_BUNDLE_ID="com.tencent.xinWeChat419Test"
export WECHAT_CLONE_ARGS_LOG="${TEST_ROOT}/clone-args.log"
export WECHAT_USE_INSTALL_LIB_ONLY=1

mkdir -p "${HOME}" "${INSTALL_DIR}" "${WECHAT_419_SOURCE}/Contents/MacOS"
cat > "${WECHAT_419_SOURCE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>4.1.9</string>
  <key>CFBundleVersion</key><string>268596</string>
  <key>CFBundleIdentifier</key><string>com.tencent.xinWeChat419Test</string>
  <key>CFBundleName</key><string>WeChat419Source</string>
  <key>CFBundleDisplayName</key><string>WeChat419Source</string>
  <key>CFBundleExecutable</key><string>WeChat</string>
</dict></plist>
PLIST
cat > "${WECHAT_419_SOURCE}/Contents/MacOS/WeChat" <<'APP'
#!/usr/bin/env bash
exit 0
APP
chmod +x "${WECHAT_419_SOURCE}/Contents/MacOS/WeChat"

cat > "${INSTALL_DIR}/wechat" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${WECHAT_CLONE_ARGS_LOG}"
source_app=""
target_app=""
while (($#)); do
  case "$1" in
    --source) source_app="$2"; shift 2 ;;
    --target) target_app="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "${target_app}/Contents"
cp "${source_app}/Contents/Info.plist" "${target_app}/Contents/Info.plist"
FAKE
chmod +x "${INSTALL_DIR}/wechat"

# shellcheck source=../install.sh
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"

export WECHAT_USE_PREFER_419=yes
output=$(maybe_offer_preferred_wechat_419 2>&1)
[[ -d "${WECHAT_419_TARGET}" ]]
grep -Fx -- 'clone' "${WECHAT_CLONE_ARGS_LOG}" >/dev/null
grep -Fx -- '--source' "${WECHAT_CLONE_ARGS_LOG}" >/dev/null
grep -Fx -- "${WECHAT_419_SOURCE}" "${WECHAT_CLONE_ARGS_LOG}" >/dev/null
grep -Fx -- '--target' "${WECHAT_CLONE_ARGS_LOG}" >/dev/null
grep -Fx -- "${WECHAT_419_TARGET}" "${WECHAT_CLONE_ARGS_LOG}" >/dev/null
grep -F '独立副本已创建' <<<"${output}" >/dev/null

rm -rf "${WECHAT_419_TARGET}"
rm -f "${WECHAT_CLONE_ARGS_LOG}"
export WECHAT_USE_PREFER_419=no
output=$(maybe_offer_preferred_wechat_419 2>&1)
[[ ! -e "${WECHAT_419_TARGET}" ]]
[[ ! -e "${WECHAT_CLONE_ARGS_LOG}" ]]
grep -F '当前 WeChat 保持不变' <<<"${output}" >/dev/null

export WECHAT_USE_PREFER_419=ask
output=$(maybe_offer_preferred_wechat_419 </dev/null 2>&1)
[[ ! -e "${WECHAT_419_TARGET}" ]]
[[ ! -e "${WECHAT_CLONE_ARGS_LOG}" ]]
grep -F '非交互模式' <<<"${output}" >/dev/null

if [[ -n "${WECHAT_REAL_BINARY:-}" ]]; then
  real_target="${TEST_ROOT}/Applications/WeChat-4.1.9-real-clone.app"
  "${WECHAT_REAL_BINARY}" clone install \
    --source "${WECHAT_419_SOURCE}" \
    --target "${real_target}" \
    --name 'WeChat 4.1.9 Test' \
    --bundle-id 'com.tencent.xinWeChat419RealTest' >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${real_target}/Contents/Info.plist")" == '4.1.9' ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${real_target}/Contents/Info.plist")" == 'com.tencent.xinWeChat419RealTest' ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${WECHAT_419_SOURCE}/Contents/Info.plist")" == 'com.tencent.xinWeChat419Test' ]]
  codesign --verify --deep "${real_target}"
fi

mkdir -p "${WECHAT_419_TARGET}/Contents"
cp "${WECHAT_419_SOURCE}/Contents/Info.plist" "${WECHAT_419_TARGET}/Contents/Info.plist"
printf 'keep\n' > "${WECHAT_419_TARGET}/marker"
export WECHAT_USE_PREFER_419=yes
output=$(maybe_offer_preferred_wechat_419 2>&1)
[[ "$(cat "${WECHAT_419_TARGET}/marker")" == "keep" ]]
[[ ! -e "${WECHAT_CLONE_ARGS_LOG}" ]]
grep -F '副本已存在' <<<"${output}" >/dev/null

echo 'install 4.1.9 choice tests passed'
