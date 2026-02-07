# DPSMate

A combat analysis addon for World of Warcraft 1.12 (Classic). Parses combat log messages in real-time to track ~40 metrics and presents them in customizable UI windows.

Originally by Shino &lt;Synced&gt; - Kronos. This fork targets TWoW/Kronos private servers.

## Installation

1. Download and extract into `Interface/AddOns/` so the folder is named `DPSMate` (not `DPSMate-master`).
2. Increase addon memory to at least 150 MB.
3. If upgrading from a previous version, delete the old SavedVariables while logged out:
   - `WTF/Account/<ACCOUNT>/SavedVariables/DPSMate.lua` (account-wide settings)
   - `WTF/Account/<ACCOUNT>/<SERVER>/<CHARACTER>/SavedVariables/DPSMate.lua` (per-character data)
4. Add these lines to `WTF/config.wtf` for full combat log range:
```
SET CombatLogRangeParty "150"
SET CombatLogRangePartyPet "150"
SET CombatLogRangeFriendlyPlayers "150"
SET CombatLogRangeFriendlyPlayersPets "150"
SET CombatLogRangeHostilePlayers "150"
SET CombatLogRangeHostilePlayersPets "150"
SET CombatLogRangeCreature "150"
```
5. Log in and `/reload` to load the addon.

## Slash Commands

| Command | Description |
|---------|-------------|
| `/dps` | Show help and available commands |
| `/dps config` | Open configuration window |
| `/dps lock` | Lock all frames |
| `/dps unlock` | Unlock all frames |
| `/dps show {name}` | Show a specific window |
| `/dps hide {name}` | Hide a specific window |
| `/dps showAll` | Show all windows |
| `/dps hideAll` | Hide all windows |
| `/dps reset` | Reset all saved data (players, abilities, history, metrics) |
| `/dps testmode` | Toggle test mode for UI testing |

## Features

**Tracking Modes (~40):**
- Damage done / DPS / damage taken / DTPS
- Enemy damage done / taken
- Healing (total, effective, overhealing) / HPS / EHPS / OHPS
- Healing taken (total, effective, overhealing)
- Healing and absorbs combined
- Absorbs done / taken
- Threat / TPS (requires KLHThreatMeter)
- Deaths with full death recap
- Interrupts (including stuns and silences)
- Dispels / decurses / cure disease / cure poison / lift magic (done and received)
- CC breakers
- Friendly fire (done and taken)
- Auras (gained, lost, uptime)
- Buffs/debuffs and procs
- Casts
- Fails

**UI:**
- Multiple independent windows showing different modes simultaneously
- Resizable and movable frames
- Per-window customization of fonts, colors, textures, bar height, spacing, columns
- Configurable display refresh rate (0.016s to 2.0s)
- Up to 40 status bars per window
- Compare mode for player-vs-player analysis
- Detail views with graphs for every mode

**Data Management:**
- Configurable segment history (1-20 fight segments)
- Boss-only fight filtering
- Automatic stale player pruning between fights
- Raid data synchronization via addon channel
- Report function for chat output

## Supported Locales

enUS, deDE, frFR, ruRU, koKR, zhCN

## Optional Dependencies

- **KLHThreatMeter** - enables threat/TPS tracking

## Troubleshooting

**SavedVariables getting too large?**
- Use `/dps reset` to wipe all accumulated data.
- Reduce the number of stored segments in General Options.
- History segments automatically strip per-tick graph data to save space.

**Missing group members?**
- Ensure combat log range settings are applied in `config.wtf` (see Installation step 4).
- Verify all raid members have the addon loaded for sync to work.
