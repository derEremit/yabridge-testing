# Harness ↔ results site data contract

Date: 2026-08-29

How the public test tree (`yabridge-staging`) and the private results
server (`https://yabridge-tests.fly.dev`) share data. Isolation runbooks,
license-identity tricks, and machine-local paths stay off this repository
and off the public API.

This is the contract to implement against. It is not a changelog of today's
wire format.

## Goal

One workflow. That is all that is needed:

1. Collect system or harness data (CLI or harness).
2. Sanitize it (no home paths).
3. POST a draft.
4. Print the edit URL.
5. A human opens that URL and edits notes, plugins, and the verdict on
   the site.

The site is a collector. The harness always pushes. The site never pulls
a checkout, a `run-manifest.json`, or a git remote of results.

There is no second publication path. The harness does **not** POST
`/api/v1/results`, does **not** auto-publish with an API key, and does
**not** treat `auto_submit` as a reason to skip the edit link.

## What is shared

These fields are the public compatibility record. They are what the
matrix, result list, and issue feedback are for.

| Field | Why it is public |
|---|---|
| `distro`, `kernel`, `desktop`, `desktop_version`, `compositor` | Host class |
| `display_server`, `xwayland_available` | Session class that changes Wine embedding |
| `wine_version`, `wine_staging`, `wine_variant`, `wine_patches`, `wine_dpi` | The Wine identity under test |
| `wine_digest_verified`, `wine_sha256` (Kron4ek archive) | Setup provenance; the digest is already a public release fact |
| `yabridge_version`, `yabridge_commit`, `yabridge_branch` | Bridge identity |
| `dpi_scale`, monitor **geometry** (width/height/position/scale/primary) | Display class |
| `cpu`, `gpu`, `gpu_driver`, `ram_gb` | Hardware class |
| `host`, `host_version` | DAW name and version, not its install path |
| plugin `name`, `type`, `vendor`, `version` | Plugin identity, not its file path |
| each test `name`, `result`, `details`, `duration_ms` | Probe / suite verdicts |
| probe `measurements` that are coordinates, classifications, assertions, sample counts, tolerance | The measured bug |
| `workarounds`, `notes` | First-click / human observations the site was built to collect |
| `overall_result` (`working` / `partial` / `broken`) | Human rollup when present |
| `regression` (`true` / `false` / omitted) | “this used to work” |
| `session_type` | How the data was produced (below) |
| `wine_prefix_kind` | Class of prefix, never the path |
| optional `submitter` | Display name only, and only if the local identity file sets it |

`session_type` values: `probe`, `suite`, `plugin`, `isolated-daw`,
`web-manual`. Add `ci` later only if public Actions is explicitly opted
into production submit (default: it is not).

`wine_prefix_kind` values: `temp-probe`, `isolated`, `clone`,
`production`, `unknown`. Derived locally from env / staging layout, not
from a path string on the wire.

## What is never shared

Strip these in the harness before HTTP. The site refuses or drops them
if they still arrive.

| Datum | Why |
|---|---|
| Absolute home or project paths | Identifies the operator and the tree |
| `environment.wine_prefix` as a path | Same |
| `plugin.path` | Same |
| `run-manifest.json` path fields (`clone_path`, `source_path`, `bridge_roots`, `bridge_home`, executables) | Local provenance only |
| `measurements.yabridge.library` as a path | Replace with `sha256` + `mode` + `version` |
| `measurements.yabridge_log_tail` and free-form `logs` that still contain `/home/…` | Logs are local; public logs must be path-redacted or omitted |
| MAC, NIC name, guest IPv4, ComputerId, installer account / email | License-identity and operator runbooks |
| `submitter_contact` unless the identity file sets `share_contact=true` | Default off; public `to_dict` never echoes it |
| Screenshots of a personal desktop | Optional; anonymous drafts only, reviewed at completion |

Do not publish an unsalted hash of a prefix path. Common staging layouts
are guessable. If two operator reports must be joinable, HMAC-SHA256 a
canonical path with a **local salt from the identity file**, and only
when that file sets `share_prefix_hmac=true`. Default: send kind only.

## How it flows

```
collect (info / probe / suite / isolated-daw notes)
    → sanitize (drop paths, redact logs, classify prefix)
    → write local report (gitignored)
    → POST /api/v1/drafts
    → print the /complete/{token} URL
    → human edits notes / plugins / verdict on that page
```

**Everyone** uses that path: a public clone of `./setup.sh` +
`./test.sh`, `install.sh`, and the operator machine. After `probe` /
`validate` / `suite` / `submit --session`, write a sanitized report,
POST a draft, print the URL. Completing (and later, re-editing) the
form is the human step. No API key. The live harness already POSTs
`/drafts` and prints `completion_url`; keep it that way.

**Isolated DAW sessions** do not produce probe rows. After a launch,
`yabridge-test submit --session` (or `./test.sh submit --session`)
builds a sanitized report from `collect_environment` + run-manifest
**scalars** (wine version, yabridge commit, digest-verified, DAW
basename) + optional notes file / `--notes`. `session_type` is
`isolated-daw`. Paths from the manifest are not copied. Same draft
URL.

**Public CI** (`.github/workflows/test-harness.yml`, `probe.yml`):
proves the harness and probe artifacts. It does **not** POST to the
live site. ubuntu-latest is not a DAW session and would pollute the
matrix. No site-pull job from the private repo into public Actions.

**Not this contract.** The site still has `POST /api/v1/results`
(publishes on accept) and `POST /api/v1/submit` (typed web form, no
harness). Do not wire the harness to either. An operator identity
file may still hold a display `submitter` and `share_contact`; it
must not grow `auto_submit` or an API key that publishes past the
edit URL. The site does not grow a “pull from GitHub” importer.

## What `/complete/{token}` does today

Accurate against the **live** results server (Fly) as of 2026-08-29.
The results working tree already implements the target lifecycle
below (“Gap”) but it is uncommitted and not deployed. Until it is
deployed, live behaves like this section.

`POST /api/v1/drafts` stores `publication_status=draft` and mints a
24-hour HMAC capability (`CLIENT_IDENTITY_SECRET`, default TTL
86 400 seconds). The response `completion_url` is
`{PUBLIC_BASE_URL}/complete/{token}`.

GET `/complete/{token}` (HTML) and GET `/api/v1/complete/{token}`
(JSON) open the form **only while** the token authenticates, is
unexpired, is still stored on the row, and that row is still
`draft`. The page shows environment (read-only) and lets the human
set overall result, host, plugins, issues, workarounds, and notes.

POST `/api/v1/complete/{token}` is a **one-shot publish**:

- writes those human fields
- sets `publication_status=published` and `completed_at`
- **spends the capability** (`completion_token` cleared in the same
  transaction)
- returns the public `/results?id=…` URL; the form JS navigates there

After that, the same URL is refused. Spent, unknown, and forged
tokens all answer 404 with one detail (`Draft not found or already
completed`). The HTML page says the link works once. Expiry is 410
with the same prose. There is no PATCH. Two browsers racing the
link produce one published report and one refusal. Moderation can
`publish` / `quarantine` / `reject`; it cannot send a row back to
`draft`.

So today’s complete URL is the **right surface** (secret link, human
fields) and the **wrong lifecycle** (publish once, then gone). It is
not yet “get a link and edit the report.”

## Gap: “edit the report” — implemented in the results tree, not deployed

Needed: the printed URL stays the editor. The human can return,
change notes / plugins / verdict, and only then decide the row is
public.

Status 2026-08-29: done in the `yabridge-results` working tree
(`CompletionFormData.publish`, default `false`; Save keeps the
draft and token, Publish spends the token; the page prefills saved
answers and has two buttons). Not committed, not on Fly.

**Smallest change that matches that** (site-side; not this repo):

1. Stop spending the token on save. The capability stays on the row
   for the rest of its TTL.
2. Treat the existing POST (or a PATCH of the same body) as an
   in-place update of the human fields. Leave `publication_status`
   as `draft`.
3. Add one explicit Publish control on that same page (second button
   or a `publish` flag on the same request). Publish does not need a
   new URL.

Until someone clicks Publish, the report stays off the matrix and
off public JSON. That is the intended “edit” story.

**Do not** choose published-but-editable as the first step. It is
fewer verbs (keep the token, allow POST after `published`), but the
first Submit still puts a half-filled report on the public list.
Save-then-publish on the existing secret URL is the smaller *product*
change even if it is one extra action.

Token TTL can stay 24 hours until someone asks for longer. Rotating
`CLIENT_IDENTITY_SECRET` still invalidates outstanding links.

## Schema / API

Bump `report_version` to `1.1.0`. Additive on the wire.

**Harness `TestReport` / site `SubmissionFields`:**

- Keep: environment class fields, host, plugin identity, tests, notes,
  workarounds, screenshots (draft path), optional `submitter`.
- Add: `session_type`, `regression` (optional bool),
  `wine_prefix_kind`, optional `wine_prefix_hmac`,
  `wine_digest_verified`, `wine_sha256`.
- 1.2.0 (2026-08-30): `environment.yabridge_repo` (git URL, or the
  literal `local` when setup built from a directory — never the path)
  and `environment.yabridge_patches` (SHA-256 of each patch applied,
  in order; empty when unpatched). A fork or patched build is now
  distinguishable from upstream in a published report.
- Stop sending: `environment.wine_prefix`, `plugin.path`.
- `submitter_contact` remains on the model, default omitted.

**Site persist / serialize:**

- Stop storing path `wine_prefix`. Keep the column unused or migrate it
  to `wine_prefix_kind` + optional hmac in a later Alembic revision.
  Until then, ignore incoming path values.
- `TestResult.to_dict()` and the completion HTML must not echo a prefix
  path or `submitter_contact`.
- Probe measurements: persist coordinates and `yabridge.sha256` /
  `mode` / `version`; drop `library` paths and `yabridge_log_tail` if
  present.
- Harness writes go to `/drafts` only. Do not require a key for
  contribution. The `submit` scope stays a quota / attribution
  upgrade, not a publication gate, and not a bypass of the edit URL.
- Moderation (`publish` / `quarantine` / `reject`) stays the kill
  switch when a note or screenshot still leaks.

**Draft completion today** publishes and burns the token. The new
work is (1) make the draft body safe **before** that click, and (2)
on the site, turn the complete URL into a real editor as above.

## What lives in which tree

**Public staging README and `docs/getting-started.md`:** generic
isolation, `./setup.sh` + digest, `./test.sh info|probe|suite`,
`yabridge-test submit` → print the edit URL. No concrete home paths,
no NIC identity, no installer account. One sentence: session-specific
operator notes stay in gitignored `run-state/` and are not this
repository.

**Public `docs/`:** this file, `getting-started.md`, `coord-probe.md`,
`test-protocol.md`. Generic `--mac` / `--writable-path` flag help may
live next to `daw-env.sh --help`. Worked examples that name a login
home, a LAN address, or a license id do not.

**Gitignored on the operator machine:** `run-state/` (manifest,
last-run notes, optional display-name identity), `env.sh`,
`prefix-copy/`, `isolation/`. That is the place for clone-only
installer ladders and ComputerId recovery. Not a second publish
channel.

**Private `yabridge-results`:** FastAPI, Alembic, Fly, moderation,
sanitizer-on-accept, publication policy, the complete-page editor.
Not a submodule of staging.

## Implementation sequence

1. Harness sanitizer + tests (path fixtures must not survive
   `model_dump` used for submit). Wire `submit` / `suite --submit` /
   `probe` optional `--submit` through it. Always `POST /drafts`.
2. Site: ignore/drop path fields; hide them from public JSON and
   completion HTML; accept `session_type` / `regression` /
   `wine_prefix_kind` (additive, extra still forbidden — declare them).
   **Done in the results working tree** (Alembic `0003_report_1_1_0`,
   applied automatically at app start). Not deployed.
3. Site editor gap (results repo): token stays valid; save keeps the
   row a draft; explicit publish on the same URL. Not required for
   the harness sanitizer to ship. **Done in the results working
   tree.** Not deployed.
4. `./test.sh submit --session` for isolated-DAW notes (scalars +
   notes only).
5. README / getting-started: submit-to-the-site, print the edit URL,
   no operator auto-publish runbook. Move concrete session notes into
   gitignored `run-state/`.

Do not teach public CI to submit. Do not add a site-side git pull.
Do not commit identity files, API keys, or `run-state/`.
Do not teach the harness `POST /api/v1/results`.
