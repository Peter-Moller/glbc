# GLBC
GitLab Backup and Clone


### .gitlab_backup.settings
```bash
GitServer="git.dns.name"
MasterServer="git"
LocalDataDir="/opt/gitlab/data/backups"
LocalConfDir="/opt/gitlab/config"
RemoteUser="username"
RemoteHost="storage.dns.name"
RemoteDataDir="/some/directory/$MasterServer"
RemoteConfDir="/some/directory/${MasterServer}_config"
BackupSignalFile=/opt/gitlab/embedded/service/gitlab-rails/tmp/backup_restore.pid
StopRebootFile=/tmp/dont_reboot
Recipient=user@system.dns.name
DeleteFilesNumDays=2
```
