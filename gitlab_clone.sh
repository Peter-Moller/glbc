#!/bin/bash
# Script to import a backup from a GitLab → to a test-server based on docker containers on a Linux server
#
# Is aware of:
# - https://git.cs.lth.se/peterm/autoreboot       (automatically reboots the computer if needed, unless a set of conditions prohibits it)
# Uses:
# - https://git.cs.lth.se/peterm/notify_monitor   (Make a note to the CS Monitoring System)
# 
# It will:
# 1. Check to see that there is an applicable file on the file server
# 2. Make sure there is sufficient space available
# 3. Fetch the file from the file server using 'scp'
# 4. Also fetch nessecary config files
# 5. Do a restore (including verification)
# 6. Email report
#
# First created 2022-05-13
# Peter Möller, Department of Computer Science, Lund University



#==============================================================================================================
#   _____ _____ ___  ______ _____    ___________   ______ _   _ _   _ _____ _____ _____ _____ _   _  _____ 
#  /  ___|_   _/ _ \ | ___ \_   _|  |  _  |  ___|  |  ___| | | | \ | /  __ \_   _|_   _|  _  | \ | |/  ___|
#  \ `--.  | |/ /_\ \| |_/ / | |    | | | | |_     | |_  | | | |  \| | /  \/ | |   | | | | | |  \| |\ `--. 
#   `--. \ | ||  _  ||    /  | |    | | | |  _|    |  _| | | | | . ` | |     | |   | | | | | | . ` | `--. \
#  /\__/ / | || | | || |\ \  | |    \ \_/ / |      | |   | |_| | |\  | \__/\ | |  _| |_\ \_/ / |\  |/\__/ /
#  \____/  \_/\_| |_/\_| \_| \_/     \___/\_|      \_|    \___/\_| \_/\____/ \_/  \___/ \___/\_| \_/\____/ 
#


# Check to see if the script is already running. Exit if so
CheckRunning() {
    if pidof -o %PPID -x "$(basename "$0")" >/dev/null; then
        debug "CRITICAL! Script $(basename "$0") is already running"

        tempfile=$(mktemp)
        pidof -o %PPID -x "$(basename "$0")" >$tempfile
        ProcessStartTime="$(ps -fo start_time -p $(cat $tempfile) --no-headers)"    # Ex: ProcessStartTime=08:55
        rm $tempfile

        prepare_email
        echo '        <tr><td>Status:</td><td style="color: style="color: red">GitLab on '$GitServer' NOT restored</td></tr>' >> "$EmailTempFile"
        echo '        <tr><td>Reason:</td><td>Restore script is already running</td></tr>' >> "$EmailTempFile"
        echo "        <tr><td>Details:</td><td>The alreay-running script was started at: $ProcessStartTime</td></tr>" >> "$EmailTempFile"
        MailSubject="Script already running"
        send_email
        exit 1
    fi
}

# Read nessesary settings file. Exit if it’s not found
Initialize() {
    if [ -r ~/.gitlab_backup.settings ]; then
        source ~/.gitlab_backup.settings
        # General settings
        Start=$(date +%s)
        now="$(date "+%Y-%m-%d %T %Z")"
        export LC_ALL=en_US.UTF-8
        TitleString="Restore report for “$GitServer” on $(date +%F)"
        StopRebootFile=/tmp/dont_reboot
        TodayDate=$(date +%Y_%m_%d)                                                                                            # Ex: TodayDate=2023_09_12
        LogDir="/var/tmp"
        GitlabImportLog=$LogDir/gitlab_importlogg_$(date +%F).txt
        GitlabReconfigureLog=$LogDir/gitlab_reconfigurelogg_$(date +%F).txt
        GitlabVerifyLog=$LogDir/gitlab_verifylogg_$(date +%F).txt
        GitlabReadinessURL="https://localhost/-/readiness"
        # What version og GitLab is running (prior to restore)
        RunningVersion="$(docker exec -t gitlab cat /opt/gitlab/version-manifest.txt | head -1 | tr -d '\r' | tr -d '\n')"     # Ex: RunningVersion='gitlab-ce 16.3.0'
        NL=$'\n'
        FormatStr="%-19s%-50s"
        CSS_colorfix="s/jobe_th_bgc/${jobe_th_bgc:-22458a}/g;s/jobe_th_c/${jobe_th_c:-white}/g;s/box_h_bgc/${box_h_bgc:-22458a}/g;s/box_h_c/${box_h_c:-white}/g"

        LocalBackupMP="$(df -kh $LocalBackupDir | grep -Ev "^Fil" | awk '{print $NF}')"                                        # Ex: LocalBackupMP=/opt
        LocalBackupFS="$(df -kh $LocalBackupDir | grep -Ev "^Fil" | awk '{print $1}')"                                         # Ex: LocalBackupFS=/dev/mapper/vg1-opt

        # Get the amount of storage available locally:
        SpaceAvailable=$(df -kB1 $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}')                                         # Ex: SpaceAvailable='301852954624'
        RestoreMethod="copy <code>gitlab-secrets.json</code> &#8594; <code>$LocalConfDir</code><br>"
        RestoreMethod+="copy <code>ssh_*</code> &#8594; <code>$LocalConfDir</code><br>"
        RestoreMethod+="copy <code>docker-compose.yaml</code> &#8594; <code>$LocalConfDir</code><br>"
        RestoreMethod+="<code>docker compose up --force-recreate -d</code><br>"
        RestoreMethod+="<i>Wait...</i><br>"
        RestoreMethod+="<code>docker exec -t gitlab gitlab-ctl stop puma</code><br>"
        RestoreMethod+="<code>docker exec -t gitlab gitlab-ctl stop sidekiq</code><br>"
        RestoreMethod+="<code>docker exec -t gitlab sh -c 'gitlab-backup restore BACKUP=${BackupFile%_gitlab_backup.tar} force=yes'</code><br>"
        RestoreMethod+="<code>docker exec -t gitlab gitlab-ctl reconfigure</code><br>"
        RestoreMethod+="<code>docker restart gitlab</code><br>"
        RestoreMethod+="<i>Wait...</i><br>"
        RestoreMethod+="<code>docker exec -t gitlab gitlab-rake gitlab:check SANITIZE=true</code>"
    else
        debug "CRITICAL! Settings file ~/.gitlab_backup.settings not found. Will exit!"
        prepare_email
        echo '        <tr><td>Status:</td><td style="color: style="color: red">GitLab on '$GitServer' NOT restored</td></tr>' >> "$EmailTempFile"
        echo '        <tr><td>Reason:</td><td>The configuration file (<code>~/.gitlab_backup.settings</code>) was not found </td></tr>' >> "$EmailTempFile"
        MailSubject="Settings file not found"
        send_email
        exit 1
    fi
}


# Send debug information to StdErr
debug() {
    local DebugMessage="$1"
    echo "$(date +%F" "%T): $DebugMessage" >&2
}


# Find where the script resides
script_name_location() {
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


# Find how the script is launched. Replace newlines with ', '
script_launcher() {
    # Start by looking at /etc/cron.d
    ScriptLauncher="$(grep "$ScriptName" /etc/cron.d/* | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"                # Ex: ScriptLauncher=/etc/cron.d/postgres
    # Also, look at the crontabs:
    if [ -z "$ScriptLauncher" ]; then
        ScriptLauncher="$(grep "$ScriptName" /var/spool/cron/crontabs/* | grep -Ev "#" | cut -d: -f1 | sed ':a;N;$!ba;s/\n/ \& /g')"
    fi
    ScriptLaunchByUser="<code>$(grep "$ScriptName" "$ScriptLauncher" | grep -Ev "#" | awk '{print $6}')</code>"                    # Ex: ScriptLaunchByUser='<code>root</code>'
    ScriptLaunchWhenStr="$(grep "$ScriptName" "$ScriptLauncher" | grep -Ev "#" | awk '{print $1" "$2" "$3" "$4" "$5}')"            # Ex: ScriptLaunchWhenStr='30 6 * * 0'
    ScriptLaunchDay="$(echo "$ScriptLaunchWhenStr" | awk '{print $5}' | sed 's/*/day/; s/0/Sunday/; s/1/Monday/; s/2/Tuesday/; s/3/Wednesday/; s/4/Thursday/; s/5/Friday/; s/6/Saturday/')"  # Ex: ScriptLaunchDay=Sunday
    ScriptLaunchHour="$(echo "$ScriptLaunchWhenStr" | awk '{print $2}')"                                                           # Ex: ScriptLaunchHour=6
    ScriptLaunchMinute="$(echo "$ScriptLaunchWhenStr" | awk '{print $1}')"                                                         # Ex: ScriptLaunchMinute=30
    ScriptLaunchText="as $ScriptLaunchByUser every $ScriptLaunchDay at $(printf "%02d:%02d" "${ScriptLaunchHour#0}" "${ScriptLaunchMinute#0}")"           # Ex: ScriptLaunchText='every Sunday at 06:30'
}


# House cleaning
delete_old_files() {
    /usr/bin/find $LocalBackupDir/ -type f -mtime +3 -exec rm -f {} \;
    /usr/bin/find $LogDir/ -type f -mtime +30 -exec rm -f {} \;
}


# Notify the monitoring system that the server is doing something for 60 minutes
trigger_maintenance() {
    MaintenanceDuration="$1"
    if [ -n "$SOURCE_TOKEN" ]; then
        curl -X 'POST' https://monitor.cs.lth.se/api/v1/sources/trigger-maintenance/"$SOURCE_TOKEN"/"$MaintenanceDuration" -H 'accept: application/json' -d '' &>/dev/null
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


# Wait untill gitlab is up and running again
SleepWait() {
    while true
    do
        STATUS="$(docker exec -t gitlab curl -k "$GitlabReadinessURL" 2>/dev/null | jq -r '.status' 2>/dev/null)"                             # Ex: STATUS=ok
        MASTER_CHECK="$(docker exec -t gitlab curl -k "$GitlabReadinessURL" 2>/dev/null | jq -r '.master_check[0].status' 2>/dev/null)"       # Ex: MASTER_CHECK=ok
        if [ "$STATUS" = "ok" ] && [ "$MASTER_CHECK" = "ok" ]; then
            break
        fi
        sleep 15
    done
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


# Start doing some work: get the backup file and associated metadata
get_remote_file_data() {
    # Use specified listing to get date and time of backup.
    # Note: on macOS, this is '-D "format"'. On Linux, the same is done with '--time-style=full-iso'
    if [ "$RemoteHostKind" = "linux" ]; then
        RemoteFiles="$(ssh $RemoteUser@$RemoteHost "ls -lst --time-style=full-iso $RemoteDataPath/*_gitlab_backup.tar")"
    else
        RemoteFiles="$(ssh $RemoteUser@$RemoteHost "ls -lst -D \"%F %H:%M\" $RemoteDataPath/*_gitlab_backup.tar")"
    fi
    # Ex: RemoteFiles=
    # '105360000 -rw-------  1 rsync_git  staff  53944320000 2023-11-10 04:57 /Volumes/RAID/Backups/git/data/1699585267_2023_11_10_16.3.6_gitlab_backup.tar
    #  105358464 -rw-------  1 rsync_git  staff  53943531520 2023-11-09 04:55 /Volumes/RAID/Backups/git/data/1699498912_2023_11_09_16.3.6_gitlab_backup.tar
    #  105339504 -rw-------  1 rsync_git  staff  53933824000 2023-11-08 10:48 /Volumes/RAID/Backups/git/data/1699433462_2023_11_08_16.3.6_gitlab_backup.tar
    #  105333280 -rw-------  1 rsync_git  staff  53930639360 2023-11-07 04:59 /Volumes/RAID/Backups/git/data/1699326112_2023_11_07_16.3.6_gitlab_backup.tar'
    RemoteFile="$(echo "$RemoteFiles" | grep "_${TodayDate}_" 2>/dev/null | head -1)"
    # Ex: RemoteFile='99134120 -rw-------  1 username  staff  50756669440 2023-08-31 04:38 /some/path/Backups/git/1693447267_2023_08_31_16.2.4_gitlab_backup.tar'
    RemoteFileName="$(echo "$RemoteFile" | awk '{print $NF}')"                     # Ex: RemoteFileName='/some/path/Backups/git/1693447267_2023_08_31_16.2.4_gitlab_backup.tar'
    BackupFile="$(basename "$RemoteFileName" 2>/dev/null)"                         # Ex: BackupFile='1693447267_2023_08_31_16.2.4_gitlab_backup.tar'
    FileSize=$(echo "$RemoteFile" | awk '{print $6}')                              # Ex: FileSize=50756669440
    FileSizeMiB="$(printf "%'d" $((FileSize / 1048576))) MiB"                      # Ex: FileSizeMiB='48,405 MiB'
    FileSizeGiB="$(printf "%'d" $(( $((FileSize+536870912)) / 1073741824))) GiB"   # Ex: FileSizeGiB='47 GiB'
    BackupTime="$(echo "$RemoteFile" | awk '{print $7" "$8}')"                     # Ex: BackupTime='2023-08-31 04:38'
}


prepare_email() {
    # Prepare the mailbody with a header:
    EmailTempFile=$(mktemp)
    echo "To: $Recipient" >> "$EmailTempFile"
    echo "Subject: STATUS" >> "$EmailTempFile"
    echo "Content-Type: text/html" >> "$EmailTempFile"
    echo "" >> "$EmailTempFile"
    curl --silent $ReportHead | sed "s/TITLE/$TitleString/;$CSS_colorfix" >> "$EmailTempFile"
    echo '<body>' >> "$EmailTempFile"
    echo '<div class="main_page">' >> "$EmailTempFile"
    echo '  <div class="flexbox-container">' >> "$EmailTempFile"
    echo '    <div id="box-header">' >> "$EmailTempFile"
    echo '      <h3>Restore report for</h3>' >> "$EmailTempFile"
    echo '      <h1>'$GitServer'</h1>' >> "$EmailTempFile"
    echo '      <h4>'$(date "+%Y-%m-%d %T %Z")'</h4>' >> "$EmailTempFile"
    echo '    </div>' >> "$EmailTempFile"
    echo '  </div>' >> "$EmailTempFile"
    echo '  <section>' >> "$EmailTempFile"
    echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
    echo '    <p align="left">Report generated by script: <code>'$ScriptFullName'</code><br>' >> "$EmailTempFile"
    echo '      Script launched '$ScriptLaunchText' by: <code>'${ScriptLauncher:---no launcher detected--}'</code> </p>' >> "$EmailTempFile"
    echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
    echo '    <table id="jobe">' >> "$EmailTempFile"
    echo '      <thead>' >> "$EmailTempFile"
    echo '        <tr><th align="right" colspan="2">Details</th></tr>' >> "$EmailTempFile"
    echo '      </thead>' >> "$EmailTempFile"
    echo '      <tbody>' >> "$EmailTempFile"
}


# Create email for successful restore:
email_success() {
    echo '        <tr><td>Status:</td><td style="color: '$RestoreStatusTC';">'$RestoreStatus'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Restore method:</td><td>'$RestoreMethod'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Running version:</td><td>'$RunningVersion'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Version in file:</td><td>'$GitlabVersionInFile'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Source host:</td><td>'${RemoteHost}'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Source directories:</td><td><code>'$RemoteDataPath'</code> &amp;<br><code>'$RemoteConfPath'</code></td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Filename:</td><td><code>'$BackupFile'</code></td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>File size:</td><td>'$FileSizeGiB'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Copy time:</td><td>'$CopyTime'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Backup ended:</td><td>'$BackupTime' (end)</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Restore started:</td><td>'$RestoreTimeStart' (start)</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Restore duration:</td><td>'$TimeTaken'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Verify:</td><td style="color: '$VerifyStatusTC'">'$VerifyStatus'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td colspan="2">Details:</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>- import:</td><td><code>'$GitlabImportLog'</code></td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>- reconfigure:</td><td><code>'$GitlabReconfigureLog'</code></td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>- verify:</td><td><code>'$GitlabVerifyLog'</code></td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Space remaining:</td><td>'$SpaceAfterRestoreGiB' ('$SpaceAfterRestorePercent') remaining on <code>'$LocalBackupMP'</code> (<code>'$LocalBackupFS'</code>)</td></tr>' >> "$EmailTempFile"
}


# Create email for when not enogh space is available on local disk
email_not_enough_space() {
    echo '        <tr><td>Status:</td><td style="color: style="color: red">GitLab on '$GitServer' NOT restored</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Reason:</td><td>Insufficient space to perform the restore</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Filename:</td><td>'$BackupFile'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>File size:</td><td>'$(printf "%'d" $((FileSize / 1048576)))' MiB</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td>Available space:</td><td>'$(printf "%'d" $((SpaceAvailable / 1048576)))' MiB</td></tr>' >> "$EmailTempFile"
}


# Create email for when one or more files could not be fetched
email_files_broken() {
    MailSubject="GitLab on $GitServer NOT restored "
    echo '        <tr><td>Status:</td><td style="color: style="color: red">GitLab on '$GitServer' NOT restored</td></tr>' >> "$EmailTempFile"
    if [ $ES_scp_database -ne 0 ]; then
        echo '        <tr><td colspan="2">Insufficient space to perform the restore</td></tr>' >> "$EmailTempFile"
        echo '        <tr><td colspan="2">No restore performed. Error: '${ES_scp_database}'</td></tr>' >> "$EmailTempFile"
    else
        echo '        <tr><td colspan="2">Could NOT fetch some of the important config files:</td></tr>' >> "$EmailTempFile"
        echo '        <tr><td colspan="2">'$ErrortextScpConfig'</td></tr>' >> "$EmailTempFile"
    fi
}


email_db_file_not_found() {
    MailSubject="GitLab on $GitServer NOT restored (no file for today ($TodayDate) found on $RemoteHost)"
    echo '        <tr><td>Status:</td><td style="color: style="color: red">GitLab on '$GitServer' NOT restored</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td colspan="2">No file found on '$RemoteHost' (looking at <code>'$RemoteDataPath'</code> & <code>'$RemoteConfPath'</code>)</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td colspan="2">Today date:  '$TodayDate'</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td colspan="2">Files on server:</td></tr>' >> "$EmailTempFile"
    echo '        <tr><td colspan="2"><code>'$(echo "$RemoteFiles" | awk '{print $6" "$7" "$8" "$9}' | sed ':a;N;$!ba;s/\n/<br>/g')'</code></td></tr>' >> "$EmailTempFile"
}

# Send the composed email if Recipient has a value
send_email() {
    echo '      </tbody>' >> "$EmailTempFile"
    echo '    </table>' >> "$EmailTempFile"
    echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
    echo '    <p>&nbsp;</p>' >> "$EmailTempFile"
    echo '  </section>' >> "$EmailTempFile"
    echo '  <p align="center"><em>Department of Computer Science, LTH/LU</em></p>' >> "$EmailTempFile"
    echo '</div>' >> "$EmailTempFile"
    echo '</body>' >> "$EmailTempFile"
    echo '</html>' >> "$EmailTempFile"
    cat "$EmailTempFile" | sed "s/Subject: STATUS/Subject: $MailSubject/" | /sbin/sendmail -t
}


# RESTORE! This is the main function!
restore_gitlab() {
    # Create a new, empty instance
    cd /opt/gitlab/ || exit 1
    debug "performing 'docker compose up --force-recreate -d'"
    docker compose up --force-recreate -d

    # Wait until it's up
    SleepWait

    # Stop 'puma' and 'sidekiq':
    docker exec -t gitlab gitlab-ctl stop puma
    docker exec -t gitlab gitlab-ctl stop sidekiq

    RestoreTimeStart="$(date +%F" "%H:%M)"

    # Run the restore. NOTE: "_gitlab_backup.tar" is omitted from the name
    debug "performing 'gitlab-backup restore BACKUP=${BackupFile%_gitlab_backup.tar} force=yes'"
    docker exec -t gitlab sh -c "GITLAB_ASSUME_YES=1 gitlab-backup restore BACKUP=${BackupFile%_gitlab_backup.tar} force=yes" &>"$GitlabImportLog"
    #docker exec -t gitlab "GITLAB_ASSUME_YES=1 gitlab-backup restore BACKUP=${BackupFile%_gitlab_backup.tar} force=yes" &>"$GitlabImportLog"
    ES_restore_gitlab=$?
    if [ -n "$(grep 'no space left on device' "$GitlabImportLog")" ]; then
        OutOfSpace='true'
    else
        OutOfSpace='false'
    fi
    debug "restore is done. Exit status: $ES_restore_gitlab. Out-of-space: $OutOfSpace"
    if [ $ES_restore_gitlab -eq 0 ] && [ "$OutOfSpace" = 'false' ]; then
        RestoreStatus="successful"
        Level="GOOD"
        MailSubject="Restore successful"
        RestoreStatusTC="green"
    else
        RestoreStatus="unsuccessful"
        Level="CRIT"
        MailSubject="Restore unsuccessful"
        RestoreStatus="unsuccessful"
        RestoreStatusTC="red"
    fi

    echo "reconfigure of gitlab after restore" > $StopRebootFile
    debug "performing 'gitlab-ctl reconfigure'"
    docker exec -t gitlab gitlab-ctl reconfigure &>"$GitlabReconfigureLog"
    # Start gitlab again:
    docker restart gitlab

    # Wait (restart takes time):
    SleepWait

    # Check if everything is OK:
    echo "checking gitlab after restore" > "$StopRebootFile"
    debug "performing 'gitlab-rake gitlab:check SANITIZE=true'"
    docker exec -t gitlab gitlab-rake gitlab:check SANITIZE=true &>"$GitlabVerifyLog"
    ES_sanitycheck=$?
    if [ $ES_sanitycheck -eq 0 ]; then
        VerifyStatus="successful"
        VerifyStatusTC="green"
    else
        VerifyStatus="unsuccessful"
        VerifyStatusTC="red"
        # Make sure the Level is CRIT even if it was GOOD from the restore
        Level="CRIT"
    fi

    End=$(date +%s)
    Secs=$((End - Start))
    TimeTakenRaw="$((Secs/3600)) hour $((Secs%3600/60)) min $((Secs%60)) sec"
    TimeTaken="$(echo "$TimeTakenRaw" | sed 's/0 hour //;s/^0 min //')"
    SpaceAfterRestoreGiB="$(df -kh $LocalBackupDir | grep -Ev "^Fil" | awk '{print $4}' | sed 's/G$//') GiB"                                 # Ex: SpaceAfterRestoreGiB='261 GiB'
    SpaceAfterRestorePercent="$(echo "scale=0; 100 - $(df -kh $LocalBackupDir | grep -Ev "^Fil" | awk '{print $5}' | tr -d '%')" | bc -l)%"  # Ex: SpaceAfterRestorePercent=74%
}


# Copy the database backup
copy_database() {
    local CopyStart=$(date +%s)
    debug "getting the backup file ($RemoteFileName) from $RemoteHost" 
    scp $RemoteUser@$RemoteHost:"$RemoteFileName" . &>/dev/null
    chmod 644 "$BackupFile"
    ES_scp_database=$?
    CopyTimeSecs=$(( $(date +%s) - CopyStart ))
    CopyTimeRaw="$((CopyTimeSecs/3600)) hour $((CopyTimeSecs%3600/60)) min $((CopyTimeSecs%60)) sec"
    CopyTime="$(echo "$CopyTimeRaw" | sed 's/0 hour //;s/^0 min //')"
    chown 998:998 "$BackupFile" 2>/dev/null
}


# Copy everything from the config directory:
copy_config() {
    cd "$LocalConfDir" || exit 1
    scp -p "$RemoteUser@$RemoteHost:$RemoteConfPath/gitlab-secrets.json" .
    ES_scp_gitlab_secrets=$?
    [[ $ES_scp_gitlab_secrets -ne 0 ]] && ErrortextScpConfig="$RemoteHost:$RemoteConfPath/gitlab-secrets.json$NL"
    scp -p "$RemoteUser@$RemoteHost:$RemoteConfPath/ssh_*" .
    ES_scp_ssh_files=$?
    [[ $ES_scp_ssh_files -ne 0 ]] && ErrortextScpConfig+="$RemoteHost:$RemoteConfPath/ssh-files$NL"
    scp -p "$RemoteUser@$RemoteHost:$RemoteConfPath/docker-compose.yaml" /opt/gitlab/docker-compose.yaml
    ES_scp_docker_compose=$?
    [[ $ES_scp_docker_compose -ne 0 ]] && ErrortextScpConfig+="$RemoteHost:$RemoteConfPath/docker-compose.yaml$NL"
    ES_scp_config=$(( ES_scp_gitlab_secrets + ES_scp_ssh_files + ES_scp_docker_compose ))
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



Initialize

CheckRunning

script_name_location

script_launcher

delete_old_files

get_remote_file_data

# Make sure AutoReboot doesn't restart the computer
echo "gitlab restore" > $StopRebootFile

trigger_maintenance "60m"

# Go to the correct directory for backups:
cd $LocalBackupDir || exit 1

prepare_email

# Continue if a file is found on the remote server
if [ -n "$RemoteFile" ]; then
    # Continue if there’s enough space available
    if [ $(echo "$FileSize * 1.1" | bc -l | cut -d\. -f1) -lt $SpaceAvailable ]; then
        
        copy_database

        copy_config

        # Continue if the transfers of both database file and config files were successful
        if [ $ES_scp_database -eq 0 ] && [ $ES_scp_config -eq 0 ]; then

            GitlabVersionInFile="$(tar -xOf "$LocalBackupDir/$BackupFile" backup_information.yml | grep -E "^:gitlab_version" | awk '{print $NF}')"       # Ex: GitlabVersionInFile=16.2.4

            # Now delete the current one and prepare for the restore:
            # Stop running instances:
            cd /opt/gitlab/ || exit 1
            docker compose down

            # Delete the old instance (save the directory 'backups')
            mv data/backups _backups
            rm -rf data/*
            mkdir data
            mv _backups data/backups

            restore_gitlab

            email_success

            # Send notification to the CS Monitoring System ('DetailStrJSON' is constructed in 'restore_gitlab')
            notify "app.gitlab.restored" "gitlab restored $RestoreStatus in ${TimeTaken/0 hour /}. (Verify: $VerifyStatus)" "$Level" "$DetailStrJSON"

            # Delete the temporary backupfile
            rm -f "$BackupFile"
        else
            # It did not go well:
            # we could not get either the database file or the config files
            # Send notification to the CS Monitoring System ('DetailStrJSON' is constructed in 'restore_gitlab')
            notify "app.gitlab.restored" "Backup file could not be retrieved from $RemoteHost. No restore performed. Error: $ES_scp_database" "CRIT" "$DetailStrJSON"

            email_files_broken

            ## Start gitlab again:
            ##docker restart gitlab

        fi
    else
        email_not_enough_space

        DetailStrJSON='{ "filename": "'$BackupFile'", "filesize": "'$((FileSize / 1048576))' MiB", "available_local_space": "'$((SpaceAvailable / 1048576))' MiB" }'
        notify "app.gitlab.restored" "Insufficient space to perform the restore" "CRIT" "$DetailStrJSON"
    fi
else
    # File not found on $RemoteHost

    email_db_file_not_found

    DetailStrJSON='{"remote-host":"'$RemoteHost'","reporter":"'$ScriptFullName'"}'
    notify "app.gitlab.restored" "No file for today ($TodayDate) found on $RemoteHost" "CRIT" "$DetailStrJSON"
fi

send_email

# Remove the block against reboot
rm $StopRebootFile
