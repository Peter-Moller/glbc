#!/bin/bash
# Back up a GitLab server running in a docker container on a Linux server
# Uses 
# - https://git.cs.lth.se/peterm/autoreboot       (automatically reboots the computer if needed, unless a set of conditions prohibits it)
# - https://git.cs.lth.se/peterm/notify_monitor   (Make a note to the CS Monitoring System)
# 
# It will:
# 1. Back the GitLab instance
# 2. Sync this backup with a storage server
# 3. Remove old files
# 4. Send email to $Recipient detailing specifics
#
# First created 2022-05-13
# Peter Möller, Department of Computer Science, Lund University


# Read nessesary settings file. Exit if it’s not found
if [ -r ~/.gitlab_backup.settings ]; then
    source ~/.gitlab_backup.settings
else
    echo "Settings file not found. Will exit!"
    exit 1
fi

NL=$'\n'
export LC_ALL=en_US.UTF-8

# Make sure AutoReboot will not reboot the machine:
echo "gitlab backup" > $StopRebootFile


#==============================================================================================================
#   _____ _____ ___  ______ _____    ___________   ______ _   _ _   _ _____ _____ _____ _____ _   _  _____
#  /  ___|_   _/ _ \ | ___ \_   _|  |  _  |  ___|  |  ___| | | | \ | /  __ \_   _|_   _|  _  | \ | |/  ___|
#  \ `--.  | |/ /_\ \| |_/ / | |    | | | | |_     | |_  | | | |  \| | /  \/ | |   | | | | | |  \| |\ `--.
#   `--. \ | ||  _  ||    /  | |    | | | |  _|    |  _| | | | | . ` | |     | |   | | | | | | . ` | `--. \
#  /\__/ / | || | | || |\ \  | |    \ \_/ / |      | |   | |_| | |\  | \__/\ | |  _| |_\ \_/ / |\  |/\__/ /
#  \____/  \_/\_| |_/\_| \_| \_/     \___/\_|      \_|    \___/\_| \_/\____/ \_/  \___/ \___/\_| \_/\____/
#

# Find where the script resides
script_location() {
    if [ -L "${BASH_SOURCE[0]}" ]; then
        # Get the *real* directory of the script
        ScriptDirName="$(dirname "$(readlink "${BASH_SOURCE[0]}")")"   # ScriptDirName='/usr/local/bin'
        # Get the *real* name of the script
        ScriptName="$(basename "$(readlink "${BASH_SOURCE[0]}")")"     # ScriptName='moodle_backup.sh'
    else
        ScriptDirName="$(dirname "${BASH_SOURCE[0]}")"
        # What is the name of the script?
        ScriptName="$(basename "${BASH_SOURCE[0]}")"
    fi
    ScriptFullName="${ScriptDirName}/${ScriptName}"
}

# Find how the script is launched. Replace newlines with ', '
script_launcher() {
    # Start by looking at /etc/cron.d
    ScriptLauncher="$(grep "$ScriptName" /etc/cron.d/* | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"  # Ex: ScriptLauncher=/etc/cron.d/postgres
    # Also, look at the crontabs:
    if [ -z "$ScriptLauncher" ]; then
        ScriptLauncher="$(grep "$ScriptFullName" /var/spool/cron/crontabs/* | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"
    fi
}


# Send a notification to the CS Monitoring System
notify() {
    Object=$1
    Message=$2
    Level=$3
    Details=$4
    if [ -z "$Details" ]; then
        Details="{}"
    fi
    if [ -x /opt/monitoring/bin/notify ]; then
        /opt/monitoring/bin/notify "$Object" "$Message" "${Level:-INFO}" "$Details"
    fi
}


# Make room so that we can perform a backup
make_room() {
    /usr/bin/find /opt/gitlab/data/backups -type f -mtime +"$DeleteFilesNumDays" -exec rm -rf {} \; &>/tmp/backup_cleanup.txt
}


# State a number of Bytes in the appropriate unit (KiB, MiB, GiB)
volume() {
    RawVolume=$1
    KiB="$(printf "%'d" $(( RawVolume / 1024 ))) KiB"
    MiB="$(printf "%'d" $(( $((RawVolume+524288)) / 1048576 ))) MiB"
    GiB="$(printf "%'d" $(( $((RawVolume+536870912)) / 1073741824 ))) GiB"
    if [ $(echo "$GiB" | awk '{print $1}') -eq 0 ]; then
        if [ $(echo "$MiB" | awk '{print $1}') -eq 0 ]; then
            echo "$KiB"
        else
            echo "$MiB"
        fi
    else
        echo "$GiB"
    fi
}


# Make sure there’s enough room for a new backup (assuming the new backup will be ≈ like the last)
check_space() {
    SizeLastBackup=$(ls -ls "$LocalBackupDir" | grep -Ev "^total " | head -1 | awk '{print $6}')                       # Ex: SizeLastBackup=17140336640
    SpaceAvailable=$(df -kB1 "$LocalBackupDir" | grep -Ev "^Fil" | awk '{print $4}')                                   # Ex: SpaceAvailable=51703066624
    if [ $(echo "$SizeLastBackup * 2.3" | bc -l | cut -d\. -f1) -gt $SpaceAvailable ]; then
        DetailsJSON='{ "reporter":"'$ScriptFullName'", "space-available":"'$SpaceAvailable'", "num-bytes-last-backup": '${SizeLastBackup:-0}' }'
        notify "/app/gitlab/backup" "Backup of gitlab cannot be done: not enough space available" "CRIT" "$DetailsJSON"
        if [ -n "$Recipient" ]; then
            # Send email:
            echo "Backup of $GitServer cannot be done: not enough space available${NL}Space-available: $(printf "%'d" $((SpaceAvailable / 1048576))) MiB${NL}Last backup:     $(printf "%'d" $((SizeLastBackup / 1048576))) MiB" | mail -s "$GitServer cannot be backed up (not enough space)" $Recipient
            exit 1
        fi
    fi
}


# Do the backup
gitlab_backup() {
    # First: see if the previous backup concluded OK. Remove $BackupSignalFile if not
    if docker exec -it gitlab ls $BackupSignalFile &>/dev/null; then
        notify "/app/gitlab/backup" "Previous backup of gitlab did not conclude. Removing signal file ($BackupSignalFile)" "INFO"
        docker exec -it gitlab rm $BackupSignalFile
    fi

    StartTimeBackup=$(date +%s)
    BackupOutputFile=$(mktemp)
    # Do the actual backup:
    /usr/bin/docker exec -t gitlab gitlab-backup create &>"$BackupOutputFile"
    ESbackup=$?
    EndTimeBackup=$(date +%s)
    TimeBackupSec=$((EndTimeBackup - StartTimeBackup))
    TimeTakenBackup="$((TimeBackupSec/3600)) hour $((TimeBackupSec%3600/60)) min $((TimeBackupSec%60)) sec"            # Ex: TimeTakenBackup='0 hour 22 min 15 sec'
    if [ $ESbackup -eq 0 ]; then
        StatusBackup="successful"
    else
        StatusBackup="unsuccessful"
    fi

    BackupNameTmp="$(grep -oE " -- Backup [e0-9._-]* is done." "$BackupOutputFile" 2>/dev/null)"                       # Ex: BackupNameTmp=' -- Backup 1692167159_2023_08_16_15.11.11 is done.'
    if [ -n "$BackupNameTmp" ]; then
        BackupName="$(echo "$BackupNameTmp" | awk '{print $3}')_gitlab_backup.tar"                                     # Ex: BackupName='1654245725_2022_06_03_15.0.1_gitlab_backup.tar'
    else
        BackupName="probably_broken_$(date +%F)_gitlab_backup.tar"
    fi
    GitlabVersionInFile="$(tar -xOf "/opt/gitlab/data/backups/$BackupName" backup_information.yml | grep -E "^:gitlab_version" | awk '{print $NF}')" # Ex: GitlabVersionInFile=16.2.4
    BackupFileSizeB=$(find "/opt/gitlab/data/backups/$BackupName" -exec ls -ls {} \; | awk '{print $6}')               # Ex: BackupFileSizeB='47692830720'
    #BackupFileSizeMiB="$(printf "%'d" $((BackupFileSize / 1048576))) MiB"                                             # Ex: BackupFileSizeMic='45,483 MiB'
    #BackupFileSizeGiB="$(printf "%'d" $(( $((BackupFileSize+536870912)) / 1073741824))) GiB"                          # Ex: BackupFileSizeGiB='47 GiB'
    BackupFileSize="$(volume "$BackupFileSizeB")"                                                                      # Ex: BackupFileSize='44 GiB'
    SpaceAvailableAfterBackup=$(df -kB1 $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}')                          # Ex: SpaceAvailableAfterBackup=67525095424
    SpaceAvailableAfterBackupGiB="$(df -kh $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}' | sed 's/G$//') GiB"   # Ex: SpaceAvailableAfterRestoreGiB='261 GiB'
    DetailsJSONBackup='{ "reporter": "'$ScriptFullName'", "file-name": "'$BackupName'", "num-bytes": '${BackupFileSizeB:-0}' }'

    if [ $ESbackup -eq 0 ]; then
        notify "/app/gitlab/backup" "Backup of gitlab performed successfully in ${TimeTakenBackup/0 hour /}" "GOOD" "$DetailsJSONBackup"
        BackupResult="successful"
    else
        notify "/app/gitlab/backup" "Backup of gitlab on $GitServer FAILED (time: ${TimeTakenBackup/0 hour /})" "CRIT" "$DetailsJSONBackup"
        BackupResult="unsuccessful"
    fi
}


# rsync the backup
rsync_backup() {
    StartTimeSync=$(date +%s)
    # Sync the database backup
    echo "rsync of backup" > $StopRebootFile
    RsyncData="$(/usr/bin/rsync --verbose --archive --delete --perms --group --times -e ssh "$LocalBackupDir"/ "$RemoteUser"@"$RemoteHost":"$RemoteDataPath"/)"
    ESrsync1=$?
    [[ $ESrsync1 -ne 0 ]] && ErrortextSync="$LocalBackupDir could not be rsynced to $RemoteHost:$RemoteDataPath$NL"
    # Sync the config directory
    RsyncConf="$(/usr/bin/rsync --verbose --archive --delete --perms --group --times -e ssh "$LocalConfDir"/ "$RemoteUser"@"$RemoteHost":"$RemoteConfPath"/)"
    ESrsync2=$?
    [[ $ESrsync2 -ne 0 ]] && ErrortextSync+="$LocalConfDir could not be rsynced to $RemoteHost:$RemoteConfPath$NL"
    # Copy the docker-compose.yaml-file
    ScpDockerYaml="$(scp -p "/opt/gitlab/docker-compose.yaml" "$RemoteUser@$RemoteHost:$RemoteConfPath")"
    ESScp=$?
    [[ $ESScp -ne 0 ]] && ErrortextSync+="/opt/gitlab/docker-compose.yaml could not be copied with scp to $RemoteHost:$RemoteConfPath$NL"
    EndTimeSync=$(date +%s)
    TimeSyncSec=$((EndTimeSync - StartTimeSync))
    TimeTakenRsync="$((TimeSyncSec/3600)) hour $((TimeSyncSec%3600/60)) min $((TimeSyncSec%60)) sec"                   # Ex: TimeTakenRsync='0 hour 5 min 19 sec'

    # Sum the number of files and bytes
    BytesData=$(echo "$RsyncData" | grep -oE "^sent [0-9,]* bytes" | awk '{print $2}' | sed 's/,//g')
    BytesConf=$(echo "$RsyncConf" | grep -oE "^sent [0-9,]* bytes" | awk '{print $2}' | sed 's/,//g')
    TransferredB=$((${BytesData:-0} + ${BytesConf:-0}))
    TransferredVolume="$(volume "$TransferredB")"
    FilesData=$(echo "$RsyncData" | grep -vcE "^building file list |^\.\/$|^$|^sent |^total|\/$")
    FilesConf=$(echo "$RsyncConf" | grep -vcE "^building file list |^\.\/$|^$|^sent |^total|\/$")
    FilesNumTransferred=$((${FilesData:-0} + ${FilesConf:-0}))
    DetailsJSONRsync='{"remote-dir-data":"'$RemoteDataPath'","remote-dir-conf":"'$RemoteConfPath'","reporter":"'$ScriptFullName'","rsync-stats": { "files":'${FilesNumTransferred:-0}', "bytes": '${TransferredB:-0}', "time": '${TimeSyncSec:-0}'}}'

    # Notify the CS Monitoring System
    if [ $ESrsync1 -eq 0 ] && [ $ESrsync2 -eq 0 ] && [ $ESScp -eq 0 ]; then
        notify "/app/rsync/backup" "Rsync of git-backup and config to $RemoteHost in ${TimeTakenRsync/0 hour /}" "GOOD" "$DetailsJSONRsync"
        StatusRsync="successful"
    else
        notify "/app/rsync/backup" "Rsync of git-backup to $RemoteHost FAILED (time: ${TimeTakenRsync/0 hour /})" "CRIT" "$DetailsJSONRsync"
        StatusRsync="unsuccessful"
    fi
}


# Create email:
create_email() {
    MailReport="Backup report from $GitServer at $(date -d @$StartTimeBackup +%F" "%H:%M" "%Z)$NL"
    MailReport+="(script: ${ScriptFullName}, launched by: ${ScriptLauncher:---no launcher detected--})$NL$NL"
    MailReport+="BACKUP of $GitServer:${NL}"
    MailReport+="=================================================$NL"
    MailReport+="Status:            $StatusBackup$NL"
    MailReport+="File name:         $BackupName$NL"
    MailReport+="File size:         $BackupFileSize$NL"
    MailReport+="Version in file:   $GitlabVersionInFile$NL"
    MailReport+="Backup started:    $(date -d @$StartTimeBackup +%F" "%H:%M" "%Z)$NL"
    MailReport+="Time taken:        ${TimeTakenBackup/0 hour /}$NL"
    MailReport+="Space:             $SpaceAvailableAfterBackupGiB remaining on $LocalBackupDir"
    MailReport+="$NL$NL"
    MailReport+="RSYNC to $RemoteHost:${NL}"
    MailReport+="=================================================$NL"
    MailReport+="Status:            $StatusRsync$NL"
    MailReport+="Backup directory:  $LocalBackupDir  →  $RemoteDataPath$NL"
    MailReport+="Config directory:  $LocalConfDir  →  $RemoteConfPath$NL"
    MailReport+="Number of files:   ${FilesNumTransferred:-0}$NL"
    #MailReport+="Bytes trasferred: $(printf "%'d" $((TransferredB / 1048576))) MiB${NL}"
    MailReport+="Volume trasferred: $TransferredVolume$NL"
    MailReport+="Time taken:        ${TimeTakenRsync/0 hour /}"
    if [ -n "$ErrortextSync" ]; then
        MailReport+="${NL}${NL}However, there were problems transferring some files:"
        MailReport+="$ErrortextSync"
    fi
    if [ "$BackupResult" = "successful" ] && [ "$StatusRsync" = "successful" ]; then
        Status="backup & rsync both successful"
    else
        Status="backup: ${BackupResult}; rsync: ${StatusRsync}"
    fi
    MailReport+="${NL}${NL}End time: $(date +%F" "%H:%M" "%Z)"
}


#
#   _____ _   _______    ___________   ______ _   _ _   _ _____ _____ _____ _____ _   _  _____
#  |  ___| \ | |  _  \  |  _  |  ___|  |  ___| | | | \ | /  __ \_   _|_   _|  _  | \ | |/  ___|
#  | |__ |  \| | | | |  | | | | |_     | |_  | | | |  \| | /  \/ | |   | | | | | |  \| |\ `--.
#  |  __|| . ` | | | |  | | | |  _|    |  _| | | | | . ` | |     | |   | | | | | | . ` | `--. \
#  | |___| |\  | |/ /   \ \_/ / |      | |   | |_| | |\  | \__/\ | |  _| |_\ \_/ / |\  |/\__/ /
#  \____/\_| \_/___/     \___/\_|      \_|    \___/\_| \_/\____/ \_/  \___/ \___/\_| \_/\____/
#
#==============================================================================================================


# First: must be in the right place:
cd "$LocalDataDir" || exit 1

# Make sure AutoReboot will not reboot the machine:
echo "gitlab backup" > $StopRebootFile

script_location

script_launcher

make_room

check_space

gitlab_backup

rsync_backup

create_email

# Send mail if address is given
if [ -n "$Recipient" ]; then
    echo "$MailReport" | mail -s "${GitServer}: $Status" $Recipient
fi

# Remove the block against reboot:
rm $StopRebootFile

# Remove the backup file:
rm $BackupOutputFile
