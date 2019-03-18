#!/bin/bash
set -eo pipefail
set -x

cat << EOF
+ install restic
+ restic restore from all

+ Configuration Directory:
    + mandatory config files:
        + File: backup.passphrase.gpg
        + Base Configuration File: config
            + mandatory settings
            + backup_repository=/volatile/restic-backup
EOF

exit 1