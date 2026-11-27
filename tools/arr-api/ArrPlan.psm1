# ArrPlan.psm1 - v0.1 (2026-11-27). The offline logic of a plan of the arr-api tool.
#
# This module sends no request and reads no config.xml. It does these tasks:
# - It reads a plan file and its snapshot, and it compares the SHA-256 values.
# - It finds the errors and the warnings of a plan.
# - It changes the state of the apps into a flat list of facts, for each comparison.
# - It makes the body of each write and of each restore.
# - It makes the table that a person approves.
#
# A fact is one value with one key, for example "sonarr/profile/7/score/12" = "2250".
#
# Made with Claude Code (Anthropic).

Set-StrictMode -Version 3.0

# Required and optional keys of each operation, and the apps that accept it.
$script:OperationRule = @{
    createCustomFormat   = @{ Apps = @('sonarr', 'radarr'); Required = @('op', 'app', 'ref', 'definition'); Optional = @(); Rank = 2 }
    updateCustomFormat   = @{ Apps = @('sonarr', 'radarr'); Required = @('op', 'app', 'id', 'definition'); Optional = @(); Rank = 3 }
    updateQualityProfile = @{ Apps = @('sonarr', 'radarr'); Required = @('op', 'app', 'id'); Optional = @('set', 'scores'); Rank = 4 }
    monitorSeries        = @{ Apps = @('sonarr'); Required = @('op', 'app', 'ids', 'monitored'); Optional = @(); Rank = $null }
    monitorSeason        = @{ Apps = @('sonarr'); Required = @('op', 'app', 'seriesId', 'seasonNumber', 'monitored'); Optional = @(); Rank = $null }
    monitorEpisodes      = @{ Apps = @('sonarr'); Required = @('op', 'app', 'seriesId', 'ids', 'monitored'); Optional = @(); Rank = $null }
    monitorMovies        = @{ Apps = @('radarr'); Required = @('op', 'app', 'ids', 'monitored'); Optional = @(); Rank = $null }
}

# The only fields of a quality profile that a plan can change, apart from the scores.
$script:ProfileSetting = @('upgradeAllowed', 'minFormatScore', 'cutoffFormatScore', 'minUpgradeFormatScore')

# All properties of a quality profile in the verified versions. The tool sends back the
# full object, thus an unknown property stops it.
$script:ProfileProperty = @{
    sonarr = @('id', 'name', 'upgradeAllowed', 'cutoff', 'items', 'minFormatScore', 'cutoffFormatScore', 'minUpgradeFormatScore', 'formatItems')
    radarr = @('id', 'name', 'upgradeAllowed', 'cutoff', 'items', 'minFormatScore', 'cutoffFormatScore', 'minUpgradeFormatScore', 'formatItems', 'language')
}

# --- Small helpers ------------------------------------------------------------

function Get-ArrValue {
    # The value of a property, or $null if the object has no such property.
    # PowerShell unrolls a list here. To find if a value is a list, read the property.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-ArrKeyProblem {
    # The names are case sensitive.
    param($Object, [string[]]$Required, [string[]]$Optional = @(), [string]$Location)
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return "$Location must be an object." }
    $names = [string[]]@($Object.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($names -cnotcontains $name) { "$Location has no key '$name'." }
    }
    foreach ($name in $names) {
        if ($Required -cnotcontains $name -and $Optional -cnotcontains $name) { "$Location has the key '$name', which is not permitted." }
    }
}

function Test-ArrInteger {
    param($Value)
    ($Value -is [int] -or $Value -is [long]) -and $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue
}

function ConvertFrom-ArrJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $Text | ConvertFrom-Json -Depth 64 -DateKind String -NoEnumerate -ErrorAction Stop
}

function ConvertTo-ArrCanonical {
    # A stable text of a value: the keys of an object are sorted, and a null property has no effect.
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [string]) { return (ConvertTo-Json -InputObject $Value -Compress) }
    if ($Value -is [System.ValueType]) { return [System.Convert]::ToString($Value, [cultureinfo]::InvariantCulture) }
    $pairs = $null
    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = @{}
        foreach ($key in $Value.Keys) { $pairs[[string]$key] = $Value[$key] }
    } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        $pairs = @{}
        foreach ($property in $Value.PSObject.Properties) { $pairs[$property.Name] = $property.Value }
    }
    if ($null -ne $pairs) {
        $names = [string[]]@($pairs.Keys)
        [array]::Sort($names, [System.StringComparer]::Ordinal)
        $parts = foreach ($name in $names) {
            if ($null -ne $pairs[$name]) { '{0}:{1}' -f (ConvertTo-Json -InputObject $name -Compress), (ConvertTo-ArrCanonical -Value $pairs[$name]) }
        }
        return '{' + (@($parts) -join ',') + '}'
    }
    $entries = foreach ($entry in $Value) { ConvertTo-ArrCanonical -Value $entry }
    '[' + (@($entries) -join ',') + ']'
}

function ConvertTo-ArrFormatDefinition {
    # The part of a custom format that the tool compares and sends. The apps add more
    # properties to each field (label, help text). The tool ignores them.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CustomFormat)

    [ordered]@{
        name                            = [string]$CustomFormat.name
        includeCustomFormatWhenRenaming = [bool]$CustomFormat.includeCustomFormatWhenRenaming
        specifications                  = @(foreach ($specification in @($CustomFormat.specifications)) {
                [ordered]@{
                    name           = [string]$specification.name
                    implementation = [string]$specification.implementation
                    negate         = [bool]$specification.negate
                    required       = [bool]$specification.required
                    fields         = @(foreach ($field in @($specification.fields)) {
                            $value = Get-ArrValue -Object $field -Name 'value'
                            if ($null -ne $value) { [ordered]@{ name = [string]$field.name; value = $value } }
                        })
                }
            })
    }
}

function Get-ArrFormatKey {
    # The canonical text of a custom format. The order of the fields has no effect.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$CustomFormat)

    $definition = ConvertTo-ArrFormatDefinition -CustomFormat $CustomFormat
    foreach ($specification in $definition.specifications) {
        $specification.fields = @($specification.fields | Sort-Object -Property { $_.name })
    }
    ConvertTo-ArrCanonical -Value $definition
}

# --- Plan and snapshot --------------------------------------------------------

function Get-ArrFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][byte[]]$Byte)
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Byte))
}

function Read-ArrPlanFile {
    # The hash and the content come from the same bytes, thus the file cannot change between them.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath)
    $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
    [pscustomobject]@{
        Sha256 = Get-ArrFileSha256 -Byte $bytes
        Byte   = $bytes
        Plan   = ConvertFrom-ArrJson -Text $text
    }
}

function Get-ArrPlanShapeError {
    # The form of the plan. The other checks need a correct form.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $problems = @(Get-ArrKeyProblem -Object $Plan -Required 'planVersion', 'snapshot', 'snapshotFiles', 'operations', 'parseTests' -Location 'The plan')
    if ($problems.Count) { return $problems }
    if ($Plan.planVersion -ne 1) { return 'planVersion must be 1.' }
    if ($Plan.operations -isnot [array] -or $Plan.operations.Count -eq 0) { return 'operations must be a list with one entry or more.' }
    if ($Plan.parseTests -isnot [array]) { return 'parseTests must be a list.' }

    $references = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $index = 0
    foreach ($operation in $Plan.operations) {
        $location = "operations[$index]"
        $index++
        $type = [string](Get-ArrValue -Object $operation -Name 'op')
        if (-not $type -or [string[]]@($script:OperationRule.Keys) -cnotcontains $type) { "$location has an unknown operation '$type'."; continue }
        $rule = $script:OperationRule[$type]
        $keyProblems = @(Get-ArrKeyProblem -Object $operation -Required $rule.Required -Optional $rule.Optional -Location $location)
        if ($keyProblems.Count) { $keyProblems; continue }
        if ($rule.Apps -cnotcontains [string]$operation.app) { "$location ($type) is not permitted for the app '$($operation.app)'."; continue }

        foreach ($name in 'id', 'seriesId', 'seasonNumber') {
            if ($rule.Required -ccontains $name -and -not (Test-ArrInteger -Value $operation.$name)) { "$location.$name must be a whole number." }
        }
        if ($rule.Required -ccontains 'monitored' -and $operation.monitored -isnot [bool]) { "$location.monitored must be true or false." }
        if ($rule.Required -ccontains 'ids') {
            $ids = @($operation.ids)
            if ($operation.ids -isnot [array] -or $ids.Count -eq 0 -or @($ids | Where-Object { -not (Test-ArrInteger -Value $_) }).Count) {
                "$location.ids must be a list of whole numbers."
            } elseif (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
                "$location.ids has a number two times."
            }
        }
        if ($rule.Required -ccontains 'definition') {
            $definitionProblems = @(Get-ArrKeyProblem -Object $operation.definition -Required 'name', 'includeCustomFormatWhenRenaming', 'specifications' -Location "$location.definition")
            if ($definitionProblems.Count) { $definitionProblems; continue }
            if ($operation.definition.includeCustomFormatWhenRenaming -isnot [bool]) { "$location.definition.includeCustomFormatWhenRenaming must be true or false." }
            if ($operation.definition.specifications -isnot [array] -or $operation.definition.specifications.Count -eq 0) { "$location.definition needs one condition or more."; continue }
            $number = 0
            foreach ($specification in $operation.definition.specifications) {
                $specificationLocation = "$location.definition.specifications[$number]"
                $number++
                $specificationProblems = @(Get-ArrKeyProblem -Object $specification -Required 'name', 'implementation', 'negate', 'required', 'fields' -Location $specificationLocation)
                if ($specificationProblems.Count) { $specificationProblems; continue }
                if ($specification.negate -isnot [bool] -or $specification.required -isnot [bool]) { "$specificationLocation needs true or false for negate and required." }
                if ($specification.fields -isnot [array] -or $specification.fields.Count -eq 0) { "$specificationLocation.fields must be a list with one entry or more."; continue }
                foreach ($field in $specification.fields) { Get-ArrKeyProblem -Object $field -Required 'name', 'value' -Location "$specificationLocation.fields" }
            }
        }
        if ($type -ceq 'createCustomFormat') {
            if ($operation.ref -isnot [string] -or -not $operation.ref) { "$location.ref must be a text." }
            elseif (-not $references.Add("$($operation.app)/$($operation.ref)")) { "$location.ref '$($operation.ref)' occurs two times." }
        }
        if ($type -ceq 'updateQualityProfile') {
            $set = Get-ArrValue -Object $operation -Name 'set'
            $scores = $null
            if ($operation.PSObject.Properties['scores']) { $scores = $operation.scores }
            if ($null -eq $set -and $null -eq $scores) { "$location needs 'set' or 'scores'." }
            if ($null -ne $set) { Get-ArrKeyProblem -Object $set -Required @() -Optional $script:ProfileSetting -Location "$location.set" }
            if ($null -ne $scores) {
                if ($scores -isnot [array] -or $scores.Count -eq 0) { "$location.scores must be a list with one entry or more." }
                else {
                    foreach ($entry in $scores) {
                        $target = if ($null -ne (Get-ArrValue -Object $entry -Name 'ref')) { 'ref' } else { 'formatId' }
                        $entryProblems = @(Get-ArrKeyProblem -Object $entry -Required $target, 'score' -Location "$location.scores")
                        if ($entryProblems.Count) { $entryProblems; continue }
                        if (-not (Test-ArrInteger -Value $entry.score)) { "$location.scores: each score must be a whole number." }
                        if ($target -eq 'formatId' -and -not (Test-ArrInteger -Value $entry.formatId)) { "$location.scores: formatId must be a whole number." }
                    }
                }
            }
        }
    }

    $index = 0
    foreach ($test in $Plan.parseTests) {
        $location = "parseTests[$index]"
        $index++
        $kind = [string](Get-ArrValue -Object $test -Name 'kind')
        if ($kind -cnotin 'match', 'noMatch', 'unchanged') { "$location.kind must be match, noMatch or unchanged."; continue }
        $required = @('app', 'kind', 'title')
        $optional = @()
        if ($kind -cne 'unchanged') { $required += 'customFormat'; $optional = @('expectedScore') }
        $testProblems = @(Get-ArrKeyProblem -Object $test -Required $required -Optional $optional -Location $location)
        if ($testProblems.Count) { $testProblems; continue }
        if ($test.app -cnotin 'sonarr', 'radarr') { "$location.app must be sonarr or radarr." }
        if ($test.title -isnot [string] -or -not $test.title.Trim()) { "$location.title must be a text." }
        $expected = Get-ArrValue -Object $test -Name 'expectedScore'
        if ($null -ne $expected -and -not (Test-ArrInteger -Value $expected)) { "$location.expectedScore must be a whole number." }
    }
}

function Get-ArrPlanScope {
    # For each app of the plan: the type of the work and the objects that it touches.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $scope = [ordered]@{}
    foreach ($operation in $Plan.operations) {
        $app = [string]$operation.app
        if (-not $scope.Contains($app)) {
            $scope[$app] = @{
                FormatWork = $false; SeriesWork = $false; MovieWork = $false
                SeriesIds  = [System.Collections.Generic.SortedSet[int]]::new()
                EpisodeIds = [System.Collections.Generic.HashSet[int]]::new()
                MovieIds   = [System.Collections.Generic.HashSet[int]]::new()
            }
        }
        $entry = $scope[$app]
        switch -CaseSensitive ($operation.op) {
            { $_ -cin 'createCustomFormat', 'updateCustomFormat', 'updateQualityProfile' } { $entry.FormatWork = $true }
            'monitorSeries' { $entry.SeriesWork = $true; foreach ($id in $operation.ids) { [void]$entry.SeriesIds.Add($id) } }
            'monitorSeason' { $entry.SeriesWork = $true; [void]$entry.SeriesIds.Add($operation.seriesId) }
            'monitorEpisodes' {
                $entry.SeriesWork = $true
                [void]$entry.SeriesIds.Add($operation.seriesId)
                foreach ($id in $operation.ids) { [void]$entry.EpisodeIds.Add($id) }
            }
            'monitorMovies' { $entry.MovieWork = $true; foreach ($id in $operation.ids) { [void]$entry.MovieIds.Add($id) } }
        }
    }
    $scope
}

function Get-ArrRequiredResource {
    # The resources that a plan needs. The snapshot, the backup and each read use this list.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Scope)

    foreach ($app in $Scope.Keys) {
        $entry = $Scope[$app]
        $names = [System.Collections.Generic.List[string]]::new()
        $names.Add('status')
        if ($entry.FormatWork) {
            $names.Add('customformat')
            $names.Add('qualityprofile')
            $names.Add($(if ($app -eq 'sonarr') { 'series' } else { 'movie' }))
        }
        if ($entry.SeriesWork) { $names.Add('series') }
        if ($entry.MovieWork) { $names.Add('movie') }
        foreach ($name in @($names | Select-Object -Unique)) {
            [pscustomobject]@{ App = $app; Name = $name; QueryValue = $null; File = "$app-$name.json" }
        }
        foreach ($id in $entry.SeriesIds) {
            [pscustomobject]@{ App = $app; Name = 'episode'; QueryValue = [string]$id; File = "$app-episode-$id.json" }
        }
    }
}

function ConvertTo-ArrState {
    # State[app][resource] is a list. The episodes of all series go into one list.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Resource,
        [Parameter(Mandatory)][System.Collections.IDictionary]$TextByFile
    )
    $state = @{}
    foreach ($item in $Resource) {
        if (-not $state.ContainsKey($item.App)) { $state[$item.App] = @{ episode = @() } }
        $data = ConvertFrom-ArrJson -Text $TextByFile[$item.File]
        if ($item.Name -eq 'episode') {
            $state[$item.App].episode = @($state[$item.App].episode) + @($data)
        } else {
            $state[$item.App][$item.Name] = @($data)
        }
    }
    $state
}

function Read-ArrBaseline {
    # Reads the snapshot files of the plan. A file that is not equal to its hash stops the read.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $resources = @(Get-ArrRequiredResource -Scope (Get-ArrPlanScope -Plan $Plan))
    $listed = $Plan.snapshotFiles
    $listedNames = [string[]]@($listed.PSObject.Properties.Name)
    foreach ($item in $resources) {
        if ($listedNames -cnotcontains $item.File) { throw "snapshotFiles has no entry for $($item.File). Make a snapshot that has it." }
    }
    $texts = @{}
    foreach ($name in $listedNames) {
        if ($name -notmatch '\A[a-z0-9-]+\.json\z') { throw "snapshotFiles has a name that is not permitted: $name." }
        $path = Join-Path ([string]$Plan.snapshot) $name
        if (-not (Test-Path -LiteralPath $path)) { throw "The snapshot file $path does not exist." }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ((Get-ArrFileSha256 -Byte $bytes) -ne [string]$listed.$name) { throw "The snapshot file $name is not equal to its SHA-256 in the plan." }
        $texts[$name] = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    ConvertTo-ArrState -Resource $resources -TextByFile $texts
}

# --- Facts ----------------------------------------------------------------------

function Get-ArrFactSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Scope
    )
    $facts = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($app in $Scope.Keys) {
        $entry = $Scope[$app]
        $data = $State[$app]
        if ($entry.FormatWork) {
            foreach ($format in $data.customformat) { $facts["$app/cf/$($format.id)"] = Get-ArrFormatKey -CustomFormat $format }
            foreach ($qualityProfile in $data.qualityprofile) {
                $prefix = "$app/profile/$($qualityProfile.id)"
                $core = @{}
                foreach ($property in $qualityProfile.PSObject.Properties) {
                    if ($property.Name -cnotin (@('id', 'formatItems') + $script:ProfileSetting)) { $core[$property.Name] = $property.Value }
                }
                $facts["$prefix/core"] = ConvertTo-ArrCanonical -Value $core
                foreach ($name in $script:ProfileSetting) { $facts["$prefix/$name"] = ConvertTo-ArrCanonical -Value $qualityProfile.$name }
                foreach ($item in $qualityProfile.formatItems) { $facts["$prefix/score/$($item.format)"] = [string]$item.score }
            }
        }
        if ($entry.SeriesWork) {
            foreach ($series in $data.series) {
                $prefix = "$app/series/$($series.id)"
                $facts["$prefix/monitored"] = ConvertTo-ArrCanonical -Value ([bool]$series.monitored)
                foreach ($season in $series.seasons) { $facts["$prefix/season/$($season.seasonNumber)"] = ConvertTo-ArrCanonical -Value ([bool]$season.monitored) }
                if ($entry.SeriesIds.Contains([int]$series.id)) {
                    $facts["$prefix/info"] = ConvertTo-ArrCanonical -Value ($series | Select-Object -Property title, year, qualityProfileId, seriesType, path)
                }
            }
            foreach ($episode in $data.episode) {
                $prefix = "$app/episode/$($episode.id)"
                $facts["$prefix/monitored"] = ConvertTo-ArrCanonical -Value ([bool]$episode.monitored)
                if ($entry.EpisodeIds.Contains([int]$episode.id)) {
                    $facts["$prefix/info"] = ConvertTo-ArrCanonical -Value ($episode | Select-Object -Property seriesId, seasonNumber, episodeNumber, title)
                    $facts["$prefix/hasFile"] = ConvertTo-ArrCanonical -Value (Get-ArrValue -Object $episode -Name 'hasFile')
                }
            }
        }
        if ($entry.MovieWork) {
            foreach ($movie in $data.movie) {
                $prefix = "$app/movie/$($movie.id)"
                $facts["$prefix/monitored"] = ConvertTo-ArrCanonical -Value ([bool]$movie.monitored)
                if ($entry.MovieIds.Contains([int]$movie.id)) {
                    $facts["$prefix/info"] = ConvertTo-ArrCanonical -Value ($movie | Select-Object -Property title, year, qualityProfileId, path)
                    $facts["$prefix/hasFile"] = ConvertTo-ArrCanonical -Value (Get-ArrValue -Object $movie -Name 'hasFile')
                }
            }
        }
    }
    $facts
}

function Compare-ArrFactSet {
    # Returns one text for each difference.
    # Strict keys: each custom format and profile fact, each info and hasFile fact, and each
    # key in -StrictKey. For the other monitoring facts, the function compares only a key that
    # both sides have: an app can add a series, a season or an episode at any time.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Expected,
        [Parameter(Mandatory)][System.Collections.Generic.Dictionary[string, string]]$Actual,
        [string[]]$StrictKey = @(),
        # A download can change hasFile during an apply.
        [switch]$IgnoreHasFile
    )
    $strict = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $StrictKey) { [void]$strict.Add($key) }
    $keys = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($key in $Expected.Keys) { [void]$keys.Add($key) }
    foreach ($key in $Actual.Keys) { [void]$keys.Add($key) }

    foreach ($key in $keys) {
        if ($IgnoreHasFile -and $key.EndsWith('/hasFile')) { continue }
        $inExpected = $Expected.ContainsKey($key)
        $inActual = $Actual.ContainsKey($key)
        if ($inExpected -and $inActual) {
            if ($Expected[$key] -cne $Actual[$key]) {
                '{0}: expected {1}, found {2}' -f $key, (Limit-ArrText -Text $Expected[$key]), (Limit-ArrText -Text $Actual[$key])
            }
            continue
        }
        $isStrict = $strict.Contains($key) -or $key -match '\A[a-z]+/(cf|profile)/|/(info|hasFile)\z'
        if ($isStrict) {
            if ($inExpected) { "${key}: expected, but it is not there" } else { "${key}: not expected, but it is there" }
        }
    }
}

function Limit-ArrText {
    param([string]$Text, [int]$Length = 160)
    if ($Text.Length -le $Length) { return $Text }
    $Text.Substring(0, $Length) + '...'
}

# --- Steps and bodies -----------------------------------------------------------

function Get-ArrPlanStep {
    # The order of the writes: monitoring off, new custom formats, changed custom formats,
    # quality profiles, monitoring on. Thus a middle state cannot start more upgrades than
    # the start state or the end state.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)

    $steps = for ($index = 0; $index -lt $Plan.operations.Count; $index++) {
        $operation = $Plan.operations[$index]
        $rank = $script:OperationRule[$operation.op].Rank
        if ($null -eq $rank) { $rank = if ($operation.monitored) { 5 } else { 1 } }
        [pscustomobject]@{ Rank = $rank; Index = $index; App = [string]$operation.app; Type = [string]$operation.op; Operation = $operation }
    }
    $number = 0
    foreach ($step in @($steps | Sort-Object -Property Rank, Index)) {
        $number++
        $step | Add-Member -NotePropertyName Number -NotePropertyValue $number -PassThru
    }
}

function Get-ArrScoreMap {
    # Custom format id to new score, for one profile operation. A ref needs -RefMap.
    param($Step, [hashtable]$RefMap)
    $map = @{}
    foreach ($entry in @(Get-ArrValue -Object $Step.Operation -Name 'scores')) {
        if ($null -eq $entry) { continue }
        $reference = Get-ArrValue -Object $entry -Name 'ref'
        if ($null -ne $reference) {
            $key = "$($Step.App)/$reference"
            if (-not $RefMap.ContainsKey($key)) { throw "The new custom format '$reference' has no id." }
            $map[[int]$RefMap[$key]] = [int]$entry.score
        } else {
            $map[[int]$entry.formatId] = [int]$entry.score
        }
    }
    $map
}

function Get-ArrSettingMap {
    param($Step)
    $map = @{}
    $set = Get-ArrValue -Object $Step.Operation -Name 'set'
    if ($null -ne $set) { foreach ($property in $set.PSObject.Properties) { $map[$property.Name] = $property.Value } }
    $map
}

function Get-ArrStepChange {
    # The facts that one step changes, with their new values.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)][hashtable]$State,
        [hashtable]$RefMap = @{}
    )
    $app = $Step.App
    $operation = $Step.Operation
    $change = [ordered]@{}
    switch -CaseSensitive ($Step.Type) {
        'monitorSeries' { foreach ($id in $operation.ids) { $change["$app/series/$id/monitored"] = ConvertTo-ArrCanonical -Value $operation.monitored } }
        'monitorSeason' { $change["$app/series/$($operation.seriesId)/season/$($operation.seasonNumber)"] = ConvertTo-ArrCanonical -Value $operation.monitored }
        'monitorEpisodes' { foreach ($id in $operation.ids) { $change["$app/episode/$id/monitored"] = ConvertTo-ArrCanonical -Value $operation.monitored } }
        'monitorMovies' { foreach ($id in $operation.ids) { $change["$app/movie/$id/monitored"] = ConvertTo-ArrCanonical -Value $operation.monitored } }
        'updateCustomFormat' { $change["$app/cf/$($operation.id)"] = Get-ArrFormatKey -CustomFormat $operation.definition }
        'createCustomFormat' {
            $newId = $RefMap["$app/$($operation.ref)"]
            $change["$app/cf/$newId"] = Get-ArrFormatKey -CustomFormat $operation.definition
            # The app adds the new custom format to each profile with the score 0.
            foreach ($qualityProfile in $State[$app].qualityprofile) { $change["$app/profile/$($qualityProfile.id)/score/$newId"] = '0' }
        }
        'updateQualityProfile' {
            $prefix = "$app/profile/$($operation.id)"
            $settings = Get-ArrSettingMap -Step $Step
            foreach ($name in $settings.Keys) { $change["$prefix/$name"] = ConvertTo-ArrCanonical -Value $settings[$name] }
            $scores = Get-ArrScoreMap -Step $Step -RefMap $RefMap
            foreach ($id in $scores.Keys) { $change["$prefix/score/$id"] = [string]$scores[$id] }
        }
    }
    $change
}

function New-ArrProfileBody {
    # The app needs the full profile. -Source gives each property. -FormatItem gives the
    # list and the order of the custom formats.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][object[]]$FormatItem,
        [hashtable]$Setting = @{},
        [hashtable]$Score = @{}
    )
    foreach ($property in $Source.PSObject.Properties) {
        if ($script:ProfileProperty[$App] -cnotcontains $property.Name) {
            throw "The profile has the property '$($property.Name)', which the tool does not know."
        }
    }
    $body = [ordered]@{}
    foreach ($name in $script:ProfileProperty[$App]) {
        if ($name -ceq 'formatItems') {
            $body[$name] = @(foreach ($item in $FormatItem) {
                    $id = [int]$item.format
                    [ordered]@{
                        format = $id
                        name   = [string]$item.name
                        score  = $(if ($Score.ContainsKey($id)) { [int]$Score[$id] } else { [int]$item.score })
                    }
                })
        } elseif ($Setting.ContainsKey($name)) {
            $body[$name] = $Setting[$name]
        } else {
            $body[$name] = $Source.$name
        }
    }
    $body
}

function New-ArrWrite {
    param([string]$App, [string]$Operation, $Body, [Nullable[int]]$Id)
    [pscustomobject]@{ App = $App; Operation = $Operation; Id = $Id; BodyJson = (ConvertTo-Json -InputObject $Body -Depth 40 -Compress) }
}

function New-ArrFormatBody {
    param($Definition, [Nullable[int]]$Id)
    $clean = ConvertTo-ArrFormatDefinition -CustomFormat $Definition
    if ($null -eq $Id) { return $clean }
    $body = [ordered]@{ id = [int]$Id }
    foreach ($key in $clean.Keys) { $body[$key] = $clean[$key] }
    $body
}

function New-ArrMonitorWrite {
    param($Step, [bool]$Monitored)
    $operation = $Step.Operation
    switch -CaseSensitive ($Step.Type) {
        'monitorSeries' { New-ArrWrite -App $Step.App -Operation 'series.monitor' -Body ([ordered]@{ seriesIds = [int[]]@($operation.ids); monitored = $Monitored }) }
        'monitorSeason' {
            $season = [ordered]@{ seasonNumber = [int]$operation.seasonNumber; monitored = $Monitored }
            $series = [ordered]@{ id = [int]$operation.seriesId; seasons = @($season) }
            New-ArrWrite -App $Step.App -Operation 'season.monitor' -Body ([ordered]@{ series = @($series) })
        }
        'monitorEpisodes' { New-ArrWrite -App $Step.App -Operation 'episode.monitor' -Body ([ordered]@{ episodeIds = [int[]]@($operation.ids); monitored = $Monitored }) }
        'monitorMovies' { New-ArrWrite -App $Step.App -Operation 'movie.monitor' -Body ([ordered]@{ movieIds = [int[]]@($operation.ids); monitored = $Monitored }) }
    }
}

function Get-ArrStepWrite {
    # The write of one step. -State is the last live state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)][hashtable]$State,
        [hashtable]$RefMap = @{}
    )
    $app = $Step.App
    $operation = $Step.Operation
    switch -CaseSensitive ($Step.Type) {
        'createCustomFormat' { New-ArrWrite -App $app -Operation 'customformat.create' -Body (New-ArrFormatBody -Definition $operation.definition) }
        'updateCustomFormat' { New-ArrWrite -App $app -Operation 'customformat.update' -Id $operation.id -Body (New-ArrFormatBody -Definition $operation.definition -Id $operation.id) }
        'updateQualityProfile' {
            $live = @($State[$app].qualityprofile | Where-Object id -EQ $operation.id)[0]
            $body = New-ArrProfileBody -App $app -Source $live -FormatItem @($live.formatItems) `
                -Setting (Get-ArrSettingMap -Step $Step) -Score (Get-ArrScoreMap -Step $Step -RefMap $RefMap)
            New-ArrWrite -App $app -Operation 'qualityprofile.update' -Id $operation.id -Body $body
        }
        default { New-ArrMonitorWrite -Step $Step -Monitored $operation.monitored }
    }
}

function Get-ArrCreatedFormat {
    # The custom formats of the live state that this create step made.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)][hashtable]$Live,
        [Parameter(Mandatory)][hashtable]$Backup
    )
    $oldIds = @($Backup[$Step.App].customformat | ForEach-Object { [int]$_.id })
    @($Live[$Step.App].customformat | Where-Object { [int]$_.id -notin $oldIds -and $_.name -ceq $Step.Operation.definition.name })
}

function Get-ArrRestoreWrite {
    # The writes that put the objects of one step back to the backup. No write deletes.
    # A new custom format stays, with the score 0 in each profile.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Step,
        [Parameter(Mandatory)][hashtable]$Live,
        [Parameter(Mandatory)][hashtable]$Backup,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Scope
    )
    $app = $Step.App
    $operation = $Step.Operation
    switch -CaseSensitive ($Step.Type) {
        'createCustomFormat' {
            foreach ($format in Get-ArrCreatedFormat -Step $Step -Live $Live -Backup $Backup) {
                foreach ($qualityProfile in $Live[$app].qualityprofile) {
                    if (@($qualityProfile.formatItems | Where-Object { $_.format -eq $format.id -and $_.score -ne 0 }).Count) {
                        $body = New-ArrProfileBody -App $app -Source $qualityProfile -FormatItem @($qualityProfile.formatItems) -Score @{ [int]$format.id = 0 }
                        New-ArrWrite -App $app -Operation 'qualityprofile.update' -Id $qualityProfile.id -Body $body
                    }
                }
            }
        }
        'updateCustomFormat' {
            $before = @($Backup[$app].customformat | Where-Object id -EQ $operation.id)[0]
            $now = @($Live[$app].customformat | Where-Object id -EQ $operation.id)[0]
            if ((Get-ArrFormatKey -CustomFormat $before) -cne (Get-ArrFormatKey -CustomFormat $now)) {
                New-ArrWrite -App $app -Operation 'customformat.update' -Id $operation.id -Body (New-ArrFormatBody -Definition $before -Id $operation.id)
            }
        }
        'updateQualityProfile' {
            $before = @($Backup[$app].qualityprofile | Where-Object id -EQ $operation.id)[0]
            $now = @($Live[$app].qualityprofile | Where-Object id -EQ $operation.id)[0]
            $oldScore = @{}
            foreach ($item in $before.formatItems) { $oldScore[[int]$item.format] = [int]$item.score }
            # A custom format that is new in this batch gets the score 0.
            foreach ($item in $now.formatItems) { if (-not $oldScore.ContainsKey([int]$item.format)) { $oldScore[[int]$item.format] = 0 } }
            $target = New-ArrProfileBody -App $app -Source $before -FormatItem @($now.formatItems) -Score $oldScore
            $current = New-ArrProfileBody -App $app -Source $now -FormatItem @($now.formatItems)
            if ((ConvertTo-ArrCanonical -Value $target) -cne (ConvertTo-ArrCanonical -Value $current)) {
                New-ArrWrite -App $app -Operation 'qualityprofile.update' -Id $operation.id -Body $target
            }
        }
        default {
            $liveFacts = Get-ArrFactSet -State $Live -Scope $Scope
            $backupFacts = Get-ArrFactSet -State $Backup -Scope $Scope
            $keys = @((Get-ArrStepChange -Step $Step -State $Backup).Keys)
            $different = @($keys | Where-Object { -not $liveFacts.ContainsKey($_) -or $liveFacts[$_] -cne $backupFacts[$_] })
            # The checks permit only a real change, thus each target had the opposite value.
            if ($different.Count) { New-ArrMonitorWrite -Step $Step -Monitored (-not $operation.monitored) }
        }
    }
}

# --- Parse tests ------------------------------------------------------------------

function Get-ArrParseProblem {
    # Compares one parse test before and after the writes.
    # -State is the live state after the writes, which the caller already compared with
    # the expected state.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Test,
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [Parameter(Mandatory)][hashtable]$State
    )
    $itemName = if ($Test.app -eq 'sonarr') { 'series' } else { 'movie' }
    $label = "Parse test ($($Test.kind)) '$($Test.title)'"
    $item = Get-ArrValue -Object $After -Name $itemName
    if ($null -eq (Get-ArrValue -Object $Before -Name $itemName) -or $null -eq $item) { return "${label}: the title matches no $itemName of the library." }

    $beforeIds = @(@(Get-ArrValue -Object $Before -Name 'customFormats') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_.id } | Sort-Object)
    $afterFormats = @(@(Get-ArrValue -Object $After -Name 'customFormats') | Where-Object { $null -ne $_ })
    $afterIds = @($afterFormats | ForEach-Object { [int]$_.id } | Sort-Object)
    $beforeScore = [int](Get-ArrValue -Object $Before -Name 'customFormatScore')
    $afterScore = [int](Get-ArrValue -Object $After -Name 'customFormatScore')

    if ($Test.kind -ceq 'unchanged') {
        if (($beforeIds -join ',') -ne ($afterIds -join ',')) { "${label}: the list of custom formats changed." }
        if ($beforeScore -ne $afterScore) { "${label}: the score changed from $beforeScore to $afterScore." }
        return
    }
    $found = @($afterFormats | Where-Object { $_.name -ceq $Test.customFormat }).Count -gt 0
    if ($Test.kind -ceq 'match' -and -not $found) { "${label}: '$($Test.customFormat)' does not match." }
    if ($Test.kind -ceq 'noMatch' -and $found) { "${label}: '$($Test.customFormat)' matches." }

    # The score of the answer must be equal to the sum of the planned scores.
    $libraryItem = @($State[$Test.app][$itemName] | Where-Object id -EQ $item.id)
    if ($libraryItem.Count -ne 1) { return "${label}: the $itemName of the answer is not in the snapshot." }
    $qualityProfile = @($State[$Test.app].qualityprofile | Where-Object id -EQ $libraryItem[0].qualityProfileId)[0]
    $sum = 0
    foreach ($formatItem in $qualityProfile.formatItems) { if ([int]$formatItem.format -in $afterIds) { $sum += [int]$formatItem.score } }
    if ($afterScore -ne $sum) { "${label}: the score is $afterScore, but the planned scores give $sum (profile '$($qualityProfile.name)')." }
    $expected = Get-ArrValue -Object $Test -Name 'expectedScore'
    if ($null -ne $expected -and $afterScore -ne $expected) { "${label}: the score is $afterScore, and the test expects $expected." }
}

# --- Checks of a plan ---------------------------------------------------------

function Get-ArrNegateGroup {
    # The unsafe groups: 2 conditions or more of one type, with a Negate and with a condition
    # that is not Required. The app accepts a group if each Required condition passes and one
    # condition of the group passes. A Negate passes for almost each title.
    # - A Required Negate next to an optional condition: the group matches almost each title,
    #   because the Negate is also the one condition that passes.
    # - An optional Negate next to a Required condition: the Negate has no effect.
    # Thus, in a group with a Negate, each condition must be Required.
    param($Definition)
    $clean = ConvertTo-ArrFormatDefinition -CustomFormat $Definition
    foreach ($group in @($clean.specifications | Group-Object -Property { $_.implementation })) {
        $negated = @($group.Group | Where-Object { $_.negate }).Count
        $optional = @($group.Group | Where-Object { -not $_.required }).Count
        if ($group.Count -ge 2 -and $negated -and $optional) {
            [pscustomobject]@{ Implementation = $group.Name; Key = ConvertTo-ArrCanonical -Value @($group.Group) }
        }
    }
}

function Get-ArrDefinitionError {
    param($Definition, [object[]]$ExistingFormat, [string]$Location)
    if (-not ([string]$Definition.name).Trim()) { "${Location}: the name is empty." }
    foreach ($specification in $Definition.specifications) {
        if (-not ([string]$specification.name).Trim()) { "${Location}: a condition has no name." }
        $example = $null
        foreach ($format in $ExistingFormat) {
            $example = @($format.specifications | Where-Object { $_.implementation -ceq $specification.implementation }) | Select-Object -First 1
            if ($example) { break }
        }
        if (-not $example) { "${Location}: the snapshot has no condition of the type '$($specification.implementation)'. The tool cannot check it."; continue }
        $exampleFields = @($example.fields | Where-Object { $null -ne (Get-ArrValue -Object $_ -Name 'value') })
        $planned = [string[]]@($specification.fields | ForEach-Object { $_.name } | Sort-Object)
        $known = [string[]]@($exampleFields | ForEach-Object { $_.name } | Sort-Object)
        if (($planned -join ',') -cne ($known -join ',')) {
            "${Location}: the condition '$($specification.name)' needs the fields $($known -join ', ')."
            continue
        }
        foreach ($field in $specification.fields) {
            $other = @($exampleFields | Where-Object { $_.name -ceq $field.name })[0]
            $kind = { param($value) if ($value -is [bool]) { 'true or false' } elseif ($value -is [string]) { 'a text' } else { 'a number' } }
            if ((& $kind $field.value) -ne (& $kind $other.value)) { "${Location}: the field '$($field.name)' needs $(& $kind $other.value)." }
        }
        if ($specification.implementation -cin 'ReleaseTitleSpecification', 'ReleaseGroupSpecification') {
            foreach ($field in $specification.fields) {
                try { [void][regex]::new([string]$field.value) } catch { "${Location}: the condition '$($specification.name)' has a regular expression that is not valid." }
            }
        }
    }
}

function Test-ArrPlan {
    # All offline checks. Returns Errors and Warnings. A plan with an error must not run.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$VerifiedVersion
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $scope = Get-ArrPlanScope -Plan $Plan

    foreach ($app in $scope.Keys) {
        $version = [string]@($State[$app].status)[0].version
        if ($version -cne $VerifiedVersion[$app]) {
            $errors.Add("$app has version $version in the snapshot. The tool is verified for $($VerifiedVersion[$app]). Compare the source code again.")
        }
    }

    $seenTarget = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # The final names of the custom formats of each app, for the uniqueness check.
    $finalName = @{}
    foreach ($app in $scope.Keys) {
        if (-not $scope[$app].FormatWork) { continue }
        $finalName[$app] = @{}
        foreach ($format in $State[$app].customformat) { $finalName[$app]["$($format.id)"] = [string]$format.name }
    }

    foreach ($step in Get-ArrPlanStep -Plan $Plan) {
        $app = $step.App
        $operation = $step.Operation
        $data = $State[$app]
        $location = "Step $($step.Number) ($app $($step.Type))"
        switch -CaseSensitive ($step.Type) {
            'createCustomFormat' {
                if ($operation.definition.includeCustomFormatWhenRenaming) { $errors.Add("${location}: a new custom format must have includeCustomFormatWhenRenaming = false.") }
                foreach ($text in Get-ArrDefinitionError -Definition $operation.definition -ExistingFormat $data.customformat -Location $location) { $errors.Add($text) }
                foreach ($group in Get-ArrNegateGroup -Definition $operation.definition) { $errors.Add("${location}: the conditions of the type $($group.Implementation) include a Negate, thus each of them must be Required.") }
                $finalName[$app]["new:$($operation.ref)"] = [string]$operation.definition.name
            }
            'updateCustomFormat' {
                $current = @($data.customformat | Where-Object id -EQ $operation.id)
                if ($current.Count -ne 1) { $errors.Add("${location}: the snapshot has no custom format with the id $($operation.id)."); continue }
                if (-not $seenTarget.Add("$app/cf/$($operation.id)")) { $errors.Add("${location}: two operations change the same custom format.") }
                foreach ($text in Get-ArrDefinitionError -Definition $operation.definition -ExistingFormat $data.customformat -Location $location) { $errors.Add($text) }
                if ([bool]$operation.definition.includeCustomFormatWhenRenaming -ne [bool]$current[0].includeCustomFormatWhenRenaming) {
                    $errors.Add("${location}: the tool does not change includeCustomFormatWhenRenaming.")
                }
                if ((Get-ArrFormatKey -CustomFormat $operation.definition) -ceq (Get-ArrFormatKey -CustomFormat $current[0])) { $errors.Add("${location}: the definition does not change.") }
                $oldGroups = @(Get-ArrNegateGroup -Definition $current[0])
                foreach ($group in Get-ArrNegateGroup -Definition $operation.definition) {
                    if (@($oldGroups | Where-Object { $_.Key -ceq $group.Key }).Count) {
                        $warnings.Add("'$($current[0].name)' already has a $($group.Implementation) group with a Negate and an optional condition. The plan does not change this group.")
                    } else {
                        $errors.Add("${location}: the conditions of the type $($group.Implementation) include a Negate, thus each of them must be Required.")
                    }
                }
                $finalName[$app]["$($operation.id)"] = [string]$operation.definition.name
            }
            'updateQualityProfile' {
                $current = @($data.qualityprofile | Where-Object id -EQ $operation.id)
                if ($current.Count -ne 1) { $errors.Add("${location}: the snapshot has no quality profile with the id $($operation.id)."); continue }
                $qualityProfile = $current[0]
                if (-not $seenTarget.Add("$app/profile/$($operation.id)")) { $errors.Add("${location}: two operations change the same profile. Put the changes into one operation.") }
                $unknown = @($qualityProfile.PSObject.Properties.Name | Where-Object { $script:ProfileProperty[$app] -cnotcontains $_ })
                if ($unknown.Count) { $errors.Add("${location}: the profile has properties that the tool does not know: $($unknown -join ', ').") }

                $result = @{}
                foreach ($name in $script:ProfileSetting) { $result[$name] = $qualityProfile.$name }
                $settings = Get-ArrSettingMap -Step $step
                foreach ($name in $settings.Keys) {
                    $value = $settings[$name]
                    $validType = if ($name -ceq 'upgradeAllowed') { $value -is [bool] } else { Test-ArrInteger -Value $value }
                    if (-not $validType) { $errors.Add("${location}: $name has a value of an incorrect type."); continue }
                    if ($value -eq $qualityProfile.$name) { $errors.Add("${location}: $name already has the value $value.") }
                    $result[$name] = $value
                }

                $score = @{}
                foreach ($item in $qualityProfile.formatItems) { $score["$($item.format)"] = [int]$item.score }
                $scoreTarget = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                foreach ($entry in @(Get-ArrValue -Object $operation -Name 'scores')) {
                    if ($null -eq $entry) { continue }
                    $reference = Get-ArrValue -Object $entry -Name 'ref'
                    if ($null -ne $reference) {
                        $target = "new:$reference"
                        $known = @($Plan.operations | Where-Object { $_.op -ceq 'createCustomFormat' -and $_.app -ceq $app -and $_.ref -ceq $reference }).Count -eq 1
                        if (-not $known) { $errors.Add("${location}: no operation of $app makes the custom format '$reference'."); continue }
                        $score[$target] = 0
                    } else {
                        $target = "$($entry.formatId)"
                        if (-not $score.ContainsKey($target)) { $errors.Add("${location}: the profile has no custom format with the id $target."); continue }
                    }
                    if (-not $scoreTarget.Add($target)) { $errors.Add("${location}: the custom format $target has two scores.") }
                    if ($score[$target] -eq $entry.score) { $errors.Add("${location}: the score of the custom format $target does not change.") }
                    $score[$target] = [int]$entry.score
                }

                # The same rules as the app.
                if ($result.minUpgradeFormatScore -lt 1) { $errors.Add("${location}: minUpgradeFormatScore must be 1 or more.") }
                $positive = 0
                foreach ($value in $score.Values) { if ($value -gt 0) { $positive += $value } }
                $highest = ($score.Values | Measure-Object -Maximum).Maximum
                if ($positive -lt $result.minFormatScore -and $highest -lt $result.minFormatScore) { $errors.Add("${location}: no release can have the minimum score $($result.minFormatScore).") }
            }
            'monitorSeries' {
                foreach ($id in $operation.ids) {
                    $series = @($data.series | Where-Object id -EQ $id)
                    if ($series.Count -ne 1) { $errors.Add("${location}: the snapshot has no series with the id $id."); continue }
                    if (-not $seenTarget.Add("$app/series/$id")) { $errors.Add("${location}: the series $id occurs two times.") }
                    if ([bool]$series[0].monitored -eq $operation.monitored) { $errors.Add("${location}: '$($series[0].title)' already has monitored = $($operation.monitored).") }
                }
            }
            'monitorSeason' {
                $series = @($data.series | Where-Object id -EQ $operation.seriesId)
                if ($series.Count -ne 1) { $errors.Add("${location}: the snapshot has no series with the id $($operation.seriesId)."); continue }
                $season = @($series[0].seasons | Where-Object seasonNumber -EQ $operation.seasonNumber)
                if ($season.Count -ne 1) { $errors.Add("${location}: '$($series[0].title)' has no season $($operation.seasonNumber)."); continue }
                if (-not $seenTarget.Add("$app/series/$($operation.seriesId)/season/$($operation.seasonNumber)")) { $errors.Add("${location}: the season occurs two times.") }
                if ([bool]$season[0].monitored -eq $operation.monitored) { $errors.Add("${location}: the season already has monitored = $($operation.monitored).") }

                $changed = @($Plan.operations | Where-Object { $_.op -ceq 'monitorEpisodes' -and $_.seriesId -eq $operation.seriesId -and $_.monitored -eq $operation.monitored } | ForEach-Object { $_.ids })
                $other = @($data.episode | Where-Object {
                        $_.seriesId -eq $operation.seriesId -and $_.seasonNumber -eq $operation.seasonNumber -and
                        [bool]$_.monitored -ne $operation.monitored -and $_.id -notin $changed
                    }).Count
                if ($other) {
                    $warnings.Add("'$($series[0].title)' season $($operation.seasonNumber): the season flag changes to $($operation.monitored), but $other episode(s) keep the other value. The web UI changes them together. The tool changes only what the plan lists.")
                }
            }
            'monitorEpisodes' {
                foreach ($id in $operation.ids) {
                    $episode = @($data.episode | Where-Object { $_.id -eq $id -and $_.seriesId -eq $operation.seriesId })
                    if ($episode.Count -ne 1) { $errors.Add("${location}: series $($operation.seriesId) has no episode with the id $id in the snapshot."); continue }
                    if (-not $seenTarget.Add("$app/episode/$id")) { $errors.Add("${location}: the episode $id occurs two times.") }
                    if ([bool]$episode[0].monitored -eq $operation.monitored) { $errors.Add("${location}: the episode $id already has monitored = $($operation.monitored).") }
                }
            }
            'monitorMovies' {
                foreach ($id in $operation.ids) {
                    $movie = @($data.movie | Where-Object id -EQ $id)
                    if ($movie.Count -ne 1) { $errors.Add("${location}: the snapshot has no movie with the id $id."); continue }
                    if (-not $seenTarget.Add("$app/movie/$id")) { $errors.Add("${location}: the movie $id occurs two times.") }
                    if ([bool]$movie[0].monitored -eq $operation.monitored) { $errors.Add("${location}: '$($movie[0].title)' already has monitored = $($operation.monitored).") }
                }
            }
        }
    }

    foreach ($app in $finalName.Keys) {
        foreach ($group in @($finalName[$app].Values | Group-Object | Where-Object Count -GT 1)) {
            $errors.Add("$app would have two custom formats with the name '$($group.Name)'.")
        }
    }

    # Parse tests: one match for each custom format that changes, and 2 unchanged titles for each app.
    foreach ($app in $scope.Keys) {
        $tests = @($Plan.parseTests | Where-Object { $_.app -ceq $app })
        $changedName = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($operation in @($Plan.operations | Where-Object { $_.app -ceq $app })) {
            if ($operation.op -cin 'createCustomFormat', 'updateCustomFormat') { [void]$changedName.Add([string]$operation.definition.name) }
            if ($operation.op -ceq 'updateQualityProfile') {
                foreach ($entry in @(Get-ArrValue -Object $operation -Name 'scores')) {
                    if ($null -eq $entry) { continue }
                    $reference = Get-ArrValue -Object $entry -Name 'ref'
                    $id = if ($null -ne $reference) { "new:$reference" } else { "$($entry.formatId)" }
                    if ($finalName[$app].ContainsKey($id)) { [void]$changedName.Add($finalName[$app][$id]) }
                }
            }
        }
        if ($changedName.Count -eq 0) { continue }
        foreach ($name in $changedName) {
            if (@($tests | Where-Object { $_.kind -ceq 'match' -and $_.customFormat -ceq $name }).Count -eq 0) {
                $errors.Add("$app needs a parse test of the kind 'match' for '$name'.")
            }
        }
        $unchanged = @($tests | Where-Object kind -CEQ 'unchanged' | ForEach-Object { $_.title } | Select-Object -Unique)
        if ($unchanged.Count -lt 2) { $errors.Add("$app needs 2 parse tests of the kind 'unchanged' with different titles.") }
    }
    foreach ($test in $Plan.parseTests) {
        if (-not $scope.Contains([string]$test.app) -or -not $scope[$test.app].FormatWork) {
            $errors.Add("The parse test '$($test.title)' is for $($test.app), and the plan changes no custom format or profile there.")
            continue
        }
        if ($test.kind -cne 'unchanged' -and @($finalName[$test.app].Values) -cnotcontains $test.customFormat) {
            $errors.Add("The parse test '$($test.title)' names '$($test.customFormat)', which is not a custom format of $($test.app).")
        }
    }

    [pscustomobject]@{ Errors = @($errors); Warnings = @($warnings | Select-Object -Unique) }
}

# --- Table for the approval ---------------------------------------------------

function Get-ArrRecyclarrName {
    # The names of the custom formats that Recyclarr manages, or $null if there is no file.
    # The names come from the comments after the ids.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir, [Parameter(Mandatory)][string]$App)

    $path = Join-Path $ConfigDir "$App.yml"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '\A\s*-\s*[0-9a-f]{32}\s*#\s*(?<name>.+?)\s*\z') { [void]$names.Add($Matches.name) }
    }
    , $names
}

function Format-ArrCell {
    param([string]$Text)
    $Text.Replace('|', '\|') -replace '\r?\n', ' '
}

function Format-ArrCondition {
    param($Specification)
    $flags = @(
        if ($Specification.required) { 'required' } else { 'optional' }
        if ($Specification.negate) { 'negate' }
    )
    $values = @($Specification.fields | ForEach-Object { "$($_.name)=$($_.value)" }) -join '; '
    '{0}, {1}: {2}' -f ($Specification.implementation -replace 'Specification\z'), ($flags -join ' '), $values
}

function Get-ArrReportRow {
    # One row for each change, in the order of the writes.
    param($Plan, [hashtable]$State)

    $row = { param($step, $object, $field, $before, $after)
        [pscustomobject]@{ Step = $step.Number; App = $step.App; Object = $object; Field = $field; Before = $before; After = $after }
    }
    foreach ($step in Get-ArrPlanStep -Plan $Plan) {
        $operation = $step.Operation
        $data = $State[$step.App]
        switch -CaseSensitive ($step.Type) {
            'createCustomFormat' {
                & $row $step "CF '$($operation.definition.name)' (new)" 'custom format' '-' 'created, score 0 in each profile'
                foreach ($specification in (ConvertTo-ArrFormatDefinition -CustomFormat $operation.definition).specifications) {
                    & $row $step "CF '$($operation.definition.name)' (new)" "condition '$($specification.name)'" '-' (Format-ArrCondition -Specification $specification)
                }
            }
            'updateCustomFormat' {
                $current = @($data.customformat | Where-Object id -EQ $operation.id)[0]
                $before = (ConvertTo-ArrFormatDefinition -CustomFormat $current)
                $after = (ConvertTo-ArrFormatDefinition -CustomFormat $operation.definition)
                $object = "CF '$($current.name)' ($($operation.id))"
                if ($before.name -cne $after.name) { & $row $step $object 'name' $before.name $after.name }
                $oldList = @($before.specifications | ForEach-Object { "'$($_.name)': $(Format-ArrCondition -Specification $_)" })
                $newList = @($after.specifications | ForEach-Object { "'$($_.name)': $(Format-ArrCondition -Specification $_)" })
                foreach ($text in $oldList) { if ($newList -cnotcontains $text) { & $row $step $object 'condition removed or changed' $text '-' } }
                foreach ($text in $newList) { if ($oldList -cnotcontains $text) { & $row $step $object 'condition added or changed' '-' $text } }
            }
            'updateQualityProfile' {
                $qualityProfile = @($data.qualityprofile | Where-Object id -EQ $operation.id)[0]
                $object = "profile '$($qualityProfile.name)'"
                $settings = Get-ArrSettingMap -Step $step
                foreach ($name in @($settings.Keys | Sort-Object)) { & $row $step $object $name "$($qualityProfile.$name)" "$($settings[$name])" }
                foreach ($entry in @(Get-ArrValue -Object $operation -Name 'scores')) {
                    if ($null -eq $entry) { continue }
                    $reference = Get-ArrValue -Object $entry -Name 'ref'
                    if ($null -ne $reference) {
                        $new = @($Plan.operations | Where-Object { $_.op -ceq 'createCustomFormat' -and $_.app -ceq $step.App -and $_.ref -ceq $reference })[0]
                        & $row $step $object "score of '$($new.definition.name)' (new)" '0' "$($entry.score)"
                    } else {
                        $item = @($qualityProfile.formatItems | Where-Object format -EQ $entry.formatId)[0]
                        & $row $step $object "score of '$($item.name)'" "$($item.score)" "$($entry.score)"
                    }
                }
            }
            'monitorSeries' {
                foreach ($id in $operation.ids) {
                    $series = @($data.series | Where-Object id -EQ $id)[0]
                    & $row $step "series '$($series.title)' ($id)" 'series flag' "$(-not $operation.monitored)" "$($operation.monitored)"
                }
            }
            'monitorSeason' {
                $series = @($data.series | Where-Object id -EQ $operation.seriesId)[0]
                & $row $step "series '$($series.title)' ($($series.id))" "season $($operation.seasonNumber) flag" "$(-not $operation.monitored)" "$($operation.monitored)"
            }
            'monitorEpisodes' {
                $series = @($data.series | Where-Object id -EQ $operation.seriesId)[0]
                $codes = @($data.episode | Where-Object { $_.id -in $operation.ids } | Sort-Object seasonNumber, episodeNumber |
                        ForEach-Object { 'S{0:D2}E{1:D2}' -f [int]$_.seasonNumber, [int]$_.episodeNumber })
                & $row $step "series '$($series.title)' ($($series.id))" "$($codes.Count) episode(s): $($codes -join ' ')" "$(-not $operation.monitored)" "$($operation.monitored)"
            }
            'monitorMovies' {
                foreach ($id in $operation.ids) {
                    $movie = @($data.movie | Where-Object id -EQ $id)[0]
                    & $row $step "movie '$($movie.title)' ($($movie.year), id $id)" 'monitored' "$(-not $operation.monitored)" "$($operation.monitored)"
                }
            }
        }
    }
}

function Format-ArrPlanReport {
    # The Markdown text that a person approves. Use it only for a plan with no error.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][hashtable]$State,
        [AllowEmptyCollection()][string[]]$Warning = @(),
        [Parameter(Mandatory)][string]$RecyclarrDir
    )
    '| Step | App | Object | Field | Before | After |'
    '|---|---|---|---|---|---|'
    foreach ($item in Get-ArrReportRow -Plan $Plan -State $State) {
        '| {0} | {1} | {2} | {3} | {4} | {5} |' -f $item.Step, $item.App, (Format-ArrCell $item.Object), (Format-ArrCell $item.Field),
            (Format-ArrCell $item.Before), (Format-ArrCell $item.After)
    }

    $use = foreach ($operation in $Plan.operations) {
        $data = $State[$operation.app]
        $itemName = if ($operation.app -eq 'sonarr') { 'series' } else { 'movie' }
        if ($operation.op -ceq 'updateQualityProfile') {
            $qualityProfile = @($data.qualityprofile | Where-Object id -EQ $operation.id)[0]
            $items = @($data[$itemName] | Where-Object qualityProfileId -EQ $operation.id)
            "- $($operation.app) profile '$($qualityProfile.name)': $($items.Count) $itemName item(s) use it, $(@($items | Where-Object monitored).Count) monitored."
        }
        if ($operation.op -ceq 'updateCustomFormat') {
            $scored = foreach ($qualityProfile in $data.qualityprofile) {
                $item = @($qualityProfile.formatItems | Where-Object format -EQ $operation.id)[0]
                if ($item.score -ne 0) {
                    $count = @($data[$itemName] | Where-Object { $_.qualityProfileId -eq $qualityProfile.id -and $_.monitored }).Count
                    "'$($qualityProfile.name)' ($($item.score), $count monitored)"
                }
            }
            "- $($operation.app) CF id $($operation.id) has a score other than 0 in: $(if ($scored) { @($scored) -join ', ' } else { 'no profile' })."
        }
    }
    if ($use) { ''; 'Use of the changed objects:'; $use }

    ''
    'Warnings:'
    '- A change of a score, of a custom format or of a monitored flag can start an automatic upgrade. An upgrade REPLACES a file.'
    '- Radarr has NO Recycling Bin. A bad upgrade there is permanent.'
    '- Sonarr and Radarr compare the QUALITY first, then the custom format score. A higher quality replaces a file with a higher score.'
    '- Do not change the same objects in the web UI during the apply.'
    foreach ($text in $Warning) { "- $text" }

    $formatLines = foreach ($app in @($Plan.operations | ForEach-Object { $_.app } | Select-Object -Unique)) {
        $managed = Get-ArrRecyclarrName -ConfigDir $RecyclarrDir -App $app
        $names = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
        $defined = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($operation in @($Plan.operations | Where-Object { $_.app -ceq $app })) {
            if ($operation.op -cin 'createCustomFormat', 'updateCustomFormat') {
                [void]$names.Add($operation.definition.name); [void]$defined.Add($operation.definition.name)
                if ($operation.op -ceq 'updateCustomFormat') {
                    $oldName = [string]@($State[$app].customformat | Where-Object id -EQ $operation.id)[0].name
                    [void]$names.Add($oldName); [void]$defined.Add($oldName)
                }
            }
            if ($operation.op -ceq 'updateQualityProfile') {
                foreach ($entry in @(Get-ArrValue -Object $operation -Name 'scores')) {
                    if ($null -ne $entry -and $null -eq (Get-ArrValue -Object $entry -Name 'ref')) {
                        [void]$names.Add([string]@($State[$app].customformat | Where-Object id -EQ $entry.formatId)[0].name)
                    }
                }
            }
        }
        foreach ($name in $names) {
            if ($null -eq $managed) { "- ${app} '$name': UNKNOWN, there is no Recyclarr file for $app." }
            elseif ($managed.Contains($name) -and $defined.Contains($name)) { "- ${app} '$name': MANAGED by Recyclarr. The daily sync can undo this change of the definition." }
            elseif ($managed.Contains($name)) { "- ${app} '$name': managed by Recyclarr (definition only). The sync does not change a score." }
            else { "- ${app} '$name': not in the Recyclarr list (comparison by name)." }
        }
    }
    if ($formatLines) { ''; 'Recyclarr:'; $formatLines }

    if ($Plan.parseTests.Count) {
        ''
        'Parse tests:'
        foreach ($test in $Plan.parseTests) {
            $detail = if ($test.kind -cne 'unchanged') {
                $expected = Get-ArrValue -Object $test -Name 'expectedScore'
                " '$($test.customFormat)'$(if ($null -ne $expected) { ", score $expected" })"
            } else { '' }
            "- $($test.app) $($test.kind)${detail}: $($test.title)"
        }
    }
}

Export-ModuleMember -Function ConvertFrom-ArrJson, ConvertTo-ArrCanonical, ConvertTo-ArrFormatDefinition, Get-ArrFormatKey,
    Get-ArrFileSha256, Read-ArrPlanFile, Get-ArrPlanShapeError, Get-ArrPlanScope, Get-ArrRequiredResource, ConvertTo-ArrState,
    Read-ArrBaseline, Get-ArrFactSet, Compare-ArrFactSet, Get-ArrPlanStep, Get-ArrStepChange, Get-ArrStepWrite,
    Get-ArrCreatedFormat, Get-ArrRestoreWrite, Get-ArrParseProblem, Test-ArrPlan, Get-ArrRecyclarrName,
    Format-ArrPlanReport
