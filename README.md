# GLBC
GitLab Backup and Clone

**GLBC** is a set of two `bash`-scripts doing the very common function of:

  1. Creating a backup of a GitLab server
  2. Restore that backup to another server (such as a testserver)

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
MasterServer="git"
LocalBackupDir="/opt/gitlab/data/backups"
LocalConfDir="/opt/gitlab/config"
RemoteUser="username"
RemoteHost="storage.dns.name"
RemotePath="/some/directory/"
RemoteDataDir="/some/directory/$MasterServer"
RemoteConfDir="/some/directory/${MasterServer}_config"
BackupSignalFile=/opt/gitlab/embedded/service/gitlab-rails/tmp/backup_restore.pid
StopRebootFile=/tmp/dont_reboot
Recipient=user@system.dns.name
DeleteFilesNumDays=2
```
