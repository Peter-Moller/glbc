# GLBC
GitLab Backup and Clone

**GLBC** is a set of two `bash`-scripts doing the very common function of:

  1. Creating a backup of a GitLab server (`gitlab_backup.sh`)
  2. Restore that backup to another server, such as a testserveri (`gitlab_clone.sh`)

The backup file is stored on a [separate] file server.

-----

### Assumptions

  * A docker based GitLab system, running on a Linux system
  * A `/opt/gitlab/docker-compose.yaml` file
  * Working `scp` and `rsync` and access between the machines involved

-----

### Settings file

In order to work, a settings file is required.

#### .gitlab_backup.settings
```bash
GitServer="git.dns.name"
MainServer="git"
ReplicaServer="git-test"
LocalBackupDir="/opt/gitlab/data/backups"
LocalConfDir="/opt/gitlab/config"
RemoteUser="username"
RemoteHost="storage.dns.name"
RemotePath="/some/directory/"
RemoteHostKind=darwin
BackupSignalFile=/opt/gitlab/embedded/service/gitlab-rails/tmp/backup_restore.pid
StopRebootFile=/tmp/dont_reboot
Recipient=user@system.dns.name
DeleteFilesNumDays=2
```


## Output

The scripts will send reports to a email (if given in the settings file) after processing is done.

### gitlab_backup.sh
```text
Backup report from git.dns.name (script: "/home/username/glbc/gitlab_backup.sh") at 2023-09-07 04:56 CEST

BACKUP of git.cs.lth.se:
=================================================
File name:        1694052066_2023_09_07_16.3.1_gitlab_backup.tar
File size:        48 GiB
Version in file:  16.3.1
Backup started:   2023-09-07 04:00 CEST
Time taken:       36 min 30 sec
Space:            89 GiB remaining on /opt/gitlab/data/backups

RSYNC to storage.dns.name:
=================================================
Backup directory: /opt/gitlab/data/backups  ->  /some/path/Backups/git/data
Config directory: /opt/gitlab/config  ->  /some/path/Backups/git/config
Number of files:  1
Bytes trasferred: 49,434 MiB
Time taken:       19 min 37 sec
```

### gitlab_clone.sh
```text
Restore report from git-test (script: "/home/username/glbc/gitlab_clone.sh")  at 2023-09-07 07:10 CEST

Gitlab restored successfully.

Details:
=================================================
Running version:   gitlab-ce 16.3.1
Version in file:   16.3.1
Source:            storage.dns.name:/some/path/Backups/git
Filename:          1694052066_2023_09_07_16.3.1_gitlab_backup.tar
Backup ended:      2023-09-07 04:36 (end)
Restore started:   2023-09-07 06:44 (start)
Restore duration:  40 min 0 sec
File size:         48 GiB
Space remaining:   110 GiB remaining on /opt/gitlab/data/backups
Verify:            correct
Details:
- import:          /var/tmp/gitlab_importlogg_2023-09-07.txt
- reconfigure:     /var/tmp/gitlab_reconfigurelogg_2023-09-07.txt
- verify:          /var/tmp/gitlab_verifylogg_2023-09-07.txt
```
