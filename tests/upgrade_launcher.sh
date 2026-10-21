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
export REPO_ROOT
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
printf 'wechat %s\n' "$*" >>"$FAKE_LOG"
[[ "${1:-}" == setup ]] && exit 0
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
  https://api.github.com/repos/leeguooooo/wechat-use/releases/tags/v1.17.0|https://api.github.com/repos/leeguooooo/wechat-use/releases/tags/v1.19.1)
    printf '{\n  "tag_name": "%s"\n}\n' "${url##*/}" ;;
  https://raw.githubusercontent.com/leeguooooo/wechat-use/main/install.sh)
    cat >"$out" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
printf 'installer INSTALL_DIR=%s PREFER_419=%s INSTALL_SKILL=%s NO_TEST_MESSAGE=%s VERSION=%s\n' "$INSTALL_DIR" "$WECHAT_USE_PREFER_419" "$WECHAT_USE_INSTALL_SKILL" "${WECHAT_USE_NO_TEST_MESSAGE:-}" "${WECHAT_USE_VERSION:-}" >>"$FAKE_LOG"
[[ "${FAKE_INSTALLER_FAIL:-0}" == 1 ]] && exit 5
# Run the real installer's message-capable steps with every precondition met,
# so only WECHAT_USE_NO_TEST_MESSAGE stands between them and a send.
WECHAT_USE_INSTALL_LIB_ONLY=1 source "$REPO_ROOT/install.sh"
installer_subscription_state() { echo active; }
wechat_get_task_allow_state() { echo true; }
ps() { printf '%s\n' "$PREFERRED_WECHAT_TARGET/Contents/MacOS/WeChat"; }
mkdir -p "$HOME/.wx-rs/com_tencent_xinWeChat419WechatUse"
touch "$HOME/.wx-rs/com_tencent_xinWeChat419WechatUse/config.json"
maybe_smoke_send >/dev/null
run_setup_step
echo loaded >"$FAKE_BRIDGE_FILE"
if [[ "${FAKE_INSTALLER_NO_CHANGE:-0}" != 1 ]]; then
  if [[ -n "${WECHAT_USE_VERSION:-}" ]]; then echo "${WECHAT_USE_VERSION#v}" >"$FAKE_VERSION_FILE"
  else sed 's/^v//' "$FAKE_LATEST_FILE" >"$FAKE_VERSION_FILE"; fi
fi
INSTALLER
    ;;
  *) exit 22 ;;
esac
EOF
# Fake launchctl: the bridge LaunchAgent is "loaded" when $FAKE_BRIDGE_FILE says so.
export FAKE_BRIDGE_FILE="$TEST_ROOT/bridge"
echo loaded >"$FAKE_BRIDGE_FILE"
cat >"$TEST_ROOT/fake-bin/launchctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == print && "$(cat "$FAKE_BRIDGE_FILE")" == loaded ]]
EOF
chmod +x "$TEST_ROOT/fake-bin/launchctl"
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
assert list(d) == ["name", "current", "latest", "update_available", "install_channel", "skills"], list(d)
ic = d["install_channel"]
assert ic["channel"] == "installer" and ic["upgradable"] is True, ic
assert d["name"] == "wechat-use" and d["current"] == "1.18.12" and d["latest"] == "1.19.1"
assert d["update_available"] is True
by = {s["channel"]: s for s in d["skills"]}
assert len(d["skills"]) == 3, d["skills"]  # the ~/.codex symlink duplicates ~/.agents
assert all({"channel", "path", "update"} <= set(s) for s in d["skills"])
assert all(s["scope"] == "user" for s in d["skills"])
assert by["git"]["agent"] == "claude-code" and by["installer"]["agent"] == "agents", d["skills"]
assert by["installer"]["source"] == "leeguooooo/wechat-use"
assert by["claude-plugin"]["update"] == "claude plugin update wechat-use@leeguooooo-plugins"
assert os.path.realpath(by["git"]["path"]) == home + "/.agents/use-family/wechat-use"
assert by["git"]["update"].endswith("pull --ff-only")
assert os.path.realpath(by["installer"]["path"]) == home + "/.agents/skills/wechat-use"
assert by["installer"]["update"] == "npx -y skills add leeguooooo/wechat-use -y -g"
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
# Default: CLI only. Skills are listed, not touched; the installer is told not to copy one.
: >"$FAKE_LOG"
git_head_before=$(git -C "$HOME/.agents/use-family/wechat-use" rev-parse HEAD)
git -C "$TEST_ROOT/skill-src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m next
run upgrade
[[ "$STATUS" == 0 ]] || fail "upgrade exit $STATUS: $ERR"
grep -Fqx "installer INSTALL_DIR=$INSTALL_DIR PREFER_419=yes INSTALL_SKILL=no NO_TEST_MESSAGE=1 VERSION=" "$FAKE_LOG" || fail "installer env: $(cat "$FAKE_LOG")"
grep -Fqx 'wechat setup --skip-verify' "$FAKE_LOG" || fail "setup must run with --skip-verify: $(cat "$FAKE_LOG")"
! grep -q '^wechat send' "$FAKE_LOG" || fail "upgrade must never send: $(cat "$FAKE_LOG")"
[[ "$OUT" == *'wechat-use 1.18.12 -> 1.19.1'* ]] || fail "prints what changed: $OUT"
! grep -q '^claude ' "$FAKE_LOG" || fail 'default upgrade must not update the plugin'
[[ "$(git -C "$HOME/.agents/use-family/wechat-use" rev-parse HEAD)" == "$git_head_before" ]] || fail 'default upgrade must not pull the skill checkout'
[[ "$OUT" == *'skill (git, claude-code, user scope, from '*'not refreshed; pass --skills or update: git -C '* ]] || fail "git skill listed: $OUT"
[[ "$OUT" == *'skill (claude-plugin, claude-code, user scope, from wechat-use@leeguooooo-plugins)'*'update: claude plugin update wechat-use@leeguooooo-plugins'* ]] || fail "plugin listed: $OUT"
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.19.1 ]] || fail 'binary upgraded'
[[ "$OUT" != *'note: the background service'* ]] || fail 'no service note when it was already loaded'
echo 'PASS: default upgrade updates the CLI only and lists skill copies without touching them'

# --skills: CLI + this tool's own skill copies.
echo 1.18.12 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
run upgrade --skills
[[ "$STATUS" == 0 ]] || fail "upgrade --skills exit $STATUS: $ERR"
grep -q 'INSTALL_SKILL=yes NO_TEST_MESSAGE=1' "$FAKE_LOG" || fail "installer-managed skill re-copied: $(cat "$FAKE_LOG")"
grep -Fqx 'claude plugin update wechat-use@leeguooooo-plugins' "$FAKE_LOG" || fail 'plugin refreshed'
[[ "$OUT" == *'skill (installer, agents):'*'refreshed by the installer'* ]] || fail "installer skill reported: $OUT"
[[ "$OUT" == *'skill (git, claude-code):'*'updated'* ]] || fail "git skill pulled: $OUT"
[[ "$(git -C "$HOME/.agents/use-family/wechat-use" rev-parse HEAD)" != "$git_head_before" ]] || fail '--skills pulls the checkout'
# Already current + --skills: skill-only refresh, installer not run, no false claim.
: >"$FAKE_LOG"
run upgrade --skills
[[ "$STATUS" == 0 && "$OUT" == *'is up to date'* ]] || fail 'already current'
[[ "$OUT" == *'skill (installer, agents):'*'not refreshed (CLI already current); to re-copy only this skill: npx -y skills add leeguooooo/wechat-use -y -g'* && "$OUT" != *'refreshed by the installer'* ]] || fail "no false refresh claim: $OUT"
grep -Fqx 'claude plugin update wechat-use@leeguooooo-plugins' "$FAKE_LOG" || fail 'skill-only refresh still updates the plugin'
! grep -q '^installer' "$FAKE_LOG" || fail 'installer must not run when current'
# Already current without --skills: nothing refreshed at all.
: >"$FAKE_LOG"
run upgrade
[[ "$STATUS" == 0 && "$OUT" == *'is up to date'* && "$OUT" == *'not refreshed; pass --skills'* ]] || fail "current, no --skills: $OUT"
! grep -q '^claude \|^installer' "$FAKE_LOG" || fail 'current without --skills touches nothing'
# A skill that cannot be refreshed (diverged checkout) is reported and exits 1, not forced.
git -C "$HOME/.agents/use-family/wechat-use" remote set-url origin "$TEST_ROOT/missing-remote"
run upgrade --skills
[[ "$STATUS" == 1 && "$ERR" == *'not updated'*'not forcing'* ]] || fail "skill refresh failure: $STATUS $ERR"
git -C "$HOME/.agents/use-family/wechat-use" remote set-url origin "$TEST_ROOT/skill-src"
echo 'PASS: --skills refreshes plugin / checkout / installer copy; skill-only when current; failures exit 1'

# --skills without an installer-managed skill: the installer is told not to install one.
rm -rf "$HOME/.agents/skills/wechat-use" "$HOME/.codex/skills/wechat-use"
echo 1.18.12 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
run upgrade --skills
grep -q 'INSTALL_SKILL=no NO_TEST_MESSAGE=1' "$FAKE_LOG" || fail 'no skill -> INSTALL_SKILL=no'
! grep -q '^wechat send' "$FAKE_LOG" || fail 'upgrade must never send'

# ---------- --tag pins a release (and is the only way to downgrade) ----------
echo 1.18.12 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
run upgrade --tag v1.17.0 --check
[[ "$STATUS" == 0 && "$OUT" == 'wechat-use 1.18.12 -> 1.17.0'* ]] || fail "tag check: $STATUS $OUT"
run upgrade --json --tag=1.17.0
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["target"]=="1.17.0" and d["latest"]=="1.19.1", d' "$TEST_ROOT/out" || fail "tag json: $OUT"
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.18.12 ]] || fail 'tag --check changes nothing'
run upgrade --tag v1.17.0
[[ "$STATUS" == 0 && "$OUT" == *'wechat-use 1.18.12 -> 1.17.0'* ]] || fail "tag install: $STATUS $OUT $ERR"
grep -q 'VERSION=v1.17.0$' "$FAKE_LOG" || fail "installer pinned: $(cat "$FAKE_LOG")"
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.17.0 ]] || fail 'downgraded to the pin'
# Without --tag an older latest never downgrades.
echo 1.20.0 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
run upgrade
[[ "$STATUS" == 0 && "$OUT" == *'1.20.0 is up to date'* ]] || fail "no implicit downgrade: $OUT"
! grep -q '^installer' "$FAKE_LOG" || fail 'no implicit downgrade: installer ran'
# Same version as the pin: no-op.
echo 1.19.1 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
run upgrade --tag v1.19.1
[[ "$STATUS" == 0 && "$OUT" == *'is up to date'* ]] || fail "pin equal to current: $OUT"
! grep -q '^installer' "$FAKE_LOG" || fail 'pin equal to current is a no-op'
# Unknown or malformed tags fail the check (exit 2) and change nothing.
echo 1.18.12 >"$FAKE_VERSION_FILE"
run upgrade --tag v9.9.9
[[ "$STATUS" == 2 && "$ERR" == *'release v9.9.9 not found'* ]] || fail "missing tag: $STATUS $ERR"
run upgrade --tag latest
[[ "$STATUS" == 2 && "$ERR" == *'--tag must look like'* ]] || fail "bad tag: $STATUS $ERR"
run upgrade --tag
[[ "$STATUS" == 2 ]] || fail 'missing --tag value'
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.18.12 ]] || fail 'failed tag lookups change nothing'
# A pinned install that lands on another version is a failure.
FAKE_INSTALLER_NO_CHANGE=1 run upgrade --tag v1.17.0
[[ "$STATUS" == 1 && "$ERR" == *'expected 1.17.0'* ]] || fail "pinned version check: $STATUS $ERR"
echo 'PASS: --tag pins (check, json, install, downgrade); bad or missing tags exit 2'

# ---------- service state is reported when the installer changes it ----------
echo not-loaded >"$FAKE_BRIDGE_FILE"
echo 1.18.12 >"$FAKE_VERSION_FILE"
run upgrade
[[ "$STATUS" == 0 && "$OUT" == *'note: the background service (ai.wechat.bridge) was not loaded before the upgrade'*'launchctl bootout gui/'* ]] || fail "service note: $OUT"
echo 'PASS: a service the installer started is reported with the command to stop it'

# A zero exit from the installer is insufficient if the version did not change.
echo 1.18.12 >"$FAKE_VERSION_FILE"
FAKE_INSTALLER_NO_CHANGE=1 run upgrade
[[ "$STATUS" == 1 && "$ERR" == *'expected 1.19.1 or newer'* ]] || fail "unchanged version: $STATUS $ERR"
# Installer failure: exit 1, clear message.
echo 1.18.12 >"$FAKE_VERSION_FILE"
FAKE_INSTALLER_FAIL=1 run upgrade
[[ "$STATUS" == 1 && "$ERR" == *'installer stopped (exit 5)'* ]] || fail "installer failure: $STATUS $ERR"

# ---------- install channel: only an installer-managed CLI is replaced ----------
(
  export WECHAT_USE_LAUNCHER_LIB_ONLY=1
  # shellcheck source=../scripts/wechat-use
  source "$LAUNCHER_SRC"
  for case in "brew:$TEST_ROOT/opt/homebrew/Cellar/wechat-use/1.0.0/bin" "npm:$TEST_ROOT/lib/node_modules/wechat-use/bin" \
      "source:$TEST_ROOT/src/wechat-use/target/release" "unknown:$TEST_ROOT/elsewhere/bin"; do
    want=${case%%:*} dir=${case#*:}
    mkdir -p "$dir"; : >"$dir/wechat"
    WU_BIN="$dir/wechat"; wu_detect_channel
    [[ "$WU_CHANNEL" == "$want" ]] || fail "$dir: expected $want, got $WU_CHANNEL"
  done
  # A symlink into the Cellar is still Homebrew's.
  ln -sf "$TEST_ROOT/opt/homebrew/Cellar/wechat-use/1.0.0/bin/wechat" "$TEST_ROOT/elsewhere/bin/wechat-link"
  # shellcheck disable=SC2034  # read by wu_detect_channel
  WU_BIN="$TEST_ROOT/elsewhere/bin/wechat-link"; wu_detect_channel
  [[ "$WU_CHANNEL" == brew && "$WU_CHANNEL_HINT" == *'brew upgrade'* ]] || fail "symlink into Cellar: $WU_CHANNEL"
)
# The installed layout itself is installer-managed (covered by --json above);
# a launcher whose binary lives elsewhere refuses and leaves the binary alone.
mkdir -p "$TEST_ROOT/Cellar/wechat-use/1.0.0/bin"
cp "$INSTALL_DIR/wechat" "$TEST_ROOT/Cellar/wechat-use/1.0.0/bin/wechat"
echo 1.18.12 >"$FAKE_VERSION_FILE"; : >"$FAKE_LOG"
WECHAT_USE_BIN="$TEST_ROOT/Cellar/wechat-use/1.0.0/bin/wechat" run upgrade
[[ "$STATUS" == 1 && "$ERR" == *'not upgrading'*'brew upgrade wechat-use'* ]] || fail "brew refusal: $STATUS $ERR"
! grep -q '^installer' "$FAKE_LOG" || fail 'refusal must not run the installer'
[[ "$(cat "$FAKE_VERSION_FILE")" == 1.18.12 ]] || fail 'refusal changes nothing'
WECHAT_USE_BIN="$TEST_ROOT/Cellar/wechat-use/1.0.0/bin/wechat" run upgrade --json
python3 -c 'import json,sys; ic=json.load(open(sys.argv[1]))["install_channel"]; assert ic["channel"]=="brew" and ic["upgradable"] is False, ic' "$TEST_ROOT/out" || fail "brew json: $OUT"
WECHAT_USE_BIN="$TEST_ROOT/Cellar/wechat-use/1.0.0/bin/wechat" run upgrade --check
[[ "$STATUS" == 0 && "$OUT" == *'install: brew'* ]] || fail "brew check: $OUT"
echo 'PASS: install channel detection; Homebrew / npm / source / unknown installs are refused untouched'

echo 'PASS: upgrade runs the installer non-interactively and verifies the result'

echo 'PASS: wechat-use launcher'
