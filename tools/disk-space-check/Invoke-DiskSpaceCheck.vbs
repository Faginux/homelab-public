' Invoke-DiskSpaceCheck.vbs - launcher for the Scheduled Task DiskSpace-Check
' Same method as Invoke-GlancesLhmUpdateCheck.vbs: wscript.exe is a GUI subsystem
' program, so no console window opens. It returns the real exit code of pwsh
' (LastTaskResult).

Dim shell, exitCode
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ""S:\github\homelab\tools\disk-space-check\Invoke-DiskSpaceCheck.ps1""", 0, True)
WScript.Quit(exitCode)
