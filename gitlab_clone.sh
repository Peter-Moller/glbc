#!/bin/bash
# Script to import a backup from a GitLab → to a test-server based on docker containers on a Linux server
#
# Uses:
# - https://git.cs.lth.se/peterm/autoreboot       (automatically reboots the computer if needed, unless a set of conditions prohibits it)
# - https://git.cs.lth.se/peterm/notify_monitor   (Make a note to the CS Monitoring System)
# 
# It will:
# 1. Check to see that there is an applicable file on the file server
# 2. Make sure there is sufficient space available
# 3. Fetch the file from the file server using 'scp'
# 4. Also fetch nessecary config files (currently fetched from the main server). TODO!
# 5. Do a restore (including verification)
# 6. Email report
#
# First created 2022-05-13
# Peter Möller, Department of Computer Science, Lund University

# General settings
Start=$(date +%s)
export LC_ALL=en_US.UTF-8
StopRebootFile=/tmp/dont_reboot
TodayDate=$(date +%Y_%m_%d)
GitlabImportLog=/var/tmp/gitlab_importlogg_$(date +%F).txt
GitlabReconfigureLog=/var/tmp/gitlab_reconfigurelogg_$(date +%F).txt
GitlabVerifyLog=/var/tmp/gitlab_verifylogg_$(date +%F).txt
NL=$'\n'
FormatStr="%-19s%-50s"
source /opt/monitoring/monitor.config   # <- is this needed? TODO!


# Read nessesary settings file. Exit if it’s not found
if [ -r ~/.gitlab_backup.settings ]; then
    source ~/.gitlab_backup.settings
else
    echo "Settings file not found. Will exit!"
    exit 1
fi


ScriptNameLocation() {
    # Find where the script resides (correct version)
    # Get the DirName and ScriptName
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

SleepWait() {
    while true
    do
        STATUS="$(docker exec -t gitlab curl -k https://localhost/-/readiness 2>/dev/null | jq -r '.status' 2>/dev/null)"                             # Ex: STATUS=ok
        MASTER_CHECK="$(docker exec -t gitlab curl -k https://localhost/-/readiness 2>/dev/null | jq -r '.master_check[0].status' 2>/dev/null)"       # Ex: MASTER_CHECK=ok
        if [ "$STATUS" = "ok" ] && [ "$MASTER_CHECK" = "ok" ]; then
            break
        fi
        sleep 15
    done
}


# Start doing some work: get the backup file and associated metadata
# Use specified listing to get date and time of backup.
# Note: on macOS, this is '-D "format"'. On Linux, the same is done with '--time-style=full-iso'
if [ "$RemoteHostKind" = "linux" ]; then
    RemoteFiles="$(ssh $RemoteUser@$RemoteHost "ls -lst --time-style=full-iso $RemotePath/data/*_gitlab_backup.tar")"
else
    RemoteFiles="$(ssh $RemoteUser@$RemoteHost "ls -lst -D \"%F %H:%M\" $RemotePath/data/*_gitlab_backup.tar")"
fi
RemoteFile="$(echo "$RemoteFiles" | grep "_${TodayDate}_" 2>/dev/null | head -1)"
# Ex: RemoteFile='99134120 -rw-------  1 username  staff  50756669440 2023-08-31 04:38 /some/path/Backups/git/1693447267_2023_08_31_16.2.4_gitlab_backup.tar'
RemoteFileName="$(echo "$RemoteFile" | awk '{print $NF}')"                     # Ex: RemoteFileName='/some/path/Backups/git/1693447267_2023_08_31_16.2.4_gitlab_backup.tar'
BackupFile="$(basename "$RemoteFileName" 2>/dev/null)"                         # Ex: BackupFile='1693447267_2023_08_31_16.2.4_gitlab_backup.tar'
FileSize=$(echo "$RemoteFile" | awk '{print $6}')                              # Ex: FileSize=50756669440
FileSizeMiB="$(printf "%'d" $((FileSize / 1048576))) MiB"                      # Ex: FileSizeMiB='48,405 MiB'
FileSizeGiB="$(printf "%'d" $(( $((FileSize+536870912)) / 1073741824))) GiB"   # Ex: FileSizeGiB='47 GiB'
BackupTime="$(echo "$RemoteFile" | awk '{print $7" "$8}')"                     # Ex: BackupTime='2023-08-31 04:38'

# Get the amount of storage available locally:
SpaceAvailable=$(df -kB1 $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}')  # Ex: SpaceAvailable='301852954624'
# What version og GitLab is running (prior to restore)
RunningVersion="$(docker exec -t gitlab cat /opt/gitlab/version-manifest.txt | head -1 | tr -d '\r' | tr -d '\n')"   # Ex: RunningVersion='gitlab-ce 16.3.0'

ScriptNameLocation

# Se till att AutoReboot inte startar om maskinen:
echo "gitlab restore" > $StopRebootFile

# Notify the monitoring system that the server is doing something for 60 minutes
if [ -n "$SOURCE_TOKEN" ]; then
    curl -X 'POST' https://monitor.cs.lth.se/api/v1/sources/trigger-maintenance/"$SOURCE_TOKEN"/60m -H 'accept: application/json' -d '' &>/dev/null
fi

# Go to the correct directory for backups:
cd $LocalBackupDir || exit 1

DetailStr='{ "reporter":"'$ScriptFullName'", "filename": "'$BackupFile'", "num-bytes": '$FileSize' }'
# Continue if a file is found on the remote server
if [ -n "$RemoteFile" ]; then
    # Continue if there’s enough space available
    if [ $(echo "$FileSize * 2.1" | bc -l | cut -d\. -f1) -lt $SpaceAvailable ]; then
        # Transfer the file
        scp $RemoteUser@$RemoteHost:"$RemoteFileName" . &>/dev/null
        ES_scp=$?

        # Continue if the transfer was successful
        if [ $ES_scp -eq 0 ]; then
            chown 998:998 "$BackupFile"

            GitlabVersionInFile="$(tar -xOf "$BackupFile" backup_information.yml | grep -E "^:gitlab_version" | awk '{print $NF}')"       # Ex: GitlabVersionInFile=16.2.4

            # Now delete the current one and prepare for the restore:
            # Stoppa körande container:
            cd /opt/gitlab/ || exit 1
            docker compose down

            # Radera den gamla instansen (spara katalogen 'backups')
            mv data/backups _backups
            rm -rf data/*
            mv _backups data/backups

            # Copy everything from the config directory on the main server: TODO!
            cd config || exit 1
            scp -p -P 2222 $MainServer.cs.lth.se:/opt/gitlab/config/gitlab-secrets.json .
            scp -p -P 2222 $MainServer.cs.lth.se:'/opt/gitlab/config/ssh_*' .
            scp -p -P 2222 $MainServer.cs.lth.se:/opt/gitlab/docker-compose.yaml /opt/gitlab/docker-compose.yaml

            # Skapa en ny, tom instans:
            cd /opt/gitlab/ || exit 1
            docker compose up --force-recreate -d

            # Wait until it's up
            SleepWait

            # Stop 'puma' and 'sidekiq':
            docker exec -t gitlab gitlab-ctl stop puma
            docker exec -t gitlab gitlab-ctl stop sidekiq

            RestoreTimeStart="$(date +%F" "%H:%M)"

            # Run the restore. NOTE: "_gitlab_backup.tar" is omitted from the name
            docker exec -t gitlab sh -c 'gitlab-backup restore BACKUP=${BackupFile%_gitlab_backup.tar} force=yes' &>"$GitlabImportLog"
            ES_restore=$?
            if [ $ES_restore -eq 0 ]; then
                RestoreStatus="successfully"
                Level="GOOD"
            else
                RestoreStatus="unsuccessfully"
                Level="CRIT"
                # Create a string with the entire message but without printf controls and with \n replaced with '\n':
                GitlabImportlogg="$(tr -d '\r' < "$GitlabImportLog" | sed "s,\x1B\[[0-9;]*[a-zA-Z],,g" | awk '{printf "%s\\n", $0}')"
                DetailStrJSON='{ "reporter":"'$ScriptFullName'", "filename": "'$BackupFile'", "num-bytes": '$FileSize', "gitlab_importlogg":"'$GitlabImportlogg'" }'
                ErrorText="$(cat $GitlabImportLog | sed "s,\x1B\[[0-9;]*[a-zA-Z],,g" | grep -Ev " Deleting |^\s*$|Unpacking backup|Cleaning up|Transfering ownership")"
                DetailStrText="Reporter: \"$ScriptFullName\"${NL}Filename: \"$BackupFile\"${NL}Filesize: $(printf "%'d" $((FileSize / 1048576))) MiB${NL}${NL}ERROR:${NL}$ErrorText"
            fi

            echo "reconfigure of gitlab after restore" > $StopRebootFile
            docker exec -t gitlab gitlab-ctl reconfigure &>"$GitlabReconfigureLog"
            # Start gitlab again:
            docker restart gitlab

            # Wait (restart takes time):
            SleepWait

            # Check if everything is OK:
            echo "checking gitlab after restore" > "$StopRebootFile"
            docker exec -t gitlab gitlab-rake gitlab:check SANITIZE=true &>"$GitlabVerifyLog"
            ES_sanitycheck=$?
            if [ $ES_sanitycheck -eq 0 ]; then
                VerifyStatus="correct"
            else
                VerifyStatus="incorrect"
                # Make sure the Level is CRIT even if it was GOOD from the restore
                Level="CRIT"
            fi

            End=$(date +%s)
            Secs=$((End - Start))
            TimeTaken="$((Secs/3600)) hour $((Secs%3600/60)) min $((Secs%60)) sec"
            #SpaceAvailableAfterRestore=$(df -kB1 $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}')            # Ex: SpaceAvailableAfterRestore=280322433024A
            SpaceAvailableAfterRestoreGiB="$(df -kh $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}' | sed 's/G$//') GiB"      # Ex: SpaceAvailableAfterRestoreGiB='261 GiB'

            # Meddela monitor-systemet att det är gjort
            notify "/app/gitlab/restored" "gitlab restored $RestoreStatus in ${TimeTaken/0 hour /}. (Verify: $VerifyStatus)" "$Level" "$DetailStrJSON"

            # Skapa rapport
            MailBodyStr="Report from $ReplicaServer (script: \"$ScriptFullName\")${NL}"
            MailBodyStr+="$NL"
            MailBodyStr+="Gitlab restored ${RestoreStatus}.${NL}"
            MailBodyStr+="$NL"
            MailBodyStr+="Details:$NL"
            MailBodyStr+="=================================================$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Running version:" "$RunningVersion")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Version in file:" "$GitlabVersionInFile")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Source:" "${RemoteHost}:$RemotePath")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Filename:" "$BackupFile")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Backup ended:" "$BackupTime (end)")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Restore started:" "$RestoreTimeStart (start)")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Restore duration:" "${TimeTaken/0 hour /}")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "File size:" "$FileSizeGiB")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Space remaining:" "$SpaceAvailableAfterRestoreGiB")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Verify:" "$VerifyStatus")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "Details:" " ")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "- import:" "$GitlabImportLog")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "- reconfigure:" "$GitlabReconfigureLog")$NL"
            MailBodyStr+="$(printf "$FormatStr\n" "- verify:" "$GitlabVerifyLog")$NL"
            if [ $ES_restore -ne 0 ]; then
                MailBodyStr+="${NL}${NL}ERROR:${NL}"
                MailBodyStr+="$ErrorText${NL}"
            fi

            # Mejla rapporten
            if [ $ES_restore -eq 0 ]; then
                echo "$MailBodyStr" | mail -s "GitLab on $GitServer restored" $Recipient
            else
                echo "$MailBodyStr" | mail -s "GitLab on $GitServer NOT restored" $Recipient
            fi

            # radera filen/filerna
            rm -f "$BackupFile"
        else
            # Meddela monitor-systemet att det inte gick bra
            notify "/app/gitlab/restored" "Backup file could not be retrieved from $RemoteHost. No restore performed. Error: $ES_scp" "CRIT" "$DetailStrJSON"
            MailBodyStr="Report from $GitServer (script: \"$ScriptFullName\")$NL"
            echo "Backup file could not be retrieved from ${RemoteHost}:$RemotePath for server $GitServer. No restore performed. Error: ${ES_scp}" | mail -s "GitLab on $GitServer NOT restored" $Recipient
            # Start gitlab again:
            docker restart gitlab
        fi
    else
        # Not enough space available on local disk
        DetailStrJSON='{ "filename": "'$BackupFile'", "filesize": "'$((FileSize / 1048576))' MiB", "available_local_space": "'$((SpaceAvailable / 1048576))' MiB" }'
        MailBodyStr="Report from $GitServer (script: \"$ScriptFullName\")$NL"
        MailBodyStr+="Insufficient space to perform the restore$NL$NL"
        MailBodyStr+="Filename:        $BackupFile$NL"
        MailBodyStr+="Filesize:        $(printf "%'d" $((FileSize / 1048576))) MiB$NL"
        MailBodyStr+="Available space: $(printf "%'d" $((SpaceAvailable / 1048576))) MiB"
        notify "/app/gitlab/restored" "Insufficient space to perform the restore" "CRIT" "$DetailStrJSON"
        echo "$DetailStrText" | mail -s "GitLab on $GitServer NOT restored" $Recipient
    fi
else
    # File not found on $RemoteHost
    DetailStrJSON='{"remote-host":"'$RemoteHost'","reporter":"'$ScriptFullName'"}'
    MailBodyStr="Report from $GitServer (script: \"$ScriptFullName\")$NL$NL"
    MailBodyStr+="No file found on $RemoteHost$NL$NL"
    MailBodyStr+="Today date:  $TodayDate$NL"
    MailBodyStr+="Remote host: $RemoteHost$NL$NL"
    MailBodyStr+="Files on server:$NL"
    MailBodyStr+="$RemoteFiles"
    notify "/app/gitlab/restored" "No file found on $RemoteHost" "CRIT" "$DetailStrJSON"
    echo "$DetailStrText" | mail -s "GitLab on $GitServer NOT restored" $Recipient
fi

# Städa undan filer som är äldre än 3 dagar
/usr/bin/find /opt/gitlab/data/backups/ -type f -mtime +3 -exec rm -f {} \;

# Ta bort låsningen mot omstart:
rm $StopRebootFile
