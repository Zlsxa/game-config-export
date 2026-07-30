<#
.SYNOPSIS
    Backs up and exports your game configuration (Counter-Strike 2, Apex Legends).

.DESCRIPTION
    This script:
      1. Locates each supported game's config, and EVERY account for games that
         keep one config per Steam account.
      2. Copies the raw config files, byte-for-byte, ready to be re-imported.
      3. Generates a human-readable .txt listing ALL settings (graphics, game
         settings, keybinds) - friendly labels where known, raw names otherwise.
      4. Generates a .txt explaining WHERE the config lives and HOW to re-import it.

    The script is READ-ONLY on your games: it never changes your settings.

    Privacy: identifying values (player name, passwords) are ALWAYS excluded from
    the readable summary, so it is safe to share. Use -Anonymize to also strip them
    from the raw copy, then verify the result before publishing it.

.PARAMETER Game
    Which game to export: cs2, apex, or all (default).

.PARAMETER OutputRoot
    Root folder to write the export to. Default: your Desktop.

.PARAMETER SteamPath
    Optional: force the Steam install path if auto-detection fails (CS2).

.PARAMETER ApexPath
    Optional: force the Apex "Saved Games\Respawn\Apex" folder.

.PARAMETER Anonymize
    Strips identifying info (player name, account ids, etc.) from the raw exported
    copy too. Use this if you intend to SHARE the raw config publicly.

.EXAMPLE
    .\Export-GameConfig.ps1

.EXAMPLE
    .\Export-GameConfig.ps1 -Game apex -OutputRoot "D:\Backups" -Anonymize

.NOTES
    License: MIT
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('cs2', 'apex', 'all')]
    [string]$Game = 'all',
    [string]$OutputRoot = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Game_Config_Export'),
    [string]$SteamPath,
    [string]$ApexPath,
    [switch]$Anonymize
)

$ErrorActionPreference = 'Stop'

# UTF-8 without BOM: what CS2 writes, and what we write back.
$utf8 = New-Object System.Text.UTF8Encoding($false)

# ===========================================================================
#  Data: translations
# ===========================================================================

# Convars/keys whose VALUES identify you. Always hidden from the readable
# summary; stripped from the raw copy when -Anonymize is used.
$SensitiveKeys = @('name', 'password', 'cl_clanid', 'cl_name', 'steamid',
                   'steamidtext', 'last_name', 'player_name')

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

# ---------------------------------------------------------------------------
#  Apex Legends
# ---------------------------------------------------------------------------
# Apex writes cvars as `key "value"` with an UNQUOTED key, unlike CS2's
# KeyValues `"key" "value"`. The CS2 scrubber anchors on the opening quote and
# therefore misses `name "SomePlayer"` entirely - hence a second pattern below.
$ApexSensitiveKeys = @('name', 'password', 'hdr_screenshot_directory',
                       'voice_input_device', 'miles_output_device')

# Files under Saved Games\Respawn\Apex worth exporting. Everything else there is
# bulk: psoCache.pso alone is ~230 MB of compiled shaders, and assets\ holds
# re-downloadable store/promo art. Copying the folder wholesale like CS2's 730
# would turn a 12 KB config into a 230 MB "backup".
$ApexConfigFiles = @('local\videoconfig.txt', 'local\settings.cfg',
                     'profile\profile.cfg', 'profile\steam_autocloud.vdf')

# Apex video settings (videoconfig.txt). Same KeyValues format as CS2, so the
# same parser reads it. Only settings whose scale is documented get a mapped
# label; the rest print raw, on purpose - see the CS2 note above.
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

# Friendly labels for the Apex cvars people actually tune. Everything present is
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

# Category rules for grouping Apex cvars. Same first-match-wins rule as CS2.
$ApexCvarCategories = @(
    @{ Name = 'Aim / Mouse'; Pattern = '^(mouse_|m_|sensitivity)' }
    @{ Name = 'Video / HUD'; Pattern = '^(cl_fov|cl_safearea|hud_|damage_indicator|colorblind|cc_|closecaption|chroma_|gfx_)' }
    @{ Name = 'Audio';       Pattern = '^(sound_|voice_|Voice|miles_)' }
    @{ Name = 'Gameplay';    Pattern = '^(cl_|CrossPlay|communication|dialogue_|first_time|menu_|mp_|ui_)' }
    @{ Name = 'Spectator';   Pattern = '^sv_spec' }
)

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

# CS2 writes UTF-8 without a BOM. Get-Content -Raw would decode it with the
# console codepage and mangle any non-ASCII convar/keybind value.
function Read-TextFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $utf8)
}

# Write a report as UTF-8 without BOM and with Windows line endings, whatever
# the source string carries: a here-string inherits the line endings of this
# .ps1, which depend on how git checked the script out. Normalizing here keeps
# the generated .txt identical on every machine, and readable in Notepad.
function Write-ReportFile {
    param([string]$Path, [string]$Text)
    # Also settle on exactly one trailing newline: a here-string ends without
    # one, StringBuilder.AppendLine leaves several.
    $body = ($Text -replace "`r?`n", "`r`n").TrimEnd("`r", "`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $body, $utf8)
}

# CS2 keeps the game settings and keybinds TWICE, and the two copies are not
# interchangeable in principle even though they match in practice:
#   local\cfg\  this PC only, Windows line endings (CRLF)
#   remote\     the Steam Cloud copy, LF endings so it can sync to Linux/macOS
# Same settings on both sides, so prefer local\ (what the game reads here) and
# fall back to the Cloud copy. cs2_video.txt only ever exists under local\.
# Picking explicitly instead of trusting Get-ChildItem's enumeration order,
# which happened to yield local\ first but is not a documented guarantee.
function Select-ConfigFile {
    param([System.IO.FileInfo[]]$Files, [string]$NamePattern, [string]$Base)
    $candidates = @($Files | Where-Object { $_.Name -like $NamePattern })
    if ($candidates.Count -eq 0) { return $null }
    # Rank on the path RELATIVE to the 730 folder, anchored at its start. Testing
    # the absolute path would misfire whenever the Steam install itself sits under
    # a folder named "local" - C:\Users\X\AppData\Local\Steam\... makes every
    # candidate look local (-notmatch is case-insensitive), and the tiebreak then
    # silently picks the Cloud copy instead.
    # local\ first, then the shortest name so slot0 wins over slot10.
    return ($candidates | Sort-Object @{ Expression = { $_.FullName.Substring($Base.Length) -notmatch '^\\local\\' } },
                                      @{ Expression = { $_.Name.Length } },
                                      Name)[0].FullName
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
    return ($SensitiveKeys -contains $k) -or ($ApexSensitiveKeys -contains $k) -or
           ($k -like '*password*') -or ($k -like '*_directory')
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
Write-Host "=== Game configuration export ===" -ForegroundColor Cyan

# A "target" is one exportable config unit: a CS2 Steam account, or the single
# Apex profile. CopyMode says how to take the raw copy - CS2 keeps everything in
# one 730 folder worth copying wholesale, Apex hides 12 KB of config inside
# 230 MB of shader cache and needs an explicit file list.
# ScrubId marks whether Id is itself an identifier: CS2's is the Steam account
# ID (ID3), Apex's is the literal folder name "profile", and blindly replacing
# that in paths would mangle ...\Apex\profile\profile.cfg.
$targets = [System.Collections.Generic.List[object]]::new()

if ($Game -in 'cs2', 'all') {
    if ($SteamPath) {
        if (-not (Test-Path $SteamPath)) { Stop-WithError "-SteamPath not found: $SteamPath" }
        $steam = (Resolve-Path $SteamPath).Path
    } else {
        $steam = Get-SteamPath
    }

    $userdataRoot = if ($steam) { Join-Path $steam 'userdata' } else { $null }
    if ($userdataRoot -and (Test-Path $userdataRoot)) {
        Write-Host "Steam found: $steam" -ForegroundColor Green
        $n = 0
        foreach ($dir in Get-ChildItem $userdataRoot -Directory -ErrorAction SilentlyContinue) {
            $g730 = Join-Path $dir.FullName '730'
            if (-not (Test-Path $g730)) { continue }

            $files   = @(Get-ChildItem $g730 -Recurse -File -ErrorAction SilentlyContinue)
            $video   = Select-ConfigFile -Files $files -Base $g730 -NamePattern 'cs2_video.txt'
            $convars = Select-ConfigFile -Files $files -Base $g730 -NamePattern 'cs2_user_convars*.vcfg'
            $keys    = Select-ConfigFile -Files $files -Base $g730 -NamePattern 'cs2_user_keys*.vcfg'
            if (-not ($video -or $convars -or $keys)) { continue }

            $n++
            $targets.Add([pscustomobject]@{
                Game     = 'CS2'
                Id       = $dir.Name
                ScrubId  = $true
                Label    = if ($Anonymize) { "account_$n" } else { $dir.Name }
                Root     = (Resolve-Path $g730).Path
                CopyMode = 'Tree'
                CopyList = $null
                Video    = $video
                Convars  = $convars
                Keys     = $keys
            })
        }
        Write-Host ("CS2 account(s) found: {0}" -f $n) -ForegroundColor Green
    } elseif ($Game -eq 'cs2') {
        Stop-WithError 'Steam or its userdata folder not found.' `
                       'Pass the path explicitly: -SteamPath "D:\Games\Steam"'
    } else {
        Write-Host "CS2: Steam not found, skipping." -ForegroundColor DarkGray
    }
}

if ($Game -in 'apex', 'all') {
    $apex = if ($ApexPath) { $ApexPath } else { Get-ApexPath }
    if ($apex -and (Test-Path $apex)) {
        $apex  = (Resolve-Path $apex).Path
        $found = @($ApexConfigFiles | Where-Object { Test-Path (Join-Path $apex $_) })
        if ($found.Count -gt 0) {
            Write-Host "Apex Legends found: $apex" -ForegroundColor Green
            $targets.Add([pscustomobject]@{
                Game     = 'Apex'
                Id       = 'profile'
                ScrubId  = $false
                Label    = 'apex_profile'
                Root     = $apex
                CopyMode = 'Selected'
                CopyList = $found
                Video    = $(if (Test-Path (Join-Path $apex 'local\videoconfig.txt')) { Join-Path $apex 'local\videoconfig.txt' })
                Convars  = $(if (Test-Path (Join-Path $apex 'profile\profile.cfg'))   { Join-Path $apex 'profile\profile.cfg' })
                Keys     = $(if (Test-Path (Join-Path $apex 'local\settings.cfg'))    { Join-Path $apex 'local\settings.cfg' })
            })
        } elseif ($Game -eq 'apex') {
            Stop-WithError "No Apex config files under $apex" 'Launch Apex at least once.'
        }
    } elseif ($Game -eq 'apex') {
        Stop-WithError 'Apex Legends config folder not found.' `
                       'Pass it explicitly: -ApexPath "...\Saved Games\Respawn\Apex"'
    } else {
        Write-Host "Apex Legends: no config found, skipping." -ForegroundColor DarkGray
    }
}

if ($targets.Count -eq 0) {
    Stop-WithError 'No game configuration found.' 'Launch the game at least once to generate its files.'
}

$backupR = Join-Path $OutputRoot ("Game_Backup_" + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))

# Precompiled once instead of per-file-per-key inside the anonymization loop.
# Two shapes, because the two games disagree on how a key is written:
#   CS2  KeyValues : "name"  "Value"   -> anchored on the opening quote
#   Apex cvar line : name    "Value"   -> anchored on start-of-line
# A single pattern cannot cover both without also matching `joy_name`, so they
# stay separate and both run over every text file.
$SensitiveRx = @(
    $SensitiveKeys | ForEach-Object {
        [regex]::new("(`"$([regex]::Escape($_))`"\s+`")[^`"]*(`")", 'IgnoreCase')
    }
    ($SensitiveKeys + $ApexSensitiveKeys) | Sort-Object -Unique | ForEach-Object {
        [regex]::new("(?im)^(\s*$([regex]::Escape($_))\s+`")[^`"]*(`")")
    }
)

# Steam does not always live under Program Files: a custom install can sit
# inside the user profile, which would drop the Windows account name into paths
# written to a file meant for publishing. Scrub it like the Steam account ID.
# The profile FOLDER name can differ from $env:USERNAME, so cover both.
# \b keeps this tight: '_' is a word character, so a username like "user" does
# not eat the middle of a convar such as cl_new_user_phase.
# The 8.3 short name matters too: a path handed in as C:\Users\LONGNA~1\... keeps
# that form through Resolve-Path, and it still spells out the start of the
# account name. Ask the filesystem for it rather than trying to derive it.
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

foreach ($acc in $targets) {
    Write-Host ""
    Write-Host ("--- $($acc.Game): $($acc.Id) ---") -ForegroundColor Cyan

    # For CS2 the userdata folder name IS your Steam account ID (ID3): it
    # converts straight to a SteamID64 and identifies you, so the export folder
    # and every printed path use a neutral label instead. Apex's Id is the
    # literal folder name "profile" and must NOT be substituted.
    $hidePath = {
        param([string]$P)
        if (-not $Anonymize) { return $P }
        if ($acc.ScrubId) { $P = $P -replace [regex]::Escape($acc.Id), '<ACCOUNT_ID>' }
        foreach ($rx in $UserRx) { $P = $rx.Replace($P, '<USER>') }
        return $P
    }

    $outDir = Join-Path $backupR (Join-Path $acc.Game.ToLower() $acc.Label)
    $rawDir = Join-Path $outDir  'raw_config_for_reimport'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

    # --- 1. Raw copy (for re-import) ---
    if ($acc.CopyMode -eq 'Tree') {
        Copy-Item -Path (Join-Path $acc.Root '*') -Destination $rawDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        # Selected files: recreate the relative folder structure so the copy can
        # be dropped straight back over the original.
        foreach ($rel in $acc.CopyList) {
            $srcF = Join-Path $acc.Root $rel
            if (-not (Test-Path $srcF)) { continue }
            $dstF = Join-Path $rawDir $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dstF -Parent) | Out-Null
            Copy-Item $srcF $dstF -Force -ErrorAction SilentlyContinue
        }
    }
    $copied = @(Get-ChildItem $rawDir -Recurse -File -ErrorAction SilentlyContinue)
    $kb = [math]::Round((($copied | Measure-Object Length -Sum).Sum / 1KB), 1)
    Write-Host "  [OK] Config copied (raw): $($copied.Count) file(s), $kb KB." -ForegroundColor Green

    if ($Anonymize) {
        # Single walk of the raw copy (it used to be enumerated twice), doing:
        #   a) delete files carrying account / third-party identifiers, plus
        #      every .dt binary blob (see $IdentifyingFiles / $TextRewritePattern);
        #   b) scrub the text files that survive.
        # The userdata folder name is itself the account ID (ID3) and converts
        # straight to a SteamID64, so it gets scrubbed out of file CONTENT too,
        # not just out of the paths we print.
        $accountIdRx = if ($acc.ScrubId) { [regex]::new("\b$([regex]::Escape($acc.Id))\b") } else { $null }
        $dropped = 0
        # Materialize before deleting: don't mutate the tree mid-enumeration.
        foreach ($f in @(Get-ChildItem $rawDir -Recurse -File -ErrorAction SilentlyContinue)) {
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
        Write-Host "  [OK] Raw copy anonymized ($dropped identifying file(s) removed)." -ForegroundColor Green
    }

    # --- 2. Human-readable summary (ALL settings) ---
    $isApex = $acc.Game -eq 'Apex'
    $h = New-Object System.Text.StringBuilder
    [void]$h.AppendLine('==============================================')
    [void]$h.AppendLine("  $(if ($isApex) { 'APEX LEGENDS' } else { 'CS2' }) CONFIGURATION - READABLE SUMMARY")
    [void]$h.AppendLine("  Exported on: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$h.AppendLine('  (Identifying values are omitted - safe to share.)')
    [void]$h.AppendLine('==============================================')
    [void]$h.AppendLine('')

    # Graphics / video. Both games store this as KeyValues, so one parser reads
    # both; only the label table and the surrounding notes differ.
    $vMap = if ($isApex) { $ApexVideoMap } else { $VideoMap }
    [void]$h.AppendLine('--- GRAPHICS / VIDEO SETTINGS ---')
    if ($isApex) {
        [void]$h.AppendLine('  (Stored in local\videoconfig.txt, which the Steam Cloud does NOT sync:')
        [void]$h.AppendLine('   these do not follow you to another PC.)')
    } else {
        [void]$h.AppendLine('  (Stored in local\ and NOT synced by the Steam Cloud: unlike your')
        [void]$h.AppendLine('   crosshair and keybinds, these do not follow you to another PC.)')
    }
    [void]$h.AppendLine('')
    if ($acc.Video) {
        $kv = ConvertFrom-KeyValues (Read-TextFile $acc.Video)
        foreach ($k in $kv.Keys) {
            # Same filter as the settings below: these files are not supposed to
            # hold a nickname, but the summary is advertised as safe to share, so
            # an unmapped key never gets printed unchecked.
            if (Test-Sensitive $k) { continue }
            if ($vMap.Contains($k)) {
                $def = $vMap[$k]
                [void]$h.AppendLine(("  {0,-36} : {1}" -f $def.Label, (Format-VideoValue $def $kv[$k])))
            } else {
                [void]$h.AppendLine(("  {0,-36} : {1}" -f ($k -replace '^setting\.', ''), $kv[$k]))
            }
        }
        if (-not $isApex) {
            # CS2 stores the refresh rate as a fraction; show the actual Hz too.
            $num = $kv['setting.refreshrate_numerator']; $den = $kv['setting.refreshrate_denominator']
            if ($num -and $den -and [double]$den -ne 0) {
                # Invariant culture: the summary is meant to be shared, a locale-
                # dependent decimal comma would read as a typo.
                $hz = [string]::Format([cultureinfo]::InvariantCulture, '{0:N2}',
                                       ([double]$num / [double]$den))
                [void]$h.AppendLine(("  {0,-36} : {1} Hz" -f '>> Refresh rate (computed)', $hz))
            }
        }
        [void]$h.AppendLine('')
        [void]$h.AppendLine('  Note: "(raw)" values are internal detail levels whose scale differs per')
        [void]$h.AppendLine('        setting. They are shown unlabelled on purpose rather than guessed.')
    } elseif ($isApex) {
        [void]$h.AppendLine('  (videoconfig.txt not found under local\.)')
    } else {
        [void]$h.AppendLine('  (cs2_video.txt not found: CS2 only writes video settings after you')
        [void]$h.AppendLine('   open Settings > Video and click Apply at least once. Do that, then')
        [void]$h.AppendLine('   run this script again.)')
    }
    [void]$h.AppendLine('')

    # Game settings (ALL, minus identifying ones), grouped by category.
    # CS2 keeps them as KeyValues in one .vcfg. Apex splits them across two
    # line-based files: profile.cfg (cloud-synced) and the cvar half of
    # settings.cfg (local), so both are read and merged here.
    $cv = $null
    if ($isApex) {
        $cv = [ordered]@{}
        foreach ($src in @($acc.Convars, $acc.Keys)) {
            if (-not $src) { continue }
            $part = ConvertFrom-CvarLines (Read-TextFile $src)
            foreach ($k in $part.Keys) { $cv[$k] = $part[$k] }
        }
        if ($cv.Count -eq 0) { $cv = $null }
    } elseif ($acc.Convars) {
        $cv = ConvertFrom-KeyValues (Read-TextFile $acc.Convars)
    }

    if ($cv) {
        # Names shorter than 3 chars are not worth hunting for: they would match
        # fragments of half the file and drown the report in false positives.
        foreach ($nk in @('name', 'player_name', 'cl_name')) {
            if ($cv[$nk] -and "$($cv[$nk])".Length -ge 3) { [void]$PlayerNames.Add("$($cv[$nk])") }
        }

        $cats   = if ($isApex) { $ApexCvarCategories } else { $ConvarCategories }
        $labels = if ($isApex) { $ApexCvarLabels }     else { $ConvarLabels }

        # Bucket every setting into its category (first matching rule wins).
        # Lists, not arrays: "$array += $x" reallocates the whole array on
        # every entry.
        $buckets = [ordered]@{}
        foreach ($c in $cats) { $buckets[$c.Name] = [System.Collections.Generic.List[string]]::new() }
        $buckets['Other'] = [System.Collections.Generic.List[string]]::new()
        $shown = 0
        foreach ($k in $cv.Keys) {
            if (Test-Sensitive $k) { continue }
            $cat = 'Other'
            foreach ($c in $cats) { if ($k -match $c.Pattern) { $cat = $c.Name; break } }
            $buckets[$cat].Add($k)
            $shown++
        }

        [void]$h.AppendLine("--- GAME SETTINGS ($shown settings) ---")
        if ($isApex) {
            [void]$h.AppendLine('  (profile\profile.cfg is synced by the Steam Cloud; the settings that')
            [void]$h.AppendLine('   live in local\settings.cfg are not.)')
        } else {
            [void]$h.AppendLine('  (Synced by the Steam Cloud: these come back on their own when you')
            [void]$h.AppendLine('   log into another PC.)')
        }
        [void]$h.AppendLine('')
        foreach ($catName in $buckets.Keys) {
            $keys = $buckets[$catName]
            if (-not $keys) { continue }
            [void]$h.AppendLine("  [ $catName ]")
            foreach ($k in $keys) {
                $line = "  {0,-40} : {1}" -f $k, $cv[$k]
                if ($labels.ContainsKey($k)) { $line += ("   # {0}" -f $labels[$k]) }
                [void]$h.AppendLine($line)
            }
            [void]$h.AppendLine('')
        }
    }

    # Keybinds (ALL present in the file)
    if ($acc.Keys -and $isApex) {
        # Apex writes one line per bind, and a separate "held" layer for keys
        # that do something different when held down. Both are listed, the held
        # ones flagged, because a bind list that silently merges them would
        # misdescribe the config.
        $binds = ConvertFrom-ApexBinds (Read-TextFile $acc.Keys)
        $layouts = @($binds | ForEach-Object { $_.Directive -replace '^bind_(held_)?', '' } | Sort-Object -Unique)
        [void]$h.AppendLine("--- KEYBINDS ($($binds.Count) binds) ---")
        [void]$h.AppendLine("  (Keyboard layout(s) in the file: $($layouts -join ', '))")
        [void]$h.AppendLine('  (Stored in local\settings.cfg - NOT synced by the Steam Cloud.)')
        [void]$h.AppendLine('')
        foreach ($b in $binds) {
            $suffix = if ($b.Held) { '   [held]' } else { '' }
            $action = if ($b.Action) { $b.Action } else { '(unbound)' }
            [void]$h.AppendLine(("  {0,-16} -> {1}{2}" -f $b.Key, $action, $suffix))
        }
        [void]$h.AppendLine('')
    } elseif ($acc.Keys) {
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
    # Same three slots in both games, but they mean different things: Apex's
    # settings.cfg carries the binds AND the input/audio cvars, and profile.cfg
    # is the cloud-synced gameplay half.
    $detected = @()
    if ($acc.Video)   { $detected += "  - $(& $hidePath $acc.Video)   (graphics / video)" }
    if ($isApex) {
        if ($acc.Keys)    { $detected += "  - $(& $hidePath $acc.Keys)   (keybinds + input/audio)" }
        if ($acc.Convars) { $detected += "  - $(& $hidePath $acc.Convars)   (gameplay / HUD, cloud-synced)" }
    } else {
        if ($acc.Convars) { $detected += "  - $(& $hidePath $acc.Convars)   (game settings)" }
        if ($acc.Keys)    { $detected += "  - $(& $hidePath $acc.Keys)   (keybinds)" }
    }

    if ($isApex) {
        $loc = @"
==============================================
  APEX LEGENDS CONFIG LOCATION & RE-IMPORT
==============================================

ORIGINAL LOCATION:
  $(& $hidePath $acc.Root)

Settings files detected:
$($detected -join [Environment]::NewLine)

----------------------------------------------
WHAT IS IN THERE: local\ VS profile\
----------------------------------------------
Apex splits its config the same way CS2 does, under different names:

  local\    THIS PC only - never uploaded. Holds videoconfig.txt (all your
            graphics settings) and settings.cfg (keybinds + input/audio cvars).
  profile\  Synced by the Steam Cloud. Holds profile.cfg (gameplay, HUD and
            accessibility settings) and steam_autocloud.vdf, a small marker
            file carrying your Steam account id.

So your GRAPHICS settings and your KEYBINDS do NOT follow you to another PC -
they sit in local\. That is the part this backup really saves for you.

Not copied on purpose:
  local\psoCache.pso   compiled shader cache, ~230 MB, rebuilt by the game
  assets\              store and promo art, re-downloaded automatically
Copying those back would be pointless and would turn a 12 KB config into a
230 MB folder.

----------------------------------------------
HOW TO RE-IMPORT THIS CONFIG (this PC or another):
----------------------------------------------
  1. Fully close Apex Legends AND Steam. Steam flushes pending Cloud uploads
     as it exits, so copying while it runs can get your files overwritten.

  2. Disable Steam Cloud for Apex before copying:
       Steam > right-click Apex Legends > Properties > General > uncheck
       Steam Cloud
     Without it, Steam re-downloads its own profile\ on the next launch and
     reverts the settings you just restored. Files in local\ (graphics and
     keybinds) are never touched by the Cloud and restore fine either way.

  3. Copy the CONTENTS of "raw_config_for_reimport\" into:
       %USERPROFILE%\Saved Games\Respawn\Apex\
     keeping the local\ and profile\ subfolders as they are.
     (If you moved your "Saved Games" folder, use that location instead.)

  4. Accept overwriting the existing files.

  5. Restart Steam, then Apex, and check your settings in-game.

  6. Only once Apex has run with the restored config, re-enable Steam Cloud if
     you want it back. In that order the Cloud uploads YOUR files instead of
     overwriting them.

Note: the first launch after restoring rebuilds the shader cache, so expect
      one slower startup and some early stutter. That is normal.
"@
    } else {
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
    }

    if ($Anonymize -and $isApex) {
        $loc += @"


ANONYMIZED EXPORT: this copy was stripped for public sharing.
  - The player name in settings.cfg was blanked, and the Steam account id in
    profile\steam_autocloud.vdf was zeroed.
  - The Windows user name was replaced with <USER> in the paths above.
  Your graphics, gameplay settings and keybinds are untouched, so this export
  still restores correctly - only the identifying values are gone.
"@
    } elseif ($Anonymize) {
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

# ===========================================================================
#  Verification pass: never trust the scrubbing blindly. Re-read what was
#  actually written and look for identifiers before the user publishes it.
# ===========================================================================
if ($Anonymize) {
    Write-Host ""
    Write-Host "Verifying the anonymized export..." -ForegroundColor Cyan

    $leakRx = [regex]'7656119\d{10}'
    $leaks  = [System.Collections.Generic.List[string]]::new()
    # Compiled once, not re-escaped for every file x every account. Only ids
    # that really are identifiers: Apex's "profile" is a folder name and would
    # flag every path in the report.
    $accountRx = @($targets | Where-Object { $_.ScrubId } |
                   ForEach-Object { [regex]::new("\b$([regex]::Escape($_.Id))\b") })
    # Player names collected while reading the ORIGINAL config files.
    $NameRx = @($PlayerNames | Sort-Object -Unique |
                ForEach-Object { [regex]::new([regex]::Escape($_), 'IgnoreCase') })

    # Anchor the relative path on the backup folder NAME, not on the length of
    # $backupR: an 8.3 short path (C:\Users\LONGNA~1\...) does not survive
    # Resolve-Path, and Get-ChildItem hands back the expanded form.
    $backupLeaf = Split-Path $backupR -Leaf

    # Scan EVERY file, whatever its extension. Filtering this pass by the
    # rewrite pattern is what let an untouched cs2_video.txt.bak - SteamID64 and
    # all - be reported as "safe to publish": the check must not share the
    # blind spot of the thing it is checking. Latin-1 maps every byte to one
    # char, so a leftover binary is searched for ASCII ids too instead of
    # throwing on invalid UTF-8.
    $scanEnc = [System.Text.Encoding]::GetEncoding(28591)

    # Strip our own placeholders before looking for leaks, or the redaction gets
    # reported as the thing it redacted: a Windows account actually named "user"
    # matches <USER>. Same trap as the SteamID64 placeholder, which is why that
    # one is numeric-but-invalid rather than a word.
    $placeholderRx = [regex]'<ACCOUNT_ID>|<USER>'

    foreach ($f in Get-ChildItem $backupR -Recurse -File -ErrorAction SilentlyContinue) {
        $txt = $placeholderRx.Replace([System.IO.File]::ReadAllText($f.FullName, $scanEnc), '')
        $cut = $f.FullName.LastIndexOf($backupLeaf)
        $rel = if ($cut -ge 0) { $f.FullName.Substring($cut + $backupLeaf.Length).TrimStart('\') }
               else            { $f.Name }
        if ($leakRx.IsMatch($txt)) { $leaks.Add("$rel : SteamID64") }
        foreach ($rx in $accountRx) {
            if ($rx.IsMatch($txt)) { $leaks.Add("$rel : Steam account ID") }
        }
        # Checked here too: anything the scrubbing covers, the verification has
        # to cover as well, or "safe to publish" means less than it says.
        foreach ($rx in $UserRx) {
            if ($rx.IsMatch($txt)) { $leaks.Add("$rel : Windows user name") }
        }
        foreach ($rx in $NameRx) {
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

Write-Host ""
Write-Host "Done! Export available in:" -ForegroundColor Cyan
Write-Host "  $backupR" -ForegroundColor White
if (-not $Anonymize) {
    Write-Host "  Reminder: this copy contains your player name and account IDs." -ForegroundColor Yellow
    Write-Host "  Use -Anonymize before publishing it anywhere." -ForegroundColor Yellow
}
Write-Host ""
try { Start-Process explorer.exe $backupR } catch {}
