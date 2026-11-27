# arr-api

This tool reads the configuration of Sonarr, Radarr and Prowlarr on ARCADE. It also changes
a small part of Sonarr and Radarr from an approved plan. Claude Code uses it with the skill
`arr-changes`.

## Scope

| The tool can change | The tool cannot change |
|---|---|
| Custom formats: make one, change its name and conditions | Delete anything |
| Scores of custom formats in the quality profiles | Quality order, cutoff quality and profile names |
| `upgradeAllowed`, `minFormatScore`, `cutoffFormatScore`, `minUpgradeFormatScore` | Media management, download clients, indexers |
| Monitored flag of a series, a season, an episode and a movie | Search, download, rename and all other commands |

The tool only reads Prowlarr. The tool does not support Cleanuparr.

## Files

| File | Function |
|---|---|
| `ArrApi.psm1` | The connection, the resource table, the write table, the body check and the leak check |
| `ArrPlan.psm1` | The offline logic: plan checks, comparisons, write bodies, restore bodies, the table |
| `Get-ArrSnapshot.ps1` | Writes one snapshot folder with one JSON file for each resource |
| `New-ArrPlan.ps1` | Makes a plan file from a change file. It adds the SHA-256 values. Offline |
| `Show-ArrPlan.ps1` | Checks a plan and prints the table, the warnings, the hash and the command. Offline |
| `Invoke-ArrPlan.ps1` | Applies one approved plan. It is the only command that changes data |
| `Test-ArrApi.ps1` | Offline tests of the module and static tests of the source files |
| `Test-ArrPlan.ps1` | Tests of complete batches against a false server |
| `Start-FakeArrServer.ps1` | The false Sonarr and Radarr on `127.0.0.1` for `Test-ArrPlan.ps1` |
## Read

```powershell
.\Get-ArrSnapshot.ps1 -App sonarr,radarr
.\Get-ArrSnapshot.ps1 -App sonarr -SeriesId 12,40    # adds the episodes of two series
```

The default output folder is `S:\docker-appdata\arr-api\snapshots`, outside the repo.
`-App` and `-SeriesId` are text parameters. With `pwsh -File`, a list such as `a,b` is one text.
A number parameter reads the text `1,2` as the number 12.

## Write

One batch has these steps:

1. Make a snapshot. For a change of a series, a season or an episode, use `-SeriesId`.
2. Write a change file (JSON) outside the repo.
3. Run `New-ArrPlan.ps1 -ChangePath <change> -SnapshotPath <folder> -OutputPath <plan>`.
4. Run `Show-ArrPlan.ps1 -PlanPath <plan>`.
5. Get the approval of the table.
6. Run the apply command that `Show-ArrPlan.ps1` printed. Use a time limit of 10 minutes.

### Change file

```json
{
  "operations": [
    { "op": "createCustomFormat", "app": "sonarr", "ref": "new1",
      "definition": { "name": "Example", "includeCustomFormatWhenRenaming": false,
        "specifications": [
          { "name": "Word", "implementation": "ReleaseTitleSpecification", "negate": false,
            "required": true, "fields": [ { "name": "value", "value": "\\bExample\\b" } ] } ] } },
    { "op": "updateQualityProfile", "app": "sonarr", "id": 4,
      "set": { "minUpgradeFormatScore": 101 },
      "scores": [ { "ref": "new1", "score": 25 }, { "formatId": 12, "score": 0 } ] },
    { "op": "monitorSeries",   "app": "sonarr", "ids": [ 12 ], "monitored": false },
    { "op": "monitorSeason",   "app": "sonarr", "seriesId": 12, "seasonNumber": 2, "monitored": false },
    { "op": "monitorEpisodes", "app": "sonarr", "seriesId": 12, "ids": [ 900, 901 ], "monitored": false },
    { "op": "monitorMovies",   "app": "radarr", "ids": [ 20 ], "monitored": true }
  ],
  "parseTests": [
    { "app": "sonarr", "kind": "match", "customFormat": "Example", "title": "<title>", "expectedScore": 25 },
    { "app": "sonarr", "kind": "unchanged", "title": "<title 2>" },
    { "app": "sonarr", "kind": "unchanged", "title": "<title 3>" }
  ]
}
```

- `updateCustomFormat` has `id` and the full new `definition`. Copy the definition from the
  snapshot, with only `name` and `value` in each field. Then change it.
- `monitorSeason` changes only the season flag. The web UI also changes the episodes. Add
  `monitorEpisodes` for the episodes. The table warns if they differ.
- Each operation must change a value.

### Parse tests

A plan that changes a custom format or a score needs these tests for each app:

- one `match` test for each custom format that changes
- two `unchanged` tests with different titles

A `noMatch` test is optional. Use it for a title that must stop to match. Each title must match
a series or a movie of the library. For each `match` and `noMatch` test, the score of the answer
must be equal to the sum of the planned scores. `expectedScore` is optional and adds one more
check.

### Plan checks

`Show-ArrPlan.ps1` gives no table and no command if the plan has an error. Examples:

- an unknown key, operation or app, an id that is not in the snapshot, or no real change
- a profile that the app would reject
- a new custom format with `includeCustomFormatWhenRenaming = true`
- a condition type that the snapshot does not have, or fields that differ from the existing ones
- **Negate rule:** conditions of one type include a `Negate`, and one of them is not `Required`

The reason for the Negate rule: the app accepts the conditions of one type if each `Required`
one passes and one of them passes. A `Negate` passes for almost each title. Next to an optional
condition, the custom format then matches almost each title, or the `Negate` has no effect.
An existing group that the plan does not change gives only a warning.

## Apply

`Invoke-ArrPlan.ps1 -PlanPath <plan> -PlanSha256 <hash>` does these steps:

1. It compares the hash of the plan and of each snapshot file. A lock stops a second apply.
2. It does the plan checks again.
3. It reads the live objects. It stops if a version differs from the verified one, or if an
   object differs from the snapshot. For custom formats and profiles, it compares all of them.
4. It writes a backup and a copy of the plan into `S:\docker-appdata\arr-api\runs\<time>`.
5. It runs the parse tests.
6. It writes in this order: monitoring off, new custom formats, changed custom formats,
   profiles, monitoring on. It reads the app again after each write.
7. It compares all custom formats, all scores and all profile fields with "backup plus plan".
8. It runs the parse tests again.
9. It writes a final snapshot.

| Exit code | Meaning |
|---|---|
| 0 | The script applied the batch and all checks passed |
| 1 | The batch failed. The restore is complete |
| 2 | The batch failed and the restore is **not** complete |
| 3 | The script stopped before the first write |

### Restore

At the first error after a write, the script restores the written objects in the reverse order.
It also restores a write that got no answer. Then it reads the apps and compares them with the
backup. The read decides the result.

- The restore deletes nothing. A new custom format stays, with the score 0 in each profile.
- The restore changes only the objects of the batch. If an other object differs, the script
  reports it (exit code 2) and does not change it.
- To undo a batch that succeeded, make a new plan with the opposite changes.

## Safety

- The module sends GET, POST and PUT requests. It has three request commands. A static test
  makes sure of this and finds no command that deletes or moves a file.
- A caller gives a resource name or an operation name, not a path.
- A write body can have only the keys of its operation. The names are case sensitive. The
  module does this check before it reads a key. Thus `moveFiles`, `rootFolderPath`,
  `deleteFiles` and `monitoringOptions` cannot go out.
- The module reads each API key from `config.xml` when it sends a request. It makes no copy.
- For the lists of Prowlarr, only the listed properties go out. The property `fields` is not
  in a list, because it holds keys, passkeys and cookies.
- A leak check stops a resource or a body if it has a loaded key, a secret parameter in a URL
  or a secret property.
- These are precautions. The scripts run with your user, thus they do not isolate the keys
  from other processes of that user.

## API facts and versions

A person compared these facts with the official source code, tags `v4.0.20.3014` (Sonarr) and
`v7.0.3.10918` (Radarr):

| Request | Fact |
|---|---|
| `PUT series/editor`, `PUT movie/editor` | The same route accepts `rootFolderPath` and `moveFiles`, and `DELETE` deletes items. The app builds a new path only if `rootFolderPath` arrives. The database does not store it |
| `POST seasonpass` | With no `monitoringOptions`, it changes only the flags in the body. With this key, it changes each episode of the series |
| `PUT episode/monitor` | An absent `monitored` is `false` |
| `POST customformat` | The app adds the new custom format to each profile with the score 0 |
| `PUT qualityprofile/{id}` | It needs the full profile with all custom formats |
| `GET parse` | The score is 0 if the title matches no item of the library |

If a version differs, `Show-ArrPlan.ps1` and `Invoke-ArrPlan.ps1` stop. After an update of an
app, compare these files of the new tag: `CustomFormatController`, `QualityProfileController`,
`QualityProfileResource`, `SeriesEditorController`, `SeasonPassController`,
`EpisodeMonitoredService`, `EpisodeController`, `MovieEditorController`, `MovieService`,
`SeriesService`, `ParseController` and `SpecificationMatchesGroup`. Then change
`$script:VerifiedVersion` in `ArrApi.psm1` and run both tests.

## Tests

```powershell
.\Test-ArrApi.ps1     # no request, no config.xml
.\Test-ArrPlan.ps1    # a false server on 127.0.0.1
```

`Test-ArrPlan.ps1` sets `ProgramData` of its own process to a folder with a false
`config.xml`. Thus the module reads a false key and the port of the false server. The module
has no code for the test. The test keeps its work folder in the temporary folder.

## Test status on the live apps

On 2026-11-27, with Sonarr 4.0.20.3014, one batch changed `minUpgradeFormatScore` of one
quality profile, and a second batch changed it back. Both ended with exit code 0. Each apply
took 5.5 s. The SHA-256 of each Sonarr snapshot file was equal before and after the two
batches. The `parse` read and the `episode` read also worked on the live apps.

These parts ran **only** against the false server: a new or changed custom format, a score
change, each monitor write, parse tests during an apply, a restore and each write to Radarr.
For the first live use of one of these parts, use a small batch.

## Limits

- A killed process does not restore. The run folder then has `backup`, `plan.json` and
  `journal.jsonl`.
- A parse test examines only the title. For the cause of an upgrade, read the History of the
  episode or the movie in the app.
- Do not change the same objects in the web UI during an apply. A restore of a profile writes
  the full profile of the backup.
- The Recyclarr information compares names. It does not compare TRaSH ids.

## Permissions

On 2026-11-27, an `ask` rule gave no prompt in auto mode. Thus the tool does not use a
permission rule as a safety control.

## Not in this version

Cleanuparr, history, queue and episode files.
