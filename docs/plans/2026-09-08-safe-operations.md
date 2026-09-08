# Safe Operations Implementation Plan

**Goal:** Address all seven reviewed risks without rebuilding an existing database or changing credentials implicitly.

**Architecture:** Keep the Bash entry points and existing menu numbers. Use a small shared Bash adapter for Compose/locking and a standard-library Python module for structured Docker metadata, SQLite inspection, archive validation, and filesystem safety. Existing installations keep their configuration and data. Only an explicit fresh install may initialize a database.

**Tech Stack:** Bash, Python 3 standard library, Docker Compose v2, PHP/Laravel in the existing container.

## Design Decisions

- Prefer fail-closed repair over automatic database replacement. A failed probe is not proof of corruption. Repair runs on the installed image and backs up before migrations.
- Snapshot images and named volumes as well as bind-mounted project data. This costs disk space and maintenance downtime, but makes rollback and cross-server recovery reproducible.
- Validate checksums, archive members, Docker ownership, and destination paths before stopping services. Keep the previous project directory after restoration.
- Keep saved-password viewing as an explicit operation. Never reset a password just because a local plaintext copy is missing.
- Separate management-script updates from application updates. Both use the user's fork; updating scripts never invokes installation automatically on existing data.

## Implementation Checklist

- [x] Shared ownership, path, database, and archive helpers, with failure tests.
- [x] Full backup and transactional restore with exact images and named volumes.
- [x] Fail-closed install/repair/update, strict readiness checks, and operation locking.
- [x] Scoped uninstall with independent backup deletion confirmation.
- [x] Explicit password reset/show and numbered backup selection.
- [x] Fork defaults, script-only updates, migration instructions, and CI tests.
- [x] Run syntax checks and local regression tests; review diff and publish the existing fix branch.

## Verification

Run `python3 -m unittest discover -s tests -v` and `bash -n` on all shell scripts. Test database flag/probe failures, missing configuration with existing data, default/custom ports, corrupt archives and escaping symlinks, foreign Docker resources, failed health checks, archive selection, and preservation of user/node/config fixtures. Container integration tests must use an isolated disposable Docker project; never run install, restore, or uninstall against the developer workspace or a live VPS as a test.

The local Windows environment has no Docker daemon. Local Python/Bash verification passed all 50 regression tests. Real container verification ran on disposable GitHub-hosted Ubuntu runners, not on the user's VPS.

## Verified Results

Runtime commit: `f5b56427fbdb8579b105845955fbae2e286c531f`.

[Safety regression run 34178050730](https://github.com/sosoveooo-bit/xboard-one-click/actions/runs/34178050730) completed successfully on 2026-09-08:

- Regression: all 50 tests, including Bash syntax, database preservation, archive validation, credential behavior, and destructive-operation guards.
- Docker round trip: exact saved images after the candidate tag changed; preserved SQLite user/node/settings fixtures; restored named volumes without overwriting the previous volumes; scoped uninstall preserved an unrelated volume and the unselected backup.
- Xboard smoke: real Xboard/NPM installation, current-version repair, deliberately injected post-update failure, successful restoration, preserved database sentinel/admin, and final application readiness.

The final Xboard smoke job completed in 4m59s. This is a CI result, not a promised VPS runtime. Public DNS, cloud firewall rules, certificate issuance, external callbacks, and production business transactions remain deployment-specific checks.
