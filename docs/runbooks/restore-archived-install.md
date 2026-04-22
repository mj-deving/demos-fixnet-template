# Restore Archived Install

When `bootstrap_fixnet_host.sh` runs in `--reuse-host` mode, it archives replaceable DEMOS state under:

```bash
/var/backups/demos-fixnet/<timestamp>
```

This archive is meant to support recovery if the replacement path fails or if you need the prior config and service wrapper back.

## What gets archived

- `demos-node.service` backup when present
- service status and `systemctl cat` output
- repo config snapshot tar
- repo branch and status
- Docker inventory
- secret file names only, not the secret contents
- `manifest.json` describing the archive

## Restore

Run on the target host as `root`:

```bash
./scripts/restore_archived_install.sh
```

That restores the latest archive by default.

To restore a specific archive and start the service immediately:

```bash
./scripts/restore_archived_install.sh \
  --archive-path /var/backups/demos-fixnet/<timestamp> \
  --start-service
```

## Important limitation

Secret contents are not restored automatically. The archive only records which secret file names existed. If the recovered service depends on a mnemonic or other secret, restore that secret file manually before starting the service.

## Why this exists

This is the first real recovery path for reuse-host replacement. It is not a perfect full-state rollback, but it converts the archive from passive breadcrumbs into an actionable restore workflow.
