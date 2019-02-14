#!/bin/bash

# see https://github.com/restic/restic/issues/1951
# hourly-restic backup of all volumes
# called as postcmd of zfs-auto-snapshot

dataset=$1
snapshotname=$2
# dataset rpool/ROOT/ubuntu
# snapshotname zfs-auto-snap_hourly-2018-10-22-1917
prefix=zfs-auto-snap
label=hourly
timestamp=2018-10-22-1917
datasetname=rpool.ROOT.ubuntu
RCACHE=~/.cache/restic

if test "$prefix" != "zfs-auto-snap_"; then exit 0; fi
if test "$label" != "hourly"; then exit 0; fi

mkdir -p $RCACHE
echo "${timestamp}" > $RCACHE/current.timestamp.${datasetname}

if test -e "$RCACHE/last.timestamp.${datasetname}" -a -e "$RCACHE/last.parent.${datasetname}"; then
    last_timestamp=$(cat "$RCACHE/last.timestamp.${datasetname}")
    last_parent=$(cat "$RCACHE/last.parent.${datasetname}")
    
    zfs get guid $dataset@${prefix}_${label}-$last_timestamp
    if test "$?" -ne "0"; then 
            fullbackup="true"
    fi
else
    fullbackup="true"
fi

zfs clone -o readonly=on $dataset@${prefix}_${label}-${timestamp} rpool/volatile/${datasetname}

if test "$fullbackup" != "true"; then
    zfs diff -H $dataset@${prefix}_${label}-$last_timestamp $dataset@${prefix}_${label}-${timestamp} | sed -r "s/^R\t[^\t]+\t(.+)/R\t\1/g" | cut -s -f 2 | sort -n | uniq | awk '{print "/volatile/'${datasetname}'" $1}' > $RCACHE/current.incremental.${datasetname}.txt
    
    restic --repo /volatile/backup-restic/ --one-file-system --parent "$last_parent" --files-from=$RCACHE/current.incremental.${datasetname}.txt --time "${timestamp}" --tag "${datasetname}" -v backup
else
    touch $RCACHE/dontrun.incremental
    check if there is a parent, get parent
    restic --repo /volatile/backup-restic/ --one-file-system $optional_parent --time "${timestamp}" --tag "${datasetname}" -v backup /volatile/${datasetname}
fi
parent=$(restic --repo /volatile/backup-restic/ --json snapshots --last --tag "${datasetname}" | jq -r ".[0].id")
echo "$parent" > $RCACHE/current.parent.${datasetname}
mv $RCACHE/current.parent.${datasetname} $RCACHE/last.parent.${datasetname}
mv $RCACHE/current.timestamp.${datasetname} $RCACHE/last.timestamp.${datasetname}

zfs destroy rpool/volatile/${datasetname}
if test "$fullbackup" = "true"; then
   rm $RCACHE/dontrun.incremental
fi
  
+ Yearly (full) create on beginning of year
+ Monthly created -i from last monthly or current yearly if month 1
+ daily created -i from last daily or current monthly if day 1
+ hourly created -i from last hourly or current daily if hour = 0

+ send after snapshot creation

+ prune yearly if +18 Month old
+ prune monthly if no longer in rotation
+ prune daily if no longer in rotation
+ prune hourly if no longer in rotation
 


restic init --repo /volatile/backup-restic
zfs clone -o readonly=on rpool/ROOT/ubuntu@zfs-auto-snap_daily-2018-08-10-0625 rpool/volatile/root
restic --repo /volatile/backup-restic/ backup --tag daily-2018-08-10-0625 --one-file-system /volatile/root/
zfs destroy rpool/volatile/root 

zfs clone -o readonly=on rpool/ROOT/ubuntu@zfs-auto-snap_daily-2018-08-11-0625 rpool/volatile/root
restic --repo /volatile/backup-restic/ backup --one-file-system /volatile/root/
zfs destroy rpool/volatile/root 

zfs clone -o readonly=on rpool/ROOT/ubuntu@zfs-auto-snap_daily-2018-08-12-0625 rpool/volatile/root
zfs diff -H rpool/ROOT/ubuntu@zfs-auto-snap_daily-2018-08-11-0625 rpool/ROOT/ubuntu@zfs-auto-snap_daily-2018-08-12-0625 | sed -r "s/^R\t[^\t]+\t(.+)/R\t\1/g" | cut -s -f 2 | sort -n | uniq | awk '{print "/volatile/root" $1}' > incremental.txt
cat incremental.txt
/volatile/root/var/backups
/volatile/root/var/backups/dpkg.diversions.0
/volatile/root/var/backups/dpkg.diversions.1.gz
/volatile/root/var/backups/dpkg.diversions.2.gz
/volatile/root/var/backups/dpkg.diversions.3.gz
/volatile/root/var/backups/dpkg.statoverride.0
/volatile/root/var/backups/dpkg.statoverride.1.gz
/volatile/root/var/backups/dpkg.statoverride.2.gz
/volatile/root/var/backups/dpkg.statoverride.3.gz
/volatile/root/var/backups/dpkg.status.0
/volatile/root/var/backups/dpkg.status.1.gz
/volatile/root/var/backups/dpkg.status.2.gz
/volatile/root/var/backups/dpkg.status.3.gz
/volatile/root/var/lib/apt/daily_lock
/volatile/root/var/lib/logrotate
/volatile/root/var/lib/logrotate/status
/volatile/root/var/lib/mlocate
/volatile/root/var/lib/mlocate/mlocate.db
/volatile/root/var/lib/private/systemd/timesync/clock
/volatile/root/var/lib/systemd/timers/stamp-apt-daily.timer
/volatile/root/var/lib/systemd/timers/stamp-apt-daily-upgrade.timer
/volatile/root/var/lib/systemd/timers/stamp-motd-news.timer

restic --repo /volatile/backup-restic/ --one-file-system --files-from=/volatile/incremental.txt -v backup

Files:          27 new,     0 changed,     0 unmodified
Dirs:           13 new,     0 changed,     0 unmodified
Data Blobs:      0 new
Tree Blobs:      8 new
Added to the repo: 4.714 KiB

processed 27 files, 8.774 MiB in 0:03
snapshot ccd25006 saved
 
restic --repo /volatile/backup-restic/ backup --one-file-system /volatile/root/

repository ef9151c3 opened successfully, password is correct

Files:           0 new,     0 changed, 27535 unmodified
Dirs:            0 new,     1 changed,     0 unmodified
Added to the repo: 349 B

processed 27535 files, 993.713 MiB in 0:07
snapshot f544907b saved

