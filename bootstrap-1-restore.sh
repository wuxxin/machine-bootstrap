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
            
+ 1 restore user and groups (for file access restore)
+ 2 restore latest pool layout (including zfs options)
    + modify legacy mounts 
+ 3 restore all files

EOF

exit 1