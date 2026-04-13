# WowStatTarget — Design Spec

## Overview

WoW Retail addon (The War Within / Midnight) that displays a floating comparison window showing the player's current secondary stats versus target values (sourced from murlok.io top 50 aggregation). Color-coded feedback indicates how close each stat is to the target.

**Target WoW Version:** Retail (Midnight). TOC Interface number to be set to the current Retail value at implementation time.

## Stats Tracked

Four secondary stats, always displayed as percentages:

- Critical Strike
- Haste
- Mastery
- Versatility (damage bonus %, not damage reduction)

## Floating Window

### General Behavior

- Semi-transparent dark background (black, 60% opacity) with subtle border
- Draggable — user positions it anywhere on screen
- Position persists across sessions via SavedVariables
- Respects WoW UI scale — uses default scaling, no custom `SetScale()`
- Monospace font (game default or equivalent)
- Font size configurable in settings
- Show/hide toggle via `/wst toggle` or close button (small X on the window)

### Number Format

- Minimum 2 digits (values < 10 get leading zero: `05`)
- Up to 3 digits supported (max display: `999`)
- Values exceeding 999 are clamped to `999` for display
- Slash tight against both numbers, padding on the left
- Examples: `  28/31 %`, `100/148 %`, `  05/02 %`

### Three Layout Modes (selectable in settings)

**A — Compact (arrows)**
- Title "WowStatTarget" at top (small, dim, uppercase)
- Each line: `StatName` (dim white) + colored `→` + colored `current/target %`
- Stat name and arrow/values separated by minimal gap (~4-5px)

**B — With Bars**
- Title "WowStatTarget" at top
- Each line: stat name + values (both in stat color) + 2px progress bar below
- Progress bar width = `min(current/target, 1.0) * 100%`
- Bar color matches the stat's threshold color

**C — Ultra Minimal**
- No title
- Abbreviated stat names: C, H, M, V
- Values only, all in stat color
- Smallest possible footprint

### Color Coding (thresholds configurable)

Colors applied to text (font color), not background.

Note: color values below are human-readable hex references. Implementation uses WoW RGB floats (0-1).

| Status   | Default Threshold        | Default Color (hex) | RGB float          |
|----------|--------------------------|---------------------|--------------------|
| Gray     | < 70% of target          | `#888888`           | `0.53, 0.53, 0.53` |
| Yellow   | 70–90% of target         | `#ffcc00`           | `1.0, 0.8, 0.0`    |
| Green    | 91–100% of target        | `#00ff00`           | `0.0, 1.0, 0.0`    |
| Red      | > 100% of target         | `#ff4444`           | `1.0, 0.27, 0.27`  |

Threshold formula: `(current / target) * 100`

**Edge case — target is 0:** Stats with target set to 0 are hidden from the floating window (not displayed). This avoids division by zero.

All four colors and all three threshold boundaries (low, high, overcap) are customizable in settings.

## Settings Panel

Accessible via `/wst` slash command (no args opens settings) or Blizzard addon options menu (Interface > AddOns > WowStatTarget).

### Slash Commands

| Command        | Action                              |
|----------------|-------------------------------------|
| `/wst`         | Open settings panel                 |
| `/wst toggle`  | Show/hide floating window           |
| `/wst reset`   | Reset all settings to defaults      |
| `/wst help`    | List available commands             |

### Fields

- **Class dropdown**: all playable WoW classes (populated from `Data.lua`)
- **Spec dropdown**: specs for selected class (dynamic, populated from `Data.lua`)
- **Target stats**: 4 numeric inputs (Crit %, Haste %, Mastery %, Versa %)
- **Layout mode**: dropdown A / B / C
- **Font size**: slider or numeric input
- **Threshold config**: low boundary (default 70), high boundary (default 90), overcap boundary (default 100)
- **Color pickers**: gray, yellow, green, red (hex input or color picker)
- **Reset to defaults**: button

### Default Values (fresh install)

- Class/Spec: blank (no selection) — addon works without it
- Target stats: all 0 (floating window shows "No targets set" message)
- Layout: A (Compact)
- Font size: 12
- Thresholds: 70 / 90 / 100
- Colors: gray `#888888`, yellow `#ffcc00`, green `#00ff00`, red `#ff4444`
- Window visible: true
- Window position: center of screen

### Notes

- Class/spec selection is for user reference only — does not affect stat reading logic
- All settings persist via SavedVariables (`WowStatTargetDB`)
- When settings change, the floating window refreshes immediately (internal callback)

### SavedVariables Schema

```lua
WowStatTargetDB = {
    class = "MAGE",              -- or nil
    spec = "Fire",               -- or nil
    targets = {
        crit = 31,
        haste = 25,
        mastery = 48,
        versa = 2,
    },
    layout = "A",                -- "A", "B", or "C"
    fontSize = 12,
    thresholds = {
        low = 70,
        high = 90,
        overcap = 100,
    },
    colors = {
        gray    = { 0.53, 0.53, 0.53 },
        yellow  = { 1.0,  0.8,  0.0  },
        green   = { 0.0,  1.0,  0.0  },
        red     = { 1.0,  0.27, 0.27 },
    },
    window = {
        visible = true,
        x = 0,
        y = 0,
    },
}
```

## Data Flow

1. **Events listened:**
   - `PLAYER_ENTERING_WORLD` — initial load + reloads + zone transitions
   - `PLAYER_EQUIPMENT_CHANGED` — gear swap
   - `COMBAT_RATING_UPDATE` — combat rating changes (gems, enchants, buffs)
   - `UNIT_AURA_CHANGED` (filtered to `unit == "player"`) — buff/debuff changes

2. **Read current stats via WoW API:**
   - Crit: `GetCritChance()` — returns total crit % including base + rating + buffs
   - Haste: `UnitSpellHaste("player")` — returns total haste %
   - Mastery: `GetMasteryEffect()` — returns `masteryEffect` (first return value, total %)
   - Versatility: `GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE)` — returns damage bonus %

3. **Compare** current vs target values from `WowStatTargetDB.targets`
4. **Calculate ratio**: `current / target * 100` (skip if target is 0)
5. **Determine color** based on configurable thresholds
6. **Update floating window** text and colors

## File Structure

```
WowStatTarget/
├── WowStatTarget.toc      # Addon manifest
├── Core.lua               # Initialization, events, stat reading
├── UI.lua                 # Floating window (drag, position, layouts A/B/C)
├── Settings.lua           # Settings panel (slash command, Blizzard options)
├── Data.lua               # Class/spec table for dropdowns
```

Additional files in repo root (not shipped with addon):
- `ACE3_MIGRATION.md` — guide for future Ace3 migration
- `docs/` — design specs and documentation

## Architecture

- **Monolithic** — no external library dependencies
- **SavedVariables** for persistence (native WoW mechanism)
- **Event-driven** — listens to game events, updates UI reactively
- Future migration path to Ace3 documented in `ACE3_MIGRATION.md`

## Out of Scope (v1)

- Automatic data fetching from murlok.io (user inputs targets manually)
- Stat weights or scoring
- Multiple profiles/specs switching automatically
- Minimap button
- Window lock/unlock toggle (future enhancement)
