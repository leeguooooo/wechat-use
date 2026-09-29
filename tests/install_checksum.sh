#!/usr/bin/env bash
# install.sh release verification: a tarball is only accepted when its own
# SHA256SUMS matches the separately published one and every binary matches it.
# Any mismatch is refused before anything under INSTALL_DIR is touched.
set -euo pipefail
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export WECHAT_USE_INSTALL_LIB_ONLY=1
# shellcheck source=../install.sh
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
TARBALL=wechat-v9.9.9-darwin-arm64.tar.gz
INSTALL_DIR="$TEST_ROOT/bin"
mkdir -p "$INSTALL_DIR"
printf 'old wechat\n' >"$INSTALL_DIR/wechat"

# $1: tamper mode — none | binary | release-sums | no-sums
make_release() {
  local stage="$TEST_ROOT/stage-$1" src="$TEST_ROOT/src-$1"
  rm -rf "$stage" "$src"; mkdir -p "$stage" "$src"
  printf 'new wechat\n' >"$src/wechat"
  printf 'new wechatd\n' >"$src/wechatd"
  (cd "$src" && shasum -a 256 wechat wechatd >SHA256SUMS)
  cp "$src/SHA256SUMS" "$stage/SHA256SUMS.release"
  case "$1" in
    binary) printf 'tampered\n' >"$src/wechatd" ;;
    release-sums) printf '%064d  wechat\n' 0 >"$stage/SHA256SUMS.release" ;;
    no-sums) rm "$src/SHA256SUMS" ;;
  esac
  (cd "$src" && tar czf "$stage/$TARBALL" ./*)
  printf '%s\n' "$stage"
}

stage=$(make_release none)
verify_release_tarball "$stage" "$TARBALL" 2>"$TEST_ROOT/err" || fail "valid release refused: $(cat "$TEST_ROOT/err")"
[[ "$(cat "$stage/wechat")" == 'new wechat' ]] || fail 'valid release extracted into the stage'

for mode in binary release-sums no-sums; do
  stage=$(make_release "$mode")
  if verify_release_tarball "$stage" "$TARBALL" 2>"$TEST_ROOT/err"; then
    fail "$mode: tampered release accepted"
  fi
  grep -q '拒绝继续' "$TEST_ROOT/err" || fail "$mode: refusal must say why: $(cat "$TEST_ROOT/err")"
  [[ "$(cat "$INSTALL_DIR/wechat")" == 'old wechat' ]] || fail "$mode: installed binary touched"
done

stage=$(make_release none)
printf 'not a tarball' >"$stage/$TARBALL"
if verify_release_tarball "$stage" "$TARBALL" 2>/dev/null; then fail 'corrupt tarball accepted'; fi
echo 'PASS: release checksum mismatch, missing SHA256SUMS and corrupt tarball are refused; installed binary untouched'
