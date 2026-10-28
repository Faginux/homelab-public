' Invoke-ComposeDriftCheck.vbs - launcher for the Scheduled Task Compose-Drift-Check
' Same method as Invoke-QbitCompatCheck.vbs: wscript.exe is a GUI subsystem
' program, so no console window opens. It returns the real exit code of pwsh
' (LastTaskResult).

Dim shell, exitCode
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ""S:\github\homelab\tools\compose-drift-check\Invoke-ComposeDriftCheck.ps1""", 0, True)
WScript.Quit(exitCode)
