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
    the raw copy, then check the verification result before publishing.

    Needs lib\Common.ps1 from the same repository - clone or download the whole
    repo rather than this single file.

.PARAMETER OutputRoot
    Root folder to write the export to. Default: your Desktop.

.PARAMETER SteamPath
    Optional: force the Steam install path if auto-detection fails.

.PARAMETER Anonymize
    Strips identifying info (Steam name, account ids) from the raw exported copy
    too. Use this if you intend to SHARE the raw config publicly.

.EXAMPLE
    .\Export-CS2Config.ps1

.EXAMPLE
    .\Export-CS2Config.ps1 -OutputRoot "D:\Backups" -Anonymize

.NOTES
    License: MIT
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CS2_Config_Export'),
    [string]$SteamPath,
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
#  CS2 data: translations
# ===========================================================================

# Video settings (cs2_video.txt) -> friendly label + value type.
# Type: quality | bool | enum | raw
# NOTE: CS2 renamed most of the CSGO-era video keys. The 'videocfg_*' detail
# levels are deliberately shown as raw numbers: their scale differs per setting
# and guessing labels would misreport your config. Higher = better, -1 = unset.
$VideoMap = [ordered]@{
    'setting.defaultres'              = @{ Label = 'Resolution - width';       Type = 'raw' }
    'setting.defaultresheight'        = @{ Label = 'Resolution - height';      Type = 'raw' }
    'setting.refreshrate_numerator'   = @{ Label = 'Refresh rate (num.)';      Type = 'raw' }
    'setting.refreshrate_denominator' = @{ Label = 'Refresh rate (den.)';      Type = 'raw' }
    'setting.fullscreen'              = @{ Label = 'Fullscreen';               Type = 'bool' }
    'setting.nowindowborder'          = @{ Label = 'Borderless window';        Type = 'bool' }
    'setting.coop_fullscreen'         = @{ Label = 'Fullscreen (coop)';        Type = 'bool' }
    'setting.fullscreen_min_on_focus_loss' = @{ Label = 'Minimize on focus loss'; Type = 'bool' }
    'setting.high_dpi'                = @{ Label = 'High-DPI scaling';         Type = 'bool' }
    'setting.monitor_index'           = @{ Label = 'Monitor index';            Type = 'raw' }
    'setting.aspectratiomode'         = @{ Label = 'Aspect ratio';             Type = 'enum'
                                           Map   = @{ '0' = 'Normal (4:3)'; '1' = 'Widescreen (16:9)'; '2' = 'Widescreen (16:10)' } }
    'setting.mat_vsync'               = @{ Label = 'Vertical sync (VSync)';    Type = 'bool' }
    'setting.gpu_level'               = @{ Label = 'Global GPU detail';        Type = 'quality' }
    'setting.cpu_level'               = @{ Label = 'Effect detail (CPU)';      Type = 'quality' }
    'setting.gpu_mem_level'           = @{ Label = 'Texture detail (GPU mem)'; Type = 'quality' }
    'setting.shaderquality'           = @{ Label = 'Shader detail';            Type = 'quality' }
    'setting.msaa_samples'            = @{ Label = 'Anti-aliasing (MSAA)';     Type = 'enum'
                                           Map   = @{ '0' = 'None'; '2' = '2x MSAA'; '4' = '4x MSAA'; '8' = '8x MSAA' } }
    'setting.r_csgo_cmaa_enable'      = @{ Label = 'Anti-aliasing (CMAA2)';    Type = 'bool' }
    'setting.r_texturefilteringquality' = @{ Label = 'Texture filtering';      Type = 'enum'
                                           Map   = @{ '0' = 'Bilinear'; '1' = 'Trilinear'; '2' = 'Anisotropic 2x'
                                                      '3' = 'Anisotropic 4x'; '4' = 'Anisotropic 8x'; '5' = 'Anisotropic 16x' } }
    'setting.r_low_latency'           = @{ Label = 'NVIDIA Reflex low latency'; Type = 'enum'
                                           Map   = @{ '0' = 'Disabled'; '1' = 'Enabled'; '2' = 'Enabled + Boost' } }
    'setting.videocfg_shadow_quality'  = @{ Label = 'Shadow quality (raw)';     Type = 'raw' }
    'setting.videocfg_dynamic_shadows' = @{ Label = 'Dynamic shadows (raw)';    Type = 'raw' }
    'setting.videocfg_texture_detail'  = @{ Label = 'Model/texture detail (raw)'; Type = 'raw' }
    'setting.videocfg_particle_detail' = @{ Label = 'Particle detail (raw)';    Type = 'raw' }
    'setting.videocfg_ao_detail'       = @{ Label = 'Ambient occlusion (raw)';  Type = 'raw' }
    'setting.videocfg_hdr_detail'      = @{ Label = 'High dynamic range (raw)'; Type = 'raw' }
    'setting.videocfg_fsr_detail'      = @{ Label = 'FidelityFX super res (raw)'; Type = 'raw' }
    'setting.knowndevice'             = @{ Label = 'GPU recognised by CS2';    Type = 'bool' }
    'VendorID'                        = @{ Label = 'GPU vendor ID';            Type = 'raw' }
    'DeviceID'                        = @{ Label = 'GPU device ID';            Type = 'raw' }
    'Version'                         = @{ Label = 'Video config version';     Type = 'raw' }
    'Autoconfig'                      = @{ Label = 'Auto-configured';          Type = 'raw' }
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

# Category rules for grouping game convars in the readable summary.
# Evaluated top-to-bottom; first regex match wins. Anything unmatched -> "Other".
$ConvarCategories = @(
    @{ Name = 'Aim / Mouse';           Pattern = '^(sensitivity|zoom_sensitivity_ratio|sensitivity_y_scale|m_yaw|m_pitch|m_raw|m_customaccel|m_mouse)' }
    @{ Name = 'Crosshair';             Pattern = '^(crosshair$|cl_crosshair|cl_fixedcrosshairgap)' }
    @{ Name = 'Grenade crosshair';     Pattern = '^cl_grenade' }
    @{ Name = 'Viewmodel / Weapon';    Pattern = '^(viewmodel_|cl_prefer_lefthanded|cl_righthand|cl_silencer_mode|cl_sniper_auto_rezoom|cl_debounce_zoom|cl_ironsight|cl_showloadout)' }
    @{ Name = 'HUD / Radar';           Pattern = '^(hud_|cl_hud|cl_radar|cl_show|safezone|cl_teamid)' }
    @{ Name = 'Buy menu';              Pattern = '^(cl_buymenu|cl_buywheel|cl_use_opens_buy_menu|cl_inventory)' }
    @{ Name = 'Audio';                 Pattern = '^(volume|voice_|snd_)' }
    @{ Name = 'Movement';              Pattern = '^option_' }
    @{ Name = 'Controller / Joystick'; Pattern = '^joy_' }
)

# ===========================================================================
#  Main
# ===========================================================================
Write-Host ""
Write-Host "=== CS2 configuration export ===" -ForegroundColor Cyan

if ($SteamPath) {
    if (-not (Test-Path $SteamPath)) { Stop-WithError "-SteamPath not found: $SteamPath" }
    $steam = (Resolve-Path $SteamPath).Path
} else {
    $steam = Get-SteamPath
}
if (-not $steam) {
    Stop-WithError 'Steam not found. Is Steam installed?' `
                   'Pass the path explicitly: .\Export-CS2Config.ps1 -SteamPath "D:\Games\Steam"'
}
Write-Host "Steam found: $steam" -ForegroundColor Green

$userdataRoot = Join-Path $steam 'userdata'
if (-not (Test-Path $userdataRoot)) {
    Stop-WithError "'userdata' folder not found under $steam" 'Log into Steam at least once.'
}

# Find every account with a CS2 folder (userdata\<id>\730) holding a known
# config file. One recursive scan per account, then an explicit pick per kind.
$accounts = [System.Collections.Generic.List[object]]::new()
foreach ($dir in Get-ChildItem $userdataRoot -Directory -ErrorAction SilentlyContinue) {
    $g730 = Join-Path $dir.FullName '730'
    if (-not (Test-Path $g730)) { continue }

    $files   = @(Get-ChildItem $g730 -Recurse -File -ErrorAction SilentlyContinue)
    $video   = Select-ConfigFile -Files $files -Base $g730 -NamePattern 'cs2_video.txt'
    $convars = Select-ConfigFile -Files $files -Base $g730 -NamePattern 'cs2_user_convars*.vcfg'
    $keys    = Select-ConfigFile -Files $files -Base $g730 -NamePattern 'cs2_user_keys*.vcfg'
    if (-not ($video -or $convars -or $keys)) { continue }

    $accounts.Add([pscustomobject]@{
        Id      = $dir.Name
        Base730 = (Resolve-Path $g730).Path
        Video   = $video
        Convars = $convars
        Keys    = $keys
    })
}

if ($accounts.Count -eq 0) {
    Stop-WithError 'No CS2 configuration found.' 'Launch CS2 at least once to generate the files.'
}
Write-Host ("CS2 account(s) found: {0}" -f $accounts.Count) -ForegroundColor Green

$backupR = Join-Path $OutputRoot ("CS2_Backup_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))

$accIndex = 0
foreach ($acc in $accounts) {
    $accIndex++
    Write-Host ""
    Write-Host ("--- Account $($acc.Id) ---") -ForegroundColor Cyan

    # The userdata folder name IS your Steam account ID (ID3): it converts
    # straight to a SteamID64 and identifies you. Under -Anonymize the export
    # folder and every printed path use a neutral label instead.
    $accLabel = if ($Anonymize) { "account_$accIndex" } else { $acc.Id }
    $hidePath = {
        param([string]$P)
        if (-not $Anonymize) { return $P }
        $P = $P -replace [regex]::Escape($acc.Id), '<ACCOUNT_ID>'
        foreach ($rx in $UserRx) { $P = $rx.Replace($P, '<USER>') }
        return $P
    }

    $outDir = Join-Path $backupR $accLabel
    $rawDir = Join-Path $outDir  'raw_config_for_reimport'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

    # --- 1. Exact raw copy of the whole 730 folder (for re-import) ---
    Copy-GameConfig -Root $acc.Base730 -Destination $rawDir -CopyMode 'Tree'
    Write-Host "  [OK] Config copied (raw)." -ForegroundColor Green

    if ($Anonymize) {
        $dropped = Invoke-ConfigAnonymize -RawDir $rawDir -AccountId $acc.Id
        Write-Host "  [OK] Raw copy anonymized ($dropped identifying file(s) removed)." -ForegroundColor Green
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
    [void]$h.AppendLine('  (Stored in local\ and NOT synced by the Steam Cloud: unlike your')
    [void]$h.AppendLine('   crosshair and keybinds, these do not follow you to another PC.)')
    [void]$h.AppendLine('')
    if ($acc.Video) {
        $kv = ConvertFrom-KeyValues (Read-TextFile $acc.Video)
        foreach ($k in $kv.Keys) {
            # Same filter as the convars below: this file is not supposed to hold
            # a nickname, but the summary is advertised as safe to share, so an
            # unmapped key never gets printed unchecked.
            if (Test-Sensitive $k) { continue }
            if ($VideoMap.Contains($k)) {
                $def = $VideoMap[$k]
                [void]$h.AppendLine(("  {0,-36} : {1}" -f $def.Label, (Format-VideoValue $def $kv[$k])))
            } else {
                [void]$h.AppendLine(("  {0,-36} : {1}" -f ($k -replace '^setting\.', ''), $kv[$k]))
            }
        }
        # CS2 stores the refresh rate as a fraction; show the actual Hz too.
        $num = $kv['setting.refreshrate_numerator']; $den = $kv['setting.refreshrate_denominator']
        if ($num -and $den -and [double]$den -ne 0) {
            # Invariant culture: the summary is meant to be shared, a locale-
            # dependent decimal comma would read as a typo.
            $hz = [string]::Format([cultureinfo]::InvariantCulture, '{0:N2}',
                                   ([double]$num / [double]$den))
            [void]$h.AppendLine(("  {0,-36} : {1} Hz" -f '>> Refresh rate (computed)', $hz))
        }
        [void]$h.AppendLine('')
        [void]$h.AppendLine('  Note: "(raw)" values are CS2 internal detail levels (higher = better,')
        [void]$h.AppendLine('        -1 = not set). They are shown unlabelled on purpose.')
    } else {
        [void]$h.AppendLine('  (cs2_video.txt not found: CS2 only writes video settings after you')
        [void]$h.AppendLine('   open Settings > Video and click Apply at least once. Do that, then')
        [void]$h.AppendLine('   run this script again.)')
    }
    [void]$h.AppendLine('')

    # Game convars (ALL, minus identifying ones), grouped by category
    if ($acc.Convars) {
        $cv = ConvertFrom-KeyValues (Read-TextFile $acc.Convars)
        Register-PlayerName $cv

        # Bucket every convar into its category (first matching rule wins).
        # Lists, not arrays: "$array += $x" reallocates the whole array on
        # every convar.
        $buckets = [ordered]@{}
        foreach ($c in $ConvarCategories) { $buckets[$c.Name] = [System.Collections.Generic.List[string]]::new() }
        $buckets['Other'] = [System.Collections.Generic.List[string]]::new()
        $shown = 0
        foreach ($k in $cv.Keys) {
            if (Test-Sensitive $k) { continue }
            $cat = 'Other'
            foreach ($c in $ConvarCategories) { if ($k -match $c.Pattern) { $cat = $c.Name; break } }
            $buckets[$cat].Add($k)
            $shown++
        }

        [void]$h.AppendLine("--- GAME SETTINGS ($shown convars) ---")
        [void]$h.AppendLine('  (Synced by the Steam Cloud: these come back on their own when you')
        [void]$h.AppendLine('   log into another PC.)')
        [void]$h.AppendLine('')
        foreach ($catName in $buckets.Keys) {
            $keys = $buckets[$catName]
            if (-not $keys) { continue }
            [void]$h.AppendLine("  [ $catName ]")
            foreach ($k in $keys) {
                $line = "  {0,-40} : {1}" -f $k, $cv[$k]
                if ($ConvarLabels.ContainsKey($k)) { $line += ("   # {0}" -f $ConvarLabels[$k]) }
                [void]$h.AppendLine($line)
            }
            [void]$h.AppendLine('')
        }
    }

    # Keybinds (ALL present in the file)
    if ($acc.Keys) {
        $kb = ConvertFrom-KeyValues (Read-TextFile $acc.Keys)
        [void]$h.AppendLine("--- KEYBINDS ($($kb.Count) keys) ---")
        [void]$h.AppendLine('  (CS2 only stores custom/changed bindings here; defaults are not listed.)')
        [void]$h.AppendLine('  (Synced by the Steam Cloud, like the game settings above.)')
        [void]$h.AppendLine('')
        foreach ($b in $kb.GetEnumerator()) {
            $action = if (-not $b.Value -or $b.Value -eq '<unbound>') { '(unbound)' } else { $b.Value }
            [void]$h.AppendLine(("  {0,-12} -> {1}" -f $b.Key, $action))
        }
        [void]$h.AppendLine('')
    }

    Write-ReportFile (Join-Path $outDir 'readable_settings.txt') $h.ToString()
    Write-Host "  [OK] Readable summary: readable_settings.txt" -ForegroundColor Green

    # --- 3. Location + re-import instructions ---
    # A here-string rather than 40 AppendLine calls: the text is laid out here
    # exactly as the user will read it in the file.
    $detected = @()
    if ($acc.Video)   { $detected += "  - $(& $hidePath $acc.Video)   (graphics / video)" }
    if ($acc.Convars) { $detected += "  - $(& $hidePath $acc.Convars)   (game settings)" }
    if ($acc.Keys)    { $detected += "  - $(& $hidePath $acc.Keys)   (keybinds)" }

    $loc = @"
==============================================
  CS2 CONFIG LOCATION & RE-IMPORT
==============================================

ORIGINAL LOCATION (this account's CS2 folder):
  $(& $hidePath $acc.Base730)

Settings files detected:
$($detected -join [Environment]::NewLine)

----------------------------------------------
WHAT IS IN THERE: local\ VS remote\
----------------------------------------------
CS2 splits your config in two, and the halves do NOT hold the same things:

  local\    THIS PC only - never uploaded to the Steam Cloud. Holds your
            VIDEO settings (cs2_video.txt), the machine convars and
            trustedlaunch.cfg.
  remote\   Synced by the Steam Cloud to every PC you log into. Holds the
            game settings and keybinds, your mute list (voice_ban.dt) and
            the inventory files.

The game settings and keybinds exist on BOTH sides:
    local\cfg\cs2_user_convars_0_slot0.vcfg   and   remote\cs2_user_convars.vcfg
Those two hold exactly the same settings - only the line endings differ (local
uses Windows CRLF, remote uses LF so the Cloud can sync to Linux and macOS).
remotecache.vdf is the Cloud's index of remote\, and the *_lastclouded files
are snapshots of the last upload, which Steam compares against to spot changes.

What this means in practice:
  - On a new PC your crosshair, sensitivity and keybinds come back BY
    THEMSELVES through the Steam Cloud.
  - Your GRAPHICS settings do NOT: they sit in local\ and are never synced.
    That is the part this backup really saves for you.

----------------------------------------------
HOW TO RE-IMPORT THIS CONFIG (this PC or another):
----------------------------------------------
  1. Fully close CS2 AND Steam. Steam flushes pending Cloud uploads as it
     exits, so copying while it is running can get your files overwritten.

  2. Disable Steam Cloud for CS2 - this is the step that makes the rest stick:
       Steam > right-click CS2 > Properties > General > uncheck Steam Cloud
     Without it Steam re-downloads its own copy of remote\ on the next launch
     and your restored game settings and keybinds are silently reverted.
     (Files in local\, video settings included, are never touched by the
     Cloud - they restore fine either way.)

  3. Copy the CONTENTS of "raw_config_for_reimport\" into the target account's
     730 folder, keeping the local\ and remote\ subfolders as they are:
       ...\Steam\userdata\<YOUR_ID>\730\
     <YOUR_ID> is the folder found in ...\Steam\userdata\ on the TARGET PC.
     It differs for every account - do not reuse the one from this export.

  4. Accept overwriting the existing files.

  5. Restart Steam, then CS2, and check your settings in-game.

  6. Only once CS2 has run with the restored config, re-enable Steam Cloud if
     you want it back. In that order the Cloud uploads YOUR files instead of
     overwriting them.

Note: the .dt files and remotecache.vdf are caches. Copying them back is
      harmless (Steam regenerates them), and leaving them out is harmless too.
"@

    if ($Anonymize) {
        $loc += @"


ANONYMIZED EXPORT: this copy was stripped for public sharing.
  - Steam account ID replaced with <ACCOUNT_ID>, in the paths above and
    inside the exported files.
  - Removed: voice_ban.dt (SteamIDs of players you muted), the inventory
    files (unique item IDs), trustedlaunch.cfg (this machine's hardware
    fingerprint) and the Steam sync caches.
  Your graphics, game settings and keybinds are untouched, so this export
  still restores correctly - only the identifying extras are gone.
"@
    }

    Write-ReportFile (Join-Path $outDir 'location_and_reimport.txt') $loc
    Write-Host "  [OK] Instructions: location_and_reimport.txt" -ForegroundColor Green
}

if ($Anonymize) { Test-ExportForLeaks -BackupRoot $backupR -AccountIds @($accounts.Id) }

Write-ExportFooter -BackupRoot $backupR -Anonymized $Anonymize.IsPresent
