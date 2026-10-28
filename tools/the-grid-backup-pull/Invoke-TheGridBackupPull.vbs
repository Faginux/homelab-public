' Invoke-TheGridBackupPull.vbs — wrapper for the Scheduled Task the-grid-BackupPull
' Same technique as Invoke-KometaRun.vbs: wscript.exe is a GUI subsystem, so
' no console flash. It passes the real exit code of pwsh (LastTaskResult).

Dim shell, exitCode
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ""S:\github\homelab\tools\the-grid-backup-pull\Invoke-TheGridBackupPull.ps1""", 0, True)
WScript.Quit(exitCode)
