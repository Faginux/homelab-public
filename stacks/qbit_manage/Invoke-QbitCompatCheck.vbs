' Invoke-QbitCompatCheck.vbs — wrapper for the Scheduled Task QbitCompat-Check
' Same technique as Invoke-KometaRun.vbs: wscript.exe is a GUI subsystem, so
' no console flash. It passes the real exit code of pwsh (LastTaskResult).

Dim shell, exitCode
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ""S:\github\homelab\stacks\qbit_manage\Invoke-QbitCompatCheck.ps1""", 0, True)
WScript.Quit(exitCode)
