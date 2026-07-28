<#
.SYNOPSIS
    Backs up and exports your Counter-Strike 2 (CS2) configuration.

.DESCRIPTION
    This script:
      1. Automatically locates Steam and EVERY account that has a CS2 config.
      2. Copies the raw config files, byte-for-byte, ready to be re-imported.
      3. Generates a human-readable .txt listing ALL settings (graphics, game
         convars, keybinds) - friendly labels where known, raw names otherwise.
      4. Generates a .txt explaining WHERE the config lives and HOW to re-import it.

    The script is READ-ONLY on your Steam installation: it never changes your settings.

    Privacy: identifying values (Steam name, passwords) are ALWAYS excluded from the
    readable summary, so it is safe to share. Use -Anonymize to also strip them from
    the raw copy.

.PARAMETER OutputRoot
    Root folder to write the export to. Default: your Desktop.

.PARAMETER SteamPath
    Optional: force the Steam install path if auto-detection fails.

.PARAMETER Anonymize
    Strips identifying info (Steam name, etc.) from the raw exported copy too.
    Use this if you intend to SHARE the raw config publicly.

.EXAMPLE
    .\Export-CS2Config.ps1

.EXAMPLE
    .\Export-CS2Config.ps1 -OutputRoot "D:\Backups" -Anonymize

.NOTES
    License: MIT
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CS2_Config_Export'),
    [string]$SteamPath,
    [switch]$Anonymize
)

$ErrorActionPreference = 'Stop'

# ===========================================================================
#  Data: translations
# ===========================================================================

# Convars/keys whose VALUES identify you. Always hidden from the readable
# summary; stripped from the raw copy when -Anonymize is used.
$SensitiveKeys = @('name', 'password', 'cl_clanid', 'cl_name', 'steamid',
                   'steamidtext', 'last_name', 'player_name')

$QualityLevels = @{ '0' = 'Low'; '1' = 'Medium'; '2' = 'High'; '3' = 'Very High' }

# Video settings (cs2_video.txt) -> friendly label + value type.
# Type: quality | bool | enum | raw
$VideoMap = [ordered]@{
    'setting.defaultres'              = @{ Label = 'Resolution - width';       Type = 'raw' }
    'setting.defaultresheight'        = @{ Label = 'Resolution - height';      Type = 'raw' }
    'setting.refreshrate_numerator'   = @{ Label = 'Refresh rate (num.)';      Type = 'raw' }
    'setting.refreshrate_denominator' = @{ Label = 'Refresh rate (den.)';      Type = 'raw' }
    'setting.fullscreen'              = @{ Label = 'Fullscreen';               Type = 'bool' }
    'setting.nowindowborder'          = @{ Label = 'Borderless window';        Type = 'bool' }
    'setting.coop_fullscreen'         = @{ Label = 'Fullscreen (coop)';        Type = 'bool' }
    'setting.aspectratiomode'         = @{ Label = 'Aspect ratio';             Type = 'enum'
                                           Map   = @{ '0' = 'Normal (4:3)'; '1' = 'Widescreen (16:9)'; '2' = 'Widescreen (16:10)' } }
    'setting.mat_vsync'               = @{ Label = 'Vertical sync (VSync)';    Type = 'bool' }
    'setting.mat_triplebuffered'      = @{ Label = 'Triple buffering';         Type = 'bool' }
    'setting.mat_queue_mode'          = @{ Label = 'Multicore rendering';      Type = 'raw' }
    'setting.motionblur_enabled'      = @{ Label = 'Motion blur';              Type = 'bool' }
    'setting.gpu_level'               = @{ Label = 'Global GPU detail';        Type = 'quality' }
    'setting.cpu_level'               = @{ Label = 'Effect detail (CPU)';      Type = 'quality' }
    'setting.mem_level'               = @{ Label = 'Texture detail';           Type = 'quality' }
    'setting.gpu_mem_level'           = @{ Label = 'Texture detail (GPU mem)'; Type = 'quality' }
    'setting.csm_quality_level'       = @{ Label = 'Shadow quality';           Type = 'quality' }
    'setting.shadowquality'           = @{ Label = 'Shadow rendering';         Type = 'quality' }
    'setting.shaderquality'           = @{ Label = 'Shader detail';            Type = 'quality' }
    'setting.aaquality'               = @{ Label = 'Anti-aliasing (MSAA)';     Type = 'quality' }
    'setting.high_dynamic_range'      = @{ Label = 'HDR';                      Type = 'quality' }
    'setting.aniso'                   = @{ Label = 'Anisotropic filtering';    Type = 'raw' }
    'setting.r_low_latency'           = @{ Label = 'Low latency (NVIDIA Reflex)'; Type = 'raw' }
    'setting.vr_enable_hmd'           = @{ Label = 'VR headset';               Type = 'bool' }
}

# Friendly labels for common game convars (annotation only; ALL convars are
# still listed even if not in this table).
$ConvarLabels = @{
    'sensitivity'              = 'Mouse sensitivity'
    'zoom_sensitivity_ratio'   = 'Zoom sensitivity ratio'
    'sensitivity_y_scale'      = 'Vertical sensitivity scale'
    'm_yaw'                    = 'Horizontal sensitivity'
    'm_pitch'                  = 'Vertical sensitivity'
    'crosshair'                = 'Crosshair shown'
    'cl_crosshairstyle'        = 'Crosshair style'
    'cl_crosshairsize'         = 'Crosshair size'
    'cl_crosshairthickness'    = 'Crosshair thickness'
    'cl_crosshairgap'          = 'Crosshair gap'
    'cl_crosshairdot'          = 'Crosshair center dot'
    'cl_crosshaircolor'        = 'Crosshair color (index)'
    'cl_crosshairalpha'        = 'Crosshair opacity'
    'cl_crosshair_drawoutline' = 'Crosshair outline'
    'viewmodel_fov'            = 'Weapon FOV'
    'viewmodel_offset_x'       = 'Weapon position X'
    'viewmodel_offset_y'       = 'Weapon position Y'
    'viewmodel_offset_z'       = 'Weapon position Z'
    'cl_prefer_lefthanded'     = 'Left-handed weapon'
    'cl_radar_always_centered' = 'Radar always centered'
    'cl_radar_scale'           = 'Radar scale'
    'voice_scale'              = 'Voice chat volume'
    'volume'                   = 'Master volume'
    'fps_max'                  = 'FPS limit'
}

# ===========================================================================
#  Helpers
# ===========================================================================
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

# Flat KeyValues parser: every "key" "value" pair (block headers have no inline value).
function ConvertFrom-KeyValues {
    param([string]$Content)
    $result = [ordered]@{}
    foreach ($m in [regex]::Matches($Content, '"([^"]+)"\s+"([^"]*)"')) {
        $result[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $result
}

function Test-Sensitive {
    param([string]$Key)
    $k = $Key.ToLower()
    return ($SensitiveKeys -contains $k) -or ($k -like '*password*')
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

# ===========================================================================
#  Main
# ===========================================================================
Write-Host ""
Write-Host "=== CS2 configuration export ===" -ForegroundColor Cyan

if ($SteamPath) {
    if (-not (Test-Path $SteamPath)) { Write-Host "[ERROR] -SteamPath not found: $SteamPath" -ForegroundColor Red; exit 1 }
    $steam = (Resolve-Path $SteamPath).Path
} else {
    $steam = Get-SteamPath
}
if (-not $steam) { Write-Host "[ERROR] Steam not found. Is Steam installed?" -ForegroundColor Red; exit 1 }
Write-Host "Steam found: $steam" -ForegroundColor Green

$userdataRoot = Join-Path $steam 'userdata'
if (-not (Test-Path $userdataRoot)) { Write-Host "[ERROR] 'userdata' folder not found." -ForegroundColor Red; exit 1 }

# Find every account with a CS2 folder (userdata\<id>\730) holding a known
# config file. One recursive scan per account (video / convars / keys).
$accounts = @()
foreach ($dir in Get-ChildItem $userdataRoot -Directory -ErrorAction SilentlyContinue) {
    $g730 = Join-Path $dir.FullName '730'
    if (-not (Test-Path $g730)) { continue }

    $files   = Get-ChildItem $g730 -Recurse -File -ErrorAction SilentlyContinue
    $video   = $files | Where-Object { $_.Name -eq 'cs2_video.txt' }          | Select-Object -First 1
    $convars = $files | Where-Object { $_.Name -like 'cs2_user_convars*.vcfg' } | Select-Object -First 1
    $keys    = $files | Where-Object { $_.Name -like 'cs2_user_keys*.vcfg' }    | Select-Object -First 1

    if ($video -or $convars -or $keys) {
        $accounts += [pscustomobject]@{
            Id      = $dir.Name
            Base730 = (Resolve-Path $g730).Path
            Video   = if ($video)   { $video.FullName }   else { $null }
            Convars = if ($convars) { $convars.FullName } else { $null }
            Keys    = if ($keys)    { $keys.FullName }    else { $null }
        }
    }
}

if ($accounts.Count -eq 0) {
    Write-Host "[ERROR] No CS2 configuration found." -ForegroundColor Red
    Write-Host "        Launch CS2 at least once to generate the files." -ForegroundColor Yellow
    exit 1
}
Write-Host ("CS2 account(s) found: {0}" -f $accounts.Count) -ForegroundColor Green

$backupR = Join-Path $OutputRoot ("CS2_Backup_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
$utf8    = New-Object System.Text.UTF8Encoding($false)

foreach ($acc in $accounts) {
    Write-Host ""
    Write-Host ("--- Account $($acc.Id) ---") -ForegroundColor Cyan

    $outDir = Join-Path $backupR $acc.Id
    $rawDir = Join-Path $outDir  'raw_config_for_reimport'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

    # --- 1. Exact raw copy of the whole 730 folder (for re-import) ---
    Copy-Item -Path (Join-Path $acc.Base730 '*') -Destination $rawDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Config copied (raw)." -ForegroundColor Green

    if ($Anonymize) {
        Get-ChildItem $rawDir -Recurse -File -Filter '*.vcfg' -ErrorAction SilentlyContinue | ForEach-Object {
            $txt = [System.IO.File]::ReadAllText($_.FullName, $utf8)
            foreach ($s in $SensitiveKeys) {
                $txt = [regex]::Replace($txt, "(`"$s`"\s+`")[^`"]*(`")", '${1}${2}')
            }
            [System.IO.File]::WriteAllText($_.FullName, $txt, $utf8)
        }
        Write-Host "  [OK] Raw copy anonymized." -ForegroundColor Green
    }

    # --- 2. Human-readable summary (ALL settings) ---
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('==============================================')
    [void]$h.AppendLine('  CS2 CONFIGURATION - READABLE SUMMARY')
    [void]$h.AppendLine("  Exported on: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$h.AppendLine('  (Identifying values are omitted - safe to share.)')
    [void]$h.AppendLine('==============================================')
    [void]$h.AppendLine('')

    # Graphics / video
    [void]$h.AppendLine('--- GRAPHICS / VIDEO SETTINGS ---')
    [void]$h.AppendLine('')
    if ($acc.Video) {
        $kv = ConvertFrom-KeyValues (Get-Content $acc.Video -Raw)
        foreach ($k in $kv.Keys) {
            if ($VideoMap.Contains($k)) {
                $def = $VideoMap[$k]
                [void]$h.AppendLine(("  {0,-36} : {1}" -f $def.Label, (Format-VideoValue $def $kv[$k])))
            } else {
                [void]$h.AppendLine(("  {0,-36} : {1}" -f ($k -replace '^setting\.', ''), $kv[$k]))
            }
        }
    } else {
        [void]$h.AppendLine('  (cs2_video.txt not found: CS2 only writes video settings after you')
        [void]$h.AppendLine('   open Settings > Video and click Apply at least once. Do that, then')
        [void]$h.AppendLine('   run this script again.)')
    }
    [void]$h.AppendLine('')

    # Game convars (ALL, minus identifying ones)
    if ($acc.Convars) {
        $cv = ConvertFrom-KeyValues (Get-Content $acc.Convars -Raw)
        [void]$h.AppendLine("--- GAME SETTINGS ($($cv.Count) convars) ---")
        [void]$h.AppendLine('')
        foreach ($k in $cv.Keys) {
            if (Test-Sensitive $k) { continue }
            $line = "  {0,-40} : {1}" -f $k, $cv[$k]
            if ($ConvarLabels.ContainsKey($k)) { $line += ("   # {0}" -f $ConvarLabels[$k]) }
            [void]$h.AppendLine($line)
        }
        [void]$h.AppendLine('')
    }

    # Keybinds (ALL present in the file)
    if ($acc.Keys) {
        $kb = ConvertFrom-KeyValues (Get-Content $acc.Keys -Raw)
        [void]$h.AppendLine("--- KEYBINDS ($($kb.Count) keys) ---")
        [void]$h.AppendLine('  (CS2 only stores custom/changed bindings here; defaults are not listed.)')
        [void]$h.AppendLine('')
        foreach ($b in $kb.GetEnumerator()) {
            $action = if (-not $b.Value -or $b.Value -eq '<unbound>') { '(unbound)' } else { $b.Value }
            [void]$h.AppendLine(("  {0,-12} -> {1}" -f $b.Key, $action))
        }
        [void]$h.AppendLine('')
    }

    [System.IO.File]::WriteAllText((Join-Path $outDir 'readable_settings.txt'), $h.ToString(), $utf8)
    Write-Host "  [OK] Readable summary: readable_settings.txt" -ForegroundColor Green

    # --- 3. Location + re-import instructions ---
    $l = New-Object System.Text.StringBuilder
    [void]$l.AppendLine('==============================================')
    [void]$l.AppendLine('  CS2 CONFIG LOCATION & RE-IMPORT')
    [void]$l.AppendLine('==============================================')
    [void]$l.AppendLine('')
    [void]$l.AppendLine('ORIGINAL LOCATION (this account''s CS2 folder):')
    [void]$l.AppendLine("  $($acc.Base730)")
    [void]$l.AppendLine('')
    [void]$l.AppendLine('Settings files detected:')
    if ($acc.Video)   { [void]$l.AppendLine("  - $($acc.Video)   (graphics / video)") }
    if ($acc.Convars) { [void]$l.AppendLine("  - $($acc.Convars)   (game settings)") }
    if ($acc.Keys)    { [void]$l.AppendLine("  - $($acc.Keys)   (keybinds)") }
    [void]$l.AppendLine('')
    [void]$l.AppendLine('----------------------------------------------')
    [void]$l.AppendLine('HOW TO RE-IMPORT THIS CONFIG (this PC or another):')
    [void]$l.AppendLine('----------------------------------------------')
    [void]$l.AppendLine('  1. Fully close CS2 AND Steam.')
    [void]$l.AppendLine('  2. (Recommended) Disable Steam Cloud for CS2 before copying,')
    [void]$l.AppendLine('     otherwise the Cloud may overwrite your restored files:')
    [void]$l.AppendLine('     Steam > right-click CS2 > Properties > General > uncheck Steam Cloud.')
    [void]$l.AppendLine('  3. Copy the CONTENTS of "raw_config_for_reimport\" into the target')
    [void]$l.AppendLine('     account''s 730 folder:')
    [void]$l.AppendLine('       ...\Steam\userdata\<YOUR_ID>\730\')
    [void]$l.AppendLine('     (<YOUR_ID> = the folder present in ...\Steam\userdata\)')
    [void]$l.AppendLine('  4. Accept overwriting the existing files.')
    [void]$l.AppendLine('  5. Restart Steam then CS2. Verify the settings in-game.')
    [void]$l.AppendLine('')
    [void]$l.AppendLine('Note: some files (.dt, remotecache.vdf) are caches; copying them back')
    [void]$l.AppendLine('      is harmless, Steam regenerates them if needed.')

    [System.IO.File]::WriteAllText((Join-Path $outDir 'location_and_reimport.txt'), $l.ToString(), $utf8)
    Write-Host "  [OK] Instructions: location_and_reimport.txt" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! Export available in:" -ForegroundColor Cyan
Write-Host "  $backupR" -ForegroundColor White
Write-Host ""
try { Start-Process explorer.exe $backupR } catch {}
