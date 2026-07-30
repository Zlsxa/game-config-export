<#
.SYNOPSIS
    Backs up and exports your Battlefield 6 configuration.

.DESCRIPTION
    This script:
      1. Locates the BF6 profile under Documents\Battlefield 6\settings\.
      2. Copies the config files, byte-for-byte, ready to be re-imported.
      3. Generates a human-readable .txt listing ALL settings - friendly labels
         where known, raw names otherwise.
      4. Generates a .txt explaining WHERE the config lives and HOW to re-import it.

    The script is READ-ONLY on your game: it never changes your settings.

    Unlike Apex, the launcher genuinely changes the path here: the EA App build
    writes settings\PROFSAVE_profile while the Steam build writes
    settings\steam\PROFSAVE_profile. Both are looked for, and both are exported
    when both exist.

    Privacy: identifying values are ALWAYS excluded from the readable summary,
    so it is safe to share. Use -Anonymize to also strip them from the raw copy,
    then check the verification result before publishing.

    Needs lib\Common.ps1 from the same repository - clone or download the whole
    repo rather than this single file.

.PARAMETER OutputRoot
    Root folder to write the export to. Default: your Desktop.

.PARAMETER SettingsPath
    Optional: force the "Documents\Battlefield 6\settings" folder.

.PARAMETER Anonymize
    Strips identifying info from the raw exported copy too. Use this if you
    intend to SHARE the raw config publicly.

.EXAMPLE
    .\Export-BF6Config.ps1

.EXAMPLE
    .\Export-BF6Config.ps1 -OutputRoot "D:\Backups" -Anonymize

.NOTES
    License: MIT
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'BF6_Config_Export'),
    [string]$SettingsPath,
    [switch]$Anonymize
)

$ErrorActionPreference = 'Stop'

$common = Join-Path $PSScriptRoot '..\lib\Common.ps1'
if (-not (Test-Path $common)) {
    Write-Host "[ERROR] lib\Common.ps1 not found next to this script." -ForegroundColor Red
    Write-Host "        Download the whole repository, not just this file." -ForegroundColor Yellow
    exit 1
}
. $common

# ===========================================================================
#  BF6 data: translations
# ===========================================================================

# Frostbite settings worth labelling. The scales below are the ones the game's
# own menu exposes; anything not listed is printed raw rather than guessed.
$BF6Map = @{
    'GstRender.ResolutionScale' = 'Resolution scale (%)'
    'GstRender.FieldOfView'     = 'Field of view (degrees)'
    'GstRender.Dx12Enabled'     = 'DirectX 12'
    'GstRender.MotionBlur'      = 'Motion blur'
    'GstRender.WeaponDOF'       = 'Depth of field (weapon)'
    'GstRender.ShadowQuality'   = 'Shadow quality'
    'GstRender.Upscaling'       = 'Upscaling'
    'GstInput.MouseSensitivity' = 'Mouse sensitivity'
}

# Value scales documented by the in-game menu. Used only where the mapping is
# unambiguous - a wrong label misreports the config, which is worse than a bare
# number.
$BF6Enums = @{
    'GstRender.ShadowQuality' = @{ '0' = 'Off'; '1' = 'Low'; '2' = 'Medium'; '3' = 'High'; '4' = 'Ultra' }
    'GstRender.Upscaling'     = @{ '0' = 'Disabled'; '1' = 'FSR'; '2' = 'DLSS'; '3' = 'XeSS' }
}

# Frostbite namespaces every key, so the prefix already is the category.
$BF6Categories = @(
    @{ Name = 'Video / Render'; Pattern = '^GstRender\.' }
    @{ Name = 'Display';        Pattern = '^GstDisplay\.' }
    @{ Name = 'Input / Mouse';  Pattern = '^GstInput\.' }
    @{ Name = 'Audio';          Pattern = '^GstAudio\.' }
    @{ Name = 'Gameplay';       Pattern = '^GstGameplay\.' }
    @{ Name = 'Interface';      Pattern = '^(GstUI\.|GstHud\.)' }
    @{ Name = 'Keybinds';       Pattern = '^(GstAction\.|GstBinding\.)' }
)

# The two builds keep their profile in different places - the one real path
# difference between launchers across the games supported here.
$BF6Profiles = @(
    @{ Launcher = 'EA App'; Relative = 'PROFSAVE_profile' }
    @{ Launcher = 'Steam';  Relative = 'steam\PROFSAVE_profile' }
)

function Get-BF6SettingsPath {
    $p = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Battlefield 6\settings'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    # GetFolderPath follows a relocated Documents folder; this is the fallback
    # for the rare case where it returns nothing useful.
    $p = Join-Path $env:USERPROFILE 'Documents\Battlefield 6\settings'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    return $null
}

# ===========================================================================
#  Main
# ===========================================================================
Write-Host ""
Write-Host "=== Battlefield 6 configuration export ===" -ForegroundColor Cyan

$settings = if ($SettingsPath) { $SettingsPath } else { Get-BF6SettingsPath }
if (-not $settings -or -not (Test-Path $settings)) {
    Stop-WithError 'Battlefield 6 settings folder not found.' `
                   'Pass it explicitly: .\Export-BF6Config.ps1 -SettingsPath "...\Documents\Battlefield 6\settings"'
}
$settings = (Resolve-Path $settings).Path
Write-Host "Settings folder: $settings" -ForegroundColor Green

$found = @($BF6Profiles | Where-Object { Test-Path (Join-Path $settings $_.Relative) })
if ($found.Count -eq 0) {
    Stop-WithError "No PROFSAVE_profile found under $settings" `
                   'Launch Battlefield 6 at least once to generate it.'
}
foreach ($p in $found) { Write-Host "  Profile found: $($p.Relative)  ($($p.Launcher) build)" -ForegroundColor Green }

$backupR = Join-Path $OutputRoot ("BF6_Backup_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
$outDir  = Join-Path $backupR 'bf6_profile'
$rawDir  = Join-Path $outDir  'raw_config_for_reimport'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

# BF6 has no per-account id in its paths - the identifying part is the Windows
# user name, which the shared scrubber replaces with <USER>.
$hidePath = {
    param([string]$P)
    if (-not $Anonymize) { return $P }
    foreach ($rx in $UserRx) { $P = $rx.Replace($P, '<USER>') }
    return $P
}

# --- 1. Raw copy (for re-import) ---
Copy-GameConfig -Root $settings -Destination $rawDir -CopyMode 'Selected' -CopyList @($found.Relative)
$copied = @(Get-ChildItem $rawDir -Recurse -File -ErrorAction SilentlyContinue)
$kb = [math]::Round((($copied | Measure-Object Length -Sum).Sum / 1KB), 1)
Write-Host "  [OK] Config copied (raw): $($copied.Count) file(s), $kb KB." -ForegroundColor Green

if ($Anonymize) {
    $dropped = Invoke-ConfigAnonymize -RawDir $rawDir -AccountId $null
    Write-Host "  [OK] Raw copy anonymized ($dropped identifying file(s) removed)." -ForegroundColor Green
}

# --- 2. Human-readable summary (ALL settings) ---
$h = New-Object System.Text.StringBuilder
[void]$h.AppendLine('==============================================')
[void]$h.AppendLine('  BATTLEFIELD 6 CONFIGURATION - READABLE SUMMARY')
[void]$h.AppendLine("  Exported on: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$h.AppendLine('  (Identifying values are omitted - safe to share.)')
[void]$h.AppendLine('==============================================')
[void]$h.AppendLine('')

foreach ($prof in $found) {
    $file = Join-Path $settings $prof.Relative
    $cfg  = ConvertFrom-KeyValueLines (Read-TextFile $file)

    # Frostbite namespaces its keys, so the identity key is not simply "name",
    # and the profile carries an EA persona id beside it. Register both kinds of
    # value so the verification pass can prove they are gone - the exact key
    # names are not documented anywhere reliable, hence matching on shape.
    foreach ($k in $cfg.Keys) {
        if ($k -match '(?i)(^|\.)(name|persona|personaid|playername|gamertag|tag|userid|playerid|nucleusid|originid)$' -and
            "$($cfg[$k])".Length -ge 3) {
            [void]$PlayerNames.Add("$($cfg[$k])")
        }
    }

    [void]$h.AppendLine("--- $($prof.Launcher.ToUpper()) BUILD: $($prof.Relative) ($($cfg.Count) settings) ---")
    [void]$h.AppendLine('')

    $buckets = [ordered]@{}
    foreach ($c in $BF6Categories) { $buckets[$c.Name] = [System.Collections.Generic.List[string]]::new() }
    $buckets['Other'] = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $cfg.Keys) {
        if (Test-Sensitive $k) { continue }
        $cat = 'Other'
        foreach ($c in $BF6Categories) { if ($k -match $c.Pattern) { $cat = $c.Name; break } }
        $buckets[$cat].Add($k)
    }

    foreach ($catName in $buckets.Keys) {
        $keys = $buckets[$catName]
        if (-not $keys) { continue }
        [void]$h.AppendLine("  [ $catName ]")
        foreach ($k in $keys) {
            $val = $cfg[$k]
            # Show the menu wording next to the number where the scale is known.
            if ($BF6Enums.ContainsKey($k) -and $BF6Enums[$k].ContainsKey("$val")) {
                $val = "$val ($($BF6Enums[$k]["$val"]))"
            }
            $line = "  {0,-42} : {1}" -f $k, $val
            if ($BF6Map.ContainsKey($k)) { $line += ("   # {0}" -f $BF6Map[$k]) }
            [void]$h.AppendLine($line)
        }
        [void]$h.AppendLine('')
    }
}

[void]$h.AppendLine('  Note: unlabelled keys are printed raw. Frostbite exposes far more')
[void]$h.AppendLine('        settings than its menu does, and inventing labels for them')
[void]$h.AppendLine('        would misreport your config.')

Write-ReportFile (Join-Path $outDir 'readable_settings.txt') $h.ToString()
Write-Host "  [OK] Readable summary: readable_settings.txt" -ForegroundColor Green

# --- 3. Location + re-import instructions ---
$detected = @($found | ForEach-Object {
    "  - $(& $hidePath (Join-Path $settings $_.Relative))   ($($_.Launcher) build)"
})

$loc = @"
==============================================
  BATTLEFIELD 6 CONFIG LOCATION & RE-IMPORT
==============================================

ORIGINAL LOCATION:
  $(& $hidePath $settings)

Profile(s) detected:
$($detected -join [Environment]::NewLine)

----------------------------------------------
WHY THERE CAN BE TWO PROFILES
----------------------------------------------
Battlefield 6 keeps its settings in a plain "Key Value" text file called
PROFSAVE_profile, and the two builds do NOT put it in the same place:

  settings\PROFSAVE_profile          the EA App build
  settings\steam\PROFSAVE_profile    the Steam build

If you have played both, both files exist and they are independent - changing
your settings in one does not touch the other. This export contains whichever
ones were present, each under its own path, so restoring puts them back where
they belong.

There may also be a user.cfg in the game's INSTALL folder (not here). It is an
optional tweak file some players add by hand; it is not part of the profile and
is not exported.

----------------------------------------------
HOW TO RE-IMPORT THIS CONFIG (this PC or another):
----------------------------------------------
  1. Fully close Battlefield 6 and its launcher. Both write the profile on
     exit, so copying while they run gets your files overwritten.

  2. Copy the CONTENTS of "raw_config_for_reimport\" into:
       %USERPROFILE%\Documents\Battlefield 6\settings\
     keeping the steam\ subfolder if it is there - that is what routes the
     profile to the right build.

  3. Accept overwriting the existing files.

  4. Start the game and check your settings in the menu.

Note: EA cloud saves can restore their own copy of the profile over yours on
      the next launch. If your settings revert, turn cloud saves off for
      Battlefield 6 in the EA App (or in Steam's game properties for the Steam
      build), restore again, launch once, then turn them back on.
"@

if ($Anonymize) {
    $loc += @"


ANONYMIZED EXPORT: this copy was stripped for public sharing.
  - Identity-looking values (name, persona, tag) were replaced with <REDACTED>.
  - The Windows user name was replaced with <USER> in the paths above.
  Your graphics, input and gameplay settings are untouched, so this export
  still restores correctly - only the identifying values are gone.
"@
}

Write-ReportFile (Join-Path $outDir 'location_and_reimport.txt') $loc
Write-Host "  [OK] Instructions: location_and_reimport.txt" -ForegroundColor Green

if ($Anonymize) { Test-ExportForLeaks -BackupRoot $backupR -AccountIds @() }

Write-ExportFooter -BackupRoot $backupR -Anonymized $Anonymize.IsPresent
