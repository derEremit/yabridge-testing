# Yabridge staging remediation design

Date: 2026-08-25

## Goal

Turn the local staging workspace into a reproducible, testable environment that
can exercise current yabridge and Wine builds without modifying production
plugin files, while hardening the associated test harness, results service, and
VM provisioning.

## Repository boundaries

The root repository owns the local orchestration:

- `setup.sh`
- `daw-env.sh`
- generated-environment policy
- root documentation, tests, and lock metadata

`yabridge-test-infra` remains an independent repository and is referenced as a
Git submodule. Changes to its harness, web service, CI, Packer, and Ansible
files are committed in that repository first; the root repository then records
the updated submodule commit.

Downloaded Wine builds, the upstream yabridge checkout, compiled binaries,
Wine prefixes, generated wrappers, editor metadata, and machine-specific audit
logs remain untracked.

## Isolation model

The current COW prefix protects writes addressed through `WINEPREFIX`, but the
existing chainloaders still target Windows plugin files under the production
prefix. Wine can access those paths through its Unix filesystem mapping, so a
plugin can write beside its own module.

The hardened launcher will:

1. Create or refresh a COW clone of the source Wine prefix.
2. Discover the Windows plugin targets used by the selected bridge set.
3. Require every target used for the test run to resolve inside the clone.
4. Generate a separate Linux bridge directory for those cloned targets.
5. Launch the DAW inside Bubblewrap with production plugin and prefix paths
   mounted read-only, while the clone and test-output paths remain writable.
6. Refuse to launch when Bubblewrap, target provenance, clone provenance, or
   mount protections cannot be established.

The production yabridge bridge directories will not be used by isolated runs.
The launcher will record clone source, source identity, yabridge commit, Wine
version, and bridge directory in machine-readable state.

## Remediation phases

### 1. Root orchestration and isolation

- Add fixture-based shell tests before changing launcher behavior.
- Make requested Wine versions and yabridge revisions override cached output.
- Install and verify the test harness during setup.
- Bind cached clones to their canonical source prefix.
- Implement cloned plugin targets, a dedicated bridge set, and Bubblewrap.
- Verify downloaded artifacts using pinned SHA-256 values.
- Emit revision and environment state for every run.
- Preserve useful Wine diagnostics by default and offer an explicit quiet mode.

### 2. Harness correctness

- Create a conventional pytest suite and make zero collection a failure.
- Return failure for both `FAIL` and `ERROR` results.
- Resolve bridge paths from yabridge configuration/status rather than assuming
  a `.so` beside the Windows plugin.
- Record the exact yabridge commit and branch from the staging environment.
- Classify Wayland sessions separately from XWayland availability.
- Replace the global-pointer mouse check with a deterministic bridged test
  plugin that reports coordinates received by its Wine child window.

### 3. Web and API security

- Replace autocomplete `innerHTML` and inline event handlers with safe DOM
  construction.
- Bound all text, list, log, screenshot, and request-body sizes.
- Protect public writes with authentication or bot protection, per-client rate
  limits, quotas, and moderation.
- Add a restrictive Content Security Policy.
- Eager-load async SQLAlchemy relationships used during serialization.
- Add integration tests for malicious autocomplete values, oversized payloads,
  anonymous abuse, and populated result pages.

### 4. Data lifecycle and performance

- Define one publication-state policy for direct submissions, drafts, public
  reads, matrix queries, and statistics.
- Exclude unpublished data from every public aggregate.
- Replace per-cell matrix queries with grouped aggregation.
- Add Alembic migrations for persistent database changes.
- Make health checks execute a real database query.

### 5. Provisioning and reproducibility

- Supply valid NoCloud `user-data` and `meta-data`.
- Replace missing Ansible includes and the obsolete CMake build with the
  supported Meson/cross-Wine flow.
- Remove known image passwords and unrestricted passwordless sudo before image
  publication.
- Pin Python dependencies, Docker images, GitHub Actions, Packer, Wine assets,
  and plugin installers to reviewed immutable versions and hashes.
- Expand CI path coverage to the harness, web service, Ansible, and Packer.

### 6. Hygiene and documentation

- Make ShellCheck, Ruff, mypy, pytest, and safe integration checks pass.
- Make help paths exit successfully and validate missing option arguments.
- Correct repository URLs, unsupported command examples, and overstated safety
  claims.
- Document residual risks and the boundary between upstream yabridge and local
  orchestration.

## Testing strategy

Behavior changes follow red-green-refactor:

- Shell behavior is tested against temporary fixture trees with fake Wine,
  Git, Meson, Ninja, yabridgectl, Bubblewrap, and DAW executables.
- Python units test parsers and result aggregation without desktop access.
- Web integration tests use a temporary database and assert status, persistence,
  escaping, authorization, rate limiting, and query behavior.
- Provisioning receives static validation plus a headless smoke build where the
  environment supports KVM/QEMU.
- No test may read from or write to the production Wine prefix except through
  an explicitly read-only fixture boundary.

## Commit strategy

The initial root commit records the pre-remediation baseline. Each remediation
phase is split into reviewable commits that contain its tests and implementation
together. Changes in `yabridge-test-infra` are committed there before the root
submodule pointer is updated. Upstream `build/yabridge-src` is never modified by
this project.

No remote is created and nothing is pushed unless explicitly requested.

## Completion criteria

- An isolated DAW run cannot write to the production prefix or plugin files.
- Requested Wine/yabridge revisions are the revisions actually executed and
  are recorded in the report.
- Harness and web suites collect meaningful tests and pass without warnings.
- Test errors produce nonzero CLI exits.
- Stored HTML cannot execute through autocomplete.
- Anonymous clients cannot create unbounded data.
- Public aggregates contain only published results.
- VM definitions validate and complete a headless provisioning smoke test.
- Root and submodule working trees are clean after their final commits.
