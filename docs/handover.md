# Handover — yabridge isolated test infra

Snapshot: **2026-08-29 ~18:00 CEST**. Continue from this file, not the prior
chat. Isolation for Bitwig and the XLN installer is **closed**. The first
public report path is **implemented on both trees, committed on neither,
deployed nowhere**.

| Area | Status |
|---|---|
| Isolated Bitwig + XLN authorize on clone | Closed |
| Harness sanitizer + `submit --session` | In staging tree, tests green, not committed |
| Site: 1.1.0 fields, path drop, Save-then-Publish editor | In results tree, 1489 tests green, not committed |
| Live Fly | **Still old code**: one-shot publish, 422 on 1.1.0 payloads |
| Commit / push / `fly deploy` / live POST | Do not do unless Sebastian asks |

## Hard rules

- Never `--fresh` or delete `prefix-copy/`.
- Never write the production Wine prefix. The host bind is read-only; installer
  writes stay on the clone.
- Do not nest Firejail and bwrap.
- Do not commit or push unless Sebastian asks.
- Never put home paths, pasta MAC, LAN IP, ComputerId, or XLN email in the
  public repo. Concrete identity lives in gitignored **`run-state/identity.env`**
  (`XLN_MAC`, `XLN_NIC`, `XLN_ADDR`, `XLN_ACCOUNT`, `BITWIG_PROJECTS`).
  `source run-state/identity.env` before any daw-env command below.

## What this is

Isolated test infrastructure for **yabridge git master** plus a pinned,
digest-verified Kron4ek wine-staging build. `daw-env.sh` launches a native DAW
against a copy-on-write clone of the operator prefix inside Bubblewrap.
Production yabridge and Wine stay on the last known-good daily stack.

- Public git origin: <https://github.com/derEremit/yabridge-testing.git>
- README / `install.sh` still say `yabridge-staging` — that name mismatch is
  real and unfixed (unknown whether the rename is intentional).
- Results site: private tree `~/projects/yabridge-results` (GitLab
  `z3nlabs/yabridge-test-feedback`), Fly app `yabridge-tests` at
  <https://yabridge-tests.fly.dev>.

### Two trees

**Staging** (`~/projects/yabridge-staging`) — public-intended harness, probe,
`daw-env.sh`. HEAD `38f91ee`. Uncommitted: isolation diff (~+3650/−300 over
18 files) plus untracked `lib/wine-wait.sh`, `lib/mac-netns-exec.sh`,
`docs/harness-site-data.md`, `docs/xln-isolated-installer.md`, this file;
first-report work: `test-harness/src/yabridge_test/sanitize.py`,
`session_report.py`, CLI `--session` / `--notes` / `--dry-run`, schema
additions, `tests/test_sanitize.py`, `tests/test_session_submit.py`.

**Results** (`~/projects/yabridge-results`) — FastAPI, Alembic, Fly. HEAD
`63b5d8f`. Uncommitted: `fly.toml` (`PRODUCTION`, `PUBLIC_BASE_URL`,
`TRUST_FLY_CLIENT_IP`), `app/models.py`, `app/schemas.py`,
`app/routes/drafts.py`, `app/routes/results.py`, `app/main.py`,
`app/templates/complete.html`, `app/static/js/complete.js`, four test files
touched, new `alembic/versions/0003_report_1_1_0.py` and
`tests/test_draft_editing.py`.

## How to run the checks (both trees)

```bash
# staging harness — venv needs dev deps once
cd test-harness && uv pip install --python .venv/bin/python -e '.[dev]'
.venv/bin/python -m pytest -q          # baseline: 18 failures, all pre-existing at HEAD (env-bound probe tests)
.venv/bin/python -m ruff check src tests && .venv/bin/python -m mypy src
cd .. && bats tests/                   # 360 tests, 0 failures
./test.sh submit --session --dry-run   # stdout is pure JSON (banner goes to stderr)

# results site
cd ~/projects/yabridge-results && uv venv .venv && uv pip install --python .venv/bin/python -r requirements.txt -r requirements-dev.txt
.venv/bin/python -m pytest -q          # 1489 passed
.venv/bin/python -m ruff check app tests && .venv/bin/python -m mypy app
```

Baseline pytest failures on staging are `test_probe_host` / probe-transport
tests that need a display or Wine; the number to compare against is **18**.
Anything above that is new.

## Closed loop (2026-08-28 / 29)

Recorded in `docs/xln-isolated-installer.md`, the `daw-env.sh` header,
gitignored `run-state/last-run-notes.md`. Do not start the next session from
zero.

| When | What happened | Evidence |
|---|---|---|
| 28th ~21:42 | Isolated Bitwig on real settings + 197 clone bridges. Pasta identity. AD2 still WRONG COMPUTER ID. | Transcript + earlier manifest `19:42Z` |
| 29th ~01:54 | XLN Cotton installer **4.7.3** on the clone reached Installation Finished / Everything is up to date after two in-app restarts in one sandbox. | `docs/xln-isolated-installer.md` + last-run-notes |
| 29th ~02:00 | Same clone + pasta identity. Bitwig relaunch: Addictive Drums 2 authorized. | Notes + README status. Manifest `generated_at` `00:00:05Z` |
| Stacks | Daily known-good that did **not** need the extra first click: yabridge **5.1.1** + Wine **9.21**. Probe stack: master **b580a9f** + Wine **11.16** Staging. | `build/component-state.env` + `run-state/run-manifest.json` |

Pasta is still userspace NAT, not Firejail macvlan. Not a blocker for this
authorize.

Live identities (not guessed):

- yabridge master `b580a9f7fc46509767ca156d4f92872552b9e571`
- Wine `wine-11.16 (Staging)`, Kron4ek digest-verified
  (`WINE_SHA256_VERIFIED=true` in `build/component-state.env`)

## XLN failure ladder

High level only. Full table, clone path map, and “what not to click” live in
[`docs/xln-isolated-installer.md`](xln-isolated-installer.md).

| Symptom | What daw-env does now |
|---|---|
| curl error 77 / missing `cacert.pem` | Restore + file-only `--ro-bind` of gitignored `run-state` CA cache |
| Lua disk-space / `remove_all` Access denied | Stage `launchCopy` so the running image is not the file Cotton deletes |
| Wrong resources / version 404 | Sync clone Program Files + App version from `updateBinary` |
| Updater quits, window gone | `lib/wine-wait.sh` — `wineserver -w` so bwrap survives `ShellExecute` |

Launch-path rule (`lib/sandbox.sh` `sandbox_stage_xln_updatebinary_launch_copy`):
once the clone's Program Files exe **matches** `updateBinary`, daw-env launches
Program Files, not launchCopy. launchCopy is only the bootstrapper for the
first pass. A stale bats test that asserted "always launchCopy" was removed on
the 29th; `sandbox launches the synced Program Files installer instead of
launchCopy` is the test that encodes the real rule.

## Remaining product bug

After AD2 authorized, the **first click** in a plugin UI only focuses. Later
clicks land on the correct control. That is **not** the
[yabridge #409](https://github.com/robbert-vdh/yabridge/issues/409)
coordinate-offset miss (that one mis-hits every click).

Comment on **#409 only**. Robbert asked Wine 10+ embedding reports to stay
there. Speak in yabridge terms: Bitwig, master `b580a9f`, Kron4ek Wine 11.16
Staging, Wayland / XWayland. Do **not** mention this project’s launcher names
upstream. Whether the drafted comment was posted is unverified. Plugin names
are still for Sebastian to fill.

## Site product — one workflow

Collect → sanitize (no home paths) → `POST /api/v1/drafts` → print secret
`/complete/{token}` → human **Saves** as often as needed (private, link stays
live) → **Publish** (public, link retired). The site never pulls a checkout.
The harness never POSTs `/api/v1/results`. Public CI does not submit.

Contract: [`docs/harness-site-data.md`](harness-site-data.md). Additive schema
**1.1.0**: top-level `session_type`, `regression`; environment
`wine_prefix_kind`, `wine_digest_verified`, `wine_sha256`. Path fields
`environment.wine_prefix` / `plugin.path` are still *accepted* from old clients
but never stored or served.

Verified offline on the 29th: `./test.sh submit --session --dry-run` output
validates against the results tree's `DraftSubmission` (`session_type=
isolated-daw`, `wine_prefix_kind=isolated`, digest verified) and contains no
home path, MAC, LAN IP, email, or ComputerId.

### What changed in the results tree (uncommitted)

- `CompletionFormData.publish: bool = False`. POST `/api/v1/complete/{token}`
  without it saves answers, replaces the tested-plugin set, keeps
  `publication_status=draft` and the token, returns the same `/complete/…` URL.
  With `publish: true` it publishes and spends the token (all previous
  single-use / racing guarantees hold for publish).
- GET `/api/v1/complete/{token}` and the HTML page return `saved` answers; the
  form prefills them and has **Save (keep private)** and **Publish** buttons.
  Refusal copy no longer says the link "works once".
- `TestResultEnvironment` gained the five 1.1.0 columns
  (`alembic/versions/0003_report_1_1_0.py`). `apply_schema()` runs
  `upgrade head` at app start, so a deploy migrates itself.
- `wine_prefix` is stored as `None`; `to_dict`, `/api/v1/results`, and the
  complete page never emit it.

### Deploy sequence when Sebastian asks

1. Commit the results tree (`fly.toml` env vars are part of it).
2. `fly deploy` from `~/projects/yabridge-results`. Confirm
   `GET /complete/<any token>` page shows both buttons.
3. Then, and only then, `./test.sh submit --session` from staging, open the
   printed URL, Save, edit, Publish.

Until step 2 is live: `POST /api/v1/drafts` on Fly **422s** on the 1.1.0
payload, and a completion POST publishes immediately.

## Relaunch — generic flags only

```bash
source run-state/identity.env
```

**XLN installer.** Pass the Cotton `updateBinary` Windows path. daw-env
rewrites it (cacert pin, launchCopy / Program Files prefer, wine-wait). Do
not launch the Program Files exe yourself. Do not pass daily Firejail as
the parent. Two installer restarts inside one sandbox are success.

```bash
./daw-env.sh --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  "$PWD/build/wine/bin/wine" \
  "C:\\ProgramData\\XLN Audio\\Temp\\App\\Cotton XLN Online Installer\\updateBinary\\XLN Online Installer.exe"
```

**Bitwig.** Same identity flags. Omit `--refresh-bridges` if isolated
bridges are already generated. Omit `--fresh` unless Sebastian explicitly
wants a new clone (that drops license state).

```bash
./daw-env.sh --refresh-bridges --mac "$XLN_MAC" --nic "$XLN_NIC" --address "$XLN_ADDR" \
  --writable-path "$(realpath -- "$BITWIG_PROJECTS")" \
  bitwig-studio
```

## Open risks

| Risk | Why it matters | Owner |
|---|---|---|
| Live Fly is behind two trees | 422 on submit; first complete click publishes | Commit + `fly deploy` when asked |
| Two-repo ownership | Public GitHub testing repo vs private GitLab results. Do not mix remotes | Sebastian |
| Secrets in public tree | Scrubbed on the 29th from README, `docs/xln-isolated-installer.md`, `daw-env.sh`, `lib/sandbox.sh` defaults, bats fixtures (fixtures now use `02:00:5e:00:53:01` / `192.0.2.132`). Re-grep before any commit for every value in `run-state/identity.env` plus `/home/<user>`; the result must be empty | Whoever commits |
| README clone URL | `yabridge-staging` vs origin `yabridge-testing` | Sebastian |
| `.index.yaml` says `publish-ready` | True only after the secrets grep above is empty at commit time | Whoever commits |

## Could not verify

- Whether live Fly already has the dirty `fly.toml` env vars.
- Whether the drafted #409 comment was posted.
- Exact plugin list for the first-click note.
- Whether pasta vs Firejail L2 will bite a later XLN run.
- Whether the README clone-URL mismatch is an intentional rename.
- The new complete-page JS in a real browser (covered by server-side tests
  only; `complete.js` Save/Publish path is untested by JS unit tests).

This pass did not commit, deploy, or POST a live report. It did install dev
deps into both `.venv`s.
