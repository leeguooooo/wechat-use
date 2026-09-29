#!/bin/sh
# Release wechat-use: roll docs/CHANGELOG.md's 未发布 section into v<version>, run the installer and SDK tests,
# push main, then hand off to the private repo's scripts/publish-release.sh (leak scan, sign + notarize, live
# preflight, draft release with the binaries + tarball + SHA256SUMS, download-verify, mark latest). Only after
# that does it sync the plugin marketplace, so Claude Code plugin installs never see a version without assets.
#   scripts/release.sh [--dry-run] 1.18.14 path/to/release-notes.md
# The binaries must already be built in the private repo (wx: cargo build --release --bins --features
# public_release, plus setup-ui). Set WECHAT_PRIVATE_DIR if it is not ../wechat-private-analysis-artifacts.
set -eu
run_ok() {  # run_ok <run-id> [-R owner/repo]: wait until the run completes (gh run watch can drop on a network error), then require success
  _r=$1; shift
  until [ "$(gh run view "$_r" "$@" --json status -q .status 2>/dev/null)" = completed ]; do gh run watch "$_r" "$@" >/dev/null 2>&1 || sleep 15; done
  [ "$(gh run view "$_r" "$@" --json conclusion -q .conclusion)" = success ]
}
DRY=; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
V=${1:?usage: scripts/release.sh [--dry-run] <version> <release-notes.md>}
V=${V#v}
NOTES=${2:-}
REPO=leeguooooo/wechat-use
MARKETPLACE=leeguooooo/plugins
cd "$(dirname "$0")/.."
PRIV=${WECHAT_PRIVATE_DIR:-$(cd .. && pwd)/wechat-private-analysis-artifacts}
die() { echo "error: $*" >&2; exit 1; }

echo "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version must look like 1.18.14"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "not on main"
[ -z "$(git status --porcelain)" ] || die "working tree not clean"
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin/main"
[ -z "$(git ls-remote --tags origin "refs/tags/v$V")" ] || die "v$V already exists"
if [ -z "$DRY" ]; then
  [ -f "$NOTES" ] || die "release notes file required (<= 8 non-blank lines, publish-release.sh enforces it)"
  NOTES=$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")
  [ -x "$PRIV/scripts/publish-release.sh" ] || die "no $PRIV/scripts/publish-release.sh (set WECHAT_PRIVATE_DIR)"
fi

trap 'git checkout -q -- docs/CHANGELOG.md' EXIT
sed -i.bak "s/^## 未发布\$/## v$V/" docs/CHANGELOG.md && rm docs/CHANGELOG.md.bak
bash -n install.sh && sh -n scripts/wechat-use
for t in tests/*.sh; do bash "$t" >/dev/null || die "$t failed"; done
node --experimental-vm-modules --test sdk/node/bridge.test.mjs examples/lib/*.test.mjs >/dev/null || die "node tests failed"
echo "checks passed"

if [ -n "$DRY" ]; then
  git --no-pager diff
  echo "dry run: reverted; nothing committed, pushed or published"
  exit 0
fi
trap - EXIT
if ! git diff --quiet; then git commit -qam "chore(release): 发布 $V"; fi
git push -q origin main
SHA=$(git rev-parse HEAD)

# publish-release.sh creates the tag on $SHA and publishes only once the uploaded assets verify.
(cd "$PRIV" && REPO=$REPO RELEASE_COMMIT=$SHA scripts/publish-release.sh "v$V" "$NOTES")
git fetch -q --tags origin

# The marketplace reads wechat-use's version from its latest release; run its sync now instead of the hourly cron.
gh workflow run auto-sync-versions.yml -R "$MARKETPLACE"
sleep 5
RUN=$(gh run list -R "$MARKETPLACE" -w auto-sync-versions.yml -e workflow_dispatch -L 1 --json databaseId -q '.[0].databaseId')
run_ok "$RUN" -R "$MARKETPLACE" && echo "marketplace synced" || echo "warn: marketplace sync run $RUN failed; the hourly run will retry"
gh api "repos/$MARKETPLACE/contents/.claude-plugin/marketplace.json" -q .content | base64 -d \
  | python3 -c "import json,sys; print('marketplace wechat-use:', next(p['version'] for p in json.load(sys.stdin)['plugins'] if p['name']=='wechat-use'))"
