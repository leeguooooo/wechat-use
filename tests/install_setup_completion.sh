#!/usr/bin/env bash
# Setup owns the typed distinction: installed/readable with an unconfirmed send
# returns zero; missing data/login/services still propagate a fatal exit.
set -euo pipefail
task_root=$(mktemp -d)
trap 'rm -rf "$task_root"' EXIT
repo_root=$(cd "$(dirname "$0")/.." && pwd)
export WECHAT_USE_INSTALL_LIB_ONLY=1
export INSTALL_DIR="$task_root/bin"
source "$repo_root/install.sh"
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/wechat" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == setup ]] || exit 99
if [[ "${MOCK_SETUP_RC}" == 0 ]]; then
  printf '%s\n' '安装已完成，CLI 已可用；发送自检尚未确认，请勿重复测试。'
else
  printf '%s\n' 'setup_incomplete: login/data/service not ready' >&2
fi
exit "$MOCK_SETUP_RC"
MOCK
chmod +x "$INSTALL_DIR/wechat"
unset WECHAT_USE_NO_TEST_MESSAGE
export MOCK_SETUP_RC=0
run_setup_step > "$task_root/soft"
grep -F 'CLI 已可用' "$task_root/soft" >/dev/null
grep -F '发送自检尚未确认' "$task_root/soft" >/dev/null
for task_rc in 1 2 3; do
  export MOCK_SETUP_RC="$task_rc"
  task_actual=0
  run_setup_step > "$task_root/fatal" 2>&1 || task_actual=$?
  [[ "$task_actual" == "$task_rc" ]] || { echo 'FAIL: installer swallowed a fatal setup result'; exit 1; }
done
echo 'PASS: installation success with send warning returns zero; fatal setup exit codes are preserved'
