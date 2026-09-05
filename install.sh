#!/usr/bin/env bash
# install.sh — one-liner installer for wechat + wechatd
#
# Default: install to ~/.local/bin (no sudo). Override with INSTALL_DIR.
# Example: INSTALL_DIR=/usr/local/bin ./install.sh  (will use sudo if needed)
set -euo pipefail

REPO="leeguooooo/wechat-use"
BINS=(wechat wechatd wechat-bridge wechat-wechaty-gateway)
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

# Supported WeChat versions (高层版本号). Per-build 兼容矩阵在运行时通过
# `wechat doctor` + profile API 查询,这里只列大版本号让用户快速判断。
SUPPORTED_WECHAT_VERSIONS="4.0.x, 4.1.x"
SUPPORTED_WECHAT_BUILDS=""
WECHAT_DOWNLOAD_URL="https://mac.weixin.qq.com/en"
PREFERRED_WECHAT_VERSION="4.1.9"
PREFERRED_WECHAT_SOURCE="${WECHAT_419_SOURCE:-}"
PREFERRED_WECHAT_TARGET="${WECHAT_419_TARGET:-/Applications/WeChat-4.1.9-wechat-use.app}"
PREFERRED_WECHAT_BUNDLE_ID="${WECHAT_419_BUNDLE_ID:-com.tencent.xinWeChat419WechatUse}"
PREFERRED_WECHAT_NAME="${WECHAT_419_NAME:-WeChat 4.1.9 (wechat-use)}"

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
  local log="${HOME}/.hermes/logs/wechat.bridge.error.log"
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
  local log="${HOME}/.hermes/logs/wechat.bridge.error.log"
  [[ -f "${log}" ]] || return 1
  # Match either of the two phrases preflight emits.
  tail -n 60 "${log}" 2>/dev/null \
    | grep -qE "Accessibility TCC (not granted|missing)"
}

# Probe whether a GUI is reachable from this script's session. curl|bash
# over SSH or in CI has no Aqua session, so AppleScript dialogs would
# fail with -1712 / -1719. Detect once so we can fall back to the text
# banner instead of issuing a dialog that never paints.
gui_available() {
  osascript -e 'tell application "System Events" to return 1' >/dev/null 2>&1
}

# Drive the TCC grant via a modal dialog. Used in non-TTY (curl|bash)
# scenarios where install.sh can't read stdin to gate progress on
# "press Enter when done". Loops up to 3 rounds: open the two GUI
# windows → display blocking dialog → user clicks 已勾选完毕 → we
# re-probe --check-trust + bootout/bootstrap. Returns 0 on grant, 1 on
# cancel or attempts exhausted.
prompt_tcc_grant_via_dialog() {
  local bridge="${INSTALL_DIR}/wechat-bridge"
  local wechatd="${INSTALL_DIR}/wechatd"
  local plist="$HOME/Library/LaunchAgents/ai.wechat.bridge.plist"
  # v1.16.4: simple drag-binary flow (post-revert from .app bundle path).
  # Drop legacy entries from any prior install layout. tccutil reset
  # against a non-existent identifier is a no-op; against a real one
  # nukes the row so the user's drag re-establishes binding cleanly.
  tccutil reset Accessibility ai.wechatskill.helper >/dev/null 2>&1 || true
  tccutil reset Accessibility ai.wechatskill.wechat-bridge >/dev/null 2>&1 || true
  tccutil reset Accessibility ai.wechatskill.wechatd >/dev/null 2>&1 || true

  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
  sleep 1
  # Open the install dir so user sees BOTH binaries side-by-side and
  # can drag both in one shot. (Dogfood 2026-04-30: `open -R` only
  # reveals one file → user thought wechat-bridge was the only thing
  # needing AX, missed wechatd → send kept silently failing.)
  open "${INSTALL_DIR}" 2>/dev/null || true
  cat <<EOF

  把以下两个 binary 都拖进 System Settings → 辅助功能 → 打开开关:
    • ${wechatd}        ← 实际合成键盘事件的进程,关键
    • ${bridge}         ← HTTP 网关,部分老路径要它

EOF

  # Live poll REAL TCC state. Bridge --check-trust returns 0 iff trusted;
  # wechatd trust verified via `wechat doctor` JSON daemon_accessibility.
  local elapsed=0
  local interval=2
  local cap=120
  while (( elapsed < cap )); do
    local bridge_ok=0
    local wechatd_ok=0
    "${bridge}" --check-trust >/dev/null 2>&1 && bridge_ok=1 || true
    if "${INSTALL_DIR}/wechat" doctor --json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if any(c['name']=='daemon_accessibility' and c['ok'] for c in d.get('checks',[])) else 1)" 2>/dev/null; then
      wechatd_ok=1
    fi
    if (( bridge_ok && wechatd_ok )); then
      launchctl bootout "gui/$(id -u)/ai.wechat.bridge" 2>/dev/null || true
      sleep 1
      if [[ -f "${plist}" ]]; then
        launchctl bootstrap "gui/$(id -u)" "${plist}" 2>/dev/null || true
      fi
      wait_for_bridge_health 2>/dev/null || true
      return 0
    fi
    info "等 Accessibility 授权… 把上面两个 binary 拖进 Settings 列表 + 打开开关 (${elapsed}s / ${cap}s,bridge=${bridge_ok} wechatd=${wechatd_ok})"
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
  warn "120s 内没等到 Accessibility 授权。在 System Settings → Privacy & Security → 辅助功能 把 wechat-bridge / wechatd 都拖进去开关 ON,然后跑 \`wechat doctor\` 复验。"
  return 1
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
  local app_bin="/Applications/WeChat.app/Contents/MacOS/WeChat"
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
  v=$(printf '%s' "${ents}" | plutil -extract com.apple.security.get-task-allow raw -o - - 2>/dev/null || true)
  if [[ "${v}" == "true" ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# Print a loud banner + a self-contained merge-mode re-sign recipe when
# WeChat lacks get-task-allow. Doesn't exit — binaries installed fine,
# this is a follow-up TCC-level prereq for `wechat send` to actually work.
#
# CRITICAL: the recipe MUST merge into WeChat 原有的 entitlements
# (官方签名里有一组系统 entitlements,不能 strip)。如果整段 replace 成
# 只有 get-task-allow=true,WeChat 每次启动都会弹「access data from
# other apps」TCC 弹框。所以必须 merge,不能 replace。
#
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
      echo ""
      printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_RED}" "${C_RESET}"
      printf '%s🛑 WeChat get-task-allow = false —— send 适配模块装不上,必失败%s\n' "${C_RED}" "${C_RESET}"
      printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_RED}" "${C_RESET}"
      echo ""
      echo "官方分发的 WeChat 签名里没 get-task-allow,wechatd 的本地调试接口无法配合"
      echo "完成 send 路径设置,必然 30s 超时 → \`wechat send\` 永远返回 \`slot_send_bp_failed_to_arm\`。"
      echo ""
      echo "下面这段【保留原有 entitlements】(官方签名里有一组系统 entitlements,"
      echo "merge 而不是 replace,否则 TCC 会反复弹框),只加 get-task-allow=true。"
      echo "复制整段到终端跑:"
      echo ""
      printf '%s' "${C_GREEN}"
      cat <<'CMD'
  WX_BIN=/Applications/WeChat.app/Contents/MacOS/WeChat
  WX_ENT=/tmp/wechat-merged-entitlements.plist
  codesign -d --entitlements :- "$WX_BIN" > "$WX_ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$WX_ENT" \
    || /usr/libexec/PlistBuddy -c "Set :com.apple.security.get-task-allow true" "$WX_ENT"
  osascript -e 'quit app "WeChat"' 2>/dev/null; sleep 2
  sudo codesign --force --sign - --entitlements "$WX_ENT" "$WX_BIN"
  open -a WeChat
CMD
      printf '%s' "${C_RESET}"
      echo ""
      echo "完成后跑 \`wechat doctor\` 应看到 wechat_get_task_allow ✓,再发就通。"
      printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_RED}" "${C_RESET}"
      echo ""
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
  local config_file="${HOME}/.wx-rs/config.json"
  # Init hasn't run → no key, no daemon — silent skip.
  if [[ ! -f "${config_file}" ]]; then
    return 0
  fi
  # Auth: just probe whether the CLI can read a token. v1.9+ refuses
  # to send without an activated token; surfacing that here would
  # confuse a fresh installer who hasn't activated yet.
  if ! "${INSTALL_DIR}/wechat" auth status >/dev/null 2>&1; then
    info "filehelper smoke send 已跳过（激活码未激活；激活后跑：wechat send 'hi' filehelper）"
    return 0
  fi
  # WeChat running? Without it the daemon can't attach to the runtime.
  if ! pgrep -x WeChat >/dev/null 2>&1; then
    info "filehelper smoke send 已跳过（WeChat 未运行；启动 WeChat 后跑：wechat send 'hi' filehelper）"
    return 0
  fi
  # WeChat get-task-allow? wechatd 的本地调试接口需要该 entitlement,
  # 没有的话 send 适配模块装不上,smoke 跑了也是浪费 30s + 误报首发
  # warmup 问题。提前 skip,banner 已经在前面打过了。
  if [[ "$(wechat_get_task_allow_state)" != "true" ]]; then
    info "filehelper smoke send 已跳过（WeChat get-task-allow=false,先跑上面那段重签命令）"
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
  local app_path="$1"
  local plist="${app_path}/Contents/Info.plist"
  [[ -f "${plist}" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${plist}" 2>/dev/null
}

wechat_app_bundle_id() {
  local app_path="$1"
  local plist="${app_path}/Contents/Info.plist"
  [[ -f "${plist}" ]] || return 1
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null
}

find_preferred_wechat_source() {
  local candidate version root
  if [[ -n "${PREFERRED_WECHAT_SOURCE}" ]]; then
    version=$(wechat_app_version "${PREFERRED_WECHAT_SOURCE}" 2>/dev/null || true)
    if [[ "${version}" == "${PREFERRED_WECHAT_VERSION}" ]]; then
      printf '%s\n' "${PREFERRED_WECHAT_SOURCE}"
      return 0
    fi
    warn "WECHAT_419_SOURCE 不是 WeChat ${PREFERRED_WECHAT_VERSION}: ${PREFERRED_WECHAT_SOURCE}"
    return 1
  fi

  for candidate in \
    "/Applications/WeChat-4.1.9.app" \
    "${HOME}/Applications/WeChat-4.1.9.app"; do
    [[ "${candidate}" == "${PREFERRED_WECHAT_TARGET}" ]] && continue
    version=$(wechat_app_version "${candidate}" 2>/dev/null || true)
    if [[ "${version}" == "${PREFERRED_WECHAT_VERSION}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  for root in /Applications "${HOME}/Applications"; do
    [[ -d "${root}" ]] || continue
    while IFS= read -r -d '' candidate; do
      [[ "${candidate}" == "${PREFERRED_WECHAT_TARGET}" ]] && continue
      version=$(wechat_app_version "${candidate}" 2>/dev/null || true)
      if [[ "${version}" == "${PREFERRED_WECHAT_VERSION}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    done < <(find "${root}" -maxdepth 1 -type d -name '*.app' -print0 2>/dev/null)
  done
  return 1
}

install_preferred_wechat_clone() {
  local source="$1"
  local target_parent
  target_parent=$(dirname "${PREFERRED_WECHAT_TARGET}")
  local clone_cmd=(
    "${INSTALL_DIR}/wechat"
    clone install
    --source "${source}"
    --target "${PREFERRED_WECHAT_TARGET}"
    --name "${PREFERRED_WECHAT_NAME}"
    --bundle-id "${PREFERRED_WECHAT_BUNDLE_ID}"
  )

  if [[ -w "${target_parent}" ]]; then
    "${clone_cmd[@]}"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    info "创建 ${PREFERRED_WECHAT_TARGET} 需要管理员权限…"
    sudo "${clone_cmd[@]}"
    return
  fi
  err "${target_parent} 不可写，且找不到 sudo"
  return 1
}

maybe_offer_preferred_wechat_419() {
  echo ""
  printf '%s推荐 WeChat %s%s\n' "${C_BOLD}" "${PREFERRED_WECHAT_VERSION}" "${C_RESET}"
  printf '  WeChat 4.1.9 是 wechat-use 当前功能覆盖最完整、使用体验最好的版本。\n'
  printf '  选择后会创建独立副本，不会覆盖 /Applications/WeChat.app，也不会改动源 app。\n\n'

  if [[ -e "${PREFERRED_WECHAT_TARGET}" ]]; then
    local existing_version existing_bundle_id
    existing_version=$(wechat_app_version "${PREFERRED_WECHAT_TARGET}" 2>/dev/null || true)
    existing_bundle_id=$(wechat_app_bundle_id "${PREFERRED_WECHAT_TARGET}" 2>/dev/null || true)
    if [[ "${existing_version}" == "${PREFERRED_WECHAT_VERSION}" \
      && "${existing_bundle_id}" == "${PREFERRED_WECHAT_BUNDLE_ID}" ]]; then
      success "独立的 WeChat ${PREFERRED_WECHAT_VERSION} 副本已存在：${PREFERRED_WECHAT_TARGET}"
    else
      warn "目标路径已存在，为防止覆盖已跳过：${PREFERRED_WECHAT_TARGET}"
    fi
    return 0
  fi

  local source
  if ! source=$(find_preferred_wechat_source); then
    info "未找到本地 WeChat ${PREFERRED_WECHAT_VERSION} app，保留你现在的 WeChat，跳过副本创建。"
    printf '  %s如果你有 4.1.9 app，可以稍后运行：%s\n' "${C_DIM}" "${C_RESET}"
    printf '  %sWECHAT_419_SOURCE=/path/to/WeChat-4.1.9.app WECHAT_USE_PREFER_419=yes ./install.sh%s\n' "${C_CYAN}" "${C_RESET}"
    return 0
  fi

  info "已找到本地 4.1.9：${source}"
  printf '  将创建：%s\n' "${PREFERRED_WECHAT_TARGET}"

  local choice="${WECHAT_USE_PREFER_419:-ask}"
  if [[ "${choice}" == "ask" ]]; then
    if [[ ( -t 0 || -t 1 || -t 2 ) && -r /dev/tty && -w /dev/tty ]]; then
      printf '%s[install] 要使用 WeChat 4.1.9 吗？[Y/n] %s' "${C_YELLOW}" "${C_RESET}" >/dev/tty
      IFS= read -r choice </dev/tty || choice="skip"
      [[ -z "${choice}" ]] && choice="yes"
    else
      info "(非交互模式，跳过 4.1.9 副本创建。设 WECHAT_USE_PREFER_419=yes 可自动选择)"
      choice="skip"
    fi
  fi

  case "${choice}" in
    y|Y|yes|YES|Yes|1|true|TRUE|"是"|"要")
      info "正在从 ${source} 创建独立副本…"
      if install_preferred_wechat_clone "${source}"; then
        success "WeChat ${PREFERRED_WECHAT_VERSION} 独立副本已创建：${PREFERRED_WECHAT_TARGET}"
        printf '  %s它使用独立 bundle id：%s%s\n' "${C_DIM}" "${PREFERRED_WECHAT_BUNDLE_ID}" "${C_RESET}"
        printf '  %s针对该副本运行：wechat-use --bundle-id %s doctor%s\n' "${C_DIM}" "${PREFERRED_WECHAT_BUNDLE_ID}" "${C_RESET}"
      else
        warn "4.1.9 副本创建失败，CLI 已正常安装，当前 WeChat 没有被改动。"
        warn "手动重试：${INSTALL_DIR}/wechat clone install --source '${source}' --target '${PREFERRED_WECHAT_TARGET}' --name '${PREFERRED_WECHAT_NAME}' --bundle-id '${PREFERRED_WECHAT_BUNDLE_ID}'"
      fi
      ;;
    n|N|no|NO|No|0|false|FALSE|"否"|"不要"|skip)
      info "已跳过 4.1.9 副本创建，当前 WeChat 保持不变。"
      ;;
    *)
      warn "无法识别选择 '${choice}'，为防止意外改动，已跳过 4.1.9 副本创建。"
      ;;
  esac
}

# Test harnesses source this file to exercise the 4.1.9 decision flow without
# downloading binaries or touching LaunchAgents. Normal installs never set it.
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

mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE}"' EXIT

# Resolve the latest release tag so we can fetch a versioned tarball +
# SHA256SUMS. Using /releases/latest/download/<file> would save one API
# round-trip, but following the redirect to a specific tag lets us
# print the version up front and also cleanly handles the case where
# the tarball name is version-suffixed.
LATEST_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
  "https://github.com/${REPO}/releases/latest" 2>/dev/null \
  | sed -E 's#.*/tag/##')
if [[ -z "${LATEST_TAG}" ]]; then
  err "无法解析最新 release tag（网络/GitHub API 不可达？）"
  exit 1
fi
info "最新版本：${LATEST_TAG}"

TARBALL="wechat-${LATEST_TAG}-darwin-arm64.tar.gz"
BASE_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}"
info "下载 ${TARBALL}"
if ! curl -fsSL "${BASE_URL}/${TARBALL}" -o "${STAGE}/${TARBALL}"; then
  err "无法下载 ${TARBALL}，release 可能缺少此文件。"
  exit 1
fi
info "下载 SHA256SUMS"
if ! curl -fsSL "${BASE_URL}/SHA256SUMS" -o "${STAGE}/SHA256SUMS.release"; then
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
  if [[ -w "${INSTALL_DIR}" ]]; then
    install -m 755 "${SRC}" "${DEST}"
  else
    info "把 ${BIN_NAME} 装到 ${INSTALL_DIR} 需要 sudo 授权……"
    sudo install -m 755 "${SRC}" "${DEST}"
  fi

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
if [[ -w "${INSTALL_DIR}" ]]; then
  rm -f "${WECHAT_USE_LINK}"
  ln -s wechat "${WECHAT_USE_LINK}"
else
  sudo rm -f "${WECHAT_USE_LINK}"
  sudo ln -s wechat "${WECHAT_USE_LINK}"
fi
success "已建立别名:${WECHAT_USE_LINK} → wechat（wechat-use 与 wechat 等价）"
echo ""

# This is the first optional product choice after the verified CLI binaries
# land. It never replaces either the current WeChat.app or the discovered
# 4.1.9 source bundle.
maybe_offer_preferred_wechat_419

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
for BIN in wechat wechatd wechat-bridge wechat-wechaty-gateway; do
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
LAUNCHAGENT_DIR="$HOME/Library/LaunchAgents"
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
# SIGKILL 兜底任何挺过 SIGTERM 的进程
for pat in \
  "${INSTALL_DIR}/wechatd" \
  "${INSTALL_DIR}/wechat-bridge" \
  "${INSTALL_DIR}/wechat-wechaty-gateway" \
  "${INSTALL_DIR}/wechat orchestrate" \
  "${INSTALL_DIR}/wechat listen"; do
  PIDS=$(pgrep -f "${pat}" 2>/dev/null || true)
  if [[ -n "${PIDS}" ]]; then
    echo "${PIDS}" | xargs kill -9 2>/dev/null || true
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
elif launchctl list 2>/dev/null | grep -q ai.wechat.bridge; then
  info "LaunchAgent 注册但 plist 不在标准路径，用 kickstart 重启"
  launchctl kickstart -k "gui/$(id -u)/ai.wechat.bridge" 2>/dev/null || true
  if ! wait_for_bridge_health; then
    dump_bridge_diag "LaunchAgent kickstart 后 /health 仍无响应"
  fi
fi

# Drive the TCC remediation flow. Three branches:
#   - interactive TTY → exec doctor --fix-tcc inline
#   - GUI but non-TTY → drive via dialog prompt
#   - neither → static fallback banner with manual instructions
# Called from two trigger sites:
#   1. Bridge crash-loops AND bridge log says "tcc_missing" (bridge layer).
#   2. Bridge /health 200 BUT `wechat doctor` reports daemon_accessibility
#      FAIL (wechatd layer — bridge serves health fine but wechatd's
#      AXIsProcessTrusted() returns false → CGEventPostToPid silently
#      dropped → send fails. Real customer dogfood found this gap on
#      v1.12.1 install.sh upgrade — bridge /health 200 made install.sh
#      claim "TCC OK" but wechatd was untrusted and send returned
#      tcc_accessibility_denied).
remediate_tcc_grant() {
  if [[ -t 0 && -t 1 ]]; then
    echo ""
    warn "Accessibility TCC 未授权 —— 直接进交互修复"
    echo ""
    exec "${INSTALL_DIR}/wechat" doctor --fix-tcc
  elif gui_available && prompt_tcc_grant_via_dialog; then
    success "Accessibility TCC: 已授权 ✓ (dialog flow)"
    warn_if_wechat_lacks_get_task_allow || true
    maybe_smoke_send
    echo ""
  else
    echo ""
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_RED}" "${C_RESET}"
    printf '%s🛑 STOP — Accessibility 授权没勾，bridge / wechatd 无法发消息！%s\n' "${C_RED}" "${C_RESET}"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_RED}" "${C_RESET}"
    echo ""
    echo "macOS Sonoma+ 要求 wechat-bridge 和 wechatd 在「辅助功能」清单里。没勾的话："
    echo "  • wechat send 看似成功但消息其实没发出（tcc_accessibility_denied）"
    echo "  • bridge 启动直接 exit 1，hermes / agent 平台拿不到数据"
    echo ""
    if gui_available; then
      echo "已为你打开两个窗口（如果系统未弹出，请手动）："
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
      sleep 1
      # Open the whole install dir (not -R a single file) so user sees both
      # wechatd AND wechat-bridge side-by-side in Finder, can drag both in
      # one shot. dogfood (190, 2026-04-30): -R only reveals one file →
      # users miss the other and assume the prompt is about wechat-bridge
      # alone, leaving wechatd ungranted → send keeps silently failing.
      open "${INSTALL_DIR}" 2>/dev/null || true
      echo "  1. System Settings → 隐私与安全 → 辅助功能"
      echo "  2. 在 Finder 窗口里**两个二进制**都拖进辅助功能清单："
      echo "     • wechatd          ← 实际合成键盘事件的进程，没勾就是 send 静默失败的根因"
      echo "     • wechat-bridge    ← HTTP 网关，少数老配置依赖它有 AX"
      echo "  3. 拖进去后开关默认 ON；如果列表里已有同名条目（cdhash 失效的旧版），"
      echo "     macOS 会自动用新拖入的覆盖，**不用先按「-」删**"
    else
      echo "（当前 session 无 GUI —— SSH / headless 装机请到目标机器物理屏前操作）"
      echo "  1. 打开 System Settings → 隐私与安全 → 辅助功能"
      echo "  2. 把以下两个二进制都拖进清单，打开右侧开关："
      echo "     • ${INSTALL_DIR}/wechat-bridge"
      echo "     • ${INSTALL_DIR}/wechatd"
    fi
    echo ""
    printf '%s勾完后跑这条命令验证 + 重启 bridge：%s\n' "${C_YELLOW}" "${C_RESET}"
    echo ""
    printf '   %s%s/wechat doctor --fix-tcc%s\n' "${C_GREEN}" "${INSTALL_DIR}" "${C_RESET}"
    echo ""
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${C_RED}" "${C_RESET}"
    echo ""
  fi
}

# Probe wechatd's AX trust. Bridge /health 200 doesn't tell us anything
# about wechatd — bridge can serve HTTP fine while wechatd silently fails
# on every send. The doctor probe runs AXIsProcessTrusted() from the
# daemon's own process, which is the only check that catches this.
# Returns 0 if explicitly trusted, 1 otherwise.
#
# FAIL-CLOSED on purpose (codex review Q3): we look for the success line
# explicitly. If doctor output format shifts (field renamed, JSON-ified,
# doctor crashes silently, etc.), absence of the success marker means
# "treat as untrusted" → user gets one extra TCC prompt. The opposite
# (look for FAIL marker, treat absence as OK) silently fails open the
# moment doctor changes wording — exactly the regression we're trying
# to prevent.
wechatd_ax_trusted() {
  local doc_out
  doc_out=$("${INSTALL_DIR}/wechat" doctor 2>&1 || true)
  # Success line shape: "✓ daemon_accessibility  OK ax_trusted=true ..."
  # Require BOTH the daemon_accessibility key AND ax_trusted=true on the
  # same line. Anything else (FAIL line, missing line, garbled output)
  # → return 1.
  if echo "$doc_out" | grep -E 'daemon_accessibility' | grep -qE 'ax_trusted=true'; then
    return 0
  fi
  return 1
}

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
    warn "bridge /health OK，但 wechatd AXIsProcessTrusted = false —— 升级把 TCC 弄丢了"
    warn "  典型场景：install.sh 升级覆盖了 wechatd 二进制（cdhash 变 → macOS 视为新 app）"
    remediate_tcc_grant
  fi
elif bridge_log_says_tcc_missing; then
  remediate_tcc_grant
else
  # /health failed but TCC isn't the cause — most likely port 18400
  # occupied or plist env wrong. Diag was already dumped right after
  # bootstrap; just point at the next step.
  warn "bridge /health 没起来，但日志里没看到 TCC missing 字样"
  warn "  ✓ 如果你是 **首次安装** 这一行通常是正常的 —— 你下面还没授权辅助功能，"
  warn "    bridge crash-restart 中。完成下面 step 2 (授权辅助功能) 后,bridge 会"
  warn "    自动起来,跑 \`wechat doctor\` 一次就全绿了。"
  warn "  ✗ 如果你已经授权过辅助功能 / 升级一次后 yellow:可能是另一进程占用 18400"
  warn "    (lsof -nP -iTCP:18400 | grep LISTEN) 或 plist env 配置错。"
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
if [[ -f /Applications/WeChat.app/Contents/Info.plist ]]; then
  DETECTED_WECHAT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    /Applications/WeChat.app/Contents/Info.plist 2>/dev/null || echo "")
  DETECTED_WECHAT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    /Applications/WeChat.app/Contents/Info.plist 2>/dev/null || echo "")
fi
WECHAT_DETECTED_LINE=""
if [[ -n "${DETECTED_WECHAT_VERSION}" ]]; then
  # Per-build 兼容矩阵交给运行时 `wechat doctor` + profile API 判定;
  # install.sh 只做大版本号粗判,版本不在 SUPPORTED 清单内时给个 yellow
  # 提示,具体是否适配请跑 `wechat doctor`。
  if echo "${SUPPORTED_WECHAT_VERSIONS}" | grep -qw "${DETECTED_WECHAT_VERSION%.*}.x" \
     || echo "${SUPPORTED_WECHAT_VERSIONS}" | grep -qw "${DETECTED_WECHAT_VERSION}"; then
    WECHAT_DETECTED_LINE="${C_GREEN}✓${C_RESET} 检测到 WeChat ${DETECTED_WECHAT_VERSION}，在支持的大版本范围内（具体适配以 \`wechat doctor\` 为准）"
  else
    WECHAT_DETECTED_LINE="${C_YELLOW}!${C_RESET} 检测到 WeChat ${DETECTED_WECHAT_VERSION}，${C_YELLOW}不在 ${SUPPORTED_WECHAT_VERSIONS} 范围内${C_RESET}，请跑 \`wechat doctor\` 查看支持状态"
  fi
fi

printf '%s版本信息%s\n' "${C_BOLD}" "${C_RESET}"
printf '  %s%-22s%s %s\n' "${C_DIM}" "wechat (CLI)" "${C_RESET}" "${INSTALLED_VER}"
printf '  %s%-22s%s %s\n' "${C_DIM}" "wechatd (daemon)" "${C_RESET}" "${INSTALLED_DAEMON_VER}"
printf '  %s%-22s%s %s\n' "${C_DIM}" "支持的 WeChat 版本" "${C_RESET}" "${SUPPORTED_WECHAT_VERSIONS}"
printf '  %s%-22s%s %s\n' "${C_DIM}" "兼容矩阵" "${C_RESET}" "运行 \`wechat doctor\` 查看当前 WeChat 是否在适配列表内"
if [[ -n "${WECHAT_DETECTED_LINE}" ]]; then
  printf '  %s%-22s%s %b\n' "${C_DIM}" "本机 WeChat" "${C_RESET}" "${WECHAT_DETECTED_LINE}"
else
  printf '  %s%-22s%s %s未检测到 /Applications/WeChat.app%s\n' "${C_DIM}" "本机 WeChat" "${C_RESET}" "${C_YELLOW}" "${C_RESET}"
fi
printf '  %s%-22s%s %s\n' "${C_DIM}" "WeChat 下载（验证版）" "${C_RESET}" "${WECHAT_DOWNLOAD_URL}"
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

printf '%s下一步 —— 按顺序执行：%s\n\n' "${C_BOLD}" "${C_RESET}"

step "$(cmd 'wechat auth activate <激活码>')"
printf '    %sv1.9.1 起需先输入激活码。无激活码？跟 Telegram 机器人申请：%s\n' "${C_DIM}" "${C_RESET}"
printf '    %s频道公告：https://t.me/wechatuse%s\n' "${C_DIM}" "${C_RESET}"
printf '    %s交流群：https://t.me/Wechatuse_talk （可选，畅所欲言 / 求助）%s\n' "${C_DIM}" "${C_RESET}"
printf '    %s申请机器人：https://t.me/WechatCliBot （/start 看说明，激活码走人工审核，⚠️ 仅个人研究用途，商业/对外服务一律拒绝）%s\n\n' "${C_DIM}" "${C_RESET}"

step "$(cmd '授权 wechat-bridge 进「辅助功能」（首次必做，不做 send 静默失败）')"
printf '    %smacOS Sonoma+ 下跨进程合成键盘事件需要 TCC Accessibility 授权。一条龙：%s\n' "${C_DIM}" "${C_RESET}"
printf '    %s  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"%s\n' "${C_DIM}" "${C_RESET}"
printf '    %s  open "%s"%s   # Finder 打开，把 wechat-bridge 拖进设置窗\n' "${C_DIM}" "${INSTALL_DIR}" "${C_RESET}"
printf '    %s路径就是：%s%s/wechat-bridge%s\n' "${C_DIM}" "${C_CYAN}" "${INSTALL_DIR}" "${C_RESET}"
printf '    %s勾选 ✓ 后，已运行的 bridge 要重启才继承授权：pkill wechat-bridge（下次 send 自动重拉）%s\n\n' "${C_DIM}" "${C_RESET}"

step "$(cmd 'wechat doctor')"
printf '    %s体检：调试环境 / WeChat / 签名 / key / daemon / binary 指纹 / ax_trusted 一行看完。%s\n\n' "${C_DIM}" "${C_RESET}"

step "$(cmd 'wechat init')"
printf '    %s抓取数据库解密 key,自动按 WeChat 版本选提取路径。WeChat 重启 / 切换账号后需要重新跑一次。%s\n\n' "${C_DIM}" "${C_RESET}"

step "$(cmd 'wechat send "来自 CLI 的消息" filehelper')"
printf '    %s发消息。daemon 自动起，热路径约 700ms。%s\n\n' "${C_DIM}" "${C_RESET}"

step "$(cmd 'wechat auth status')"
printf '    %s查激活状态 + 剩余天数。到期后 `wechat auth renew` 看如何重新提交审核。%s\n\n' "${C_DIM}" "${C_RESET}"

step "$(cmd 'wechat doctor')  ${C_DIM}（任何时候出问题先跑这个）${C_RESET}"

# ─────────────────────────────────────────────────────────────────────
# 可选：装 wechat-use 进 Claude Code / Codex / Cursor 等 agent runner
# ─────────────────────────────────────────────────────────────────────
#
# 装好 CLI 之后,大部分用户立刻就会想"接 AI agent"。如果检测到 Claude
# Code 已经在用(`~/.claude/` 存在)+ npx 可跑,我们 prompt 一下让用户
# 顺手装 skill,免去 README 跳来跳去。
#
# 仍是 opt-in:不强装,curl|bash piped 模式下默认 skip(stdin 不可控),
# 永远打印"手动装"hint 兜底。
printf '\n%s—— 接 AI agent (可选) ——%s\n\n' "${C_BOLD}" "${C_RESET}"

# Skill 装到 `~/.agents/skills/`(`npx skills add -g` 的标准位置),Claude Code /
# Codex / Cursor / Claude Desktop 等读这个目录的 agent runner 都会用到。
# 所以我们只检测 npx 是否能跑,不挑 agent —— 装上谁用谁的事。
if command -v npx >/dev/null 2>&1; then
  SKILL_CMD="npx -y skills add leeguooooo/wechat-use -y -g"
  info "检测到 npx,可以一键装 wechat-use 进 ~/.agents/skills/"
  printf '    %s任何读这个目录的 agent(Claude Code / Codex / Cursor / Claude Desktop / …)%s\n' "${C_DIM}" "${C_RESET}"
  printf '    %s下次启动自动学会 sessions / history / send / sent 等全部命令%s\n' "${C_DIM}" "${C_RESET}"
  printf '    %s命令:%s %s\n\n' "${C_DIM}" "${C_RESET}" "$(cmd "$SKILL_CMD")"

  # 尝试拿 /dev/tty(curl|bash 模式下 stdin 已被 piped,但 tty 仍可用)。
  # 拿不到就 skip prompt,只打 hint,跟 rustup / oh-my-zsh 相同 pattern。
  answer=""
  if [ -r /dev/tty ]; then
    printf '%s[install] 现在装吗?[Y/n] %s' "${C_YELLOW}" "${C_RESET}"
    IFS= read -r answer </dev/tty || answer="__SKIP__"
  else
    info "(非交互模式,跳过自动装。复制上面那条命令自己跑就行)"
    answer="__SKIP__"
  fi

  case "${answer:-}" in
    n|N|no|NO|"否"|"拒绝"|__SKIP__)
      info "跳过 skill 自动装。需要时手动跑上面的命令。"
      ;;
    *)
      info "装 skill 中…(npx 第一次跑会拉 ~5MB 包,可能要 10-30s)"
      if $SKILL_CMD; then
        success "wechat-use 已装到 ~/.agents/skills/wechat-use/。下次 agent 启动自动加载。"
      else
        warn "skill 安装失败。可以手动重试上面的命令;不影响 CLI 本身工作。"
      fi
      ;;
  esac
else
  info "未检测到 npx(需要 Node.js)。"
  printf '    %s如果你用 Claude Code / Codex / Cursor 等 agent,装好 Node.js 后跑:%s\n' "${C_DIM}" "${C_RESET}"
  printf '    %s%s\n' "  " "$(cmd 'npx -y skills add leeguooooo/wechat-use -y -g')"
  printf '\n'
fi
