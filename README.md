# Game Config Export 🎮

**PowerShell** scripts that back up and export your game configuration in one click.

**Supported games:** Counter-Strike 2 · Apex Legends · Battlefield 6

For every config it finds, a script produces:

1. 📦 **`raw_config_for_reimport/`** — an **exact copy** of the config files, ready to be re-imported as-is.
2. 📄 **`readable_settings.txt`** — a **human-readable** summary listing **every** setting (all graphics options, all game settings, all keybinds) with friendly labels where known (e.g. `Global GPU detail: High`, `Anisotropic filtering: 4x`). Identifying values are always omitted, so it's safe to share.
3. 🗺️ **`location_and_reimport.txt`** — where the original config lives and **how to re-import it** (same PC or another one).

👉 See [`cs2/examples/`](cs2/examples/), [`apex/examples/`](apex/examples/) and [`bf6/examples/`](bf6/examples/) for a preview of what they generate.

> ✅ The scripts are **100% read-only** on your games — they never change your settings.

---

## Repository layout

```
lib/Common.ps1              shared: anonymization, verification, parsers
cs2/Export-CS2Config.ps1    Counter-Strike 2
cs2/examples/
apex/Export-ApexConfig.ps1  Apex Legends
apex/examples/
bf6/Export-BF6Config.ps1    Battlefield 6
bf6/examples/
```

One script per game, but the privacy-critical code lives once in `lib/Common.ps1`.
That's deliberate: the anonymizer and its verification pass are where mistakes
actually hurt, and a per-game copy is how one of them silently rots.

## Requirements

- Windows
- The game launched **at least once**, so its config files exist

## Where the scripts look

They target the **default install locations**, with a couple of fallbacks and an
explicit override each. Nothing is hardcoded to a drive letter, but a truly
custom layout needs the override.

**CS2** — Steam is located in this order:

1. `HKCU\Software\Valve\Steam` → `SteamPath` *(where Steam records its own path)*
2. `HKLM\SOFTWARE\WOW6432Node\Valve\Steam` → `InstallPath`
3. `C:\Program Files (x86)\Steam`, `C:\Program Files\Steam`, `C:\Steam`

The config is read from `<Steam>\userdata\<account>\730\`. A Steam installed
anywhere is found through the registry; override with `-SteamPath`.

**Apex** — the config sits in the *Saved Games* known folder:

1. `HKCU\...\Explorer\User Shell Folders` → the `Saved Games` entry. Windows only
   writes that entry when the folder has been *moved* (another drive, OneDrive),
   so on a default setup it is simply absent and step 2 applies.
2. `%USERPROFILE%\Saved Games`

then `\Respawn\Apex\`. Override with `-ApexPath`.

The **game's own install folder is irrelevant** for Apex — whether it sits in
`C:\Program Files\EA Games\` (the EA App default), a Steam library or anywhere
else, the settings are always written to the same place. The script only reads
Steam libraries (via `libraryfolders.vdf`, so non-default library folders count)
to *suggest* an answer to the launcher question, never to find the config.

If auto-detection fails, both scripts stop with the reason and print the exact
override to use, rather than failing silently or exporting nothing:

```
[ERROR] Apex Legends config folder not found.
        Pass it explicitly: .\Export-ApexConfig.ps1 -ApexPath "...\Saved Games\Respawn\Apex"
```

## Install

**Download the whole repository** — *Code > Download ZIP*, or:

```powershell
git clone https://github.com/Zlsxa/game-config-export.git
```

⚠️ Grabbing a single `.ps1` will **not** work: each game script loads
`lib\Common.ps1` from the folder above it, and tells you so if it's missing.

## Usage

**Easy way:** right-click the script for your game > **Run with PowerShell**.

If Windows blocks scripts (execution policy), open a PowerShell terminal in the
repo folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\cs2\Export-CS2Config.ps1
powershell -ExecutionPolicy Bypass -File .\apex\Export-ApexConfig.ps1
powershell -ExecutionPolicy Bypass -File .\bf6\Export-BF6Config.ps1
```

When it finishes, the export folder opens automatically (default: your **Desktop**).

### Options

```powershell
# Choose the output folder (default: Desktop)
.\cs2\Export-CS2Config.ps1 -OutputRoot "D:\Backups"

# Force the paths if auto-detection fails
.\cs2\Export-CS2Config.ps1  -SteamPath "D:\Games\Steam"
.\apex\Export-ApexConfig.ps1 -ApexPath "D:\Saved Games\Respawn\Apex"

# Skip the "which launcher?" question (Apex)
.\apex\Export-ApexConfig.ps1 -Launcher steam
.\apex\Export-ApexConfig.ps1 -Launcher ea

# Remove identifying values from the copy (to SHARE your config publicly)
.\cs2\Export-CS2Config.ps1   -Anonymize
.\apex\Export-ApexConfig.ps1 -Anonymize
```

## Where each game keeps its config

| | Counter-Strike 2 | Apex Legends | Battlefield 6 |
|---|---|---|---|
| Location | `Steam\userdata\<id>\730\` | `%USERPROFILE%\Saved Games\Respawn\Apex\` | `%USERPROFILE%\Documents\Battlefield 6\settings\` |
| Per account | yes — every Steam account is exported | no — one config per Windows user | no |
| Graphics | `cs2_video.txt` | `local\videoconfig.txt` | `PROFSAVE_profile` (`GstRender.*`) |
| Game settings | `cs2_user_convars*.vcfg` | `profile\profile.cfg` + `local\settings.cfg` | same file (`GstInput.*`, `GstAudio.*`…) |
| Keybinds | `cs2_user_keys*.vcfg` | `local\settings.cfg` | same file |
| Cloud-synced half | `remote\` | `profile\` | whole profile |
| File format | KeyValues `"k" "v"` | mixed: KeyValues + `k "v"` | `k v`, unquoted |

**In both games the graphics settings are the part the Steam Cloud does *not* sync** — they stay on the PC that wrote them. Your crosshair, sensitivity and binds come back on their own when you log in elsewhere; your video settings don't. That's what this backup is really for.

For Apex the script copies **only the config files**: `local\psoCache.pso` is a ~230 MB compiled shader cache and `assets\` is re-downloadable store art, so a full-folder copy would turn a 12 KB config into a 230 MB folder for nothing.

## ⚠️ CS2: graphics / video settings

CS2 only writes its video settings file (`cs2_video.txt`) **after** you open
**Settings > Video** and click **Apply** at least once. If you just installed the
game, do that first, otherwise the "graphics" section of the summary will be empty
(everything else — game settings, crosshair, keybinds — still works).

CS2 renamed most of the old CSGO video keys. Detail levels (`videocfg_*`) are
reported as **raw numbers** on purpose — their scale differs per setting, and
inventing labels would misreport your config. Higher = better, `-1` = not set.

## Output structure

Each script writes its own export folder on your Desktop:

```
CS2_Config_Export/                    Apex_Config_Export/
└── CS2_Backup_YYYY-MM-DD_HH-mm/      └── Apex_Backup_YYYY-MM-DD_HH-mm/
    └── <account_id>/                     └── apex_profile/
        ├── raw_config_for_reimport/          ├── raw_config_for_reimport/
        ├── readable_settings.txt             ├── readable_settings.txt
        └── location_and_reimport.txt         └── location_and_reimport.txt
```

CS2 produces one folder **per Steam account** found; Apex has a single config
per Windows user.

## CS2: `local\` vs `remote\` — why this backup is worth having

Inside `730\`, CS2 splits your config in two, and the halves don't hold the same
things:

| | `local\` | `remote\` |
|---|---|---|
| Scope | **this PC only**, never uploaded | **synced by the Steam Cloud** to every PC you log into |
| Holds | `cs2_video.txt`, machine convars, `trustedlaunch.cfg` | game settings, keybinds, mute list, inventory files |

The game settings and keybinds exist on **both** sides —
`local\cfg\cs2_user_convars_0_slot0.vcfg` and `remote\cs2_user_convars.vcfg`.
They hold exactly the same settings; only the line endings differ (`local` uses
Windows CRLF, `remote` uses LF so the Cloud can sync to Linux and macOS). The
script reads the `local` copy and falls back to the Cloud one if that's all
a PC has. `remotecache.vdf` is the Cloud's index of `remote\`, and
`*_lastclouded` files are snapshots of the last upload Steam diffs against.

**What this means:** on a new PC your crosshair, sensitivity and binds come back
**by themselves** through the Cloud. Your **graphics settings don't** — they live
in `local\` and are never synced. That's the part this backup actually saves.

## Apex: `local\` vs `profile\`

Apex splits things the same way, under different names:

| | `local\` | `profile\` |
|---|---|---|
| Scope | **this PC only**, never uploaded | **synced by the Steam Cloud** |
| Holds | `videoconfig.txt` (all graphics), `settings.cfg` (keybinds + input/audio) | `profile.cfg` (gameplay, HUD, accessibility), `steam_autocloud.vdf` |

So for Apex **both your graphics settings and your keybinds** stay on the PC —
even more reason to keep a backup than for CS2, where at least the binds follow you.

## Battlefield 6: two profiles, one per build

BF6 is the one game here where **the launcher really does change the path**:

```
settings\PROFSAVE_profile          the EA App build
settings\steam\PROFSAVE_profile    the Steam build
```

If you have played both, both files exist and they are **independent** — changing
your settings in one does not touch the other. The script exports whichever ones
it finds, each under its own relative path, so restoring puts them back where
they belong. No question to answer: the files themselves say which builds you have.

A `user.cfg` may also sit in the game's *install* folder. It is an optional
hand-written tweak file, not part of the profile, and is not exported.

> ⚠️ BF6 is the only supported game I could not test against a real install —
> it isn't on this machine. The paths and the file format come from a separate
> tool that handles the same game, and the export/anonymize path is covered by
> tests against a synthetic profile. Treat the BF6 support as sound but unproven
> on real data, and check the summary against your in-game menu the first time.

### Steam or EA App?

The Apex script asks at startup which launcher the game comes from, and
preselects an answer from Apex-specific evidence (`steam_autocloud.vdf` in the
config, an Apex entry in a Steam library). Press Enter to accept it, or use
`-Launcher steam|ea` to skip the question entirely.

It only changes the **cloud-save step** of the generated re-import guide — the
EA App has no "Steam Cloud" checkbox, so those instructions would be wrong for
half the users. **The config path is identical either way**: the launcher decides
where the *game* is installed, not where it saves your settings. Having both
launchers installed on the PC changes nothing, which is why the script never
looks at that — plenty of people run Steam for other games and Apex from the EA App.

## Re-importing your config

The steps below are for CS2; the generated `location_and_reimport.txt` has the
matching ones for Apex (same idea, `%USERPROFILE%\Saved Games\Respawn\Apex\`
instead, and expect one slower first launch while the shader cache rebuilds).

1. Fully close **CS2 and Steam**. Steam flushes pending Cloud uploads as it
   exits, so copying while it runs can get your files overwritten.
2. **Disable Steam Cloud** for CS2 — *(Properties > General)*. This is the step
   that makes the rest stick: without it, Steam re-downloads its own copy of
   `remote\` on the next launch and silently reverts your restored game settings
   and keybinds. Files in `local\` (video settings included) are never touched by
   the Cloud and restore fine either way.
3. Copy the **contents** of `raw_config_for_reimport/` into
   `...\Steam\userdata\<YOUR_ID>\730\`, keeping the `local\` and `remote\`
   subfolders as they are. `<YOUR_ID>` is the folder in `...\Steam\userdata\` on
   the **target** PC — it differs per account, don't reuse the one from the export.
4. Accept overwriting the existing files.
5. Restart Steam, then CS2, and check your settings in-game.
6. **Only after** CS2 has run once with the restored config, re-enable Steam
   Cloud if you want it back. In that order the Cloud uploads *your* files
   instead of overwriting them.

## Privacy

A default export is a **personal** backup and contains more than your settings:

| Data | Game | Where |
|------|------|-------|
| Your player name | both | `name` convar / cvar |
| Your Steam account ID | CS2 | the export **folder name** + paths (converts to a SteamID64) |
| Your Steam account ID | Apex | `profile\steam_autocloud.vdf` |
| **SteamID64 of every player you muted** | CS2 | `voice_ban.dt` — *other people's* data |
| Unique inventory item IDs | CS2 | `cs2_preferred_items.txt`, loadout files |
| This machine's hardware fingerprint | CS2 | `trustedlaunch.cfg` |
| Your Windows user name | Apex | it's in the config path itself |

So: **never publish a default export.** The `readable_settings.txt` summary alone
never shows your player name.

Use **`-Anonymize`** when you intend to publish (GitHub, Discord, a forum). It:

- names CS2 folders `account_1` and replaces the account ID with `<ACCOUNT_ID>`,
  in the printed paths **and inside the exported files**;
- replaces your Windows user name with `<USER>`, including its 8.3 short form
  (`LONGNA~1`), which paths keep even after resolution;
- **deletes** `voice_ban.dt`, the inventory files, `trustedlaunch.cfg`, Steam
  sync caches, stale `*_lastclouded` duplicates, and every `.dt` blob (binary
  Steam caches: none of them hold settings, and none can be scrubbed reliably);
- blanks identifying settings (`name`, passwords, `cl_clanid`, screenshot
  directory, audio device names…) in every text file — in **both** the CS2
  KeyValues form `"name" "x"` and the Apex cvar form `name "x"`;
- zeroes any leftover SteamID64 / account id;
- then **re-reads every file of the finished export** — whatever its extension —
  and refuses to call it clean if an identifier is still there:

```
Verifying the anonymized export...
  [OK] No identifier found in the export - safe to publish.
```

The verification hunts for your **player name** too, not just numeric ids: it
remembers the name it read from the original config, so a nickname surviving in
an unexpected field still gets caught.

Your graphics, game settings and keybinds are untouched, so an anonymized export
still re-imports correctly.

The included `.gitignore` also prevents accidentally committing an export into this repo.

## License

[MIT](LICENSE) — do whatever you want with it.
