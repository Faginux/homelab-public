# glances-lhm — CPU temperature for Glances on ARCADE

Glances on Windows shows no CPU temperature. This tool adds the sensor `Tctl` to it. The
Homepage block of ARCADE then shows the temperature like the blocks of the scope and the-grid.

## Why Glances has no temperature on Windows

Glances reads the CPU temperature only through `psutil.sensors_temperatures()`. psutil does not
have this function on Windows. Checked on 2026-10-14: Glances 4.2.1 (installed) and the `master`
branch both use only psutil, and `hasattr(psutil, 'sensors_temperatures')` is `False` with psutil
7.2.2. The Glances issue `#1824` describes the same problem. An update of Glances does not fix it.

## How it works

| Part | Detail |
|---|---|
| `glances_lhm.py` | The launcher. It adds `psutil.sensors_temperatures()` and then starts Glances. All the arguments go to Glances. |
| Source of the value | The sensor `Core (Tctl/Tdie)` of `LibreHardwareMonitorLib.dll`, loaded with `pythonnet` (`netfx` runtime). The DLL files come from the WinGet package `LibreHardwareMonitor.LibreHardwareMonitor` (0.9.6). The script copies them to `C:\Program Files\GlancesLhm\lib`. |
| Driver | PawnIO (`C:\Program Files\PawnIO`). It is already on ARCADE, and the Beszel agent uses it too. WinRing0 is not used. |
| What Glances sees | A sensor with the label `Tctl` and the type `temperature_core`. The Homepage widget `glances` looks for the labels `cpu_thermal`, `Core`, `Tctl` and `Temperature`. |
| Cache | The launcher reads the hardware at most every 4 seconds. After a failure it waits 60 seconds before the next try. |
| Failure | If the library does not load, Glances still runs. It shows no temperature. |

## Security

The service `Glances` runs as LocalSystem. It runs `glances_lhm.py` and loads the DLL files. If a
normal user can change these files, that user gets code that runs as SYSTEM at the next start of
the service. An automatic security review found this in the first version of the tool. It
used the WinGet folder in the profile of Faginux and the repository, and both are writable by a
normal user. The tool now works in this way:

- The service runs the copy in `C:\Program Files\GlancesLhm`. Only SYSTEM, Administrators and
  TrustedInstaller can write there. The launcher looks for the library in the `lib` directory
  next to it, and it does not add other directories to the search path.
- `Set-GlancesLauncher.ps1` checks the owner and the permissions of all the copied files. It stops
  before it changes the service if another user can write there.
- `C:\Python314`, with Glances and `pythonnet`, is writable by SYSTEM and Administrators only
  (checked on 2026-10-14).
- The DLL files are not signed (`Get-AuthenticodeSignature` gives `NotSigned`), so the tool cannot
  check a signature. The script shows the SHA256 of `LibreHardwareMonitorLib.dll` at each copy.
- `GLANCES_LHM_DIR` changes the library directory. It is for tests. Do not set it for the service,
  and never point it at a directory that a normal user can write.

## Install

1. Install `pythonnet` in the Python of the service (done on 2026-10-14):

   ```powershell
   C:\Python314\python.exe -m pip install "pythonnet==3.2.1"
   ```

2. Do a dry run of the switch. It reads the registry and changes nothing:

   ```powershell
   pwsh -NoProfile -File S:\github\homelab\tools\glances-lhm\Set-GlancesLauncher.ps1 -WhatIf
   ```

3. Run it in an elevated PowerShell. The script copies the launcher and the DLL files to
   `C:\Program Files\GlancesLhm` and checks the permissions there. Then it sets the parameters of
   the service, restarts the service and waits for the API. It restores the old parameters if the
   API does not come back in 60 seconds. At the end it reads the sensors and shows `Tctl`:

   ```powershell
   pwsh -NoProfile -File S:\github\homelab\tools\glances-lhm\Set-GlancesLauncher.ps1
   ```

4. Add `cputemp: true` to the block `ARCADE` in `nodes/scope/homepage/conf/widgets.yaml`.
   Do this after step 3. Before it, the block would show an empty temperature.

## Update check (a message, not an automatic copy)

Winget can update the package LibreHardwareMonitor, and the copy in `C:\Program Files\GlancesLhm`
stays old. `Invoke-GlancesLhmUpdateCheck.ps1` tells Faginux when this happens.

| What | Detail |
|---|---|
| Scheduled Task | `Glances-LhmUpdateCheck`, from 00:07 every **6 hours** (00:07, 06:07, 12:07, 18:07), user `ARCADE\arcade`, Limited, `StartWhenAvailable`, limit 5 min. No other task of ARCADE starts at these times (checked on 2026-10-15). |
| Registration | `Register-GlancesLhmUpdateCheck.ps1` (use `-WhatIf` for a dry run). It runs again without a problem to update the task. |
| Launcher | `Invoke-GlancesLhmUpdateCheck.vbs` (`wscript.exe`, no console window, it returns the exit code of pwsh). |
| What it compares | The SHA256 of each `.dll` in the root of the package folder and in `C:\Program Files\GlancesLhm\lib`. A run takes less than 1 second. |
| The 2 minutes | If the files differ, the script waits 120 seconds and compares again. It sends the message only if the difference is the same and no differing file changed in the last 120 seconds. The winget update is over. |
| Message | One Telegram message for each change, in the uniform format: `⬆️ 🖥 ARCADE · 🌡️ Glances Tctl`. It gives the old and new version and the command of `Set-GlancesLauncher.ps1`. When the copy is equal again, it sends `🔁` once. |
| State | `S:\docker-appdata\glances-lhm-check\state.json` (the change that Faginux knows) and `check.ndjson` (one line for each run). |
| Telegram | `S:\Scripts\Tmm\telegram.config.psd1`, the shared "Ops" bot. The script reads it only to send. |

**Why a message and not an automatic copy.** Faginux chose this on 2026-10-15. An automatic copy
would run as SYSTEM and copy DLL files from a folder that a normal user can write. This opens again
the weakness in the section *Security*, and now no person is in the loop. The DLL files are not
signed, so the script cannot check them. A new version of LibreHardwareMonitor can also stop
working with `pythonnet` (the runtime `netfx` needs a .NET Framework build). With the message,
Faginux runs `Set-GlancesLauncher.ps1` himself and sees `Tctl` or the warning. If you want the automatic
copy later, the script must also keep the old copy and restore it when `Tctl` is missing.

Tests (2026-10-15, in scratch folders, with a fake Telegram server on `127.0.0.1`):

- The real package and the real copy are equal: no message (`in-sync`).
- One DLL changed: one message (`sent:ok`), and the state saves the change.
- The next run for the same change: no message (`already-notified`).
- The DLL is the same again: one `🔁` message (`back-to-normal:ok`), then `in-sync`.
- A file with a time in the future (`too-recent`), and a file that changes during the 120 seconds
  (`still-changing`): no message.
- The folder of the copy does not exist (the launcher is not installed): no message (`not-deployed`).
- The real Scheduled Task, started by hand: result 0 and `in-sync` in the log.

```powershell
.\Invoke-GlancesLhmUpdateCheck.ps1 -NoSend -WaitSeconds 0   # print the message, no Telegram, state unchanged
.\Invoke-GlancesLhmUpdateCheck.ps1 -Force                   # send even if Faginux already knows this change
Unregister-ScheduledTask -TaskName Glances-LhmUpdateCheck -Confirm:$false   # remove the task
```

## Undo

```powershell
pwsh -NoProfile -File S:\github\homelab\tools\glances-lhm\Set-GlancesLauncher.ps1 -Mode Disable
```

The same result by hand: `nssm set Glances AppParameters "-m glances -w -B 198.51.100.10 -p 18208"`, then
`Restart-Service Glances`. Remove `cputemp: true` from `widgets.yaml` too. The files in
`C:\Program Files\GlancesLhm` stay. To remove them, run
`Remove-Item 'C:\Program Files\GlancesLhm' -Recurse` in an elevated shell.

## Test result (2026-10-14)

- The probe with `pythonnet` 3.2.1 on Python 3.14 read `Core (Tctl/Tdie)` = 56 °C. The CPU opened in
  0.12 s.
- The launcher ran on the test port `127.0.0.1:61299`. `GET /api/4/sensors` gave `Tctl` = 54 °C,
  the same value 5 seconds later. The test process ran in the elevated shell of Faginux, not as
  LocalSystem.
- The final layout (the launcher and a `lib` directory with the 27 DLL files, 6 MB, no extra search
  path) gave `Tctl` = 53 °C on the same test port.
- The first version of the permission check had a bug. Its mask held the composite rights `Modify`
  and `FullControl`, which also hold the read bits. So it refused the standard permissions of
  `C:\Program Files`, where `Users` can only read. Faginux found it at the first real run, and the
  service was not changed. The check now uses the write bits only and compares SIDs. Test with six
  cases: it accepts the real `C:\Program Files\GlancesLhm` and a copy where `Users` can only read.
  It refuses a copy where `Users` can change files, a copy where `Everyone` can write, the directory of
  this tool in the repository, and the WinGet directory in the profile of Faginux.

## Problems

- **No `Tctl` in `/api/4/sensors`.** Run the launcher by hand on a test port in an elevated shell
  and read the errors:

  ```powershell
  C:\Python314\python.exe "C:\Program Files\GlancesLhm\glances_lhm.py" -w -B 127.0.0.1 -p 61299
  ```

- **The block of ARCADE shows an API error, and the service is `Running`.** Windows can reserve a range of
  TCP ports above 49152 at each boot (Hyper-V, Docker). Look at `netsh interface ipv4 show excludedportrange
  protocol=tcp`. If the port of Glances is in a range, it cannot bind (`WinError 10013` when you run the
  launcher by hand), and NSSM restarts it every 11 seconds. This happened on 2026-10-17 with 61208, which was
  in 61195 to 61294. The port is now 18208, below 49152, so no range can contain it. To use another port,
  run `Set-GlancesLauncher.ps1 -Port <number>` and change the URL in `widgets.yaml`.
- **LibreHardwareMonitor gets an update, or you remove it.** The service uses its own copy, so it
  keeps working. To refresh the copy, run `Set-GlancesLauncher.ps1` again.
- **A new Python version.** You install `pythonnet` for one Python only. Install it again after
  an upgrade of `C:\Python314`.
