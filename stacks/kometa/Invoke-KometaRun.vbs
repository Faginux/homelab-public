' Invoke-KometaRun.vbs — wrapper for the Scheduled Tasks Kometa-Nightly / Kometa-Quick
' Same technique as S:\Scripts\Tmm\tmm-plex-watcher.vbs: wscript.exe is a GUI
' subsystem, so no console flash. Argument: Full | Quick.
' It passes the real exit code of pwsh (LastTaskResult of the Scheduled Task).

Dim shell, mode, exitCode
mode = "Full"
If WScript.Arguments.Count > 0 Then mode = WScript.Arguments(0)
Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run("pwsh.exe -NoProfile -ExecutionPolicy Bypass -File ""S:\github\homelab\stacks\kometa\Invoke-KometaRun.ps1"" -Mode " & mode, 0, True)
WScript.Quit(exitCode)
