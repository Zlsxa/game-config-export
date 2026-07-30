<#
.SYNOPSIS
    Backs up and exports your Apex Legends configuration.

.DESCRIPTION
    This script:
      1. Locates the Apex config under the "Saved Games" folder.
      2. Copies the config files, byte-for-byte, ready to be re-imported.
      3. Generates a human-readable .txt listing ALL settings (graphics, game
         settings, keybinds) - friendly labels where known, raw names otherwise.
      4. Generates a .txt explaining WHERE the config lives and HOW to re-import it.

    The script is READ-ONLY on your game: it never changes your settings.

    Only the config files are copied. local\psoCache.pso is a ~230 MB compiled
    shader cache and assets\ is re-downloadable store art, so copying the folder
    wholesale would turn a 12 KB config into a 230 MB "backup".

    Privacy: identifying values (player name) are ALWAYS excluded from the
    readable summary, so it is safe to share. Use -Anonymize to also strip them
    from the raw copy, then check the verification result before publishing.

    Needs lib\Common.ps1 from the same repository - clone or download the whole
    repo rather than this single file.

.PARAMETER OutputRoot
    Root folder to write the export to. Default: your Desktop.

.PARAMETER ApexPath
    Optional: force the "Saved Games\Respawn\Apex" folder if auto-detection fails.

.PARAMETER Launcher
    Which launcher Apex is installed from: steam or ea (EA App / Origin).
    Omit it and the script asks at startup. It only changes the cloud-save
    instructions in the generated re-import guide - the config itself is written
    to the same folder either way.

.PARAMETER Anonymize
    Strips identifying info (player name, Steam account id, Windows user name)
    from the raw exported copy too. Use this to SHARE the config publicly.

.EXAMPLE
    .\Export-ApexConfig.ps1

.EXAMPLE
    .\Export-ApexConfig.ps1 -OutputRoot "D:\Backups" -Anonymize

.NOTES
    License: MIT
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Apex_Config_Export'),
    [string]$ApexPath,
    [ValidateSet('steam', 'ea')]
    [string]$Launcher,
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
#  Apex data: translations
# ===========================================================================

# Files under Saved Games\Respawn\Apex worth exporting. Everything else there is
# bulk: psoCache.pso alone is ~230 MB of compiled shaders, and assets\ holds
# re-downloadable store/promo art.
$ApexConfigFiles = @('local\videoconfig.txt', 'local\settings.cfg',
                     'profile\profile.cfg', 'profile\steam_autocloud.vdf')

# Apex video settings (videoconfig.txt). Same KeyValues format as CS2, so the
# shared parser reads it. Only settings whose scale is documented get a mapped
# label; the rest print raw, on purpose rather than guessed.
$ApexVideoMap = [ordered]@{
    'setting.defaultres'          = @{ Label = 'Resolution - width';        Type = 'raw' }
    'setting.defaultresheight'    = @{ Label = 'Resolution - height';       Type = 'raw' }
    'setting.last_display_width'  = @{ Label = 'Display width';             Type = 'raw' }
    'setting.last_display_height' = @{ Label = 'Display height';            Type = 'raw' }
    'setting.fullscreen'          = @{ Label = 'Fullscreen';                Type = 'bool' }
    'setting.nowindowborder'      = @{ Label = 'Borderless window';         Type = 'bool' }
    'setting.mat_vsync_mode'      = @{ Label = 'Vertical sync (VSync)';     Type = 'enum'
                                       Map   = @{ '0' = 'Disabled'; '1' = 'Enabled'; '2' = 'Adaptive' } }
    'setting.mat_antialias_mode'  = @{ Label = 'Anti-aliasing (raw)';       Type = 'raw' }
    'setting.mat_forceaniso'      = @{ Label = 'Anisotropic filtering';     Type = 'enum'
                                       Map   = @{ '1' = 'Off'; '2' = '2x'; '4' = '4x'; '8' = '8x'; '16' = '16x' } }
    'setting.mat_picmip'          = @{ Label = 'Texture streaming budget';  Type = 'raw' }
    'setting.stream_memory'       = @{ Label = 'Texture streaming memory';  Type = 'raw' }
    'setting.shadow_enable'       = @{ Label = 'Shadows enabled';           Type = 'bool' }
    'setting.csm_enabled'         = @{ Label = 'Sun shadow coverage on';    Type = 'bool' }
    'setting.csm_cascade_res'     = @{ Label = 'Sun shadow resolution';     Type = 'raw' }
    'setting.shadow_maxdynamic'   = @{ Label = 'Spot shadow count';         Type = 'raw' }
    'setting.ssao_quality'        = @{ Label = 'Ambient occlusion quality'; Type = 'raw' }
    'setting.volumetric_lighting' = @{ Label = 'Volumetric lighting';       Type = 'bool' }
    'setting.volumetric_fog'      = @{ Label = 'Volumetric fog';            Type = 'bool' }
    'setting.map_detail_level'    = @{ Label = 'Model detail';              Type = 'raw' }
    'setting.particle_cpu_level'  = @{ Label = 'Effects detail';            Type = 'raw' }
    'setting.cl_ragdoll_maxcount' = @{ Label = 'Ragdoll count';             Type = 'raw' }
    'setting.dvs_enable'          = @{ Label = 'Adaptive resolution (DVS)'; Type = 'bool' }
    'setting.dvs_gpuframetime_min'= @{ Label = 'Adaptive res. target min';  Type = 'raw' }
    'setting.dvs_gpuframetime_max'= @{ Label = 'Adaptive res. target max';  Type = 'raw' }
    'setting.gamma'               = @{ Label = 'Brightness (gamma)';        Type = 'raw' }
    'setting.sound_volume'        = @{ Label = 'Master volume';             Type = 'raw' }
    'setting.configversion'       = @{ Label = 'Video config version';      Type = 'raw' }
}

# Friendly labels for the cvars people actually tune. Everything present is
# still listed, labelled or not.
$ApexCvarLabels = @{
    'mouse_sensitivity'                       = 'Mouse sensitivity'
    'm_acceleration'                          = 'Mouse acceleration'
    'mouse_use_per_scope_sensitivity_scalars' = 'Per-scope sensitivity'
    'cl_fovScale'                             = 'Field of view scale'
    'cl_safearea'                             = 'HUD safe area'
    'sound_volume_voice'                      = 'Voice chat volume'
    'voice_scale'                             = 'Voice volume'
    'VoiceChatMode'                           = 'Voice chat mode'
    'colorblind_mode'                         = 'Colourblind mode'
    'CrossPlay_user_optin'                    = 'Crossplay enabled'
    'damage_indicator_style_pilot'            = 'Damage indicator style'
    'lookstrafe'                              = 'Look-strafe'
    'lookspring'                              = 'Look-spring'
}

# Category rules for grouping cvars. First regex match wins; unmatched -> "Other".
$ApexCvarCategories = @(
    @{ Name = 'Aim / Mouse'; Pattern = '^(mouse_|m_|sensitivity)' }
    @{ Name = 'Video / HUD'; Pattern = '^(cl_fov|cl_safearea|hud_|damage_indicator|colorblind|cc_|closecaption|chroma_|gfx_)' }
    @{ Name = 'Audio';       Pattern = '^(sound_|voice_|Voice|miles_)' }
    @{ Name = 'Gameplay';    Pattern = '^(cl_|CrossPlay|communication|dialogue_|first_time|menu_|mp_|ui_)' }
    @{ Name = 'Spectator';   Pattern = '^sv_spec' }
)

# Guess which launcher Apex came from, to preselect an answer in the prompt.
# Only Apex-specific evidence counts. Whether Steam or the EA App is installed
# on the PC says nothing: plenty of people run Steam for other games and Apex
# from the EA App.
#   steam_autocloud.vdf  -> Steam synced THIS config at some point
#   appmanifest_1172470  -> Apex is installed through Steam right now
# Neither proves the current launcher on its own (a leftover .vdf survives a
# Steam uninstall), which is why this only ever suggests a default and the user
# has the final say.
function Get-LauncherGuess {
    param([string]$ApexRoot)
    if (Test-Path (Join-Path $ApexRoot 'profile\steam_autocloud.vdf')) {
        return @{ Value = 'steam'; Why = 'profile\steam_autocloud.vdf found' }
    }
    $libs = @()
    $steam = Get-SteamPath
    if ($steam) {
        $libs += (Join-Path $steam 'steamapps')
        $lf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $lf) {
            foreach ($m in [regex]::Matches((Get-Content $lf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps')
            }
        }
    }
    foreach ($l in ($libs | Sort-Object -Unique)) {
        if (Test-Path (Join-Path $l 'appmanifest_1172470.acf')) {
            return @{ Value = 'steam'; Why = 'Apex found in a Steam library' }
        }
    }
    return @{ Value = 'ea'; Why = 'no Steam trace found for Apex' }
}

# Ask which launcher the game comes from. The answer only tailors the cloud-save
# step of the re-import guide - that step is wrong for half the users otherwise,
# since the EA App has no "Steam Cloud" checkbox.
function Read-Launcher {
    param([string]$Default, [string]$Why)
    Write-Host ""
    Write-Host "Which launcher is Apex Legends installed from?" -ForegroundColor Cyan
    Write-Host "  [1] Steam"
    Write-Host "  [2] EA App (Origin)"
    Write-Host ("  Detected: {0}  ({1})" -f $(if ($Default -eq 'steam') { 'Steam' } else { 'EA App' }), $Why) -ForegroundColor DarkGray
    # No console to answer on (scheduled task, piped input): keep the detected
    # value rather than blocking forever on Read-Host.
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected) {
        Write-Host "  (no interactive console - using the detected value)" -ForegroundColor DarkGray
        return $Default
    }
    while ($true) {
        $answer = Read-Host ("  Choice [1/2, Enter = detected]")
        if (-not $answer)              { return $Default }
        if ($answer -in '1', 'steam')  { return 'steam' }
        if ($answer -in '2', 'ea', 'origin') { return 'ea' }
        Write-Host "  Please type 1 or 2." -ForegroundColor Yellow
    }
}

# Apex keeps its config in the "Saved Games" known folder, which users can
# relocate (to another drive, or to OneDrive). Ask the shell where it actually
# is before falling back to the default location under the profile.
function Get-ApexPath {
    $roots = @()
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $sg  = (Get-ItemProperty -Path $key -Name '{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}' -ErrorAction Stop).'{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}'
        if ($sg) { $roots += [Environment]::ExpandEnvironmentVariables($sg) }
    } catch {}
    $roots += (Join-Path $env:USERPROFILE 'Saved Games')
    foreach ($r in $roots) {
        $p = Join-Path $r 'Respawn\Apex'
        if ($r -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    }
    return $null
}

# ===========================================================================
#  Main
# ===========================================================================
Write-Host ""
Write-Host "=== Apex Legends configuration export ===" -ForegroundColor Cyan

$apex = if ($ApexPath) { $ApexPath } else { Get-ApexPath }
if (-not $apex -or -not (Test-Path $apex)) {
    Stop-WithError 'Apex Legends config folder not found.' `
                   'Pass it explicitly: .\Export-ApexConfig.ps1 -ApexPath "...\Saved Games\Respawn\Apex"'
}
$apex  = (Resolve-Path $apex).Path
$found = @($ApexConfigFiles | Where-Object { Test-Path (Join-Path $apex $_) })
if ($found.Count -eq 0) {
    Stop-WithError "No Apex config files under $apex" 'Launch Apex at least once to generate them.'
}
Write-Host "Apex Legends found: $apex" -ForegroundColor Green

if (-not $Launcher) {
    $guess    = Get-LauncherGuess -ApexRoot $apex
    $Launcher = Read-Launcher -Default $guess.Value -Why $guess.Why
}
$isSteam = $Launcher -eq 'steam'
Write-Host ("Launcher: {0}" -f $(if ($isSteam) { 'Steam' } else { 'EA App (Origin)' })) -ForegroundColor Green

$video   = $(if (Test-Path (Join-Path $apex 'local\videoconfig.txt')) { Join-Path $apex 'local\videoconfig.txt' })
$binds   = $(if (Test-Path (Join-Path $apex 'local\settings.cfg'))    { Join-Path $apex 'local\settings.cfg' })
$profileCfg = $(if (Test-Path (Join-Path $apex 'profile\profile.cfg'))   { Join-Path $apex 'profile\profile.cfg' })

$backupR = Join-Path $OutputRoot ("Apex_Backup_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
$outDir  = Join-Path $backupR 'apex_profile'
$rawDir  = Join-Path $outDir  'raw_config_for_reimport'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

# Apex has no per-account id in its paths - the identifying part is the Windows
# user name, which the shared scrubber replaces with <USER>.
$hidePath = {
    param([string]$P)
    if (-not $Anonymize) { return $P }
    foreach ($rx in $UserRx) { $P = $rx.Replace($P, '<USER>') }
    return $P
}

# --- 1. Raw copy of the config files only (for re-import) ---
Copy-GameConfig -Root $apex -Destination $rawDir -CopyMode 'Selected' -CopyList $found
$copied = @(Get-ChildItem $rawDir -Recurse -File -ErrorAction SilentlyContinue)
$kb = [math]::Round((($copied | Measure-Object Length -Sum).Sum / 1KB), 1)
Write-Host "  [OK] Config copied (raw): $($copied.Count) file(s), $kb KB." -ForegroundColor Green

if ($Anonymize) {
    # No account id to pass: Apex's identifier is inside steam_autocloud.vdf and
    # is handled by the shared id patterns.
    $dropped = Invoke-ConfigAnonymize -RawDir $rawDir -AccountId $null
    Write-Host "  [OK] Raw copy anonymized ($dropped identifying file(s) removed)." -ForegroundColor Green
}

# --- 2. Human-readable summary (ALL settings) ---
$h = New-Object System.Text.StringBuilder
[void]$h.AppendLine('==============================================')
[void]$h.AppendLine('  APEX LEGENDS CONFIGURATION - READABLE SUMMARY')
[void]$h.AppendLine("  Exported on: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$h.AppendLine('  (Identifying values are omitted - safe to share.)')
[void]$h.AppendLine('==============================================')
[void]$h.AppendLine('')

# Graphics / video
[void]$h.AppendLine('--- GRAPHICS / VIDEO SETTINGS ---')
[void]$h.AppendLine('  (Stored in local\videoconfig.txt, which the Steam Cloud does NOT sync:')
[void]$h.AppendLine('   these do not follow you to another PC.)')
[void]$h.AppendLine('')
if ($video) {
    $kv = ConvertFrom-KeyValues (Read-TextFile $video)
    foreach ($k in $kv.Keys) {
        # The summary is advertised as safe to share, so an unmapped key never
        # gets printed unchecked.
        if (Test-Sensitive $k) { continue }
        if ($ApexVideoMap.Contains($k)) {
            $def = $ApexVideoMap[$k]
            [void]$h.AppendLine(("  {0,-36} : {1}" -f $def.Label, (Format-VideoValue $def $kv[$k])))
        } else {
            [void]$h.AppendLine(("  {0,-36} : {1}" -f ($k -replace '^setting\.', ''), $kv[$k]))
        }
    }
    [void]$h.AppendLine('')
    [void]$h.AppendLine('  Note: "(raw)" values are internal detail levels whose scale differs per')
    [void]$h.AppendLine('        setting. They are shown unlabelled on purpose rather than guessed.')
} else {
    [void]$h.AppendLine('  (videoconfig.txt not found under local\.)')
}
[void]$h.AppendLine('')

# Game settings: Apex splits them across two line-based files - profile.cfg
# (cloud-synced) and the cvar half of settings.cfg (local) - so both are read
# and merged here.
$cv = [ordered]@{}
foreach ($src in @($profileCfg, $binds)) {
    if (-not $src) { continue }
    $part = ConvertFrom-CvarLines (Read-TextFile $src)
    foreach ($k in $part.Keys) { $cv[$k] = $part[$k] }
}
if ($cv.Count -gt 0) {
    Register-PlayerName $cv

    # Bucket every setting into its category (first matching rule wins).
    # Lists, not arrays: "$array += $x" reallocates the whole array each time.
    $buckets = [ordered]@{}
    foreach ($c in $ApexCvarCategories) { $buckets[$c.Name] = [System.Collections.Generic.List[string]]::new() }
    $buckets['Other'] = [System.Collections.Generic.List[string]]::new()
    $shown = 0
    foreach ($k in $cv.Keys) {
        if (Test-Sensitive $k) { continue }
        $cat = 'Other'
        foreach ($c in $ApexCvarCategories) { if ($k -match $c.Pattern) { $cat = $c.Name; break } }
        $buckets[$cat].Add($k)
        $shown++
    }

    [void]$h.AppendLine("--- GAME SETTINGS ($shown settings) ---")
    [void]$h.AppendLine('  (profile\profile.cfg is synced by the Steam Cloud; the settings that')
    [void]$h.AppendLine('   live in local\settings.cfg are not.)')
    [void]$h.AppendLine('')
    foreach ($catName in $buckets.Keys) {
        $keys = $buckets[$catName]
        if (-not $keys) { continue }
        [void]$h.AppendLine("  [ $catName ]")
        foreach ($k in $keys) {
            $line = "  {0,-40} : {1}" -f $k, $cv[$k]
            if ($ApexCvarLabels.ContainsKey($k)) { $line += ("   # {0}" -f $ApexCvarLabels[$k]) }
            [void]$h.AppendLine($line)
        }
        [void]$h.AppendLine('')
    }
}

# Keybinds. Apex writes one line per bind, and a separate "held" layer for keys
# that do something different when held down. Both are listed, the held ones
# flagged, because a bind list that silently merges them would misdescribe the
# config.
if ($binds) {
    $bindList = ConvertFrom-ApexBinds (Read-TextFile $binds)
    $layouts  = @($bindList | ForEach-Object { $_.Directive -replace '^bind_(held_)?', '' } | Sort-Object -Unique)
    [void]$h.AppendLine("--- KEYBINDS ($($bindList.Count) binds) ---")
    [void]$h.AppendLine("  (Keyboard layout(s) in the file: $($layouts -join ', '))")
    [void]$h.AppendLine('  (Stored in local\settings.cfg - NOT synced by the Steam Cloud.)')
    [void]$h.AppendLine('')
    foreach ($b in $bindList) {
        $suffix = if ($b.Held) { '   [held]' } else { '' }
        $action = if ($b.Action) { $b.Action } else { '(unbound)' }
        [void]$h.AppendLine(("  {0,-16} -> {1}{2}" -f $b.Key, $action, $suffix))
    }
    [void]$h.AppendLine('')
}

Write-ReportFile (Join-Path $outDir 'readable_settings.txt') $h.ToString()
Write-Host "  [OK] Readable summary: readable_settings.txt" -ForegroundColor Green

# --- 3. Location + re-import instructions ---
$detected = @()
if ($video)   { $detected += "  - $(& $hidePath $video)   (graphics / video)" }
if ($binds)   { $detected += "  - $(& $hidePath $binds)   (keybinds + input/audio)" }
if ($profileCfg) { $detected += "  - $(& $hidePath $profileCfg)   (gameplay / HUD, cloud-synced)" }

$loc = @"
==============================================
  APEX LEGENDS CONFIG LOCATION & RE-IMPORT
==============================================

ORIGINAL LOCATION:
  $(& $hidePath $apex)

Settings files detected:
$($detected -join [Environment]::NewLine)

----------------------------------------------
WHAT IS IN THERE: local\ VS profile\
----------------------------------------------
Apex splits its config the same way CS2 does, under different names:

  local\    THIS PC only - never uploaded. Holds videoconfig.txt (all your
            graphics settings) and settings.cfg (keybinds + input/audio cvars).
  profile\  Synced to the cloud by your launcher. Holds profile.cfg (gameplay,
            HUD and accessibility settings)$(if ($isSteam) { ", and steam_autocloud.vdf,
            a small marker file carrying your Steam account id" }).

So your GRAPHICS settings and your KEYBINDS do NOT follow you to another PC -
they sit in local\. That is the part this backup really saves for you.

Note: this config folder is the same whatever launcher you use - the launcher
      decides where the GAME is installed, not where it saves your settings.

Not copied on purpose:
  local\psoCache.pso   compiled shader cache, ~230 MB, rebuilt by the game
  assets\              store and promo art, re-downloaded automatically
Copying those back would be pointless and would turn a 12 KB config into a
230 MB folder.

----------------------------------------------
HOW TO RE-IMPORT THIS CONFIG (this PC or another):
----------------------------------------------
  1. Fully close Apex Legends AND $(if ($isSteam) { 'Steam' } else { 'the EA App' }). The launcher flushes pending
     cloud uploads as it exits, so copying while it runs can get your files
     overwritten.

$(if ($isSteam) {
@'
  2. Disable Steam Cloud for Apex before copying:
       Steam > right-click Apex Legends > Properties > General > uncheck
       Steam Cloud
     Without it, Steam re-downloads its own profile\ on the next launch and
     reverts the settings you just restored. Files in local\ (graphics and
     keybinds) are never touched by the Cloud and restore fine either way.
'@
} else {
@'
  2. Disable cloud saves for Apex in the EA App before copying:
       EA App > Settings > Application > turn off "Cloud saves"
     (The EA App moves its settings around between versions - if that path
     does not match, look for "Cloud saves" anywhere in its settings.)
     Without it the EA App re-downloads its own profile\ on the next launch
     and reverts the settings you just restored. Files in local\ (graphics and
     keybinds) are not cloud-synced and restore fine either way.
'@
})

  3. Copy the CONTENTS of "raw_config_for_reimport\" into:
       %USERPROFILE%\Saved Games\Respawn\Apex\
     keeping the local\ and profile\ subfolders as they are.
     (If you moved your "Saved Games" folder, use that location instead.)

  4. Accept overwriting the existing files.

  5. Restart $(if ($isSteam) { 'Steam' } else { 'the EA App' }), then Apex, and check your settings in-game.

  6. Only once Apex has run with the restored config, re-enable cloud saves if
     you want them back. In that order the cloud uploads YOUR files instead of
     overwriting them.

Note: the first launch after restoring rebuilds the shader cache, so expect
      one slower startup and some early stutter. That is normal.
"@

if ($Anonymize) {
    $loc += @"


ANONYMIZED EXPORT: this copy was stripped for public sharing.
  - The player name in settings.cfg was blanked$(if (Test-Path (Join-Path $apex 'profile\steam_autocloud.vdf')) { ", and the Steam account id
    in profile\steam_autocloud.vdf was zeroed" }).
  - The Windows user name was replaced with <USER> in the paths above.
  Your graphics, gameplay settings and keybinds are untouched, so this export
  still restores correctly - only the identifying values are gone.
"@
}

Write-ReportFile (Join-Path $outDir 'location_and_reimport.txt') $loc
Write-Host "  [OK] Instructions: location_and_reimport.txt" -ForegroundColor Green

if ($Anonymize) { Test-ExportForLeaks -BackupRoot $backupR -AccountIds @() }

Write-ExportFooter -BackupRoot $backupR -Anonymized $Anonymize.IsPresent
