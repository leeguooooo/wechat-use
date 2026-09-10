#!/usr/bin/env bash
set -euo pipefail
export WECHAT_USE_INSTALL_LIB_ONLY=1
source "$(cd "$(dirname "$0")/.." && pwd)/install.sh"
npx() { printf '%s\n' "$MOCK_OUTPUT"; return "$MOCK_STATUS"; }
MOCK_STATUS=0
MOCK_OUTPUT='Installation complete'
output=$(install_agent_skill 2>&1)
[[ "$output" == *'✓'* && "$output" != *'部分安装'* ]]
MOCK_OUTPUT=$'Installation complete\nFailed to install 1\nPromptScript does not support global skill installation'
output=$(install_agent_skill 2>&1)
[[ "$output" == *'仅部分安装成功'* && "$output" == *'PromptScript'* ]]
[[ "$output" != *'✓'* ]]
MOCK_STATUS=1
MOCK_OUTPUT='Network error'
output=$(install_agent_skill 2>&1)
[[ "$output" == *'未安装成功'* && "$output" != *'✓'* ]]
echo 'PASS: complete, partial-success exit 0, and failed skill installs have distinct results'
