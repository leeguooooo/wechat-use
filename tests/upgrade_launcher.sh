#!/usr/bin/env bash
# wechat-use launcher: `upgrade`, the daily notice and skill discovery.
# Network, installer, git remote and `claude` are all faked; nothing leaves the temp dir.
set -euo pipefail
TEST_ROOT=$(cd -P "$(mktemp -d)" && pwd)
trap 'rm -rf "$TEST_ROOT"' EXIT
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAUNCHER_SRC="$REPO_ROOT/scripts/wechat-use"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Isolated environment: temp HOME / cache, fake bin dir first on PATH.
export HOME="$TEST_ROOT/home"
export XDG_CACHE_HOME="$TEST_ROOT/cache"
mkdir -p "$HOME" "$TEST_ROOT/fake-bin" "$TEST_ROOT/install"
unset CI WECHAT_USE_NO_UPDATE_CHECK USE_NO_UPDATE_CHECK GITHUB_TOKEN WECHAT_USE_BIN 2>/dev/null || true
export PATH="$TEST_ROOT/fake-bin:$PATH"
export FAKE_LOG="$TEST_ROOT/calls.log"
export FAKE_VERSION_FILE="$TEST_ROOT/version"
export FAKE_LATEST_FILE="$TEST_ROOT/latest"
: >"$FAKE_LOG"
echo 1.18.12 >"$FAKE_VERSION_FILE"
echo v1.19.0 >"$FAKE_LATEST_FILE"

# Installed layout: $INSTALL_DIR/wechat (fake binary) + $INSTALL_DIR/wechat-use (launcher).
INSTALL_DIR="$TEST_ROOT/install"
cp "$LAUNCHER_SRC" "$INSTALL_DIR/wechat-use"
cat >"$INSTALL_DIR/wechat" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -V|--version) printf 'wechat-use %s\n' "$(cat "$FAKE_VERSION_FILE")"; exit 0 ;;
  -h|--help) printf 'Usage: wechat [OPTIONS] <COMMAND>\n\nCommands:\n  update-guard        WeChat auto-update lock\n  sessions            list\n'; exit 0 ;;
esac
printf 'binary:%s\n' "$*"
exit 7
EOF
chmod +x "$INSTALL_DIR/wechat" "$INSTALL_DIR/wechat-use"

# Fake curl: GitHub API returns $FAKE_LATEST_FILE unless FAKE_NET=down;
# the installer URL serves a fake installer that records its environment.
cat >"$TEST_ROOT/fake-bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url="" auth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift 2 ;;
    --connect-timeout|--max-time|--proto|--proto-redir) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf 'curl %s %s\n' "$url" "$auth" >>"$FAKE_LOG"
[[ "${FAKE_NET:-up}" == down ]] && exit 6
case "$url" in
  https://api.github.com/repos/leeguooooo/wechat-use/releases/latest)
    printf '{\n  "url": "x",\n  "tag_name": "%s",\n  "prerelease": false\n}\n' "$(cat "$FAKE_LATEST_FILE")" ;;
  https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh)
    cat >"$out" <<'INSTALLER'
#!/usr/bin/env bash
printf 'installer INSTALL_DIR=%s PREFER_419=%s INSTALL_SKILL=%s\n' "$INSTALL_DIR" "$WECHAT_USE_PREFER_419" "$WECHAT_USE_INSTALL_SKILL" >>"$FAKE_LOG"
[[ "${FAKE_INSTALLER_FAIL:-0}" == 1 ]] && exit 5
cat "$FAKE_LATEST_FILE" | sed 's/^v//' >"$FAKE_VERSION_FILE"
INSTALLER
    ;;
  *) exit 22 ;;
esac
EOF
cat >"$TEST_ROOT/fake-bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$FAKE_LOG"
EOF
chmod +x "$TEST_ROOT/fake-bin/curl" "$TEST_ROOT/fake-bin/claude"

CACHE="$XDG_CACHE_HOME/wechat-use/update-check.json"
api_calls() { grep -c 'api.github.com' "$FAKE_LOG" || true; }
run() { # run the launcher, split stdout/stderr, keep exit code
  set +e
  "$INSTALL_DIR/wechat-use" "$@" >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  STATUS=$?
  set -e
  OUT=$(cat "$TEST_ROOT/out"); ERR=$(cat "$TEST_ROOT/err")
}
NOTICE='wechat-use 1.19.0 is available (you have 1.18.12). Upgrade: wechat-use upgrade'

# ---------- version comparison ----------
(
  export WECHAT_USE_LAUNCHER_LIB_ONLY=1
  # shellcheck source=../scripts/wechat-use
  source "$LAUNCHER_SRC"
  wu_version_gt 1.19.0 1.18.12 || fail '1.19.0 > 1.18.12'
  wu_version_gt 1.18.13 1.18.12 || fail '1.18.13 > 1.18.12'
  wu_version_gt 2.0.0 1.99.99 || fail '2.0.0 > 1.99.99'
  wu_version_gt v1.18.10 1.18.9 || fail 'numeric, not lexical, with v prefix'
  wu_version_gt 1.18.12 1.18.12 && fail 'equal is not newer'
  wu_version_gt 1.18.9 1.18.10 && fail '1.18.9 < 1.18.10'
  wu_version_gt 1.18.12-rc.1 1.18.12 && fail 'pre-release suffix ignored'
  wu_version_gt garbage 1.0.0 && fail 'garbage is never newer'
  wu_version_gt 1.18 1.18.0 && fail 'missing part counts as 0'
  wu_version_gt 1.18.1 1.18 || fail '1.18.1 > 1.18'
  true
)
echo 'PASS: version comparison'

# ---------- first run: synchronous check writes the cache, notice on stderr only ----------
export WECHAT_USE_UPDATE_CHECK_SYNC=1
run sessions --json
[[ "$STATUS" == 7 ]] || fail "exit code passthrough, got $STATUS"
[[ "$OUT" == 'binary:sessions --json' ]] || fail "stdout must be the binary's only: $OUT"
[[ "$ERR" == "$NOTICE" ]] || fail "notice on stderr: $ERR"
[[ "$(api_calls)" == 1 ]] || fail 'one network check'
python3 - "$CACHE" <<'EOF' || fail 'cache shape'
import json, sys, time
c = json.load(open(sys.argv[1]))
assert set(c) == {"checked_at", "latest"}, c
assert c["latest"] == "1.19.0" and abs(time.time() - c["checked_at"]) < 60, c
EOF
echo 'PASS: notice goes to stderr only; stdout and exit code untouched; cache written'

# ---------- 24 h throttle ----------
run sessions
[[ "$(api_calls)" == 1 ]] || fail 'fresh cache must not hit the network'
[[ "$ERR" == "$NOTICE" ]] || fail 'fresh cache still shows the notice'
now=$(date +%s)
printf '{"checked_at": %s, "latest": "1.19.0"}\n' $((now - 86400 + 120)) >"$CACHE"
run sessions
[[ "$(api_calls)" == 1 ]] || fail 'under 24 h: no check'
printf '{"checked_at": %s, "latest": "1.19.0"}\n' $((now - 86401)) >"$CACHE"
echo v1.19.1 >"$FAKE_LATEST_FILE"
run sessions
[[ "$(api_calls)" == 2 ]] || fail 'over 24 h: one check'
[[ "$ERR" == 'wechat-use 1.19.1 is available (you have 1.18.12). Upgrade: wechat-use upgrade' ]] || fail "refreshed latest: $ERR"
# Offline: failure is silent, keeps the previous latest, still stamps checked_at.
printf '{"checked_at": %s, "latest": "1.19.1"}\n' $((now - 90000)) >"$CACHE"
FAKE_NET=down run sessions
[[ "$(api_calls)" == 3 ]] || fail 'offline: one attempt'
[[ "$ERR" == *'1.19.1 is available'* && "$ERR" != *curl* ]] || fail "offline must stay silent: $ERR"
checked=$(sed -nE 's/.*"checked_at": ([0-9]+).*/\1/p' "$CACHE")
(( checked >= now )) || fail 'offline failure still updates checked_at'
FAKE_NET=down run sessions
[[ "$(api_calls)" == 3 ]] || fail 'offline machine is not retried every call'
echo 'PASS: 24 h throttle, offline failure silent and throttled'

# Default (background) refresh: the command returns at once, the cache fills behind it.
unset WECHAT_USE_UPDATE_CHECK_SYNC
echo v1.19.2 >"$FAKE_LATEST_FILE"
printf '{"checked_at": %s, "latest": "1.19.1"}\n' $((now - 90000)) >"$CACHE"
run sessions
[[ "$OUT" == 'binary:sessions' && "$ERR" == *'1.19.1 is available'* ]] || fail "background mode uses the cached value now: $ERR"
for _ in $(seq 1 50); do grep -q '"1.19.2"' "$CACHE" && break; sleep 0.1; done
grep -q '"1.19.2"' "$CACHE" || fail 'background refresh updated the cache'
export WECHAT_USE_UPDATE_CHECK_SYNC=1
echo v1.19.1 >"$FAKE_LATEST_FILE"
echo 'PASS: stale cache refreshed in the background without delaying the command'

# ---------- up to date: no notice ----------
echo 1.19.1 >"$FAKE_VERSION_FILE"
printf '{"checked_at": %s, "latest": "1.19.1"}\n' "$(date +%s)" >"$CACHE"
run sessions
[[ -z "$ERR" ]] || fail "no notice when current: $ERR"
echo 1.18.12 >"$FAKE_VERSION_FILE"

# ---------- opt-outs and skipped invocations ----------
rm -f "$CACHE"
for var in CI WECHAT_USE_NO_UPDATE_CHECK USE_NO_UPDATE_CHECK; do
  before=$(api_calls)
  env "$var=1" "$INSTALL_DIR/wechat-use" sessions >"$TEST_ROOT/out" 2>"$TEST_ROOT/err" || true
  [[ ! -s "$TEST_ROOT/err" && "$(api_calls)" == "$before" && ! -f "$CACHE" ]] || fail "$var must disable check and notice"
done
printf '{"checked_at": %s, "latest": "1.19.1"}\n' $((now - 90000)) >"$CACHE"
for args in '--version' '-V' '--help' '-h' 'help' 'send --help' 'update-guard -h'; do
  before=$(api_calls)
  # shellcheck disable=SC2086
  run $args
  [[ -z "$ERR" && "$(api_calls)" == "$before" ]] || fail "no check/notice for: $args ($ERR)"
done
echo 'PASS: CI / WECHAT_USE_NO_UPDATE_CHECK / USE_NO_UPDATE_CHECK and --version/--help skip the check'

# update-guard is WeChat's own updater lock: passed through untouched.
run update-guard status
[[ "$OUT" == 'binary:update-guard status' && "$STATUS" == 7 ]] || fail 'update-guard must reach the binary'

# ---------- help lists upgrade (the family upgrade script greps for it) ----------
run --help
[[ "$OUT" == *$'Commands:\n  upgrade '* && "$OUT" == *update-guard* ]] || fail "help must list upgrade: $OUT"
echo 'PASS: update-guard passes through; --help lists upgrade'

# ---------- upgrade --check / --json ----------
: >"$FAKE_LOG"
run upgrade --check
[[ "$STATUS" == 0 && "$OUT" == 'wechat-use 1.18.12 -> 1.19.1' ]] || fail "check: $STATUS $OUT"
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.18.12 ]] || fail '--check must change nothing'
! grep -q installer "$FAKE_LOG" || fail '--check must not run the installer'
echo 1.19.1 >"$FAKE_VERSION_FILE"
run upgrade --check
[[ "$OUT" == 'wechat-use 1.19.1 is up to date' ]] || fail "up to date: $OUT"
echo 1.18.12 >"$FAKE_VERSION_FILE"
GITHUB_TOKEN=tok-placeholder run upgrade --check
grep -q 'Authorization: Bearer tok-placeholder' "$FAKE_LOG" || fail 'GITHUB_TOKEN honoured'

# Skill channels: plugin, git checkout (via symlink), installer-managed copy, duplicate symlink.
mkdir -p "$HOME/.claude/plugins" "$HOME/.agents/use-family" "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.claude/skills"
printf '{"version": 2, "plugins": {"wechat-use@leeguooooo-plugins": [{"installPath": "x"}]}}\n' >"$HOME/.claude/plugins/installed_plugins.json"
# A local "remote" so `git pull --ff-only` works offline.
git init -q "$TEST_ROOT/skill-src"
touch "$TEST_ROOT/skill-src/SKILL.md"
git -C "$TEST_ROOT/skill-src" add SKILL.md
git -C "$TEST_ROOT/skill-src" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q "$TEST_ROOT/skill-src" "$HOME/.agents/use-family/wechat-use"
ln -s "$HOME/.agents/use-family/wechat-use" "$HOME/.claude/skills/wechat-use"
mkdir -p "$HOME/.agents/skills/wechat-use"; touch "$HOME/.agents/skills/wechat-use/SKILL.md"
ln -s "$HOME/.agents/skills/wechat-use" "$HOME/.codex/skills/wechat-use"
run upgrade --json
[[ "$STATUS" == 0 && -z "$ERR" ]] || fail "json: $STATUS $ERR"
python3 - "$TEST_ROOT/out" "$HOME" <<'EOF' || fail "json shape: $OUT"
import json, os, sys
d = json.load(open(sys.argv[1]))
home = os.path.realpath(sys.argv[2])
assert list(d) == ["name", "current", "latest", "update_available", "skills"], list(d)
assert d["name"] == "wechat-use" and d["current"] == "1.18.12" and d["latest"] == "1.19.1"
assert d["update_available"] is True
by = {s["channel"]: s for s in d["skills"]}
assert len(d["skills"]) == 3, d["skills"]  # the ~/.codex symlink duplicates ~/.agents
assert all(set(s) == {"channel", "path", "update"} for s in d["skills"])
assert by["claude-plugin"]["update"] == "claude plugin update wechat-use@leeguooooo-plugins"
assert os.path.realpath(by["git"]["path"]) == home + "/.agents/use-family/wechat-use"
assert by["git"]["update"].endswith("pull --ff-only")
assert os.path.realpath(by["installer"]["path"]) == home + "/.agents/skills/wechat-use"
assert by["installer"]["update"] == "wechat-use upgrade"
EOF
echo 1.19.1 >"$FAKE_VERSION_FILE"
run upgrade --json
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["update_available"] is False' "$TEST_ROOT/out" || fail 'update_available false'
echo 1.18.12 >"$FAKE_VERSION_FILE"
echo 'PASS: upgrade --check / --json shape, skill channels detected and de-duplicated'

# A skill folder inside an enclosing repo (dotfiles $HOME) is not treated as a checkout.
(
  export HOME="$TEST_ROOT/home2"
  mkdir -p "$HOME/.agents/skills/wechat-use"; touch "$HOME/.agents/skills/wechat-use/SKILL.md"
  git init -q "$HOME"
  export WECHAT_USE_LAUNCHER_LIB_ONLY=1
  # shellcheck source=../scripts/wechat-use
  source "$LAUNCHER_SRC"
  wu_discover_skills
  [[ "${#WU_SKILLS[@]}" == 1 && "${WU_SKILLS[0]%%$'\t'*}" == installer ]] || fail "enclosing repo: ${WU_SKILLS[*]}"
)
echo 'PASS: enclosing git repo is never pulled'

# ---------- network failure: exit 2 ----------
FAKE_NET=down run upgrade --check
[[ "$STATUS" == 2 && -z "$OUT" && "$ERR" == *'could not read the latest release'* ]] || fail "exit 2 on network failure: $STATUS"
FAKE_NET=down run upgrade --json
[[ "$STATUS" == 2 && -z "$OUT" ]] || fail 'json exit 2, nothing on stdout'
run upgrade --bogus
[[ "$STATUS" == 2 ]] || fail 'unknown option'
echo 'PASS: exit 2 when the check fails'

# ---------- real upgrade (fake installer) ----------
: >"$FAKE_LOG"
run upgrade
[[ "$STATUS" == 0 ]] || fail "upgrade exit $STATUS: $ERR"
grep -Fqx "installer INSTALL_DIR=$INSTALL_DIR PREFER_419=yes INSTALL_SKILL=yes" "$FAKE_LOG" || fail "installer env: $(cat "$FAKE_LOG")"
[[ "$OUT" == *'wechat-use 1.18.12 -> 1.19.1'* ]] || fail "prints what changed: $OUT"
grep -Fqx 'claude plugin update wechat-use@leeguooooo-plugins' "$FAKE_LOG" || fail 'plugin refreshed'
[[ "$OUT" == *'skill (installer):'*'refreshed by the installer'* ]] || fail "installer skill reported: $OUT"
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.19.1 ]] || fail 'binary upgraded'
[[ "$OUT" == *'skill (git):'*'updated'* ]] || fail "git skill pulled: $OUT"
# Already current: installer not run.
: >"$FAKE_LOG"
run upgrade
[[ "$STATUS" == 0 && "$OUT" == *'is up to date'* ]] || fail 'already current'
[[ "$OUT" == *'skill (installer):'*'not refreshed (CLI already current)'* && "$OUT" != *'refreshed by the installer'* ]] || fail "no false refresh claim: $OUT"
! grep -q '^installer' "$FAKE_LOG" || fail 'installer must not run when current'
# A skill that cannot be refreshed (diverged checkout) is reported and exits 1, not forced.
git -C "$HOME/.agents/use-family/wechat-use" remote set-url origin "$TEST_ROOT/missing-remote"
run upgrade
[[ "$STATUS" == 1 && "$ERR" == *'not updated'*'not forcing'* ]] || fail "skill refresh failure: $STATUS $ERR"
git -C "$HOME/.agents/use-family/wechat-use" remote set-url origin "$TEST_ROOT/skill-src"
# No installer-managed skill: the installer is told not to install one.
rm -rf "$HOME/.agents/skills/wechat-use" "$HOME/.codex/skills/wechat-use"
echo 1.18.12 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
run upgrade
grep -q 'INSTALL_SKILL=no' "$FAKE_LOG" || fail 'no skill -> INSTALL_SKILL=no'
# Installer failure: exit 1, clear message.
echo 1.18.12 >"$FAKE_VERSION_FILE"
FAKE_INSTALLER_FAIL=1 run upgrade
[[ "$STATUS" == 1 && "$ERR" == *'installer stopped (exit 5)'* ]] || fail "installer failure: $STATUS $ERR"
echo 'PASS: upgrade runs the installer non-interactively, refreshes skills, reports the change'

echo 'PASS: wechat-use launcher'
