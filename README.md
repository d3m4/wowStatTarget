# WowStatTarget

A lightweight WoW Retail addon that displays a floating window comparing your current secondary stats against your target values. Color-coded feedback shows you at a glance how close you are to your goals.

![Layout Examples](https://img.shields.io/badge/WoW-Midnight%2012.x-blueviolet)

## Features

- **Floating window** — draggable, semi-transparent, sits anywhere on your screen
- **3 layout modes** — choose your style in settings:
  - **A (Compact)** — stat names + arrow + colored values
  - **B (With Bars)** — colored values + 2px progress bars
  - **C (Ultra Minimal)** — single-letter abbreviations, smallest footprint
- **Color-coded stats** — instantly see where you stand:
  - Gray: far from target
  - Yellow: getting close
  - Green: on target
  - Red: overcapped
- **Per-spec targets** — saved separately for each specialization, auto-switches when you change spec
- **Fully configurable** — colors, thresholds, font size, layout mode

## Installation

Copy the `WowStatTarget` folder into your WoW addons directory:

```
World of Warcraft/_retail_/Interface/AddOns/WowStatTarget/
```

The folder should contain: `WowStatTarget.toc`, `Core.lua`, `UI.lua`, `Settings.lua`, `Data.lua`

Then `/reload` in-game or restart WoW.

## Usage

| Command | Action |
|---------|--------|
| `/wst` | Open settings panel |
| `/wst toggle` | Show/hide the floating window |
| `/wst reset` | Reset all settings to defaults |
| `/wst help` | List available commands |

### Quick Start

1. Type `/wst` to open settings
2. Select your class and spec from the dropdowns
3. Enter your target percentages for Crit, Haste, Mastery, and Versatility
4. The floating window updates in real-time as your stats change

## Settings

- **Class & Spec** — for reference and per-spec target storage
- **Target Stats** — your goal percentages for each secondary stat
- **Layout** — switch between Compact (A), With Bars (B), or Ultra Minimal (C)
- **Font Size** — adjustable from 8 to 24
- **Thresholds** — customize when colors change (defaults: gray < 70%, yellow 70-90%, green 91-100%, red > 100%)
- **Colors** — hex color codes for each threshold level

## How It Works

The addon reads your current secondary stats from the WoW API and compares them against your configured targets. The ratio `(current / target)` determines the color:

```
current = 20%, target = 25%  ->  80% of target  ->  Yellow
current = 24%, target = 25%  ->  96% of target  ->  Green
current = 30%, target = 25%  -> 120% of target  ->  Red (overcap)
```

Stats update automatically when you change gear, receive buffs, or switch specs.

## File Structure

```
WowStatTarget/
  WowStatTarget.toc   -- Addon manifest
  Data.lua             -- Class/spec lookup tables
  Core.lua             -- Events, stat reading, slash commands
  UI.lua               -- Floating window and layouts
  Settings.lua         -- Configuration panel
```

## Learning Resource

This addon's source code is heavily commented in English, explaining WoW addon development concepts like frames, events, SavedVariables, slash commands, and the anchor system. If you're new to WoW addon development, reading through the code is a good way to learn.

## License

MIT
