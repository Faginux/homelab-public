<#
.SYNOPSIS
    Checks the real CONTENTS of the volume-backup archives on ARCADE.

.DESCRIPTION
    A green Telegram notification only tells that the backup made and uploaded
    the tar. It does NOT tell that the tar contains your data.

    If you rename a folder or move a stack, a bind mount can mount an empty
    folder. The backup succeeds, the notification is green, and the archive
    contains a directory with zero files. This really occurred on 2026-07-26
    with Paperless.

    This script opens the last archive, counts the entries for each source and
    reports the sources that are missing or empty. It is the only check that
    finds that type of failure.

    Run it AFTER EACH CHANGE to the docker-compose.yml of the stack.

.PARAMETER ArchiveDir
    Folder of the local archives.

.PARAMETER MaxAgeDays
    Maximum age of the last archive. The local backup runs on Monday and
    Thursday, so after 4 days something did not run.

.PARAMETER CheckRemote
    Also checks the offsite copy on the-grid through SSH (dvb-remote-the-grid). It checks
    that the archives are there. It also checks that age encrypted the last one
    (header). Only the local archive, which stays in clear text, gets the contents
    check. Until 2026-10-11 the offsite copy was on the Raspberry Pi.

.PARAMETER Detail
    Shows the subfolders in docker-yml.

.EXAMPLE
    .\Test-BackupContent.ps1
    Quick check of the last local archive.

.EXAMPLE
    .\Test-BackupContent.ps1 -CheckRemote -Detail
    Full check, local + the-grid, with detail for each service.

.NOTES
    Compatible with PowerShell 5.1 and 7 (no ternary operator, no ?? or ?.).
    Exit code 0 = all correct, 1 = problems found.
#>

[CmdletBinding()]
param(
    [string] $ArchiveDir = "S:\Bakcup_Servarr+\Docker Volumes",
    [int]    $MaxAgeDays = 4,
    [string] $RemoteHost = "the-grid",
    [string] $RemotePath = "/srv/backup/from-arcade",
    [switch] $CheckRemote,
    [switch] $Detail
)

# =============================================================================
#  EXPECTED SOURCES
#  Key    = name of the source in the archive (second level of the path)
#  Value  = minimum number of entries. Below it, the alarm starts.
#  The minimums are well below the observed values: they find a
#  collapse (broken mount), they do not report a normal change.
#  IF YOU ADD OR REMOVE A MOUNT IN THE COMPOSE, UPDATE THIS TABLE.
# =============================================================================
# Aligned again on 2026-10-02: caddy-*, crowdsec-*, hermes-*, paperless-*
# left the compose between 2026-08-29 and 2026-09-13. They gave false FAILs here.
$SorgentiAttese = [ordered]@{
    'docker-yml'          = 100
    'immich-db-dumps'     = 5
    'docker-appdata'      = 1000
}

$Problemi = 0

function Write-Esito {
    param(
        [string] $Stato,
        [string] $Testo
    )
    $colore = "Gray"
    if ($Stato -eq "OK")   { $colore = "Green"  }
    if ($Stato -eq "WARN") { $colore = "Yellow" }
    if ($Stato -eq "FAIL") { $colore = "Red"    }
    Write-Host ("[{0,-4}] " -f $Stato) -ForegroundColor $colore -NoNewline
    Write-Host $Testo
}

function Write-Titolo {
    param([string] $Testo)
    Write-Host ""
    Write-Host ("--- {0} " -f $Testo).PadRight(64, '-') -ForegroundColor Cyan
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Test-BackupContent  --  ARCADE" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
#  0. Prerequisites
# -----------------------------------------------------------------------------
$tar = Get-Command tar.exe -ErrorAction SilentlyContinue
if ($null -eq $tar) {
    Write-Esito "FAIL" "tar.exe non trovato. Serve Windows 10 1803+ o Git for Windows."
    exit 1
}

if (-not (Test-Path -LiteralPath $ArchiveDir)) {
    Write-Esito "FAIL" ("Cartella archivi inesistente: {0}" -f $ArchiveDir)
    exit 1
}

# -----------------------------------------------------------------------------
#  1. Find the last archive
# -----------------------------------------------------------------------------
Write-Titolo "Archivio locale"

$ultimo = Get-ChildItem -LiteralPath $ArchiveDir -Filter "arcade-volumes-*.tar.gz" -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 1

if ($null -eq $ultimo) {
    Write-Esito "FAIL" "Nessun archivio arcade-volumes-*.tar.gz trovato."
    exit 1
}

$tuttiGliArchivi = @(Get-ChildItem -LiteralPath $ArchiveDir -Filter "arcade-volumes-*.tar.gz" -File)
$etaGiorni = [math]::Round(((Get-Date) - $ultimo.LastWriteTime).TotalDays, 1)
$pesoMB    = [math]::Round($ultimo.Length / 1MB, 1)

Write-Host ("  File     : {0}" -f $ultimo.Name)
Write-Host ("  Data     : {0}  ({1} giorni fa)" -f $ultimo.LastWriteTime.ToString("dd/MM/yyyy HH:mm"), $etaGiorni)
Write-Host ("  Peso     : {0} MB" -f $pesoMB)
Write-Host ("  In totale: {0} archivi in cartella" -f $tuttiGliArchivi.Count)
Write-Host ""

if ($etaGiorni -gt $MaxAgeDays) {
    Write-Esito "FAIL" ("Ultimo backup di {0} giorni fa (soglia {1}). Il cron non sta girando?" -f $etaGiorni, $MaxAgeDays)
    $Problemi++
} else {
    Write-Esito "OK" "Eta' dell'archivio nella norma."
}

if ($pesoMB -lt 100) {
    Write-Esito "WARN" ("Archivio da soli {0} MB: sospetto. Atteso ~500 MB." -f $pesoMB)
    $Problemi++
}

# -----------------------------------------------------------------------------
#  2. Read the index of the archive (also checks the integrity of the gzip)
# -----------------------------------------------------------------------------
Write-Titolo "Lettura indice"

$voci = @()
try {
    $voci = @(& tar.exe -tzf $ultimo.FullName 2>$null)
} catch {
    $voci = @()
}

if ($voci.Count -eq 0) {
    Write-Esito "FAIL" "Impossibile leggere l'archivio: gzip corrotto o troncato."
    exit 1
}

Write-Esito "OK" ("Archivio leggibile, {0} voci indicizzate." -f $voci.Count)

# -----------------------------------------------------------------------------
#  3. Count the entries for each source
#     The paths in the archive are /backup/<source>/... so the source
#     is the third item after the split on '/' (the first is empty).
# -----------------------------------------------------------------------------
Write-Titolo "Sorgenti"

$conteggio = @{}
foreach ($v in $voci) {
    $pezzi = $v.TrimStart('/') -split '/'
    if ($pezzi.Count -ge 2 -and $pezzi[0] -eq 'backup') {
        $nome = $pezzi[1]
        if ($conteggio.ContainsKey($nome)) {
            $conteggio[$nome] = $conteggio[$nome] + 1
        } else {
            $conteggio[$nome] = 1
        }
    }
}

Write-Host ("  {0,-22} {1,8}   {2}" -f "SORGENTE", "VOCI", "ESITO")
Write-Host ("  {0}" -f ("-" * 50))

foreach ($nome in $SorgentiAttese.Keys) {
    $n = 0
    if ($conteggio.ContainsKey($nome)) { $n = $conteggio[$nome] }
    $minimo = $SorgentiAttese[$nome]

    $stato = "OK"
    $nota  = ""
    if ($n -eq 0) {
        $stato = "FAIL"
        $nota  = "ASSENTE - mount rimosso o rinominato"
        $Problemi++
    } elseif ($n -le 1) {
        $stato = "FAIL"
        $nota  = "VUOTA - il mount punta a un path sbagliato"
        $Problemi++
    } elseif ($n -lt $minimo) {
        $stato = "WARN"
        $nota  = ("sotto il minimo atteso ({0})" -f $minimo)
        $Problemi++
    }

    $colore = "Green"
    if ($stato -eq "WARN") { $colore = "Yellow" }
    if ($stato -eq "FAIL") { $colore = "Red"    }

    Write-Host ("  {0,-22} {1,8}   " -f $nome, $n) -NoNewline
    Write-Host ("{0} {1}" -f $stato, $nota) -ForegroundColor $colore
}

# Sources in the archive that the table does not expect
foreach ($nome in $conteggio.Keys) {
    if (-not $SorgentiAttese.Contains($nome)) {
        Write-Host ("  {0,-22} {1,8}   " -f $nome, $conteggio[$nome]) -NoNewline
        Write-Host "NUOVA - aggiungila a `$SorgentiAttese nello script" -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------------
#  4. docker-yml detail (optional)
# -----------------------------------------------------------------------------
if ($Detail) {
    Write-Titolo "Dettaglio docker-yml"
    $sub = @{}
    foreach ($v in $voci) {
        $pezzi = $v.TrimStart('/') -split '/'
        if ($pezzi.Count -ge 3 -and $pezzi[0] -eq 'backup' -and $pezzi[1] -eq 'docker-yml') {
            $nome = $pezzi[2]
            if ($sub.ContainsKey($nome)) {
                $sub[$nome] = $sub[$nome] + 1
            } else {
                $sub[$nome] = 1
            }
        }
    }
    $sub.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        Write-Host ("  {0,-28} {1,6}" -f $_.Key, $_.Value)
    }
}

# -----------------------------------------------------------------------------
#  5. Regression checks
# -----------------------------------------------------------------------------
Write-Titolo "Controlli di regressione"

# 5a. The private SSH key must NEVER go into the archive. That archive
#     goes offsite to the-grid. A private key in a backup is a gift to an attacker.
$chiaveDentro = @($voci | Where-Object { $_ -like "*volume-backup/ssh/id_ed25519*" })
if ($chiaveDentro.Count -gt 0) {
    Write-Esito "FAIL" "CHIAVE PRIVATA SSH PRESENTE NELL'ARCHIVIO - controlla BACKUP_EXCLUDE_REGEXP"
    $Problemi++
} else {
    Write-Esito "OK" "Chiave privata SSH correttamente esclusa."
}

# 5b. hermes-home/.cache is 1.5 GB and must stay out.
$cacheDentro = @($voci | Where-Object { $_ -like "*hermes-home/.cache/*" })
if ($cacheDentro.Count -gt 0) {
    Write-Esito "WARN" ("hermes-home/.cache dentro l'archivio ({0} file): esclusione saltata." -f $cacheDentro.Count)
    $Problemi++
} else {
    Write-Esito "OK" "hermes-home/.cache correttamente escluso."
}

# 5c. The official Immich dumps are the only way to restore that database.
$dumpImmich = @($voci | Where-Object { $_ -like "*immich-db-dumps/*.sql.gz" })
if ($dumpImmich.Count -lt 3) {
    Write-Esito "FAIL" ("Solo {0} dump Immich nell'archivio: l'automatic backup e' fermo?" -f $dumpImmich.Count)
    $Problemi++
} else {
    Write-Esito "OK" ("{0} dump Immich presenti." -f $dumpImmich.Count)
}

# -----------------------------------------------------------------------------
#  6. Offsite copy (optional)
# -----------------------------------------------------------------------------
if ($CheckRemote) {
    Write-Titolo "Copia offsite su the-grid"
    Write-Host ("  Host: {0}   Path: {1}" -f $RemoteHost, $RemotePath)
    Write-Host ""

    # Note: it is not necessary to check the CONTENTS remotely. The uploaded archive
    # is the same file that the check above already did. Remotely, it is important
    # to know that it arrived, that its size is correct and that the rotation runs.
    $listato = & ssh $RemoteHost ("ls -lh --time-style=long-iso {0}/ 2>/dev/null" -f $RemotePath) 2>$null

    if ($LASTEXITCODE -ne 0 -or $null -eq $listato) {
        Write-Esito "FAIL" ("SSH verso {0} fallito. the-grid e' raggiungibile? IP cambiato?" -f $RemoteHost)
        $Problemi++
    } else {
        $listato | ForEach-Object { Write-Host ("  {0}" -f $_) }
        # Since 2026-10-02 age encrypts the offsite copies (.tar.gz.age).
        # The pattern also accepts the old plain .tar.gz files until the
        # retention removes them.
        $remoti = @($listato | Where-Object { $_ -like "*arcade-volumes-*.tar.gz*" })
        Write-Host ""
        if ($remoti.Count -eq 0) {
            Write-Esito "FAIL" "Nessun archivio su the-grid."
            $Problemi++
        } else {
            Write-Esito "OK" ("{0} archivi presenti su the-grid." -f $remoti.Count)

            # The name contains the ISO date: the alphabetical order is the
            # chronological order. Last field of the ls line = file name.
            $nomi = @($remoti | ForEach-Object { ($_ -split '\s+')[-1] } | Sort-Object)
            $ultimoRemoto = $nomi[-1]
            $inChiaro = @($nomi | Where-Object { $_ -like "*.tar.gz" })

            if ($ultimoRemoto -notlike "*.tar.gz.age") {
                Write-Esito "FAIL" ("L'ultimo archivio su the-grid NON e' cifrato: {0}. AGE_PUBLIC_KEYS sparita dal compose?" -f $ultimoRemoto)
                $Problemi++
            } else {
                # The first 21 bytes of an age file are "age-encryption.org/v1".
                # It does not prove that it decrypts (that needs the private key, only in
                # Bitwarden). It proves that age encrypted the file and that the start is complete.
                $header = & ssh $RemoteHost ("head -c 21 {0}/{1}" -f $RemotePath, $ultimoRemoto) 2>$null
                if ($header -eq "age-encryption.org/v1") {
                    Write-Esito "OK" ("Ultimo archivio cifrato, header age valido: {0}" -f $ultimoRemoto)
                } else {
                    Write-Esito "FAIL" ("Header age assente o illeggibile: {0}" -f $ultimoRemoto)
                    $Problemi++
                }
            }
            if ($inChiaro.Count -gt 0) {
                Write-Host ("  Archivi in chiaro ancora presenti (pre-cifratura): {0}" -f $inChiaro.Count)
            }
        }
    }
}

# -----------------------------------------------------------------------------
#  7. Verdict
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Cyan
if ($Problemi -eq 0) {
    Write-Host " RISULTATO: TUTTO OK" -ForegroundColor Green
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ""
    exit 0
} else {
    Write-Host (" RISULTATO: {0} PROBLEMA/I RILEVATO/I" -f $Problemi) -ForegroundColor Red
    Write-Host ("=" * 64) -ForegroundColor Cyan
    Write-Host ""
    exit 1
}
