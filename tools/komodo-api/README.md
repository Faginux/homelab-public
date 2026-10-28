# komodo-api — Claude Code API key for Komodo

`Invoke-KomodoApi.ps1` calls the Komodo API (`/read`, `/write`, `/execute`). It uses the key of
the service user **`claude-ops`**. With this script, Claude Code manages the Stacks of
ARCADE without the UI. The reason: the action buttons of the UI do not respond to the clicks
of the browser extension (2026-10-02). For the context, read `PIANO-KOMODO-SECRETS-GATE.md`
§2b.3.

## Scope

On 2026-10-13, Faginux extended the scope. `claude-ops` is now the tool for actions on Stacks and
containers. Claude uses it **only** with the authorization of Faginux. `ListPermissions` with the
real key gives these permissions (2026-10-13, 13:36):

| What | Permission |
|---|---|
| 9 Stacks (`cleanuparr` on V4, 8 on the-grid) | Execute + Inspect + Logs |
| `tdarr`, `immich`, `qbit_manage` (V4, created by `claude-ops` on 2026-10-14) | Write + Inspect + Logs + Terminal. Komodo gives these permissions to the creator. Faginux sets them to Execute + Inspect + Logs. |
| Server `the-grid` | Read + Inspect + Logs |
| Server `arcade` | Read + Attach + Inspect + Logs. Attach lets Claude create Stacks on V4. |
| Procedure "Poll updates (mai deploy)" | Execute |

The permissions are per resource. A new Stack needs its permissions again, unless Faginux sets them
in *Base Permissions on Resource Types*.

The source of v2.3.3 shows why this scope:

- `DeployStack`, `PullStack`, `DestroyStack` and `RunStackService` need **Execute on the Stack**
  (`bin/core/src/api/execute/stack.rs`).
- Execute on a Server allows all the actions in `bin/core/src/api/execute/server.rs`:
  `StopContainer`, `DestroyContainer`, `StopAllContainers`, `DeleteImage`, `PruneImages`,
  `DeleteVolume` and `PruneVolumes`. These actions can delete data. The key does not have this
  level.
- Terminal on a Server: Periphery has the host terminal off on both Servers
  (`disable_terminals = true` on the-grid, `PERIPHERY_DISABLE_TERMINALS=true` on V4). The container
  terminal is on. Thus Terminal gives a shell in each container of the Server, and a container
  shell can read the environment of that container. The key does not have Terminal.

Before 2026-10-13 at 13:36, the key had Execute + Terminal on both Servers and Read on the Stacks.
With that scope, it could delete volumes but it could not deploy a Stack.

The test of 2026-10-02 with the first scope gave these results:

- `ListServers` returns only `arcade`.
- `ListStacks` returns only the Stacks that this user created.
- Komodo refuses `GetStack flaresolverr`.

The source of v2.3.3 shows two facts:

- Non-admin users can create Stacks. The variable `KOMODO_DISABLE_NON_ADMIN_CREATE` is not set.
- To attach a Stack to a Server, a user needs `Read` and `Attach` (`resource/stack.rs`,
  `validate_config`).

The key gives Claude no new powers on the hosts. Claude already has the Docker CLI on V4, and on
the-grid through SSH (`ops` is in the group `docker`). But the key gives a new **path**. The
pre-tool-guard and the classifier of Claude Code read shell commands. They do not read the body of
an API call. Thus, on this path, only the **Regola numero uno** (rule number one) stops a change.
Claude runs Deploy, Destroy, Delete and the container actions only with the confirmation of Faginux.

## Credentials

The credentials are in `%USERPROFILE%\.config\komodo-claude\credentials.json`. The file contains
`url`, `key` and `secret`. The file is outside the repo. Faginux wrote the file with `Read-Host`.
The file has the permissions that it inherits from `~/.config`: SYSTEM, Administrators and
`ARCADE\arcade`.

⚠️ In `icacls`, write the full name, which has the computer name and the user name:
`ARCADE\arcade`. The user name is the same as the name of the PC. The bare name resolved
as the computer account and made the directory unreadable. The fix was `icacls … /reset /T`.

To rotate the key, do these steps:

1. Create a new key in Komodo (Settings → Users → `claude-ops`).
2. Write the new credentials file.
3. Delete the old key.

## Usage

```powershell
.\Invoke-KomodoApi.ps1 -Kind read -Type ListStacks
.\Invoke-KomodoApi.ps1 -Kind execute -Type DeployStack -Params @{ stack = 'cleanuparr' }
```

The script always omits these fields from the response: `deployed_config`, `deployed_contents`,
`remote_contents`, `file_contents`, `environment`, `contents`, `secret`. In their place, it writes
`<redatto: N caratteri>`. Komodo returns errors as HTTP 500, with the message in the body.

## Run Directory of the Stacks of ARCADE

Periphery sees the repo in `/run/desktop/mnt/host/s/github/homelab` (`stacks/komodo-periphery`).
The access is read-only. The Run Directory is
`/run/desktop/mnt/host/s/github/homelab/stacks/<nome>`.
