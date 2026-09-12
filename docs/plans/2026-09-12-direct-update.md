# Direct Updates

User request: normal application updates must not create backups or be blocked by full-backup disk requirements.

Decision: menu 2 and `bash update.sh` perform direct updates, even when an older deploy.env has PRE_UPDATE_BACKUP=1. Retain an explicit `--with-backup` option for users who deliberately choose rollback protection. Do not silently fall back to direct updating after a requested backup fails.

Scope: keep manual backups, restore, repair and reconfiguration protections unchanged. Never delete existing backups. Keep configuration preservation, operation locking, pre/post readiness checks and business-row checks. The small temporary row/configuration comparison file is diagnostic metadata, not a recoverable backup.

Risk: direct updates can leave an incompatible image or migrated database after failure. No automatic recovery is claimed in this mode. Downloading images still requires free disk space; this change removes only full-backup disk requirements.

Verification: mock successful direct updates with legacy config, explicit backups, backup errors, migration errors, and healthcheck failures; confirm direct mode never calls backup/restore. Run the complete regression suite and isolated Docker smoke workflow, including a real direct update before an explicit backed-up failure/rollback test.
