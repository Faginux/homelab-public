' Invoke-ServarrBackup.vbs - launcher for the Scheduled Task Servarr-Backup
' wscript.exe is a GUI program, so no console window opens. It returns the real
' exit code of PowerShell (LastTaskResult). It starts the .ps1 from its own
' folder, so the same file works in the repo and in the payload of the ISO.
' Windows PowerShell 5.1, not pwsh: a new system can have no PowerShell 7 yet.

Dim shell, fso, folder, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
exitCode = shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & folder & "\Invoke-ServarrBackup.ps1""", 0, True)
WScript.Quit(exitCode)
