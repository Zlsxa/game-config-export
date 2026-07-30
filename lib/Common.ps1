<#
    Shared plumbing for the per-game export scripts.

    Everything here is game-agnostic: file discovery helpers, the KeyValues and
    cvar parsers, the anonymization pass and - most importantly - the
    verification pass that re-reads the finished export and refuses to call it
    clean if an identifier survived.

    It lives in one place on purpose. Each hardening fix below was found the
    hard way, and duplicating them per game is how one copy silently rots.

    Dot-source it from a game script:
        . (Join-Path $PSScriptRoot '..\lib\Common.ps1')
#>

# UTF-8 without BOM: what these games write, and what we write back.
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ===========================================================================
#  Shared data
# ===========================================================================

# Keys whose VALUES identify you. Always hidden from the readable summary;
# blanked in the raw copy when -Anonymize is used. Both games are covered here
# because a single scrubber runs over every text file either script produces.
$SensitiveKeys = @(
    # CS2
    'name', 'password', 'cl_clanid', 'cl_name', 'steamid', 'steamidtext',
    'last_name', 'player_name',
    # Apex
    'hdr_screenshot_directory', 'voice_input_device', 'miles_output_device'
)

# Files carrying account/third-party identifiers and NOT needed to restore
# settings. -Anonymize drops them from the raw copy entirely.
#   voice_ban.dt        : SteamID64 of every player YOU muted (other people's data!)
#   cs2_preferred_items : unique inventory asset IDs -> traceable back to your account
#   trustedlaunch.cfg   : Trusted-Mode hardware fingerprint of THIS machine
#   *_lastclouded       : stale duplicates of the convar files
#   socache/remotecache : Steam sync caches, regenerated automatically
$IdentifyingFiles = @('voice_ban.dt', 'socache.dt', 'remotecache.vdf',
                      'trustedlaunch.cfg',
                      'cs2_preferred_items.txt', 'cs2_loadout_favorites.txt',
                      'cs2_shuffle_slots.txt', 'csgo_saved_item_shuffles.txt')

# Files the anonymizer may rewrite as text. Deliberately does NOT include .dt:
# those are binary Steam blobs, and decoding one as UTF-8 then writing it back
# would silently corrupt it. -Anonymize deletes every .dt instead (none of them
# hold settings), because a binary blob cannot be scrubbed reliably.
$TextRewritePattern = '\.(vcfg(_lastclouded)?|txt|vdf|cfg|bak)$'

# Last-resort scrubbing of raw identifiers that may appear in any text file:
# SteamID64 (7656119xxxxxxxxxx), and account ids sitting next to an id key in
# either KeyValues ("steamid" "123") or ini (steamid = 123) form.
# The SteamID64 placeholder stays numeric (so nothing that parses these files
# chokes on it) but deliberately does NOT start with 7656119: otherwise the
# redacted value matches the leak pattern below and the verification pass
# reports its own scrubbing as a leak.
$IdPatterns = @(
    @{ Rx = [regex]'7656119\d{10}';                  Repl = '76500000000000000' }
    @{ Rx = [regex]'(?i)("(?:accountid|steamid|steamid64|ownerid)"\s+")\d+(")'
       Repl = '${1}0${2}' }
    @{ Rx = [regex]'(?im)^(\s*accountid\s*=\s*)\d+'; Repl = '${1}0' }
    @{ Rx = [regex]'(?im)^(\s*steamid\s*=\s*)\d+';   Repl = '${1}0' }
)

$QualityLevels = @{ '0' = 'Low'; '1' = 'Medium'; '2' = 'High'; '3' = 'Very High' }

# Two shapes, because the two games disagree on how a key is written:
#   CS2  KeyValues : "name"  "Value"   -> anchored on the opening quote
#   Apex cvar line : name    "Value"   -> anchored on start-of-line
# A single pattern cannot cover both without also matching `joy_name`, so they
# stay separate and both run over every text file.
$SensitiveRx = @(
    $SensitiveKeys | ForEach-Object {
        [regex]::new("(`"$([regex]::Escape($_))`"\s+`")[^`"]*(`")", 'IgnoreCase')
    }
    $SensitiveKeys | ForEach-Object {
        [regex]::new("(?im)^(\s*$([regex]::Escape($_))\s+`")[^`"]*(`")")
    }
)

# A game is not always installed under Program Files: a custom install can sit
# inside the user profile, and Apex's config always does. That would drop the
# Windows account name into paths written to a file meant for publishing.
# The profile FOLDER name can differ from $env:USERNAME, so cover both - and the
# 8.3 short name too, since a path handed in as C:\Users\LONGNA~1\... keeps that
# form through Resolve-Path and still spells out the start of the account name.
# \b keeps this tight: '_' is a word character, so a username like "user" does
# not eat the middle of a convar such as cl_new_user_phase.
$shortUser = $null
try {
    $shortUser = Split-Path ((New-Object -ComObject Scripting.FileSystemObject).GetFolder($env:USERPROFILE).ShortPath) -Leaf
} catch {}

$UserRx = @($env:USERNAME, (Split-Path $env:USERPROFILE -Leaf), $shortUser) |
          Where-Object { $_ } | Sort-Object -Unique | ForEach-Object {
              [regex]::new("\b$([regex]::Escape($_))\b", 'IgnoreCase')
          }

# Player names read from the ORIGINAL config, kept so the verification pass can
# prove they are gone from the export. Without this the check hunts for numeric
# ids only and would happily clear an export that still spells out your nickname.
$PlayerNames = [System.Collections.Generic.List[string]]::new()

# ===========================================================================
#  Helpers
# ===========================================================================

# Right-click > "Run with PowerShell" closes the window the instant the script
# ends, so a bare `exit 1` shows the user nothing at all. Hold the window open
# when we are attached to a real console.
function Stop-WithError {
    param([string]$Message, [string[]]$Hint)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    foreach ($h in $Hint) { Write-Host "        $h" -ForegroundColor Yellow }
    if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host 'Press Enter to close...' -ForegroundColor DarkGray
        [void](Read-Host)
    }
    exit 1
}

# These games write UTF-8 without a BOM. Get-Content -Raw would decode it with
# the console codepage and mangle any non-ASCII setting value.
function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

# Write a report as UTF-8 without BOM and with Windows line endings, whatever
# the source string carries: a here-string inherits the line endings of the
# .ps1, which depend on how git checked the script out. Normalizing here keeps
# the generated .txt identical on every machine, and readable in Notepad.
function Write-ReportFile {
    param([string]$Path, [string]$Text)
    # Also settle on exactly one trailing newline: a here-string ends without
    # one, StringBuilder.AppendLine leaves several.
    $body = ($Text -replace "`r?`n", "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $body, $utf8)
}

# Flat KeyValues parser: every "key" "value" pair (block headers have no inline
# value). Used by CS2 throughout, and by Apex for videoconfig.txt.
function ConvertFrom-KeyValues {
    param([string]$Content)
    $result = [ordered]@{}
    foreach ($m in [regex]::Matches($Content, '"([^"]+)"\s+"([^"]*)"')) {
        $result[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $result
}

# Apex cvar lines: `cl_fovScale "1.27216005"` - unquoted key, quoted value.
# settings.cfg mixes these with bind lines, so skip anything starting with bind.
function ConvertFrom-CvarLines {
    param([string]$Content)
    $result = [ordered]@{}
    foreach ($m in [regex]::Matches($Content, '(?m)^\s*(?!bind)([A-Za-z_][\w\.]*)\s+"([^"]*)"\s*$')) {
        $result[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $result
}

# Apex bind lines: `bind_US_standard "q" "+offhand1" 0`, plus the bind_held_*
# variant for the hold-to-activate layer. The keyboard layout is part of the
# directive name, so keep it: a bind file from an AZERTY layout is not the same
# thing as one from QWERTY.
function ConvertFrom-ApexBinds {
    param([string]$Content)
    $binds = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($Content, '(?m)^\s*(bind\w*)\s+"([^"]*)"\s+"([^"]*)"')) {
        $binds.Add([pscustomobject]@{
            Directive = $m.Groups[1].Value
            Key       = $m.Groups[2].Value
            Action    = $m.Groups[3].Value
            Held      = $m.Groups[1].Value -like '*_held_*' -or $m.Groups[1].Value -like 'bind_held*'
        })
    }
    return $binds
}

function Test-Sensitive {
    param([string]$Key)
    $k = $Key.ToLower()
    return ($SensitiveKeys -contains $k) -or ($k -like '*password*') -or ($k -like '*_directory')
}

function Format-VideoValue {
    param($Def, $Raw)
    switch ($Def.Type) {
        'quality' { if ($QualityLevels.ContainsKey("$Raw")) { $QualityLevels["$Raw"] } else { "$Raw (raw)" } }
        'bool'    { switch ("$Raw".ToLower()) { {$_ -in '1','true'} { 'Enabled' } {$_ -in '0','false'} { 'Disabled' } default { "$Raw (raw)" } } }
        'enum'    { if ($Def.Map.ContainsKey("$Raw")) { $Def.Map["$Raw"] } else { "$Raw (raw)" } }
        default   { "$Raw" }
    }
}

# CS2 keeps the game settings and keybinds TWICE, and the two copies are not
# interchangeable in principle even though they match in practice:
#   local\cfg\  this PC only, Windows line endings (CRLF)
#   remote\     the Steam Cloud copy, LF endings so it can sync to Linux/macOS
# Same settings on both sides, so prefer local\ (what the game reads here) and
# fall back to the Cloud copy.
function Select-ConfigFile {
    param([System.IO.FileInfo[]]$Files, [string]$NamePattern, [string]$Base)
    $candidates = @($Files | Where-Object { $_.Name -like $NamePattern })
    if ($candidates.Count -eq 0) { return $null }
    # Rank on the path RELATIVE to the game folder, anchored at its start.
    # Testing the absolute path would misfire whenever the install itself sits
    # under a folder named "local" - C:\Users\X\AppData\Local\Steam\... makes
    # every candidate look local (-notmatch is case-insensitive), and the
    # tiebreak then silently picks the Cloud copy instead.
    # local\ first, then the shortest name so slot0 wins over slot10.
    return ($candidates | Sort-Object @{ Expression = { $_.FullName.Substring($Base.Length) -notmatch '^\\local\\' } },
                                      @{ Expression = { $_.Name.Length } },
                                      Name)[0].FullName
}

function Get-SteamPath {
    try {
        $p = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    } catch {}
    try {
        $p = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction Stop).InstallPath
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    } catch {}
    foreach ($c in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", 'C:\Steam')) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    return $null
}

# Remember a player name so the verification pass can prove it is gone.
# Names shorter than 3 chars are not worth hunting for: they would match
# fragments of half the file and drown the report in false positives.
function Register-PlayerName {
    param($Settings, [string[]]$Keys = @('name', 'player_name', 'cl_name'))
    if (-not $Settings) { return }
    foreach ($k in $Keys) {
        if ($Settings[$k] -and "$($Settings[$k])".Length -ge 3) {
            [void]$PlayerNames.Add("$($Settings[$k])")
        }
    }
}

# ===========================================================================
#  Raw copy + anonymization
# ===========================================================================

# Copy the config for re-import. CopyMode 'Tree' takes the whole folder (CS2
# keeps everything worth having in one place); 'Selected' takes only the listed
# relative paths, which is what Apex needs - its folder hides 12 KB of config
# inside 230 MB of shader cache.
function Copy-GameConfig {
    param([string]$Root, [string]$Destination, [string]$CopyMode, [string[]]$CopyList)
    if ($CopyMode -eq 'Tree') {
        Copy-Item -Path (Join-Path $Root '*') -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # Recreate the relative folder structure so the copy can be dropped
        # straight back over the original.
        foreach ($rel in $CopyList) {
            $srcF = Join-Path $Root $rel
            if (-not (Test-Path $srcF)) { continue }
            $dstF = Join-Path $Destination $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dstF -Parent) | Out-Null
            Copy-Item $srcF $dstF -Force -ErrorAction SilentlyContinue
        }
    }
}

# Single walk of the raw copy, doing:
#   a) delete files carrying account / third-party identifiers, plus every .dt
#      binary blob (see $IdentifyingFiles / $TextRewritePattern);
#   b) scrub the text files that survive.
# AccountId is scrubbed out of file CONTENT too, not just out of printed paths -
# but only when it really is an identifier. Apex's is the literal folder name
# "profile", and substituting that would mangle ...\Apex\profile\profile.cfg.
function Invoke-ConfigAnonymize {
    param([string]$RawDir, [string]$AccountId)
    $accountIdRx = if ($AccountId) { [regex]::new("\b$([regex]::Escape($AccountId))\b") } else { $null }
    $dropped = 0
    # Materialize before deleting: don't mutate the tree mid-enumeration.
    foreach ($f in @(Get-ChildItem $RawDir -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($IdentifyingFiles -contains $f.Name -or $f.Name -like '*_lastclouded' -or
            $f.Extension -eq '.dt') {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            $dropped++
            continue
        }
        if ($f.Name -notmatch $TextRewritePattern) { continue }
        $txt = [System.IO.File]::ReadAllText($f.FullName, $utf8)
        foreach ($rx in $SensitiveRx) { $txt = $rx.Replace($txt, '${1}${2}') }
        foreach ($p in $IdPatterns)   { $txt = $p.Rx.Replace($txt, $p.Repl) }
        if ($accountIdRx) { $txt = $accountIdRx.Replace($txt, '<ACCOUNT_ID>') }
        foreach ($rx in $UserRx) { $txt = $rx.Replace($txt, '<USER>') }
        [System.IO.File]::WriteAllText($f.FullName, $txt, $utf8)
    }
    return $dropped
}

# ===========================================================================
#  Verification: never trust the scrubbing blindly. Re-read what was actually
#  written and look for identifiers before the user publishes it.
# ===========================================================================
function Test-ExportForLeaks {
    param([string]$BackupRoot, [string[]]$AccountIds)

    Write-Host ""
    Write-Host "Verifying the anonymized export..." -ForegroundColor Cyan

    $leakRx = [regex]'7656119\d{10}'
    $leaks  = [System.Collections.Generic.List[string]]::new()
    # Compiled once, not re-escaped for every file x every account.
    $accountRx = @($AccountIds | Where-Object { $_ } |
                   ForEach-Object { [regex]::new("\b$([regex]::Escape($_))\b") })
    # Player names collected while reading the ORIGINAL config files.
    $nameRx = @($PlayerNames | Sort-Object -Unique |
                ForEach-Object { [regex]::new([regex]::Escape($_), 'IgnoreCase') })

    # Anchor the relative path on the backup folder NAME, not on the length of
    # $BackupRoot: an 8.3 short path (C:\Users\LONGNA~1\...) does not survive
    # Resolve-Path, and Get-ChildItem hands back the expanded form.
    $backupLeaf = Split-Path $BackupRoot -Leaf

    # Scan EVERY file, whatever its extension. Filtering this pass by the
    # rewrite pattern is what once let an untouched cs2_video.txt.bak - SteamID64
    # and all - be reported as "safe to publish": the check must not share the
    # blind spot of the thing it is checking. Latin-1 maps every byte to one
    # char, so a leftover binary is searched for ASCII ids too instead of
    # throwing on invalid UTF-8.
    $scanEnc = [System.Text.Encoding]::GetEncoding(28591)

    # Strip our own placeholders before looking for leaks, or the redaction gets
    # reported as the thing it redacted: a Windows account actually named "user"
    # matches <USER>. Same trap as the SteamID64 placeholder, which is why that
    # one is numeric-but-invalid rather than a word.
    $placeholderRx = [regex]'<ACCOUNT_ID>|<USER>'

    foreach ($f in Get-ChildItem $BackupRoot -Recurse -File -ErrorAction SilentlyContinue) {
        $txt = $placeholderRx.Replace([System.IO.File]::ReadAllText($f.FullName, $scanEnc), '')
        $cut = $f.FullName.LastIndexOf($backupLeaf)
        $rel = if ($cut -ge 0) { $f.FullName.Substring($cut + $backupLeaf.Length).TrimStart('\') }
               else            { $f.Name }
        if ($leakRx.IsMatch($txt)) { $leaks.Add("$rel : SteamID64") }
        foreach ($rx in $accountRx) {
            if ($rx.IsMatch($txt)) { $leaks.Add("$rel : account ID") }
        }
        # Checked here too: anything the scrubbing covers, the verification has
        # to cover as well, or "safe to publish" means less than it says.
        foreach ($rx in $UserRx) {
            if ($rx.IsMatch($txt)) { $leaks.Add("$rel : Windows user name") }
        }
        foreach ($rx in $nameRx) {
            if ($rx.IsMatch($txt)) { $leaks.Add("$rel : player name") }
        }
    }

    if ($leaks.Count -eq 0) {
        Write-Host "  [OK] No identifier found in the export - safe to publish." -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] Identifiers still present - DO NOT PUBLISH AS-IS:" -ForegroundColor Red
        foreach ($x in ($leaks | Select-Object -Unique)) { Write-Host "    - $x" -ForegroundColor Yellow }
    }
}

# Closing banner shared by both scripts.
function Write-ExportFooter {
    param([string]$BackupRoot, [bool]$Anonymized)
    Write-Host ""
    Write-Host "Done! Export available in:" -ForegroundColor Cyan
    Write-Host "  $BackupRoot" -ForegroundColor White
    if (-not $Anonymized) {
        Write-Host "  Reminder: this copy contains your player name and account IDs." -ForegroundColor Yellow
        Write-Host "  Use -Anonymize before publishing it anywhere." -ForegroundColor Yellow
    }
    Write-Host ""
    try { Start-Process explorer.exe $BackupRoot } catch {}
}
