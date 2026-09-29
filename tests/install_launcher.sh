#!/usr/bin/env bash
# install.sh installs scripts/wechat-use from the release tag, or keeps the symlink.
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export WECHAT_USE_INSTALL_LIB_ONLY=1
source "$REPO_ROOT/install.sh"
INSTALL_DIR="$TEST_ROOT/bin"
STAGE="$TEST_ROOT/stage"
LATEST_TAG=v9.9.9
mkdir -p "$INSTALL_DIR" "$STAGE"
printf 'binary\n' > "$INSTALL_DIR/wechat"
LINK="$INSTALL_DIR/wechat-use"

curl() {  # serves the repo's launcher for the pinned tag only
  local out='' url=''
  while [[ $# -gt 0 ]]; do
    case "$1" in -o) out="$2"; shift 2 ;; --connect-timeout|--max-time|--proto|--proto-redir) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
  done
  printf '%s\n' "$url" >> "$TEST_ROOT/urls"
  case "$MODE" in
    missing) return 22 ;;
    bogus) printf 'echo not the launcher\n' > "$out" ;;
    ok) cp "$REPO_ROOT/scripts/wechat-use" "$out" ;;
  esac
}

# Release without the launcher: plain alias, as before.
MODE=missing install_wechat_use_command > /dev/null
[[ -L "$LINK" && "$(readlink "$LINK")" == wechat ]]
grep -Fqx 'https://raw.githubusercontent.com/leeguooooo/wechat-use/v9.9.9/scripts/wechat-use' "$TEST_ROOT/urls"

# Unexpected content is never installed.
MODE=bogus install_wechat_use_command > /dev/null
[[ -L "$LINK" ]]

# Release with the launcher: the symlink becomes the executable launcher.
MODE=ok install_wechat_use_command > /dev/null
[[ -f "$LINK" && ! -L "$LINK" && -x "$LINK" ]]
cmp -s "$REPO_ROOT/scripts/wechat-use" "$LINK"
inode=$(stat -f %i "$LINK")
out=$(MODE=ok install_wechat_use_command)
[[ "$out" == *'已是当前版本'* && "$(stat -f %i "$LINK")" == "$inode" ]]

# An older release again: back to the alias (no stale launcher left behind).
MODE=missing install_wechat_use_command > /dev/null
[[ -L "$LINK" && "$(readlink "$LINK")" == wechat ]]
echo 'PASS: launcher pinned to the release tag, validated, atomic; alias fallback for older releases'
