# Catalog scan review (2026-10-19)

Source revision: `b87c25a436d5e7b422146cad8e2908dc95a3acc0`. With plugin-scanner 3.0.123, the local score was 77 before these changes and 89 after. These are local preflight results; listing still requires the catalog's own centralized score of at least 80.

## Changes

Only new workflow files reference GitHub Actions, and they are pinned to immutable SHAs. A vulnerability reporting policy and Dependabot are added, and a read-only, offline source scan runs on pushes and pull requests using the catalog's exact action SHA and score threshold. No scanner suppressions or baseline are configured, and no runtime code changed.

## Remaining findings

Every remaining `HARDCODED_SECRET` location is a synthetic test fixture or a documented development-only placeholder, not a live credential:

| Rule | Severity | Location | What it is |
| --- | --- | --- | --- |
| `HARDCODED_SECRET` | high | `examples/05-saas-orchestrate-template/tests/helpers.ts:339` | default `test-token` for a test auth header |
| `HARDCODED_SECRET` | high | `examples/05-saas-orchestrate-template/tests/inbound.test.ts:124` | `wrong-secret` used to assert a 401 signature mismatch |
| `HARDCODED_SECRET` | high | `examples/lib/bot-contract.test.mjs:18` | `fixture-key` in a stubbed environment |
| `HARDCODED_SECRET` | high | `examples/lib/gateway-options.mjs:13` | `local-development-only` placeholder, used only on loopback with `WECHATY_GATEWAY_DEV_INSECURE=1` |
| `HARDCODED_SECRET` | high | `sdk/node/bridge.test.mjs:12` | `test-token` passed to a fake fetch |

## Reproduction

```sh
# In an isolated Python environment:
python -m pip install plugin-scanner==3.0.123
plugin-scanner scan . --format json --output /tmp/scan.json --min-score 80 --fail-on-severity none
```
