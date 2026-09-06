#!/usr/bin/env bash
# install.sh — one-liner installer for wechat + wechatd
#
# Default: install to ~/.local/bin (no sudo). Override with INSTALL_DIR.
# Example: INSTALL_DIR=/usr/local/bin ./install.sh  (will use sudo if needed)
set -euo pipefail

REPO="leeguooooo/wechat-use"
BINS=(wechat wechatd wechat-bridge wechat-mcp wechat-wechaty-gateway)
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# Supported WeChat versions (高层版本号). Per-build 兼容矩阵在运行时通过
# `wechat doctor` + profile API 查询,这里只列大版本号让用户快速判断。
SUPPORTED_WECHAT_VERSIONS="4.1.9"
SUPPORTED_WECHAT_BUILDS=""
WECHAT_DOWNLOAD_URL="https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_4.1.9.dmg"
WECHAT_419_DMG_URL="$WECHAT_DOWNLOAD_URL"
WECHAT_419_DMG_BACKUP_URL="https://pub-1d3598b37fc7448ba5cd296047de72dc.r2.dev/wechat/WeChatMac_4.1.9_268602.dmg"
WECHAT_419_DMG_SHA256="0e8510d1a004fe6373aa0ad1806d73d4bcf9a32f0c62284d8eb82cefe2b78d06"
PREFERRED_WECHAT_VERSION="4.1.9"
PREFERRED_WECHAT_SOURCE="${WECHAT_419_SOURCE:-}"
PREFERRED_WECHAT_TARGET="${WECHAT_419_TARGET:-$HOME/Applications/WeChat-4.1.9-wechat-use.app}"
PREFERRED_WECHAT_BUNDLE_ID="com.tencent.xinWeChat419WechatUse"
PREFERRED_WECHAT_NAME="${WECHAT_419_NAME:-微信 4.1.9（工具专用）}"
WECHAT_419_ICON_URL="https://raw.githubusercontent.com/leeguooooo/wechat-use/1cb0f670437ca002fe778bad37ec4d02abdcdc31/assets/wechat-tool-419.icns"
WECHAT_419_ICON_SHA256="dc2968342b225d5506b88607b7a79b9b69384a341555c42f36f37b7daeb28d09"

# ANSI color helpers — only emit if stderr/stdout is a tty so logs piped to
# files or grep stay readable.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

info()    { printf '%s[install]%s %s\n'      "${C_CYAN}"  "${C_RESET}" "$1"; }
success() { printf '%s[install] ✓%s %s\n'    "${C_GREEN}" "${C_RESET}" "$1"; }
warn()    { printf '%s[install] !%s %s\n'    "${C_YELLOW}" "${C_RESET}" "$1" >&2; }
err()     { printf '%s[install] ✗%s %s\n'    "${C_RED}"   "${C_RESET}" "$1" >&2; }
step()    { printf '%s[install] →%s %s\n'    "${C_YELLOW}" "${C_RESET}" "$1"; }
cmd()     { printf '%s%s%s'                  "${C_CYAN}"  "$1"          "${C_RESET}"; }

# Probe wechat-bridge /health on localhost:18400. Used to verify the
# LaunchAgent is actually serving (vs. crash-looping at AX preflight).
# 15s window covers cold start + cargo-build LaunchAgent jitter; in a
# crash loop we'll burn ~10 spawn attempts inside this window, so a
# negative result is reliable, not a false-negative on slow startup.
wait_for_bridge_health() {
  local window="${1:-15}"
  local deadline=$(( SECONDS + window ))
  while (( SECONDS < deadline )); do
    if curl -fsS -m 1 http://127.0.0.1:18400/health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Two-phase health probe used at final verification: 15s warm window,
# then a 10s retry pass. Without the retry, an upgrade that just relaunched
# the LaunchAgent occasionally trips the user-visible warn even though
# bridge comes up a couple seconds later (race: launchd respawn jitter).
wait_for_bridge_health_retry() {
  if wait_for_bridge_health 15; then
    return 0
  fi
  step "bridge 还没起来，再等 10s …"
  wait_for_bridge_health 10
}

# Fetch crash-loop diagnostic from launchctl + the bridge's own error log.
# Customers with no TCC see "ai.wechat.bridge missing" — but the WHY is
# in stderr (Accessibility TCC missing / port 18400 occupied / signature
# tripped), and they'll never `tail` it on their own. Surface the real
# reason inline so the next install step (TCC fix) is anchored to the
# observed failure mode, not a guess.
bridge_error_log() {
  local plist="${LAUNCHAGENT_PLIST:-$HOME/Library/LaunchAgents/ai.wechat.bridge.plist}" configured=""
  if [[ -f "$plist" ]]; then
    configured=$(plutil -extract StandardErrorPath raw -o - "$plist" 2>/dev/null || true)
  fi
  printf '%s\n' "${configured:-/tmp/wechat-bridge.err}"
}

dump_bridge_diag() {
  local label="${1:-bridge 未通过 /health 检查}"
  # All output goes to stderr — keep it on a single stream so the
  # diag block doesn't get reordered around stdout `success` lines
  # under buffered pipes (`tee`, ssh, CI).
  warn "${label}"
  local print_out
  print_out=$(launchctl print "gui/$(id -u)/ai.wechat.bridge" 2>/dev/null || true)
  if [[ -n "${print_out}" ]]; then
    local last_exit runs state
    last_exit=$(printf '%s\n' "${print_out}" | awk -F'=' '/last exit code/ { gsub(/ /,"",$2); print $2; exit }')
    runs=$(printf '%s\n' "${print_out}" | awk -F'=' '/^[[:space:]]+runs[[:space:]]*=/ { gsub(/ /,"",$2); print $2; exit }')
    state=$(printf '%s\n' "${print_out}" | awk -F'=' '/^[[:space:]]+state[[:space:]]*=/ { gsub(/^ +/,"",$2); print $2; exit }')
    printf '    %slaunchctl: state=%s runs=%s last_exit=%s%s\n' \
      "${C_DIM}" "${state:-?}" "${runs:-?}" "${last_exit:-?}" "${C_RESET}" >&2
  fi
  local log
  log=$(bridge_error_log)
  if [[ -f "${log}" ]]; then
    printf '%s── 最近 30 行 bridge stderr (%s) ──%s\n' "${C_DIM}" "${log}" "${C_RESET}" >&2
    tail -n 30 "${log}" 2>/dev/null | sed 's/^/    /' >&2
    printf '%s── 日志结束 ──%s\n' "${C_DIM}" "${C_RESET}" >&2
  else
    printf '    %s（未找到 %s）%s\n' "${C_DIM}" "${log}" "${C_RESET}" >&2
  fi
}

# Read bridge.error.log and decide whether the failure mode is "TCC
# missing" specifically (vs. port conflict, plist env, or unknown).
# `wechat-bridge --check-trust` is unreliable as ground truth because
# AXIsProcessTrusted reads the *caller* process's trust state, and an
# install.sh process forked from the user's shell can inherit Terminal /
# iTerm / SSH agent's TCC grant — a false positive while the launchd-
# spawned bridge service still gets rejected. The bridge's own preflight
# stderr ("Accessibility TCC not granted") is the ground truth — it's
# emitted by the same audit-token context that fails to serve.
bridge_log_says_tcc_missing() {
  local log
  log=$(bridge_error_log)
  [[ -f "${log}" ]] || return 1
  # Match either of the two phrases preflight emits.
  tail -n 60 "${log}" 2>/dev/null \
    | grep -qE "Accessibility TCC (not granted|missing)"
}

# Probe WeChat's get-task-allow entitlement.
#
# 官方分发的 WeChat 默认 `get-task-allow=false`(键根本不在 entitlements
# plist 里)。macOS 公开调试接口在该 entitlement 缺失时无法配合 wechatd
# 完成 send 路径设置。结果:`wechat send` 在 30s 后返回
# `slot_send_bp_failed_to_arm`,哪怕 TCC 全绿。线上回归(2026-05-18):
# TCC ✓ + ax_trusted=true ✓,smoke send 仍超时,根因就是该 entitlement
# 没补 → 本函数在 install 末尾兜底自检。
#
# Echoes one of: true / false / no_app / no_sig
wechat_get_task_allow_state() {
  local app_bin="${PREFERRED_WECHAT_TARGET}/Contents/MacOS/WeChat"
  if [[ ! -x "${app_bin}" ]]; then
    echo "no_app"
    return
  fi
  local ents
  if ! ents=$(codesign -d --entitlements :- "${app_bin}" 2>/dev/null); then
    echo "no_sig"
    return
  fi
  local v
  v=$(printf '%s' "${ents}" | plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - - 2>/dev/null || true)
  if [[ "${v}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Route repairs through the managed CLI; never suggest quitting or re-signing
# the main WeChat application by its display name.
# Returns 0 if OK / can't tell; 1 if confirmed broken.
warn_if_wechat_lacks_get_task_allow() {
  local state
  state="$(wechat_get_task_allow_state)"
  case "${state}" in
    true)
      success "WeChat get-task-allow ✓ —— wechatd send 适配模块可正常装载"
      return 0
      ;;
    no_app)
      # 后续 doctor 会提示装 WeChat,这里不重复
      return 0
      ;;
    no_sig)
      warn "WeChat 二进制读不到签名 entitlements (rare),先跑 \`wechat doctor\` 排查"
      return 1
      ;;
    false|*)
      warn "独立微信缺少 get-task-allow：$PREFERRED_WECHAT_TARGET"
      info '请运行 wechat-use init 修复独立副本，再运行 wechat-use doctor；不要重签或退出主微信。'
      return 1
      ;;
  esac
}

# Optional post-flight smoke send to filehelper. Two reasons:
#   1. WeChat 内部的 send pipeline 只在第一次真实用户 send 之后才完全
#      就绪;bridge bootout/bootstrap 之后第一次 send 经常命中
#      `delivery_verify_timeout`。给 filehelper 发一条做 warmup,
#      用户的第一条真实 send 就不会静默失败。
#   2. 端到端验证:CLI → daemon → bridge → WeChat → DB 一次性走通。
#
# Skipped silently when prerequisites (init / auth / WeChat running)
# aren't in place — this is a smoke test, not an init replacement.
maybe_smoke_send() {
  if [[ "${SERVICES_REUSED:-0}" == 1 ]]; then
    info '保留现有服务，跳过重复测试消息。'
    return 0
  fi
  local config_file="${HOME}/.wx-rs/com_tencent_xinWeChat419WechatUse/config.json"
  # Init hasn't run → no key, no daemon — silent skip.
  if [[ ! -f "${config_file}" ]]; then
    return 0
  fi
  # Auth: just probe whether the CLI can read a token. v1.9+ refuses
  # to send without an activated token; surfacing that here would
  # confuse a fresh installer who hasn't activated yet.
  if [[ "$(installer_subscription_state)" != active ]]; then
    info "filehelper smoke send 已跳过（激活码未激活；激活后跑：wechat send 'hi' filehelper）"
    return 0
  fi
  # WeChat running? Without it the daemon can't attach to the runtime.
  if ! ps -axo comm= | grep -Fx -- "$PREFERRED_WECHAT_TARGET/Contents/MacOS/WeChat" >/dev/null; then
    info "filehelper smoke send 已跳过（WeChat 未运行；启动 WeChat 后跑：wechat send 'hi' filehelper）"
    return 0
  fi
  # WeChat get-task-allow? wechatd 的本地调试接口需要该 entitlement,
  # 没有的话 send 适配模块装不上,smoke 跑了也是浪费 30s + 误报首发
  # warmup 问题。提前 skip,banner 已经在前面打过了。
  if [[ "$(wechat_get_task_allow_state)" != "true" ]]; then
    info "filehelper smoke send 已跳过（独立微信需要修复；请运行 wechat-use init）"
    return 0
  fi
  info "跑 filehelper smoke send：warmup WeChat 内部 send pipeline + 端到端验证"
  local stamp output
  stamp=$(date '+%H:%M:%S')
  if output=$("${INSTALL_DIR}/wechat" send "[install] smoke ${stamp}" filehelper 2>&1); then
    success "filehelper smoke 通过：CLI → daemon → bridge → WeChat → DB 全链路 OK"
  else
    warn "filehelper smoke 失败 —— 首发 warmup 未完成 / daemon 未就绪 / 运行时状态异常"
    printf '%s\n' "${output}" | sed 's/^/    /' >&2
    warn "  解法：在 WeChat 任意聊天 GUI 里【手动】发一条消息（warmup send pipeline），"
    warn "  然后再跑：${INSTALL_DIR}/wechat send 'hi' filehelper"
  fi
}

wechat_app_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

wechat_app_bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

wechat_app_build() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null
}

supported_419_source() {
  local app="$1" build
  [[ "$(wechat_app_version "$app" || true)" == "4.1.9" ]] || return 1
  build=$(wechat_app_build "$app" || true)
  [[ "$build" == "268596" || "$build" == "268602" ]]
}

usable_419_source() {
  supported_419_source "$1" || return 1
  local inherit
  inherit=$(codesign -d --entitlements :- "$1/Contents/MacOS/WeChatAppEx.app" 2>/dev/null \
    | plutil -extract 'com\.apple\.security\.inherit' raw -o - - 2>/dev/null || true)
  [[ "$inherit" == true ]]
}

find_preferred_wechat_source() {
  local candidate
  if [[ -n "$PREFERRED_WECHAT_SOURCE" ]]; then
    usable_419_source "$PREFERRED_WECHAT_SOURCE" || {
      err "指定源不是可用的微信 4.1.9，或子模块签名已被修改：$PREFERRED_WECHAT_SOURCE"
      return 1
    }
    printf '%s\n' "$PREFERRED_WECHAT_SOURCE"
    return 0
  fi
  for candidate in /Applications/WeChat-4.1.9.app "$HOME/Applications/WeChat-4.1.9.app" /Applications/WeChat.app; do
    if usable_419_source "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

choose_preferred_wechat_419() {
  local choice="${WECHAT_USE_PREFER_419:-ask}"
  if [[ "$choice" == ask ]] && previous_clone_choice_is_valid; then
    info "复用已确认的独立副本：$PREFERRED_WECHAT_NAME"
    return 0
  fi
  printf '\n微信 4.1.9 独立副本\n'
  printf '  wechat-use 专注兼容微信 4.1.9，功能支持最全、使用体验最好。\n'
  printf '  同意后自动安装独立副本，工具默认使用它；主微信程序和聊天数据保持原样。\n'
  printf '  副本需要单独登录，自动更新会关闭，以保持 4.1.9。\n\n'
  if [[ "$choice" == ask ]]; then
    if open_install_tty; then
      printf '[install] 安装并使用微信 4.1.9 独立副本？[Y/n] ' >&3
      IFS= read -r choice <&3 || choice=skip
      exec 3>&-
      [[ -n "$choice" ]] || choice=yes
    else
      err '非交互安装请设置 WECHAT_USE_PREFER_419=yes；未获得选择，安装未开始。'
      return 2
    fi
  fi
  case "$choice" in
    y|Y|yes|YES|Yes|1|true|TRUE|是|要) return 0 ;;
    n|N|no|NO|No|0|false|FALSE|否|不要|skip)
      info '已取消安装。主微信保持原样。'
      return 2 ;;
    *) err "无法识别选择：$choice"; return 2 ;;
  esac
}

previous_clone_choice_is_valid() {
  local config="${1:-$HOME/.wx-rs/managed-wechat.json}" target
  [[ -d "$PREFERRED_WECHAT_TARGET" && -f "$config" ]] || return 1
  supported_419_source "$PREFERRED_WECHAT_TARGET" || return 1
  [[ "$(wechat_app_bundle_id "$PREFERRED_WECHAT_TARGET")" == "$PREFERRED_WECHAT_BUNDLE_ID" ]] || return 1
  target=$(cd "$PREFERRED_WECHAT_TARGET" && pwd -P) || return 1
  [[ "$(plutil -extract app_path raw -o - "$config" 2>/dev/null)" == "$target" &&
     "$(plutil -extract bundle_id raw -o - "$config" 2>/dev/null)" == "$PREFERRED_WECHAT_BUNDLE_ID" &&
     "$(plutil -extract version raw -o - "$config" 2>/dev/null)" == 4.1.9 &&
     "$(plutil -extract build raw -o - "$config" 2>/dev/null)" == "$(wechat_app_build "$target")" ]]
}

cleanup_install_stage() {
  if [[ -n "${WECHAT_419_MOUNT:-}" ]]; then
    hdiutil detach "$WECHAT_419_MOUNT" -quiet 2>/dev/null || true
  fi
  if [[ -n "${STAGE:-}" && -d "$STAGE" ]]; then
    rm -rf -- "$STAGE"
  fi
}

download_preferred_wechat_source() {
  local dmg="$STAGE/WeChatMac_4.1.9.dmg" actual url verified=0
  info '从微信官方下载 4.1.9（约 466 MB）…' >&2
  # Both sources must provide the exact frozen vendor build. A mutable manifest
  # must never replace this pinned checksum during installation.
  for url in "$WECHAT_419_DMG_URL" "$WECHAT_419_DMG_BACKUP_URL"; do
    if [[ "$url" == "$WECHAT_419_DMG_BACKUP_URL" ]]; then
      warn '官方下载失败或校验不符，自动尝试 4.1.9 备份源…'
    fi
    if curl --fail --location --show-error --connect-timeout 20 --max-time 900 \
      --speed-limit 1024 --speed-time 30 --proto '=https' --proto-redir '=https' \
      "$url" -o "$dmg"; then
      actual=$(shasum -a 256 "$dmg" | awk '{print $1}') || actual=""
      if [[ "$actual" == "$WECHAT_419_DMG_SHA256" ]]; then
        verified=1
        break
      fi
    fi
  done
  [[ "$verified" == 1 ]] || {
    err '官方源和备份源均未提供通过校验的 4.1.9 安装包，已停止安装。请稍后重跑同一安装命令。'
    return 1
  }
  WECHAT_419_MOUNT="$STAGE/wechat-419-dmg"
  hdiutil attach -readonly -nobrowse -quiet -mountpoint "$WECHAT_419_MOUNT" "$dmg" || return 1
  PREFERRED_WECHAT_SOURCE="$WECHAT_419_MOUNT/WeChat.app"
  usable_419_source "$PREFERRED_WECHAT_SOURCE" || return 1
  codesign --verify --deep --strict "$PREFERRED_WECHAT_SOURCE" || return 1
  local signature
  signature=$(codesign -dvv "$PREFERRED_WECHAT_SOURCE" 2>&1) || return 1
  [[ "$signature" == *"TeamIdentifier=5A4RE8SF68"* ]] || {
    err '安装包不是预期的腾讯签名，已停止安装。'
    return 1
  }
}

preferred_branding_is_current() {
  local app="$1" plist="$1/Contents/Info.plist" strings key filesystem_name
  filesystem_name=$(basename "${PREFERRED_WECHAT_TARGET%/}" .app)
  for key in CFBundleName CFBundleDisplayName; do
    [[ "$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)" == "$filesystem_name" ]] || return 1
    for strings in "$app"/Contents/Resources/*.lproj/InfoPlist.strings; do
      [[ -f "$strings" ]] || continue
      [[ ! -L "$strings" && ! -L "${strings%/*}" ]] || return 1
      [[ "$(plutil -extract "$key" raw -o - "$strings" 2>/dev/null || true)" == "$PREFERRED_WECHAT_NAME" ]] || return 1
    done
  done
  [[ "$(plutil -extract CFBundleIconFile raw -o - "$plist" 2>/dev/null || true)" == WeChatTool419 ]] || return 1
  ! plutil -extract CFBundleIconName raw -o - "$plist" >/dev/null 2>&1 || return 1
  [[ "$(shasum -a 256 "$app/Contents/Resources/WeChatTool419.icns" 2>/dev/null | awk '{print $1}')" == "$WECHAT_419_ICON_SHA256" ]]
}

swap_branding_bundle() {
  # macOS renamex_np(RENAME_SWAP=2) atomically exchanges two non-empty
  # directories. Stock Ruby/Fiddle calls libc; no SDK compilation is needed.
  env -u RUBYOPT -u RUBYLIB /usr/bin/ruby --disable-gems -rfiddle -e '
    swap = Fiddle::Function.new(Fiddle::Handle::DEFAULT["renamex_np"],
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    raise SystemCallError.new("renamex_np", Fiddle.last_error) unless swap.call(ARGV[0], ARGV[1], 2).zero?
  ' "$1" "$2"
}

refresh_branding_registration() {
  touch "$1"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$1" >/dev/null 2>&1 || true
}

brand_preferred_wechat_419() (
  local app="$PREFERRED_WECHAT_TARGET" work='' swapped=0 staged plist strings key item backup original_inode original_info filesystem_name
  [[ -d "$app" && ! -L "$app" ]] || { err '副本路径无效或是符号链接，未修改'; return 1; }
  app=$(cd "$app" && pwd -P) || return 1
  case "$app" in /Applications/WeChat.app|/Applications/WeChat.app/*) err '不能修改主微信'; return 1 ;; esac
  supported_419_source "$app" &&
    [[ "$(wechat_app_bundle_id "$app")" == "$PREFERRED_WECHAT_BUNDLE_ID" ]] || { err '只能修改工具专用的 4.1.9 副本'; return 1; }
  [[ ! -L "$app/Contents" && ! -L "$app/Contents/Info.plist" && ! -L "$app/Contents/Resources" ]] || return 1
  codesign --verify --deep --strict "$app" || return 1
  if preferred_branding_is_current "$app"; then return 0; fi
  original_inode=$(stat -f %i "$app") || return 1
  original_info=$(shasum -a 256 "$app/Contents/Info.plist" | awk '{print $1}') || return 1
  [[ -x /usr/bin/ruby ]] || { err '缺少 macOS Ruby，无法安全交换副本，未修改'; return 1; }
  work=$(mktemp -d "${app%/*}/.wechat-branding.XXXXXX") || return 1
  trap 'if [[ "$swapped" == 0 && -n "$work" && -d "$work" ]] && ! preferred_branding_is_current "$app"; then rm -rf -- "$work"; fi' EXIT
  # Download and pin the complete icon before writing any app content.
  curl --fail --location --silent --show-error --connect-timeout 20 --max-time 120 \
    --proto '=https' --proto-redir '=https' "$WECHAT_419_ICON_URL" -o "$work/icon.icns" || return 1
  [[ "$(shasum -a 256 "$work/icon.icns" | awk '{print $1}')" == "$WECHAT_419_ICON_SHA256" ]] || { err '工具图标校验不符，原副本未修改'; return 1; }
  codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null || return 1
  plutil -lint "$work/entitlements.plist" >/dev/null || return 1
  [[ "$(plutil -extract 'com\.apple\.security\.get-task-allow' raw -o - "$work/entitlements.plist")" == true ]] || return 1
  staged="$work/WeChat.app"
  cp -cR "$app" "$staged" 2>/dev/null || cp -R "$app" "$staged" || return 1
  [[ "$(stat -f %i "$app/Contents/MacOS/WeChat")" != "$(stat -f %i "$staged/Contents/MacOS/WeChat")" ]] || return 1
  plist="$staged/Contents/Info.plist"
  filesystem_name=$(basename "$app" .app)
  for key in CFBundleName CFBundleDisplayName; do
    # Finder only applies InfoPlist.strings names when the unlocalized name
    # matches the app's filename. Keep the stable ASCII path for tool routing.
    plutil -replace "$key" -string "$filesystem_name" "$plist" || return 1
    for strings in "$staged"/Contents/Resources/*.lproj/InfoPlist.strings; do
      [[ -f "$strings" ]] || continue
      [[ ! -L "$strings" && ! -L "${strings%/*}" ]] || return 1
      # Vendor .strings may use OpenStep text; plutil cannot rewrite that
      # format directly. CFBundle also accepts lossless binary-plist strings.
      plutil -convert binary1 "$strings" || return 1
      plutil -replace "$key" -string "$PREFERRED_WECHAT_NAME" "$strings" || return 1
    done
  done
  [[ ! -L "$staged/Contents/Resources/WeChatTool419.icns" ]] || return 1
  cp "$work/icon.icns" "$staged/Contents/Resources/WeChatTool419.icns" || return 1
  plutil -replace CFBundleIconFile -string WeChatTool419 "$plist" || return 1
  plutil -remove CFBundleIconName "$plist" 2>/dev/null || true
  # Preserve the clone's complete sandbox / app groups / debugger entitlements,
  # and keep every Tencent-signed nested component byte-for-byte unchanged.
  codesign --force --sign - --entitlements "$work/entitlements.plist" "$staged" || return 1
  codesign --verify --deep --strict "$staged" || return 1
  codesign -d --entitlements :- "$staged" > "$work/verified-entitlements.plist" 2>/dev/null || return 1
  plutil -convert xml1 "$work/entitlements.plist" "$work/verified-entitlements.plist" || return 1
  cmp -s "$work/entitlements.plist" "$work/verified-entitlements.plist" || { err '副本权限发生变化，未替换'; return 1; }
  for item in Contents/Resources/wechat.dylib Contents/Frameworks/wechat.dylib; do
    [[ ! -f "$app/$item" ]] || cmp -s "$app/$item" "$staged/$item" || return 1
  done
  preferred_branding_is_current "$staged" || return 1
  [[ "$(stat -f %i "$app")" == "$original_inode" &&
    "$(shasum -a 256 "$app/Contents/Info.plist" | awk '{print $1}')" == "$original_info" ]] || { err '副本在准备期间发生变化，未替换'; return 1; }
  swap_branding_bundle "$app" "$staged" || return 1
  swapped=1
  # Keep the old inode tree for the still-running app and for recovery. The
  # non-.app suffix prevents accidentally launching a duplicate bundle id.
  backup="$staged"
  if mv "$staged" "$work/Previous.app.previous"; then backup="$work/Previous.app.previous"; fi
  refresh_branding_registration "$app"
  success "副本名称和图标已更新：$PREFERRED_WECHAT_NAME"
  info "已保留旧副本：${backup}；没有重启微信或修改登录数据。"
  info '正在运行的 Dock 图标可能在副本下次启动时刷新。'
)

maybe_brand_preferred_wechat_419() {
  if ! brand_preferred_wechat_419; then
    warn '副本名称或图标暂未更新，不影响独立微信功能；稍后重跑同一安装命令即可重试。'
  fi
}

maybe_offer_preferred_wechat_419() {
  local managed_cli="${MANAGED_SETUP_CLI:-$INSTALL_DIR/wechat}"
  # User consent was collected before any installation or service changes.
  if [[ -e "$PREFERRED_WECHAT_TARGET" || -L "$PREFERRED_WECHAT_TARGET" ]]; then
    supported_419_source "$PREFERRED_WECHAT_TARGET" &&
      [[ "$(wechat_app_bundle_id "$PREFERRED_WECHAT_TARGET" || true)" == "$PREFERRED_WECHAT_BUNDLE_ID" ]] || {
        err "目标路径已被其他 app 占用，请保留或移走它后重试：$PREFERRED_WECHAT_TARGET"
        return 1
      }
    maybe_brand_preferred_wechat_419
    "$managed_cli" clone use "$PREFERRED_WECHAT_TARGET" || return 1
  else
    if ! PREFERRED_WECHAT_SOURCE=$(find_preferred_wechat_source); then
      [[ -z "${WECHAT_419_SOURCE:-}" ]] || return 1
      download_preferred_wechat_source || return 1
    fi
    info "从 $PREFERRED_WECHAT_SOURCE 创建独立副本…"
    "$managed_cli" clone install \
      --source "$PREFERRED_WECHAT_SOURCE" --target "$PREFERRED_WECHAT_TARGET" \
      --name "$PREFERRED_WECHAT_NAME" --bundle-id "$PREFERRED_WECHAT_BUNDLE_ID" \
      --make-default || return 1
    maybe_brand_preferred_wechat_419
  fi
  "$managed_cli" update-guard disable || return 1
  defaults write "$PREFERRED_WECHAT_BUNDLE_ID" SUEnableAutomaticChecks -bool false
  defaults write "$PREFERRED_WECHAT_BUNDLE_ID" SUAutomaticallyUpdate -bool false
  export WECHAT_TARGET_BUNDLE_ID="$PREFERRED_WECHAT_BUNDLE_ID"
  unset WECHAT_TARGET_PID WECHAT_TARGET_WXID
  success "工具已默认使用微信 4.1.9 独立副本：$PREFERRED_WECHAT_TARGET"
}

prepare_preferred_wechat_419() {
  MANAGED_SETUP_CLI="$STAGE/wechat"
  if ! maybe_offer_preferred_wechat_419; then
    unset MANAGED_SETUP_CLI
    err '独立微信准备失败，安装未完成；现有 CLI 和后台服务尚未替换。'
    err '请按上方错误修复后重跑同一安装命令；网络下载失败可直接重试。'
    return 1
  fi
  unset MANAGED_SETUP_CLI
}

# Test harnesses source this file to exercise the 4.1.9 decision flow without
# downloading binaries or touching LaunchAgents. Normal installs never set it.
install_destination_command() {
  local directory="$1"
  shift
  if [[ -w "$directory" ]]; then "$@"; else sudo "$@"; fi
}

install_binary_atomically() {
  local source="$1" destination="$2" candidate
  candidate=$(install_destination_command "${destination%/*}" mktemp "${destination%/*}/.${destination##*/}.install.XXXXXX") || return 1
  # A running signed Mach-O must keep its original inode and bytes until
  # graceful shutdown; overwriting it in place triggers macOS SIGKILL.
  if install_destination_command "${destination%/*}" install -m 755 "$source" "$candidate" &&
      install_destination_command "${destination%/*}" mv -f "$candidate" "$destination"; then
    return 0
  fi
  install_destination_command "${destination%/*}" rm -f -- "$candidate"
  return 1
}

installed_binary_matches_staged() {
  [[ -f "$2" && -x "$2" && ! -L "$2" ]] && cmp -s "$1" "$2"
}

installer_json_value() {
  printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

installer_check_ok() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    report = json.load(sys.stdin)
    checks = [c for c in report["checks"] if c.get("name") == sys.argv[1]]
    valid = len(checks) == 1 and checks[0].get("ok") is True
except (ValueError, KeyError, TypeError, AttributeError):
    valid = False
sys.exit(0 if valid else 1)
' "$2" 2>/dev/null
}

wechatd_ax_trusted() {
  local report
  report=$("$INSTALL_DIR/wechat" doctor --json 2>/dev/null) || return 1
  installer_check_ok "$report" daemon_accessibility
}

can_reuse_running_services() {
  [[ "${BINARIES_CHANGED:-1}" == 0 && "${CLONE_SELECTION_UNCHANGED:-0}" == 1 ]] || return 1
  local plist="${LAUNCHAGENT_PLIST:-$HOME/Library/LaunchAgents/ai.wechat.bridge.plist}" registered health bridge_pid daemon_pid
  [[ -f "$plist" ]] || return 1
  [[ "$(plutil -extract ProgramArguments.0 raw -o - "$plist" 2>/dev/null)" == "$INSTALL_DIR/wechat-bridge" ]] || return 1
  registered=$(launchctl print "gui/$(id -u)/ai.wechat.bridge" 2>/dev/null) || return 1
  [[ "$(printf '%s\n' "$registered" | awk -F ' = ' '/^[[:space:]]*program = / {print $2; exit}')" == "$INSTALL_DIR/wechat-bridge" ]] || return 1
  bridge_pid=$(printf '%s\n' "$registered" | awk '/^[[:space:]]*pid = / {print $3; exit}')
  [[ "$bridge_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  health=$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:18400/health) || return 1
  [[ "$(installer_json_value "$health" bridge_version)" == "${LATEST_TAG#v}" &&
     "$(installer_json_value "$health" daemon.version)" == "${LATEST_TAG#v}" &&
     "$(installer_json_value "$health" daemon.alive)" == true ]] || return 1
  daemon_pid=$(installer_json_value "$health" daemon.pid) || return 1
  [[ "$daemon_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$(ps -p "$bridge_pid" -o comm= 2>/dev/null)" == "$INSTALL_DIR/wechat-bridge" &&
     "$(ps -p "$daemon_pid" -o comm= 2>/dev/null)" == "$INSTALL_DIR/wechatd" &&
     "$(ps -p "$daemon_pid" -o ppid= 2>/dev/null | tr -d ' ')" == "$bridge_pid" ]] || return 1
  wechatd_ax_trusted || return 1
  # A doctor probe must not have switched/restarted the daemon behind the
  # parent/path checks above (e.g. a simultaneous repair in another terminal).
  health=$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:18400/health) || return 1
  [[ "$(installer_json_value "$health" daemon.pid)" == "$daemon_pid" &&
     "$(installer_json_value "$health" daemon.alive)" == true ]]
}

run_service_phase() {
  if can_reuse_running_services; then
    SERVICES_REUSED=1
    success '版本文件未变，已验证的后台服务保持运行，无需重启。'
  else
    SERVICES_REUSED=0
    reset_wechat_services
  fi
}

install_launchagent_dir() {
  printf '%s/Library/LaunchAgents\n' "$HOME"
}

installer_subscription_state() {
  local status
  if ! status=$("$INSTALL_DIR/wechat" auth status 2>/dev/null); then printf 'unknown\n'; return; fi
  # auth status exits zero even when missing/expired; require explicit text.
  case "$status" in
    *'✓ 有效'*) printf 'active\n' ;;
    *'尚未激活'*) printf 'missing\n' ;;
    *'已过期'*|*'已吊销'*) printf 'inactive\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

print_install_next_steps() {
  local report="$1" subscription="$2" bridge_ok="$3" pending=0 doctor_shown=0
  printf '\n安装结果\n  副本：%s\n  路径：%s\n' "$PREFERRED_WECHAT_NAME" "$PREFERRED_WECHAT_TARGET"
  if [[ "$subscription" == active && "$bridge_ok" == 1 &&
        "$(installer_json_value "$report" status)" == ok &&
        "$(installer_json_value "$report" query_ready)" == true &&
        "$(installer_json_value "$report" send_ready)" == true ]] &&
      installer_check_ok "$report" wechat_running &&
      installer_check_ok "$report" daemon_accessibility &&
      installer_check_ok "$report" config_present &&
      installer_check_ok "$report" key_file_present; then
    success '已就绪，无需重新激活、授权或初始化。'
    info '查看会话：wechat-use sessions；诊断问题：wechat-use doctor'
    return 0
  fi
  info '工具已安装，尚未完成的步骤如下：'
  case "$subscription" in
    missing) step '激活：wechat-use auth activate <激活码>'; info '申请激活码：https://t.me/WechatCliBot'; pending=1 ;;
    inactive) step '续订：wechat-use auth renew（无需重新激活）'; pending=1 ;;
    active) : ;;
    *) step '确认订阅状态：wechat-use auth status'; pending=1 ;;
  esac
  if ! installer_json_value "$report" status >/dev/null; then
    step '未能读取体检结果，请运行：wechat-use doctor'
    return 0
  fi
  if ! installer_check_ok "$report" wechat_running; then
    step "打开「${PREFERRED_WECHAT_NAME}」，按提示完成登录。主微信无需退出。"
    pending=1
  fi
  if ! installer_check_ok "$report" daemon_accessibility; then
    step '辅助功能授权：wechat-use doctor --fix-tcc'
    info "只需检查 $INSTALL_DIR/wechat-bridge 和 $INSTALL_DIR/wechatd，不要重置其他应用权限。"
    pending=1
  elif [[ "$bridge_ok" != 1 ]]; then
    step '后台服务尚未就绪，请运行：wechat-use doctor'
    pending=1; doctor_shown=1
  fi
  if ! installer_check_ok "$report" config_present || ! installer_check_ok "$report" key_file_present; then
    step '副本登录后初始化：wechat-use init'
    pending=1
  elif [[ "$(installer_json_value "$report" query_ready)" != true ]]; then
    if [[ "$doctor_shown" == 0 ]]; then step '检查读取配置：wechat-use doctor'; fi
    pending=1
  elif [[ "$(installer_json_value "$report" send_ready)" != true ]]; then
    step '登录并打开任意聊天后验证：wechat-use send "安装验证" filehelper'
    pending=1
  fi
  if [[ "$pending" == 0 ]]; then step '检查剩余问题：wechat-use doctor'; fi
}

open_install_tty() {
  { exec 3<>/dev/tty; } 2>/dev/null
}

read_optional_install_choice() {
  if open_install_tty; then
    printf '[install] 安装 AI agent skill？[y/N]（30 秒内未选择则跳过） ' >&3
    local answer=''
    IFS= read -r -t 30 answer <&3 || answer=no
    exec 3>&-
    printf '%s\n' "$answer"
  else
    return 1
  fi
}

offer_agent_skill_install() {
  local choice="${WECHAT_USE_INSTALL_SKILL:-ask}"
  local skill_file="$HOME/.agents/skills/wechat-use/SKILL.md"
  if [[ "$choice" == ask && -f "$skill_file" ]]; then
    info '已检测到 wechat-use skill；更新命令：npx -y skills add leeguooooo/wechat-use -y -g'
    return 0
  fi
  if ! command -v npx >/dev/null 2>&1; then
    info '可选：安装 Node.js 后，用 npx -y skills add leeguooooo/wechat-use -y -g 接入 AI agent。'
    return 0
  fi
  if [[ "$choice" == ask ]]; then
    # Check the caller's terminal before command substitution redirects stdout.
    if [[ -t 1 ]]; then choice=$(read_optional_install_choice) || choice=no
    else choice=no; fi
  fi
  case "$choice" in
    y|Y|yes|YES|Yes|1|true|是)
      install_agent_skill ;;
    *) info '未安装可选 skill。需要时运行：npx -y skills add leeguooooo/wechat-use -y -g' ;;
  esac
}

install_agent_skill() {
  local output status=0
  output=$(npx -y skills add leeguooooo/wechat-use -y -g 2>&1) || status=$?
  printf '%s\n' "$output"
  # skills can exit 0 after a partial installation (for example, an agent
  # without global-install support). Preserve its detail instead of claiming
  # every selected agent succeeded.
  if [[ "$status" != 0 ]]; then
    warn 'skill 未安装成功，不影响 CLI；可稍后重试。'
  elif printf '%s\n' "$output" | grep -q 'Failed to install'; then
    warn 'skill 仅部分安装成功；请查看上方失败的 agent，不影响已成功安装的部分和 CLI。'
  else
    success 'wechat-use skill 已安装。'
  fi
}

# Installation stays in the background. macOS permission grants require the
# user's interaction, so expose the explicit recovery command without opening UI.
remediate_tcc_grant() {
  warn "Accessibility 权限未授权；安装已完成，发送功能需先授权。"
  info "在方便时运行：${INSTALL_DIR}/wechat doctor --fix-tcc（会打开系统设置）"
  info "需要授权的程序：${INSTALL_DIR}/wechatd 和 ${INSTALL_DIR}/wechat-bridge"
}

if [[ "${WECHAT_USE_INSTALL_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "macOS only"
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  err "Apple Silicon only"
  exit 1
fi

step '1/4 确认独立微信副本'
choose_preferred_wechat_419 || exit $?
mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
STAGE=$(mktemp -d)
trap cleanup_install_stage EXIT

# Resolve the latest release tag so we can fetch a versioned tarball +
# SHA256SUMS. Using /releases/latest/download/<file> would save one API
# round-trip, but following the redirect to a specific tag lets us
# print the version up front and also cleanly handles the case where
# the tarball name is version-suffixed.
step '2/4 检查并下载工具版本'
if ! LATEST_TAG=$(curl -fsSLI --connect-timeout 20 --max-time 60 -o /dev/null -w '%{url_effective}' \
  "https://github.com/${REPO}/releases/latest" 2>/dev/null \
  | sed -E 's#.*/tag/##'); then
  err '无法连接版本服务器，现有安装未修改；请稍后重试。'
  exit 1
fi
if [[ ! "$LATEST_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  err '未取得有效版本号，现有安装未修改；请稍后重试。'
  exit 1
fi
info "最新版本：${LATEST_TAG}"

TARBALL="wechat-${LATEST_TAG}-darwin-arm64.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}"
info "下载 ${TARBALL}"
if ! curl -fsSL --retry 2 --connect-timeout 20 --max-time 300 "${BASE_URL}/${TARBALL}" -o "${STAGE}/${TARBALL}"; then
  err "无法下载 ${TARBALL}，release 可能缺少此文件。"
  exit 1
fi
info "下载 SHA256SUMS"
if ! curl -fsSL --retry 2 --connect-timeout 20 --max-time 60 "${BASE_URL}/SHA256SUMS" -o "${STAGE}/SHA256SUMS.release"; then
  err "无法下载 SHA256SUMS，release 可能缺少此文件。"
  exit 1
fi

# Verify tarball integrity against the published SHA256SUMS. The
# published file lists per-binary hashes (wechat / wechatd), not the
# tarball, so we compute + check here explicitly before extracting.
info "校验 tarball SHA-256"
(
  cd "${STAGE}"
  tar xzf "${TARBALL}"
  # SHA256SUMS lives inside the tarball too — prefer that (maintainer
  # hashes) and cross-check against the separately-uploaded copy so a
  # tampered tarball can't ship mismatched hashes.
  if [[ ! -f SHA256SUMS ]]; then
    err "tarball 内缺少 SHA256SUMS，拒绝继续。"
    exit 1
  fi
  if ! cmp -s SHA256SUMS SHA256SUMS.release; then
    err "tarball 内 SHA256SUMS 与 release 附件不一致，拒绝继续。"
    exit 1
  fi
  if ! shasum -a 256 -c SHA256SUMS >/dev/null; then
    err "二进制 SHA-256 校验失败，拒绝继续。"
    exit 1
  fi
)
success "SHA-256 校验通过"

# Prepare the required clone using verified staged binaries BEFORE replacing
# any installed CLI or touching its LaunchAgents. Failures stay recoverable.
for BIN_NAME in "${BINS[@]}"; do
  [[ -s "$STAGE/$BIN_NAME" && -f "$STAGE/$BIN_NAME" && ! -L "$STAGE/$BIN_NAME" ]] || {
    err "安装包缺少有效的 $BIN_NAME，原安装未修改。"; exit 1;
  }
done
step '3/4 准备工具专用微信（主微信保持原样）'
CLONE_SELECTION_UNCHANGED=0
if previous_clone_choice_is_valid; then CLONE_SELECTION_UNCHANGED=1; fi
prepare_preferred_wechat_419 || exit 1

BINARIES_CHANGED=0
for BIN_NAME in "${BINS[@]}"; do
  SRC="${STAGE}/${BIN_NAME}"
  if [[ ! -s "${SRC}" ]]; then
    err "tarball 里缺少 ${BIN_NAME}"
    exit 1
  fi
  # Rotate .prev / .prev2 before overwrite. Two-generation rotation:
  #   .prev2 (oldest) ← .prev ← current → (overwritten by new)
  # Why two: customers who hit a bad release sometimes need to roll back
  # past the immediately-previous version (e.g. 1.12.1 broke them, 1.12.0
  # also broke them, want to go back to 1.10.38). One-generation rotation
  # silently dropped the older binary on each install, surprising users
  # who expected `.prev` to mean "the version before THIS one and that's
  # it". Now `.prev` is N-1, `.prev2` is N-2.
  DEST="${INSTALL_DIR}/${BIN_NAME}"
  if installed_binary_matches_staged "$SRC" "$DEST"; then
    info "$BIN_NAME 文件未变，保留现有文件和回滚备份。"
    continue
  fi
  BINARIES_CHANGED=1
  # v1.16.0+: prior install may have left wechatd / wechat-bridge as a
  # symlink to ~/Applications/WechatSkillHelper.app/Contents/MacOS/<bin>.
  # `install -m 755` over a symlink is system-dependent — pre-emptively
  # unlink so we always lay down a fresh regular file. Bundle setup
  # below re-establishes the symlink.
  if [[ -L "${DEST}" ]]; then
    rm -f "${DEST}"
  fi
  if [[ -f "${DEST}" ]]; then
    if [[ -w "${INSTALL_DIR}" ]]; then
      [[ -f "${DEST}.prev" ]] && mv -f "${DEST}.prev" "${DEST}.prev2"
      cp -p "${DEST}" "${DEST}.prev"
    else
      [[ -f "${DEST}.prev" ]] && sudo mv -f "${DEST}.prev" "${DEST}.prev2"
      sudo cp -p "${DEST}" "${DEST}.prev"
    fi
  fi
  install_binary_atomically "$SRC" "$DEST" || { err "安装 $BIN_NAME 失败，原文件保持不变"; exit 1; }

  # Ad-hoc signed binary — 去掉 quarantine 避免 Gatekeeper 弹窗
  if [[ -w "${INSTALL_DIR}/${BIN_NAME}" ]]; then
    xattr -d com.apple.quarantine "${INSTALL_DIR}/${BIN_NAME}" 2>/dev/null || true
  else
    sudo xattr -d com.apple.quarantine "${INSTALL_DIR}/${BIN_NAME}" 2>/dev/null || true
  fi

  # Ad-hoc codesign with a stable identifier. Without this, every
  # upgrade gets a new content hash → TCC (Accessibility /
  # Input Monitoring) sees it as a NEW binary → user has to re-grant.
  # With a stable --identifier, some macOS builds will recognize the
  # new binary as a continuation of the previous grant and skip the
  # re-auth prompt. Not guaranteed (Sonoma+ is strict), but measurably
  # better than nothing.
  #
  # CRITICAL: only sign if the existing signature isn't already ours.
  # Re-running `codesign --force` on a binary that ALREADY has our
  # stable identifier still rotates the CDHash, which on Sonoma+ is
  # often enough to invalidate the existing TCC grant. So we skip the
  # sign when the binary's already correctly signed (e.g. user re-ran
  # install.sh with no upgrade). Customer report v1.10.32: every reinstall
  # was kicking them out of Accessibility because of unconditional
  # `--force` re-signing.
  IDENTIFIER="ai.wechatskill.${BIN_NAME}"
  # Probe existing signature. `codesign -dv` exits non-zero on unsigned
  # binaries (most fresh installs); `set -euo pipefail` would propagate the
  # pipeline failure into the assignment and abort the installer. Wrap in
  # `if cmd; then ...; else ...; fi` so the failure is consumed explicitly.
  # `-dvvv` (vs `-dv`) also emits the `Authority=` chain to stderr so we can
  # tell a Developer ID signature apart from an ad-hoc one.
  CS_PROBE=$(mktemp "${TMPDIR:-/tmp}/wechat-install-cs-probe.XXXXXX")
  if codesign -dvvv "${INSTALL_DIR}/${BIN_NAME}" 2>"${CS_PROBE}"; then
    EXISTING_IDENT=$(awk -F'=' '/^Identifier=/ { print $2 }' "${CS_PROBE}" | tr -d '\r')
  else
    EXISTING_IDENT=""
  fi
  IS_DEVID=0
  if grep -q 'Authority=Developer ID Application' "${CS_PROBE}" 2>/dev/null; then
    IS_DEVID=1
  fi
  rm -f "${CS_PROBE}"

  if [[ "${IS_DEVID}" == "1" ]]; then
    # Release binaries are now Developer ID signed + notarized upstream. Re-
    # signing with an ad-hoc identity would DESTROY that signature and bring
    # back the per-upgrade CDHash churn that drops the Accessibility / Input
    # Monitoring grant. The whole point of Developer ID is that macOS keys the
    # TCC grant off the stable identity (team + identifier), so it survives
    # upgrades. Leave it exactly as shipped — do NOT touch it.
    info "${BIN_NAME} 已 Developer ID 签名（已公证），保留原签名 —— TCC 跨升级不用重勾"
  elif [[ "${EXISTING_IDENT}" == "${IDENTIFIER}" ]]; then
    # Already ad-hoc signed by us with the same identifier — leave alone, TCC
    # is presumably still in effect. (Legacy path for pre-Developer-ID releases.)
    info "${BIN_NAME} 已 ad-hoc 签名 (${IDENTIFIER})，跳过 re-sign 保留 TCC 授权"
  else
    CODESIGN_ERR=$(mktemp "${TMPDIR:-/tmp}/wechat-install-codesign.XXXXXX")
    # `set -e` would abort the installer on non-zero codesign before we ever
    # reach the warn branch. Use `if codesign; then ...; else ...; fi` so the
    # failure is observed and surfaced rather than killing the run.
    if [[ -w "${INSTALL_DIR}/${BIN_NAME}" ]]; then
      CODESIGN_CMD=(codesign --force --sign - --identifier "${IDENTIFIER}" "${INSTALL_DIR}/${BIN_NAME}")
    else
      CODESIGN_CMD=(sudo codesign --force --sign - --identifier "${IDENTIFIER}" "${INSTALL_DIR}/${BIN_NAME}")
    fi
    if "${CODESIGN_CMD[@]}" 2>"${CODESIGN_ERR}"; then
      # Verify signature was actually applied — catches "silent"
      # codesign no-ops where exit 0 but sig wasn't written.
      if ! codesign --verify "${INSTALL_DIR}/${BIN_NAME}" 2>>"${CODESIGN_ERR}"; then
        warn "codesign --verify ${BIN_NAME} 不通过 —— 签名可能没真正落到 binary 上"
        sed 's/^/    /' "${CODESIGN_ERR}" >&2
      fi
    else
      warn "codesign 对 ${BIN_NAME} 失败："
      sed 's/^/    /' "${CODESIGN_ERR}" >&2
      warn "  binary 已安装但未签名；Accessibility TCC 可能每次升级都要重新勾"
    fi
    rm -f "${CODESIGN_ERR}"
  fi

  success "已安装：${INSTALL_DIR}/${BIN_NAME}"
done
echo ""

# wechat-use 是新的主命令名（与 profile-use / iphone-use / chrome-use 同系列）。
# 实际二进制仍叫 `wechat`，这里建一个 `wechat-use` → `wechat` 软链，两个名字等价。
# 旧脚本 / 文档里的 `wechat ...` 继续可用，新文档统一用 `wechat-use ...`。
WECHAT_USE_LINK="${INSTALL_DIR}/wechat-use"
if [[ -L "$WECHAT_USE_LINK" && "$(readlink "$WECHAT_USE_LINK")" == wechat ]]; then
  info 'wechat-use 命令别名已就绪。'
elif [[ -w "${INSTALL_DIR}" ]]; then
  rm -f "${WECHAT_USE_LINK}"
  ln -s wechat "${WECHAT_USE_LINK}"
else
  sudo rm -f "${WECHAT_USE_LINK}"
  sudo ln -s wechat "${WECHAT_USE_LINK}"
fi
success "已建立别名:${WECHAT_USE_LINK} → wechat（wechat-use 与 wechat 等价）"
echo ""

# v1.16.4 REVERT: cleanup remnants of the v1.16.0–v1.16.3 .app bundle
# approach. The install loop already replaced ~/.local/bin/{wechatd,
# wechat-bridge} symlinks with regular files; here we (a) remove the
# now-orphaned .app dir, (b) revert LaunchAgent plist if it points
# inside the .app. Idempotent: safe to run on any install.
HELPER_APP_LEGACY="$HOME/Applications/WechatSkillHelper.app"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/ai.wechat.bridge.plist"
if [[ -d "${HELPER_APP_LEGACY}" ]]; then
  info "清理 v1.16.0~3 残留:删除 ${HELPER_APP_LEGACY}"
  rm -rf "${HELPER_APP_LEGACY}"
fi
if [[ -f "${LAUNCHAGENT_PLIST}" ]]; then
  CURRENT_PROG_PATH=$(plutil -extract ProgramArguments.0 raw -o - "${LAUNCHAGENT_PLIST}" 2>/dev/null || true)
  if [[ "${CURRENT_PROG_PATH}" == *"WechatSkillHelper.app"* ]]; then
    info "回滚 LaunchAgent ProgramArguments 到 ${INSTALL_DIR}/wechat-bridge"
    plutil -replace ProgramArguments.0 -string "${INSTALL_DIR}/wechat-bridge" "${LAUNCHAGENT_PLIST}"
  fi
fi

# v1.16.5+: clean up older `wechat` / `wechatd` / `wechat-bridge` /
# `wechat-wechaty-gateway` binaries that shadow the just-installed
# ${INSTALL_DIR}/* on PATH. Common offender: ~/.cargo/bin/wechat from
# the historical `cargo install` flow. Real customer (2026-05-08): had
# v1.14.4 in ~/.cargo/bin and v1.16.4 in ~/.local/bin → `wechat init`
# silently invoked the v1.14.4 binary missing the running-process
# attachability probe → confusing kr=5 error. We auto-remove shadow
# binaries iff they're (a) older or same version, (b) in a known-safe
# user-owned directory. /usr/local/bin and other system paths get a
# loud warning + explicit fix command instead (avoid sudo escalation
# during install).
NEW_VERSION_TAG="${VERSION:-${TAG:-}}"
NEW_VERSION_TAG="${NEW_VERSION_TAG#v}"
# Known shadow locations — directories where users historically install
# binaries that may shadow ${INSTALL_DIR}. We check these directly
# instead of relying on `command -v` because fish's universal PATH
# (fish_user_paths) doesn't always propagate to install.sh's bash
# subprocess via env, so command-v can falsely report "no shadow"
# even when fish's `which wechat` returns an older binary.
KNOWN_SHADOW_DIRS=("$HOME/.cargo/bin" "$HOME/bin")
for BIN in wechat wechatd wechat-bridge wechat-mcp wechat-wechaty-gateway; do
  EXPECTED="${INSTALL_DIR}/${BIN}"
  for SHADOW_DIR in "${KNOWN_SHADOW_DIRS[@]}"; do
    SHADOW="${SHADOW_DIR}/${BIN}"
    if [[ "${SHADOW}" == "${EXPECTED}" ]]; then continue; fi
    if [[ -e "${SHADOW}" || -L "${SHADOW}" ]]; then
      OTHER_VER=$("${SHADOW}" --version 2>/dev/null | awk '{print $NF}' || true)
      info "清理 PATH 旧 ${BIN}: ${SHADOW} (v${OTHER_VER:-?}) — 让 ${EXPECTED} (v${NEW_VERSION_TAG:-?}) 生效"
      rm -f "${SHADOW}"
    fi
  done
  # Then check command -v as a fallback for paths we don't know
  # about — warn-only, since deleting from /usr/local/bin etc. needs
  # sudo and might surprise users.
  RESOLVED=$(command -v -- "${BIN}" 2>/dev/null || true)
  if [[ -n "${RESOLVED}" && "${RESOLVED}" != "${EXPECTED}" ]]; then
    case "${RESOLVED}" in
      "${HOME}/.cargo/bin/"*|"${HOME}/bin/"*)
        : # already handled by the explicit-dir loop above
        ;;
      *)
        warn "PATH 上有另一个 ${BIN}: ${RESOLVED} — 会遮住新装的 ${EXPECTED}"
        printf '  手动清掉:%s\n' "$(cmd "rm -f ${RESOLVED}")"
        ;;
    esac
  fi
done

reset_wechat_services() {
# Reset all wechat LaunchAgents in one shot.
#
# 2026-05-18: 之前这里只处理 ai.wechat.bridge,但用户机上可能还存在
# ai.wechat.orchestrate (或未来其它 LaunchAgent),KeepAlive=true 会在
# 我们杀掉 wechatd 后立刻把它拉起来,带着 stale launchd responsibility
# chain。即使 TCC 里 wechatd 的 cdhash 已经 Allowed,macOS 按 responsible
# process 二次判定仍 false → AXIsProcessTrusted 永远 false,install.sh
# 卡在等 Accessibility 的轮询里。
#
# 修复:发现 ~/Library/LaunchAgents/ai.wechat.*.plist 全部 bootout →
# 杀干净所有进程 → 再 bootstrap 回来。新用户没 plist 是 no-op,老用户
# 有几个就处理几个。无论起点如何,终态都是「干净 chain 的 LaunchAgent」。
#
# Why not `launchctl kickstart -k`: kickstart 只重执行进程,不重读 plist
# 的 EnvironmentVariables,也不重置 launchd 缓存的 responsibility chain。
# bootout + bootstrap 是唯一彻底重置的方式。
LAUNCHAGENT_DIR=$(install_launchagent_dir)
LAUNCHAGENT_PLIST="${LAUNCHAGENT_DIR}/ai.wechat.bridge.plist"  # 兼容下文 health 探测
WECHAT_AGENT_PLISTS=()
if [[ -d "${LAUNCHAGENT_DIR}" ]]; then
  while IFS= read -r -d '' plist; do
    WECHAT_AGENT_PLISTS+=("${plist}")
  done < <(find "${LAUNCHAGENT_DIR}" -maxdepth 1 -name 'ai.wechat.*.plist' -print0 2>/dev/null)
fi

if (( ${#WECHAT_AGENT_PLISTS[@]} > 0 )); then
  info "卸载 ${#WECHAT_AGENT_PLISTS[@]} 个 wechat LaunchAgent（彻底重置 launchd responsibility chain，否则 TCC 授权按旧 chain 算永远 false）"
  for plist in "${WECHAT_AGENT_PLISTS[@]}"; do
    agent="$(basename "${plist}" .plist)"
    launchctl bootout "gui/$(id -u)/${agent}" 2>/dev/null || true
  done
else
  info "未发现 wechat LaunchAgent (首次安装),直接装"
fi

# 杀掉所有 wechat-* 进程。bootout 已经卸掉 KeepAlive,所以这次杀完不会
# 被自动拉起。包括之前手动起的、orchestrate 派生的、daemon 派生的全部。
# 用 INSTALL_DIR 前缀过滤,避免误杀 WeChat.app 本身。
for pat in \
  "${INSTALL_DIR}/wechatd" \
  "${INSTALL_DIR}/wechat-bridge" \
  "${INSTALL_DIR}/wechat-wechaty-gateway" \
  "${INSTALL_DIR}/wechat orchestrate" \
  "${INSTALL_DIR}/wechat listen"; do
  PIDS=$(pgrep -f "${pat}" 2>/dev/null || true)
  if [[ -n "${PIDS}" ]]; then
    info "停掉 ${pat##*/} (pid: ${PIDS})"
    echo "${PIDS}" | xargs kill 2>/dev/null || true
  fi
done
sleep 2
# Give debugger-owning daemons time to detach cleanly. Never SIGKILL them
# during migration: their attached WeChat process could be left suspended.
for pat in \
  "${INSTALL_DIR}/wechatd" \
  "${INSTALL_DIR}/wechat-bridge" \
  "${INSTALL_DIR}/wechat-wechaty-gateway" \
  "${INSTALL_DIR}/wechat orchestrate" \
  "${INSTALL_DIR}/wechat listen"; do
  PIDS=$(pgrep -f "${pat}" 2>/dev/null || true)
  if [[ -n "${PIDS}" ]]; then
    for stopped_pid in $PIDS; do
      for _ in {1..15}; do
        kill -0 "$stopped_pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$stopped_pid" 2>/dev/null; then
        err "旧服务仍在退出（pid=$stopped_pid），请稍后重试安装。"
        exit 1
      fi
    done
  fi
done
sleep 1

# Bootstrap 回来。
#
# 顺序关键!!! ai.wechat.bridge 必须**先**起,因为 ai.wechat.orchestrate
# RunAtLoad=true,bootstrap 后立刻派生 `wechat orchestrate run`,而该进程
# 自己会 spawn wechatd 子进程。如果 orchestrate 抢在 bridge lazy-start
# wechatd 之前,新 wechatd 的 launchd responsibility chain 就是
# orchestrate → wechat CLI → install.sh 这条 stale path,AXIsProcessTrusted
# 永远 false,install.sh 卡死在 wait Accessibility 循环。
#
# 修复:bridge 先 bootstrap + curl /health 强制 lazy-start wechatd(chain
# 干净:wechatd 父 = bridge,bridge 父 = launchd),wechatd 站稳之后再
# bootstrap 其它 plist。其它 LaunchAgent 起来时发现 wechatd socket
# `/tmp/wechatd-${UID}.sock` 已被 bridge 派生的 wechatd 占用,二次 spawn
# 必失败自杀 → 不污染 chain。
#
# 192.168.0.190 实测:不分顺序时 orchestrate 抢先 → wechatd chain 污染;
# 分顺序后 bridge 抢先 → wechatd ax_trusted=true 一遍过。
BRIDGE_PLIST_PATH="${LAUNCHAGENT_DIR}/ai.wechat.bridge.plist"

# v1.16.19+: 首次安装 / plist 被清空场景兜底写一份。历史上 install.sh
# 只 bootstrap 已存在的 plist,fresh 机器或 plist 被删干净的用户 install
# 完根本没 LaunchAgent — bridge 永远不开机自启,agent / Hermes / Cloudflare
# Tunnel 集成静默坏。daemon 通过 CLI lazy-spawn 自救,但 bridge 必须有
# launchd entry 才能 login 自启 + crash 自恢复。
mkdir -p "${LAUNCHAGENT_DIR}"
if [[ ! -f "${BRIDGE_PLIST_PATH}" ]]; then
  info "写 ai.wechat.bridge LaunchAgent plist (首次安装 / plist 被清空)"
  cat > "${BRIDGE_PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.wechat.bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/wechat-bridge</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
    <key>Crashed</key><true/>
  </dict>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>/tmp/wechat-bridge.log</string>
  <key>StandardErrorPath</key><string>/tmp/wechat-bridge.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>RUST_LOG</key><string>info</string>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${INSTALL_DIR}:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF
  plutil -lint "${BRIDGE_PLIST_PATH}" >/dev/null 2>&1 || warn "  写出的 plist 语法异常,跑 \`plutil -lint ${BRIDGE_PLIST_PATH}\` 看详情"
fi

if [[ -f "${BRIDGE_PLIST_PATH}" ]]; then
  info "先 bootstrap ai.wechat.bridge 抢 wechatd spawn 权 (避免其它 LaunchAgent 派生污染 chain)"
  launchctl bootstrap "gui/$(id -u)" "${BRIDGE_PLIST_PATH}" 2>/dev/null || true
  # Strong-trigger lazy-start: bridge 起来后 curl /health 让它 fork
  # wechatd。给 2s 让 wechatd 真正落地接管 sock,之后其它 plist 派生
  # 的 wechatd 才会发现 sock 被占而自杀。
  curl -fsS -m 3 http://127.0.0.1:18400/health >/dev/null 2>&1 || true
  sleep 2
fi

if (( ${#WECHAT_AGENT_PLISTS[@]} > 0 )); then
  # 然后 bootstrap 剩下的(orchestrate 等)。如果只有 bridge 一个 plist,
  # 这个循环啥也不做。
  REMAINING=0
  for plist in "${WECHAT_AGENT_PLISTS[@]}"; do
    agent="$(basename "${plist}" .plist)"
    [[ "${agent}" == "ai.wechat.bridge" ]] && continue
    REMAINING=$((REMAINING + 1))
    if ! launchctl bootstrap "gui/$(id -u)" "${plist}" 2>/dev/null; then
      warn "  bootstrap ${agent} 失败 — 这个 LaunchAgent 可能已经损坏,跑 \`launchctl print gui/$(id -u)/${agent}\` 看详情"
    fi
  done
  if (( REMAINING > 0 )); then
    info "bootstrap 完剩余 ${REMAINING} 个 LaunchAgent (bridge 已先起,wechatd 由 bridge 派生)"
  fi

  # Bridge /health 复验 (上面 curl 已经试过一次,这里如果还没成是真问题)。
  if [[ -f "${BRIDGE_PLIST_PATH}" ]]; then
    if wait_for_bridge_health; then
      RUNNING_PID=$(pgrep -f "${INSTALL_DIR}/wechat-bridge" 2>/dev/null | head -1)
      success "LaunchAgent 已接管 + /health 200 OK (pid=${RUNNING_PID:-?})"
    else
      dump_bridge_diag "LaunchAgent 启动后 wechat-bridge /health 15s 内无 200 响应"
      warn "  常见原因：Accessibility TCC 未授权 / 端口 18400 被占 / plist env 配置错"
      warn "  下面 TCC 检查会进一步确认；如果是端口冲突跑：lsof -nP -iTCP:18400 | grep LISTEN"
    fi
  fi
elif [[ ! -f "$BRIDGE_PLIST_PATH" ]] && launchctl list 2>/dev/null | grep -q ai.wechat.bridge; then
  info "LaunchAgent 注册但 plist 不在标准路径，用 kickstart 重启"
  launchctl kickstart -k "gui/$(id -u)/ai.wechat.bridge" 2>/dev/null || true
  if ! wait_for_bridge_health; then
    dump_bridge_diag "LaunchAgent kickstart 后 /health 仍无响应"
  fi
fi
}

step '4/4 检查后台服务与剩余设置'
run_service_phase


# TCC / health verification. Ground truth: /health 200 from the
# launchd-spawned bridge AND wechatd's AXIsProcessTrusted() == true.
#
# Note on wechat-wechaty-gateway: not AX-checked here. It's a gRPC
# Wechaty-protocol shim that forwards through wechatd/wechat-bridge —
# never synthesizes keyboard events itself. If that ever changes,
# add a wechaty_gateway_ax_trusted probe alongside.
#
# Four states:
#   bridge_healthy + wechatd_ax_trusted  → all green
#   bridge_healthy + wechatd UNtrusted   → upgrade-on-Sonoma+ TCC reset; remediate
#   bridge crash + log says tcc_missing  → bridge-layer TCC; remediate
#   bridge crash + no tcc log            → other crash cause (port / plist / sig)
if wait_for_bridge_health_retry; then
  if wechatd_ax_trusted; then
    success "Accessibility TCC: 已授权 ✓ (bridge /health 200 OK + wechatd ax_trusted)"
    warn_if_wechat_lacks_get_task_allow || true
    maybe_smoke_send
    echo ""
  else
    warn '后台接口可用，但未能确认 wechatd 的辅助功能授权，请继续检查。'
    remediate_tcc_grant
  fi
elif bridge_log_says_tcc_missing; then
  remediate_tcc_grant
else
  # /health failed but TCC isn't the cause — most likely port 18400
  # occupied or plist env wrong. Diag was already dumped right after
  # bootstrap; just point at the next step.
  warn '后台服务未就绪，日志未显示明确的辅助功能授权错误。请运行 wechat-use doctor 排查，不要反复重置授权。'
  echo ""
fi

# Print installed CLI version + the supported WeChat matrix so the user
# immediately knows what they got and what their WeChat needs to look like.
INSTALLED_VER="(unknown)"
if [[ -x "${INSTALL_DIR}/wechat" ]]; then
  INSTALLED_VER=$("${INSTALL_DIR}/wechat" --version 2>/dev/null | awk '{print $2}')
  [[ -z "${INSTALLED_VER}" ]] && INSTALLED_VER="(unknown)"
fi
INSTALLED_DAEMON_VER="(unknown)"
if [[ -x "${INSTALL_DIR}/wechatd" ]]; then
  INSTALLED_DAEMON_VER=$("${INSTALL_DIR}/wechatd" --version 2>/dev/null | awk '{print $2}')
  [[ -z "${INSTALLED_DAEMON_VER}" ]] && INSTALLED_DAEMON_VER="(unknown)"
fi

# Best-effort detect locally-installed WeChat version+build for the
# "do they match" headline.
DETECTED_WECHAT_VERSION=""
DETECTED_WECHAT_BUILD=""
if [[ -f "${PREFERRED_WECHAT_TARGET}/Contents/Info.plist" ]]; then
  DETECTED_WECHAT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${PREFERRED_WECHAT_TARGET}/Contents/Info.plist" 2>/dev/null || echo "")
  DETECTED_WECHAT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "${PREFERRED_WECHAT_TARGET}/Contents/Info.plist" 2>/dev/null || echo "")
fi
printf '\n版本：wechat %s / wechatd %s / 工具微信 %s（%s）\n' \
  "$INSTALLED_VER" "$INSTALLED_DAEMON_VER" "${DETECTED_WECHAT_VERSION:-未检测到}" "${DETECTED_WECHAT_BUILD:-未知构建}"
if [[ "$DETECTED_WECHAT_VERSION" != "$PREFERRED_WECHAT_VERSION" ]]; then
  warn "独立副本版本需要检查：$PREFERRED_WECHAT_TARGET；请运行 wechat-use doctor。"
fi
echo ""

# Auto-add INSTALL_DIR to PATH if missing. Idempotent: only inserts if
# the rc file doesn't already reference the directory.
path_export_line() {
  printf 'export PATH="%s:$PATH"  # added by wechat-use installer' "${1}"
}

_rc_already_covers_install_dir() {
  # Returns 0 if the rc file already exports the install dir to PATH,
  # whether written as the absolute path or the $HOME-relative form.
  # Common forms users / installers leave in zshrc/bashrc:
  #   export PATH="$HOME/.local/bin:$PATH"
  #   export PATH="/Users/leo/.local/bin:$PATH"
  #   . "$HOME/.local/bin/env"   ← rustup-style; also covers PATH
  #   fish_add_path /Users/leo/.local/bin
  local rc_path="$1"
  local install_dir="$2"
  [[ -f "$rc_path" ]] || return 1
  # Use grep -F (fixed strings) so '$HOME' isn't read as regex anchor.
  if grep -qF "${install_dir}" "$rc_path" 2>/dev/null; then
    return 0
  fi
  if [[ "$install_dir" == "$HOME"/* ]] \
    && grep -qF "\$HOME${install_dir#$HOME}" "$rc_path" 2>/dev/null; then
    return 0
  fi
  if grep -qF ".local/bin/env" "$rc_path" 2>/dev/null; then
    return 0
  fi
  return 1
}

ensure_rc_has_path() {
  local rc_path="$1"
  local install_dir="$2"
  [[ -f "$rc_path" ]] || touch "$rc_path"
  if _rc_already_covers_install_dir "$rc_path" "$install_dir"; then
    return 2  # already covered (don't append a duplicate)
  fi
  printf '\n%s\n' "$(path_export_line "$install_dir")" >> "$rc_path"
  return 0
}

ensure_fish_has_path() {
  local install_dir="$1"
  local fish_conf="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$fish_conf")"
  [[ -f "$fish_conf" ]] || touch "$fish_conf"
  if _rc_already_covers_install_dir "$fish_conf" "$install_dir"; then
    return 2
  fi
  printf '\n# added by wechat-use installer\nfish_add_path %s\n' "$install_dir" >> "$fish_conf"
  return 0
}

case ":$PATH:" in
  *":${INSTALL_DIR}:"*)
    # Already on PATH this session.
    ;;
  *)
    # Detect user's shell from $SHELL and auto-append to the matching rc
    # file. Tell them exactly what we changed + how to activate in the
    # current shell without a new terminal.
    current_shell_name="$(basename "${SHELL:-}")"
    added_file=""
    rc_state=""  # appended | already_covered | unknown
    case "$current_shell_name" in
      bash)
        rc_rc=0
        ensure_rc_has_path "$HOME/.bashrc" "$INSTALL_DIR" || rc_rc=$?
        if [[ $rc_rc -eq 0 ]]; then added_file="$HOME/.bashrc"; rc_state="appended"
        elif [[ $rc_rc -eq 2 ]]; then added_file="$HOME/.bashrc"; rc_state="already_covered"
        fi
        ;;
      zsh)
        rc_rc=0
        ensure_rc_has_path "$HOME/.zshrc" "$INSTALL_DIR" || rc_rc=$?
        if [[ $rc_rc -eq 0 ]]; then added_file="$HOME/.zshrc"; rc_state="appended"
        elif [[ $rc_rc -eq 2 ]]; then added_file="$HOME/.zshrc"; rc_state="already_covered"
        fi
        ;;
      fish)
        rc_rc=0
        ensure_fish_has_path "$INSTALL_DIR" || rc_rc=$?
        if [[ $rc_rc -eq 0 ]]; then added_file="$HOME/.config/fish/config.fish"; rc_state="appended"
        elif [[ $rc_rc -eq 2 ]]; then added_file="$HOME/.config/fish/config.fish"; rc_state="already_covered"
        fi
        ;;
      *)
        rc_state="unknown_shell"
        ;;
    esac
    case "$rc_state" in
      appended)
        success "已把 ${INSTALL_DIR} 加到 ${added_file}"
        printf '  %s要在当前 shell 立刻生效%s\n' "${C_DIM}" "${C_RESET}"
        printf '  %s\n\n' "$(cmd "source $added_file")"
        ;;
      already_covered)
        # rc 里其实已写了路径，只是当前这个非交互 shell 没 source 它。
        # 不再把这条当 "失败" 报。告诉用户在自己的交互 shell 里 source 一下。
        success "${added_file} 里已包含 ${INSTALL_DIR}（之前装过 / 别的工具加过）"
        printf '  %s在当前 shell 立刻生效%s\n' "${C_DIM}" "${C_RESET}"
        printf '  %s\n\n' "$(cmd "source $added_file")"
        ;;
      *)
        warn "${INSTALL_DIR} 不在 PATH 中，且未能识别 shell 自动追加。手动加："
        printf '\n'
        printf '  %s# bash / zsh%s\n' "${C_DIM}" "${C_RESET}"
        printf '  %s\n' "$(cmd "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc")"
        printf '\n'
        printf '  %s# fish%s\n' "${C_DIM}" "${C_RESET}"
        printf '  %s\n' "$(cmd "fish_add_path $INSTALL_DIR")"
        printf '\n'
        ;;
    esac
    ;;
esac

# One current snapshot; print only incomplete steps, never ask configured users
# to reactivate/reinitialize merely because they ran the installer again.
FINAL_DOCTOR_REPORT=$("$INSTALL_DIR/wechat" doctor --json 2>/dev/null || true)
FINAL_SUBSCRIPTION_STATE=$(installer_subscription_state)
FINAL_BRIDGE_OK=0
if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:18400/health >/dev/null 2>&1; then FINAL_BRIDGE_OK=1; fi
print_install_next_steps "$FINAL_DOCTOR_REPORT" "$FINAL_SUBSCRIPTION_STATE" "$FINAL_BRIDGE_OK"
offer_agent_skill_install
