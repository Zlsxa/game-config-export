# Game Config Export 🎮

A single **PowerShell** script that backs up and exports your game configuration in one click.

**Supported games:** Counter-Strike 2 · Apex Legends

For every config it finds, it produces:

1. 📦 **`raw_config_for_reimport/`** — an **exact copy** of the config files, ready to be re-imported as-is.
2. 📄 **`readable_settings.txt`** — a **human-readable** summary listing **every** setting (all graphics options, all game settings, all keybinds) with friendly labels where known (e.g. `Global GPU detail: High`, `Anisotropic filtering: 4x`). Identifying values are always omitted, so it's safe to share.
3. 🗺️ **`location_and_reimport.txt`** — where the original config lives and **how to re-import it** (same PC or another one).

👉 See the [`examples/`](examples/) folder for a preview of what the script generates.

> ✅ The script is **100% read-only** on your games — it never changes your settings.

---

## Requirements

- Windows
- The game launched **at least once**, so its config files exist

## Install

Just download **`Export-GameConfig.ps1`** (*Code > Download ZIP*, or grab that single file).

## Usage

**Easy way:** right-click `Export-GameConfig.ps1` > **Run with PowerShell**. It exports every supported game it finds.

If Windows blocks scripts (execution policy), open a PowerShell terminal in the folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Export-GameConfig.ps1
```

When it finishes, the export folder opens automatically (default: your **Desktop**).

### Options

```powershell
# One game only (default: all)
.\Export-GameConfig.ps1 -Game cs2
.\Export-GameConfig.ps1 -Game apex

# Choose the output folder (default: Desktop)
.\Export-GameConfig.ps1 -OutputRoot "D:\Backups"

# Force the paths if auto-detection fails
.\Export-GameConfig.ps1 -SteamPath "D:\Games\Steam"
.\Export-GameConfig.ps1 -ApexPath "D:\Saved Games\Respawn\Apex"

# Remove identifying values from the copy (to SHARE your config publicly)
.\Export-GameConfig.ps1 -Anonymize
```

## Where each game keeps its config

| | Counter-Strike 2 | Apex Legends |
|---|---|---|
| Location | `Steam\userdata\<id>\730\` | `%USERPROFILE%\Saved Games\Respawn\Apex\` |
| Per Steam account | yes — every account is exported | no — one config per Windows user |
| Graphics | `cs2_video.txt` | `local\videoconfig.txt` |
| Game settings | `cs2_user_convars*.vcfg` | `profile\profile.cfg` + `local\settings.cfg` |
| Keybinds | `cs2_user_keys*.vcfg` | `local\settings.cfg` |
| Cloud-synced half | `remote\` | `profile\` |

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

```
Game_Config_Export/
└── Game_Backup_YYYY-MM-DD_HH-mm/
    ├── cs2/
    │   └── <account_id>/
    │       ├── raw_config_for_reimport/   ← exact copy (re-import)
    │       ├── readable_settings.txt      ← human summary
    │       └── location_and_reimport.txt  ← where + how to re-import
    └── apex/
        └── apex_profile/
            └── (same three)
```

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
