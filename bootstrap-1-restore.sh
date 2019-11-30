#!/bin/bash
set -eo pipefail
set -x

restic_version="0.9.6"
restic_download_name="restic_${restic_version}_linux_amd64.bz2"
restic_download_url="https://github.com/restic/restic/releases/download/v${restic_version}/${restic_download_name}"
restic_download_hash="a88ca09d1dd051d470965667a224a2b81930c6628a0566b7b17868be40207dc8"
restic_local_download="/usr/local/lib/${restic_download_name}"
restic_local_binary="/usr/local/bin/restic"

rclone_version="1.50.2"
rclone_download_name="rclone-v${rclone_version}-linux-amd64.zip"
rclone_download_url="https://github.com/rclone/rclone/releases/download/v${rclone_version}/${rclone_download_name}"
rclone_download_hash="2112883164f1f341b246a275936e7c3019d68135002098d84637839dec9526c8"
rclone_local_download="/usr/local/lib/${rclone_download_name}"
rclone_local_extract="rclone-v${rclone_version}-linux-amd64/rclone"
rclone_local_binary="/usr/local/bin/rclone"

apt-get install bzip2 unzip fuse curl
curl -o "$rclone_local_download" "$rclone_download_url"
sha256 "$rclone_download_hash" "$rclone_local_download"
unzip -q -j -o -d /usr/local/bin $rclone_local_download $rclone_local_extract
chmod 755 ${rclone_local_binary}
curl -o "$restic_local_download" "$restic_download_url"
sha256 "$restic_download_hash" "$restic_local_download"
bzip2 -d < "${restic_local_download}" > "${restic_local_binary}"
chmod 755 ${restic_local_binary}

cat << EOF

Unfinished:

+ Configuration Directory:
    + mandatory config files:
        + File: backup.passphrase.gpg
        + Base Configuration File: machine-config.env
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
