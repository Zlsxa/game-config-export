# CS2 Config Export 🎮

A **PowerShell** script that backs up and exports your **Counter-Strike 2** configuration in one click.

For every Steam account it finds, it produces:

1. 📦 **`raw_config_for_reimport/`** — an **exact copy** of the config files, ready to be re-imported as-is.
2. 📄 **`readable_settings.txt`** — a **human-readable** summary listing **every** setting (all graphics options, all game convars, all keybinds) with friendly labels where known (e.g. `Global GPU detail: High`, `Shadow quality: Low`). Identifying values are always omitted, so it's safe to share.
3. 🗺️ **`location_and_reimport.txt`** — where the original config lives and **how to re-import it** (same PC or another one).

👉 See the [`examples/`](examples/) folder for a preview of what the script generates.

> ✅ The script is **100% read-only** on your Steam installation — it never changes your settings.

---

## Requirements

- Windows
- Steam + Counter-Strike 2 launched **at least once** (so the config files exist)

## Install

Just download **`Export-CS2Config.ps1`** (*Code > Download ZIP*, or grab that single file).

## Usage

**Easy way:** right-click `Export-CS2Config.ps1` > **Run with PowerShell**.

If Windows blocks scripts (execution policy), open a PowerShell terminal in the folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Export-CS2Config.ps1
```

When it finishes, the export folder opens automatically (default: your **Desktop**).

### Options

```powershell
# Choose the output folder (default: Desktop)
.\Export-CS2Config.ps1 -OutputRoot "D:\Backups"

# Force the Steam path if auto-detection fails
.\Export-CS2Config.ps1 -SteamPath "D:\Games\Steam"

# Remove the Steam name from the copy (useful to SHARE your config publicly)
.\Export-CS2Config.ps1 -Anonymize
```

## ⚠️ Graphics / video settings

CS2 only writes its video settings file (`cs2_video.txt`) **after** you open
**Settings > Video** and click **Apply** at least once. If you just installed the
game, do that first, otherwise the "graphics" section of the summary will be empty
(everything else — game settings, crosshair, keybinds — still works).

## What gets exported

| File                       | Contents                                              |
|----------------------------|-------------------------------------------------------|
| `cs2_video.txt`            | Graphics / video settings (resolution, shadows, etc.) |
| `cs2_user_convars*.vcfg`   | Game settings (crosshair, sensitivity, viewmodel…)    |
| `cs2_user_keys*.vcfg`      | Keybinds                                              |

Output structure:

```
CS2_Config_Export/
└── CS2_Backup_YYYY-MM-DD_HH-mm/
    └── <account_id>/
        ├── raw_config_for_reimport/   ← exact copy (re-import)
        ├── readable_settings.txt      ← human summary
        └── location_and_reimport.txt  ← where + how to re-import
```

## Re-importing your config

1. Fully close **CS2 and Steam**.
2. *(Recommended)* Disable **Steam Cloud** for CS2 (Properties > General), otherwise the Cloud may overwrite your restored files.
3. Copy the **contents** of `raw_config_for_reimport/` into:
   `...\Steam\userdata\<YOUR_ID>\730\`
4. Accept overwriting the existing files.
5. Restart Steam then CS2.

## Privacy

- CS2 config files contain your **Steam name**. The raw exported copy keeps it (for a faithful re-import) — so **don't share your export as-is**.
- The `readable_settings.txt` summary **never** shows your Steam name.
- Use the **`-Anonymize`** option to strip your name from the exported copy if you want to share it.
- The included `.gitignore` prevents accidentally committing an export into this repo.

## License

[MIT](LICENSE) — do whatever you want with it.
