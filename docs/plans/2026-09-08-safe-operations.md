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
- [ ] Run syntax checks and local regression tests; review diff and publish the existing fix branch.

## Verification

Run `python3 -m unittest discover -s tests -v` and `bash -n` on all shell scripts. Test database flag/probe failures, missing configuration with existing data, default/custom ports, corrupt archives and escaping symlinks, foreign Docker resources, failed health checks, archive selection, and preservation of user/node/config fixtures. Container integration tests must use an isolated disposable Docker project; never run install, restore, or uninstall against the developer workspace or a live VPS as a test.

Local environment has no Docker daemon. Container integration is supplied as an opt-in Linux test and must be reported separately from mocked regression coverage.
