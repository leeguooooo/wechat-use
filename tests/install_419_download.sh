#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export WECHAT_USE_INSTALL_LIB_ONLY=1
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"
STAGE="$TEST_ROOT/stage"
mkdir -p "$STAGE"
WECHAT_419_DMG_SHA256=$(printf 'frozen-vendor-build' | shasum -a 256 | awk '{print $1}')

# Exercise the real download/verification loop, without downloading a vendor
# binary or mounting a disk image. Signature and bundle checks remain in place.
curl() {
  local url='' out=''
  while (($#)); do
    case "$1" in
      https://*) url="$1"; shift ;;
      -o) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$url" >> "$TEST_ROOT/requests"
  local behavior="$PRIMARY_RESULT"
  [[ "$url" != "$WECHAT_419_DMG_BACKUP_URL" ]] || behavior="$BACKUP_RESULT"
  case "$behavior" in
    ok) printf 'frozen-vendor-build' > "$out" ;;
    mismatch) printf 'unexpected-build' > "$out" ;;
    partial) printf 'partial' > "$out"; return 28 ;;
    fail) return 22 ;;
  esac
}
hdiutil() { printf '%s\n' "$*" >> "$TEST_ROOT/mounts"; }
usable_419_source() { return 0; }
codesign() {
  [[ "$1" != -dvv ]] || printf 'TeamIdentifier=5A4RE8SF68\n'
}
run_case() {
  PRIMARY_RESULT="$1" BACKUP_RESULT="$2"
  local expected="$3" requests="$4"
  : > "$TEST_ROOT/requests"
  : > "$TEST_ROOT/mounts"
  # A stale valid package must not mask failed transfers from both sources.
  printf 'frozen-vendor-build' > "$STAGE/WeChatMac_4.1.9.dmg"
  if download_preferred_wechat_source > "$TEST_ROOT/output" 2>&1; then
    [[ "$expected" == success ]] || { echo 'FAIL: invalid package accepted'; exit 1; }
    [[ -s "$TEST_ROOT/mounts" ]]
  else
    [[ "$expected" == failure ]] || { echo 'FAIL: fallback did not recover'; exit 1; }
    [[ ! -s "$TEST_ROOT/mounts" ]]
  fi
  [[ "$(wc -l < "$TEST_ROOT/requests" | tr -d ' ')" == "$requests" ]]
  [[ "$(head -n 1 "$TEST_ROOT/requests")" == "$WECHAT_419_DMG_URL" ]]
  if [[ "$requests" == 2 ]]; then
    [[ "$(tail -n 1 "$TEST_ROOT/requests")" == "$WECHAT_419_DMG_BACKUP_URL" ]]
  fi
}
run_case ok fail success 1
run_case fail ok success 2
run_case mismatch ok success 2
run_case partial ok success 2
run_case fail fail failure 2
run_case mismatch mismatch failure 2
run_case partial fail failure 2
echo 'PASS: official first, HTTP/timeout/hash fallback, pinned backup validation, no mount on total failure'
