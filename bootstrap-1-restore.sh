#!/bin/bash
set -eo pipefail
set -x

cat << EOF
+ install restic binary

+ Configuration Directory:
    + mandatory config files:
        + File: backup.passphrase.gpg
        + Base Configuration File: config
            + mandatory settings
            + backup_repository=/volatile/restic-backup

+ restic restore:
    + 1 restore user and groups (for file access restore)
    + 2 restore latest pool layout (including zfs options)
        + modify legacy mounts 
    + 3 restore all files
    + 4 corrections
    + 5 last corrections to the setup will be done in 2-chroot-restore

EOF

exit 1