' Set-ImmichMlQueue.vbs - launcher for the Scheduled Task Immich-MlQueueWindow
' wscript.exe is a GUI subsystem program, so no console window opens. The
' launcher finds the script in its own folder and returns the exit code of pwsh
' (LastTaskResult).

Dim shell, fso, folder, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
exitCode = shell.Run("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File """ & folder & "\Set-ImmichMlQueue.ps1"" -State Auto -Apply", 0, True)
WScript.Quit(exitCode)
