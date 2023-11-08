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
RsyncArgs="--verbose --archive --delete --perms --group --times -e ssh"
BackupMethod="gitlab gitlab-backup create"
ReportHead=https://fileadmin.cs.lth.se/intern/backup/custom_report_head.html
now="$(date "+%Y-%m-%d %T %Z")"

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
    ScriptLauncher="$(grep "$ScriptName" /etc/cron.d/* | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"                # Ex: ScriptLauncher=/etc/cron.d/postgres
    # Also, look at the crontabs:
    if [ -z "$ScriptLauncher" ]; then
        ScriptLauncher="$(grep "$ScriptName" /var/spool/cron/crontabs/* | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"
    fi
    ScriptLaunchWhenStr="$(grep "$ScriptName" "$ScriptLauncher" | grep -Ev "#" | awk '{print $1" "$2" "$3" "$4" "$5}')"            # Ex: ScriptLaunchWhenStr='55 3 * * *'
    ScriptLaunchDay="$(echo "$ScriptLaunchWhenStr" | awk '{print $5}' | sed 's/*/day/; s/0/Sunday/; s/1/Monday/; s/2/Tuesday/; s/3/Wednesday/; s/4/Thursday/; s/5/Friday/; s/6/Saturday/')"
    ScriptLaunchHour="$(echo "$ScriptLaunchWhenStr" | awk '{print $2}')"                                                           # Ex: ScriptLaunchHour=3
    ScriptLaunchMinute="$(echo "$ScriptLaunchWhenStr" | awk '{print $1}')"                                                         # Ex: ScriptLaunchMinute=55
    ScriptLaunchText="$(echo Time="$ScriptLaunchDay at $(printf "%02d:%02d" "${ScriptLaunchHour#0}" "${ScriptLaunchMinute#0}")")"  # Ex: ScriptLaunchText='day at 03:55'
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
    TimeTakenBackupRaw="$((TimeBackupSec/3600)) hour $((TimeBackupSec%3600/60)) min $((TimeBackupSec%60)) sec"         # Ex: TimeTakenBackupRaw='0 hour 22 min 15 sec'
    TimeTakenBackup="$(echo "$TimeTakenBackupRaw" | sed 's/0 hour //;s/^0 min //')"                                    # Ex: TimeTakenBackup='22 min 15 sec'
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
    # First, copy the backup script itself
    /usr/bin/rsync $RsyncArgs ${ScriptFullName} $RemoteUser@$RemoteHost:$RemoteDataPath/../

    RsyncData="$(/usr/bin/rsync $RsyncArgs "$LocalBackupDir"/ "$RemoteUser"@"$RemoteHost":"$RemoteDataPath"/)"
    ESrsync1=$?
    [[ $ESrsync1 -ne 0 ]] && ErrortextSync="$LocalBackupDir could not be rsynced to $RemoteHost:$RemoteDataPath$NL"
    # Sync the config directory
    RsyncConf="$(/usr/bin/rsync $RsyncArgs "$LocalConfDir"/ "$RemoteUser"@"$RemoteHost":"$RemoteConfPath"/)"
    ESrsync2=$?
    [[ $ESrsync2 -ne 0 ]] && ErrortextSync+="$LocalConfDir could not be rsynced to $RemoteHost:$RemoteConfPath$NL"
    # Copy the docker-compose.yaml-file
    ScpDockerYaml="$(scp -p "/opt/gitlab/docker-compose.yaml" "$RemoteUser@$RemoteHost:$RemoteConfPath")"
    ESScp=$?
    [[ $ESScp -ne 0 ]] && ErrortextSync+="/opt/gitlab/docker-compose.yaml could not be copied with scp to $RemoteHost:$RemoteConfPath$NL"
    EndTimeSync=$(date +%s)
    TimeSyncSec=$((EndTimeSync - StartTimeSync))
    TimeTakenRsyncRaw="$((TimeSyncSec/3600)) hour $((TimeSyncSec%3600/60)) min $((TimeSyncSec%60)) sec"                # Ex: TimeTakenRsyncRaw='0 hour 5 min 19 sec'
    TimeTakenRsync="$(echo "$TimeTakenRsyncRaw" | sed 's/0 hour //;s/^0 min //')"                                      # Ex: TimeTakenRsync='5 min 19 sec'


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
    MailReport+="Space:             $SpaceAvailableAfterBackupGiB remaining on $LocalBackupDir (disk: $(df $LocalBackupDir | grep -Ev "^File" | awk '{print $NF}'))"
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


# Create HTML email:
email_html_create() {
    EmailTempFile=$(mktemp)
    # Get the status of the whole operation
    if [ $ESbackup -eq 0 ] && [ $ESrsync1 -eq 0 ] && [ $ESrsync2 -eq 0 ]; then
        Status='backup & rsync both successful'
    else
        Status="backup: ${BackupStatusDB}; rsync: ${RsyncStatus}"
    fi
    # Set the headers in order to use sendmail
    echo "To: $Recipient" >> $EmailTempFile
    echo "Subject: $Status" >> $EmailTempFile
    echo "Content-Type: text/html" >> $EmailTempFile
    echo "" >> $EmailTempFile

    # Get the head of the custom report, replace SERVER and DATE
    curl --silent $ReportHead | sed "s/SERVER/$GitServer/;s/DATE/$(date +%F)/" >> $EmailTempFile
    # Only continue if it worked
    if grep "Backup report for" $EmailTempFile 2>/dev/null ; then
        echo "<body>" >> $EmailTempFile
        echo '<div class="main_page">' >> $EmailTempFile
        echo '  <div class="flexbox-container">' >> $EmailTempFile
        echo '    <div id="box-header">' >> $EmailTempFile
        echo "      <h3>Backup report for</h3>" >> $EmailTempFile
        echo "      <h1>$GitServer</h1>" >> $EmailTempFile
        echo "      <h4>$now</h4>" >> $EmailTempFile
        echo "    </div>" >> $EmailTempFile
        echo "  </div>" >> $EmailTempFile
        echo "  <section>" >> $EmailTempFile
        echo "    <p>&nbsp;</p>" >> $EmailTempFile
        echo "    <p align=\"left\"> Report generated by script: <code>${ScriptFullName}</code><br>" >> $EmailTempFile
        echo "      Script launched $ScriptLaunchText by: <code>${ScriptLauncher:---no launcher detected--}</code> </p>" >> $EmailTempFile
        echo '    <p align="left">&nbsp;</p>' >> $EmailTempFile
        echo '    <table id="jobe">' >> $EmailTempFile
        echo "      <thead>" >> $EmailTempFile
        echo '        <tr><th align="right" colspan="2">Backup</th></tr>' >> $EmailTempFile
        echo "      </thead>" >> $EmailTempFile
        echo "      <tbody>" >> $EmailTempFile
        if [ "$StatusBackup" = "successful" ]; then
            TextColor="green"
        else
            TextColor="red"
        fi
        echo '        <tr><td>Status:</td><td style="color: '$TextColor';">'$StatusBackup'</td></tr>' >> $EmailTempFile
        echo '        <tr><td>Method:</td><td><code>'$BackupMethod'</code></td></tr>' >> $EmailTempFile
        echo '        <tr><td>File name:</td><td><code>'$BackupName'</code></td></tr>' >> $EmailTempFile
        echo '        <tr><td>File size:</td><td>'$BackupFileSize'</td></tr>' >> $EmailTempFile
        echo '        <tr><td>Version in file:</td><td>'$GitlabVersionInFile'</td></tr>' >> $EmailTempFile
        echo "        <tr><td>Backup Started:</td><td>$(date -d @$StartTimeBackup +%F" "%H:%M" "%Z)</td></tr>" >> $EmailTempFile
        echo "        <tr><td>Time taken, DB:</td><td>$TimeTakenBackup</td></tr>" >> $EmailTempFile
        echo "        <tr><td>Space:</td><td>$SpaceAvailableAfterBackupGiB remaining on disk <code>$(df $LocalBackupDir | grep -Ev "^File" | awk '{print $NF}')</code> (<code>$(df $LocalBackupDir | grep -Ev "^File" | awk '{print $1}')</code>)</td></tr>" >> $EmailTempFile
        echo "      </tbody>" >> $EmailTempFile
        echo "    </table>" >> $EmailTempFile
        echo "    <p>&nbsp;</p>" >> $EmailTempFile
        echo "    <p>&nbsp;</p>" >> $EmailTempFile
        echo "    <table id="jobe">" >> $EmailTempFile
        echo "      <thead>" >> $EmailTempFile
        echo "        <tr>" >> $EmailTempFile
        echo '          <th align="right" colspan="2">rsync</th>' >> $EmailTempFile
        echo "        </tr>" >> $EmailTempFile
        echo "      </thead>" >> $EmailTempFile
        echo "      <tbody>" >> $EmailTempFile
        if [ "$StatusRsync" = "successful" ]; then
            echo '        <tr><td>Status:</td><td style="color: green;">'$StatusRsync'</td></tr>' >> $EmailTempFile
        else
            RsyncErrList="$(echo "$RsyncInfo" | grep -E "^rsync: " | sed 's/rsync: //' | sort | awk -F "\"" '{print $1"[filename]"NF}' | uniq -c)"
            RsyncNumErr=$(echo "$RsyncInfo" | grep -cE "^rsync: ")
            echo '        <tr><td>Status:</td><td style="color: red;">'$StatusRsync'</td></tr>' >> $EmailTempFile
            echo "        <tr><td>$RsyncNumErr errors:</td><td><table><tr><td><b>Num</b></td><td><b>Explanation</b></td></tr>" >> $EmailTempFile
            while read -r ROW
            do
                ErrNum="$(echo "$ROW" | awk '{print $1}')"
                ErrText="$(echo "$ROW" | awk '{for(i=2;i<=NF;i++){printf "%s ", $i}}')"
                echo "<tr><td align=\"right\">$ErrNum</td><td>$ErrText</td></tr>" >> $EmailTempFile
            done <<< "$RsyncErrList"
            echo "        </table></td></tr>" >> $EmailTempFile
        fi
        echo "        <tr><td>Remote server:</td><td>$RemoteHost</td></tr>" >> $EmailTempFile
        echo "        <tr><td>Backup directory:</td><td><code>$LocalBackupDir</code>  &#8594;  <code>$RemoteDataPath</code></td></tr>" >> $EmailTempFile
        echo "        <tr><td>Config directory:</td><td><code>$LocalConfDir/</code> &#8594; <code>$RemoteConfPath</code></td></tr>" >> $EmailTempFile
        echo "        <tr><td>Number of files:</td><td>${FilesNumTransferred:-0}</td></tr>" >> $EmailTempFile
        echo "        <tr><td>Volume trasferred:</td><td>$(printf "%'d" $((TransferredB / 1048576))) MiB</td></tr>" >> $EmailTempFile
        echo "        <tr><td>Time taken:</td><td>$TimeTakenRsync</td></tr>" >> $EmailTempFile
        echo "      </tbody>" >> $EmailTempFile
        echo "    </table>" >> $EmailTempFile
        echo "  </section>" >> $EmailTempFile
        echo '  <p align="center"><em>Department of Computer Science, LTH/LU</em></p>' >> $EmailTempFile
        echo "</div>" >> $EmailTempFile
        echo "</body>" >> $EmailTempFile
        echo "</html>" >> $EmailTempFile
    else
        echo "<body>" >> $EmailTempFile
        echo "<h1>Could not get $ReportHead!!</h1>"
        echo "</body>" >> $EmailTempFile
        echo "</html>" >> $EmailTempFile
    fi
}


# Skicka mejlet
email_html_send() {
    if [ -n "$Recipient" ]; then
        cat $EmailTempFile | /sbin/sendmail -t
        #echo "$MailReport" | mail -s "${GitServer}: $Status" "$Recipient"
    fi
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

#create_email

email_html_create

email_html_send

# Send mail if address is given
#if [ -n "$Recipient" ]; then
#    echo "$MailReport" | mail -s "${GitServer}: $Status" $Recipient
#fi

# Remove the block against reboot:
rm $StopRebootFile

# Remove the backup file:
rm $BackupOutputFile
