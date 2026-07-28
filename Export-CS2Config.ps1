<#
.SYNOPSIS
    Backs up and exports your Counter-Strike 2 (CS2) configuration.

.DESCRIPTION
    This script:
      1. Automatically locates Steam and EVERY account that has a CS2 config.
      2. Copies the raw config files, byte-for-byte, ready to be re-imported.
      3. Generates a human-readable .txt (e.g. Graphics = High, Shadows = Low).
      4. Generates a .txt explaining WHERE the config lives and HOW to re-import it.

    The script is READ-ONLY on your Steam installation: it never changes your settings.

.PARAMETER OutputRoot
    Root folder to write the export to. Default: your Desktop.

.PARAMETER SteamPath
    Optional: force the Steam install path if auto-detection fails.

.PARAMETER Anonymize
    Strips identifying info (Steam name) from the exported copy.
    Use this if you intend to SHARE your config publicly.

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

# ---------------------------------------------------------------------------
#  1. Locate the Steam installation
# ---------------------------------------------------------------------------
function Get-SteamPath {
    try {
        $p = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop).SteamPath
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    } catch {}
    try {
        $p = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -ErrorAction Stop).InstallPath
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    } catch {}
    foreach ($candidate in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam", 'C:\Steam')) {
        if ($candidate -and (Test-Path $candidate)) { return (Resolve-Path $candidate).Path }
    }
    return $null
}

# ---------------------------------------------------------------------------
#  2. Flat "KeyValues" parser: grabs every "key" "value" pair.
#     Works for cs2_video.txt and the .vcfg files (even nested), because block
#     headers ("config", "convars", ...) have no inline value.
# ---------------------------------------------------------------------------
function ConvertFrom-KeyValues {
    param([string]$Content)
    $result = [ordered]@{}
    $regex = [regex]'"([^"]+)"\s+"([^"]*)"'
    foreach ($m in $regex.Matches($Content)) { $result[$m.Groups[1].Value] = $m.Groups[2].Value }
    return $result
}

# ---------------------------------------------------------------------------
#  3. Human-readable translations
# ---------------------------------------------------------------------------
$QualityLevels = @{ '0' = 'Low'; '1' = 'Medium'; '2' = 'High'; '3' = 'Very High' }

function Convert-Quality { param($v) if ($QualityLevels.ContainsKey("$v")) { $QualityLevels["$v"] } else { "$v (raw value)" } }
function Convert-Bool {
    param($v)
    switch ("$v".ToLower()) {
        '1'     { 'Enabled' }  'true'  { 'Enabled' }
        '0'     { 'Disabled' } 'false' { 'Disabled' }
        default { "$v (raw value)" }
    }
}

# Video settings (cs2_video.txt) — Type: quality | bool | enum | raw
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
}

# Useful game convars (cs2_user_convars*.vcfg). Identifying convars (e.g. "name")
# are intentionally NOT listed here so the summary stays anonymous.
$ConvarMap = [ordered]@{
    'sensitivity'                   = 'Mouse sensitivity'
    'zoom_sensitivity_ratio'        = 'Zoom sensitivity ratio'
    'sensitivity_y_scale'           = 'Vertical sensitivity scale'
    'm_yaw'                         = 'Horizontal sensitivity (m_yaw)'
    'm_pitch'                       = 'Vertical sensitivity (m_pitch)'
    'crosshair'                     = 'Crosshair shown'
    'cl_crosshairstyle'             = 'Crosshair - style'
    'cl_crosshairsize'              = 'Crosshair - size'
    'cl_crosshairthickness'         = 'Crosshair - thickness'
    'cl_crosshairgap'               = 'Crosshair - gap'
    'cl_crosshairdot'               = 'Crosshair - center dot'
    'cl_crosshaircolor'             = 'Crosshair - color (index)'
    'cl_crosshairalpha'             = 'Crosshair - opacity'
    'cl_crosshair_drawoutline'      = 'Crosshair - outline'
    'viewmodel_fov'                 = 'Weapon field of view (viewmodel FOV)'
    'viewmodel_offset_x'            = 'Weapon position - X'
    'viewmodel_offset_y'            = 'Weapon position - Y'
    'viewmodel_offset_z'            = 'Weapon position - Z'
    'cl_prefer_lefthanded'          = 'Left-handed weapon'
}

# ---------------------------------------------------------------------------
#  4. Main program
# ---------------------------------------------------------------------------
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

# Find every account with a CS2 folder (userdata\<id>\730) that has at least one
# known config file (video / convars / keys), wherever it lives inside 730.
$accounts = @()
foreach ($dir in Get-ChildItem $userdataRoot -Directory -ErrorAction SilentlyContinue) {
    $g730 = Join-Path $dir.FullName '730'
    if (-not (Test-Path $g730)) { continue }

    $video   = Get-ChildItem $g730 -Recurse -File -Filter 'cs2_video.txt'          -ErrorAction SilentlyContinue | Select-Object -First 1
    $convars = Get-ChildItem $g730 -Recurse -File -Filter 'cs2_user_convars*.vcfg' -ErrorAction SilentlyContinue | Select-Object -First 1
    $keys    = Get-ChildItem $g730 -Recurse -File -Filter 'cs2_user_keys*.vcfg'    -ErrorAction SilentlyContinue | Select-Object -First 1

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

$stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$backupR = Join-Path $OutputRoot "CS2_Backup_$stamp"
$utf8    = New-Object System.Text.UTF8Encoding($false)

foreach ($acc in $accounts) {
    Write-Host ""
    Write-Host ("--- Account $($acc.Id) ---") -ForegroundColor Cyan

    $outDir = Join-Path $backupR $acc.Id
    $rawDir = Join-Path $outDir  'raw_config_for_reimport'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

    # 4a. EXACT copy of the whole 730 folder (full config, for re-import)
    Copy-Item -Path (Join-Path $acc.Base730 '*') -Destination $rawDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Config copied (raw)." -ForegroundColor Green

    # 4a-bis. Optional anonymization of the copy (removes the Steam name)
    if ($Anonymize) {
        $sensitive = @('name', 'password', 'cl_clanid')
        Get-ChildItem $rawDir -Recurse -File -Filter '*.vcfg' -ErrorAction SilentlyContinue | ForEach-Object {
            $txt = [System.IO.File]::ReadAllText($_.FullName, $utf8)
            foreach ($s in $sensitive) {
                $txt = [regex]::Replace($txt, "(`"$s`"\s+`")[^`"]*(`")", '${1}${2}')
            }
            [System.IO.File]::WriteAllText($_.FullName, $txt, $utf8)
        }
        Write-Host "  [OK] Copy anonymized (Steam name removed)." -ForegroundColor Green
    }

    # 4b. HUMAN-READABLE summary
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('==============================================')
    [void]$h.AppendLine('  CS2 CONFIGURATION - READABLE SUMMARY')
    [void]$h.AppendLine("  Exported on: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$h.AppendLine('==============================================')
    [void]$h.AppendLine('')

    # ---- Video / graphics ----
    [void]$h.AppendLine('--- GRAPHICS / VIDEO SETTINGS ---')
    [void]$h.AppendLine('')
    if ($acc.Video) {
        $kv = ConvertFrom-KeyValues (Get-Content $acc.Video -Raw)
        foreach ($key in $VideoMap.Keys) {
            if ($kv.Contains($key)) {
                $def = $VideoMap[$key]; $raw = $kv[$key]
                switch ($def.Type) {
                    'quality' { $disp = Convert-Quality $raw }
                    'bool'    { $disp = Convert-Bool $raw }
                    'enum'    { $disp = if ($def.Map.ContainsKey("$raw")) { $def.Map["$raw"] } else { "$raw (raw value)" } }
                    default   { $disp = $raw }
                }
                [void]$h.AppendLine(("  {0,-38} : {1}" -f $def.Label, $disp))
            }
        }
        $unknown = $kv.Keys | Where-Object { $_ -like 'setting.*' -and -not $VideoMap.Contains($_) }
        if ($unknown) {
            [void]$h.AppendLine('')
            [void]$h.AppendLine('  (Other video settings, raw values)')
            foreach ($k in $unknown) { [void]$h.AppendLine(("  {0,-38} : {1}" -f ($k -replace '^setting\.', ''), $kv[$k])) }
        }
    } else {
        [void]$h.AppendLine('  (cs2_video.txt not found: CS2 only writes the video settings after')
        [void]$h.AppendLine('   you open Settings > Video and click Apply at least once. Do that,')
        [void]$h.AppendLine('   then run this script again.)')
    }
    [void]$h.AppendLine('')

    # ---- Game convars ----
    if ($acc.Convars) {
        $cv = ConvertFrom-KeyValues (Get-Content $acc.Convars -Raw)
        [void]$h.AppendLine('--- GAME SETTINGS (main) ---')
        [void]$h.AppendLine('')
        foreach ($key in $ConvarMap.Keys) {
            if ($cv.Contains($key)) { [void]$h.AppendLine(("  {0,-38} : {1}" -f $ConvarMap[$key], $cv[$key])) }
        }
        [void]$h.AppendLine('')
    }

    # ---- Keybinds ----
    if ($acc.Keys) {
        $kb = ConvertFrom-KeyValues (Get-Content $acc.Keys -Raw)
        $bound = $kb.GetEnumerator() | Where-Object { $_.Value -and $_.Value -ne '<unbound>' }
        if ($bound) {
            [void]$h.AppendLine('--- KEYBINDS ---')
            [void]$h.AppendLine('')
            foreach ($b in $bound) { [void]$h.AppendLine(("  {0,-12} -> {1}" -f $b.Key, $b.Value)) }
            [void]$h.AppendLine('')
        }
    }

    $humanPath = Join-Path $outDir 'readable_settings.txt'
    [System.IO.File]::WriteAllText($humanPath, $h.ToString(), $utf8)
    Write-Host "  [OK] Readable summary: readable_settings.txt" -ForegroundColor Green

    # 4c. LOCATION + re-import instructions
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

    $locPath = Join-Path $outDir 'location_and_reimport.txt'
    [System.IO.File]::WriteAllText($locPath, $l.ToString(), $utf8)
    Write-Host "  [OK] Instructions: location_and_reimport.txt" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! Export available in:" -ForegroundColor Cyan
Write-Host "  $backupR" -ForegroundColor White
Write-Host ""
try { Start-Process explorer.exe $backupR } catch {}
