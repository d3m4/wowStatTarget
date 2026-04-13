# Ace3 Migration Guide — WowStatTarget

This document describes how to migrate WowStatTarget from its current monolithic architecture (zero dependencies) to the Ace3 framework.

## 1. What Is Ace3 and Why Migrate

Ace3 is the de facto standard framework for World of Warcraft addons. It is a collection of small, embeddable libraries that handle the repetitive plumbing every addon needs — event handling, saved variables, options UI, slash commands, etc.

**Reasons to migrate:**

- **Profile support out of the box.** AceDB gives you per-character, per-spec, and global profiles with a profile switcher UI — no custom code needed.
- **Blizzard options integration for free.** AceConfig generates a full options panel (sliders, dropdowns, color pickers, toggles) from a declarative table. No manual frame creation.
- **Less boilerplate.** Event registration, slash commands, and addon lifecycle are handled by the framework.
- **Community standard.** Most actively maintained addons use Ace3. Contributors will already know the patterns.
- **Battle-tested.** Ace3 handles edge cases in SavedVariables, event ordering, and UI scaling that are easy to get wrong in hand-rolled code.

**When NOT to migrate:** If the addon is small, stable, and you don't need profiles or a richer options UI, the current monolithic approach is perfectly fine. Ace3 adds ~150 KB of embedded libraries and a learning curve.

## 2. Key Ace3 Libraries and What They Replace

| Ace3 Library | Replaces | What It Does |
|---|---|---|
| **AceAddon-3.0** | Manual addon initialization in `Core.lua` | Provides `OnInitialize()` and `OnEnable()` lifecycle hooks. Handles module registration. |
| **AceEvent-3.0** | Manual event frame (`CreateFrame("Frame")` + `SetScript("OnEvent", ...)`) | Mixin that adds `self:RegisterEvent("EVENT", "HandlerMethod")`. No raw frame needed. |
| **AceDB-3.0** | Manual `WowStatTargetDB` management (defaults, nil checks, schema) | Wraps SavedVariables with typed defaults, profile support, and a profile management UI. |
| **AceConfig-3.0** | Hand-built settings panel in `Settings.lua` (UIDropDownMenu, EditBox, Slider frames) | Generates an options table from a declarative Lua table. Supports groups, dropdowns, ranges, colors, inputs. |
| **AceConfigDialog-3.0** | Manual Blizzard `InterfaceOptions_AddCategory` integration | Renders the AceConfig options table inside the Blizzard addon settings panel. |
| **AceConsole-3.0** | Manual `SLASH_WOWSTATTARGET1 = "/wst"` handling | Provides `self:RegisterChatCommand("wst", "ChatCommand")` with argument parsing. |

Libraries you do **NOT** need for this addon:

- AceComm / AceSerializer — addon-to-addon communication (not needed)
- AceTimer — `C_Timer.After` is sufficient for our use case
- AceGUI — only needed if building standalone GUI windows outside Blizzard options (our floating window is a custom frame, not an options panel)

## 3. Step-by-Step Migration Plan

### Phase 1 — Add Ace3 Libraries (no code changes yet)

1. Create a `Libs/` folder in the addon directory.
2. Embed the required libraries (see Section 4).
3. Create `embeds.xml` to load them.
4. Update the `.toc` file to load `embeds.xml` before any addon files.

Result:
```
WowStatTarget/
├── Libs/
│   ├── LibStub/
│   ├── CallbackHandler-1.0/
│   ├── AceAddon-3.0/
│   ├── AceEvent-3.0/
│   ├── AceDB-3.0/
│   ├── AceDBOptions-3.0/
│   ├── AceConfig-3.0/
│   ├── AceConfigDialog-3.0/
│   ├── AceConfigRegistry-3.0/
│   ├── AceConfigCmd-3.0/
│   ├── AceConsole-3.0/
│   └── AceGUI-3.0/
├── embeds.xml
├── WowStatTarget.toc
├── Data.lua
├── Core.lua
├── UI.lua
└── Settings.lua
```

### Phase 2 — Migrate Core.lua (addon lifecycle + events)

**Before:**
```lua
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("COMBAT_RATING_UPDATE")
frame:SetScript("OnEvent", function(self, event, ...)
    -- dispatch
end)
```

**After:**
```lua
local WowStatTarget = LibStub("AceAddon-3.0"):NewAddon(
    "WowStatTarget", "AceConsole-3.0", "AceEvent-3.0"
)

function WowStatTarget:OnInitialize()
    -- Set up AceDB, register options, register slash commands
end

function WowStatTarget:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnStatEvent")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "OnStatEvent")
    self:RegisterEvent("COMBAT_RATING_UPDATE", "OnStatEvent")
    self:RegisterEvent("UNIT_AURA_CHANGED", "OnAuraChanged")
end
```

**What gets removed:** The raw event frame, the `SetScript("OnEvent", ...)` dispatcher, manual `frame:RegisterEvent()` calls.

### Phase 3 — Migrate SavedVariables (AceDB)

**Before (manual defaults + nil guards):**
```lua
if not WowStatTargetDB then WowStatTargetDB = {} end
if not WowStatTargetDB.targets then WowStatTargetDB.targets = { crit = 0, haste = 0, mastery = 0, versa = 0 } end
-- ... repeated for every field
```

**After (declarative defaults):**
```lua
local defaults = {
    profile = {
        class = nil,
        spec = nil,
        targets = { crit = 0, haste = 0, mastery = 0, versa = 0 },
        layout = "A",
        fontSize = 12,
        thresholds = { low = 70, high = 90, overcap = 100 },
        colors = {
            gray   = { r = 0.53, g = 0.53, b = 0.53 },
            yellow = { r = 1.0,  g = 0.8,  b = 0.0  },
            green  = { r = 0.0,  g = 1.0,  b = 0.0  },
            red    = { r = 1.0,  g = 0.27, b = 0.27 },
        },
        window = { visible = true, x = 0, y = 0 },
    },
}

function WowStatTarget:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("WowStatTargetDB", defaults, true)
end
```

**What changes:**
- Access becomes `self.db.profile.targets.crit` instead of `WowStatTargetDB.targets.crit`.
- Colors use `{r, g, b}` table keys (AceConfig color type expects this).
- `.toc` SavedVariables line stays the same (`WowStatTargetDB`), but the internal structure changes (AceDB wraps it with profile/global/char namespaces).
- You get profile switching, copying, and deletion for free.

**Migration concern:** Existing users' `WowStatTargetDB` will have the old flat structure. Handle this with a one-time migration check in `OnInitialize()`:
```lua
if WowStatTargetDB and WowStatTargetDB.targets and not WowStatTargetDB.profiles then
    -- Old format detected: copy values into the new profile structure
    -- then clear the old keys
end
```

### Phase 4 — Migrate Settings.lua (AceConfig)

**Before:** Manual frame creation with `UIDropDownMenu_Initialize`, `CreateFrame("EditBox")`, `CreateFrame("Slider")`, color picker frames, callback wiring.

**After:** A single options table:
```lua
local options = {
    name = "WowStatTarget",
    type = "group",
    args = {
        classSelect = {
            type = "select",
            name = "Class",
            values = function() --[[ build from ns.ClassSpecData ]] end,
            order = 1,
        },
        specSelect = {
            type = "select",
            name = "Specialization",
            values = function() --[[ dynamic based on selected class ]] end,
            order = 2,
        },
        targets = {
            type = "group",
            name = "Target Stats",
            inline = true,
            order = 3,
            args = {
                crit    = { type = "range", name = "Critical Strike %", min = 0, max = 100, step = 1, order = 1 },
                haste   = { type = "range", name = "Haste %",           min = 0, max = 100, step = 1, order = 2 },
                mastery = { type = "range", name = "Mastery %",         min = 0, max = 100, step = 1, order = 3 },
                versa   = { type = "range", name = "Versatility %",     min = 0, max = 100, step = 1, order = 4 },
            },
        },
        layout = {
            type = "select",
            name = "Layout Mode",
            values = { A = "Compact (arrows)", B = "With Bars", C = "Ultra Minimal" },
            order = 4,
        },
        fontSize = {
            type = "range",
            name = "Font Size",
            min = 8, max = 24, step = 1,
            order = 5,
        },
        -- thresholds, colors, etc.
    },
}

LibStub("AceConfig-3.0"):RegisterOptionsTable("WowStatTarget", options)
LibStub("AceConfigDialog-3.0"):AddToBlizOptions("WowStatTarget", "WowStatTarget")
```

**What gets removed:** All manual frame creation code for the settings panel. `UIDropDownMenu` calls. Manual `InterfaceOptions_AddCategory`. The entire hand-built settings UI.

**What stays:** `Settings.lua` still exists but now contains only the options table definition and the `get`/`set` callbacks that read/write `self.db.profile`.

### Phase 5 — Migrate Slash Commands (AceConsole)

**Before:**
```lua
SLASH_WOWSTATTARGET1 = "/wst"
SlashCmdList["WOWSTATTARGET"] = function(msg)
    if msg == "toggle" then ...
    elseif msg == "reset" then ...
    end
end
```

**After:**
```lua
function WowStatTarget:OnInitialize()
    self:RegisterChatCommand("wst", "SlashCommand")
end

function WowStatTarget:SlashCommand(input)
    if input == "toggle" then
        -- toggle window
    elseif input == "reset" then
        self.db:ResetProfile()
    else
        -- Open options
        LibStub("AceConfigDialog-3.0"):Open("WowStatTarget")
    end
end
```

### Phase 6 — Files That Do NOT Change

| File | Why |
|---|---|
| **Data.lua** | Pure data table. No framework dependency. Stays exactly as-is. |
| **UI.lua** (floating window) | The floating stat window is a custom `CreateFrame` with drag support. Ace3 does not provide a replacement for this — AceGUI is for options panels, not HUD overlays. This file stays as custom code. |

### Summary of Changes Per File

| File | Change |
|---|---|
| `WowStatTarget.toc` | Add `embeds.xml` before addon files |
| `embeds.xml` | New file — loads Ace3 libs |
| `Core.lua` | Rewrite to use AceAddon + AceEvent lifecycle |
| `Settings.lua` | Rewrite to use AceConfig options table (much shorter) |
| `UI.lua` | Minor changes — read from `self.db.profile` instead of `WowStatTargetDB` |
| `Data.lua` | No changes |

## 4. How to Embed Ace3 Libraries

### Option A — Using .pkgmeta (recommended for CurseForge/WoWInterface packaging)

Create a `.pkgmeta` file in the repo root:

```yaml
package-as: WowStatTarget

externals:
  Libs/LibStub:
    url: https://repos.curseforge.com/wow/libstub/trunk
    tag: 1.0
  Libs/CallbackHandler-1.0:
    url: https://repos.curseforge.com/wow/callbackhandler/trunk/CallbackHandler-1.0
    tag: 1.0
  Libs/AceAddon-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceAddon-3.0
  Libs/AceEvent-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceEvent-3.0
  Libs/AceDB-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceDB-3.0
  Libs/AceDBOptions-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceDBOptions-3.0
  Libs/AceConsole-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceConsole-3.0
  Libs/AceConfig-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceConfig-3.0
  Libs/AceConfigDialog-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceConfigDialog-3.0
  Libs/AceConfigRegistry-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceConfigRegistry-3.0
  Libs/AceConfigCmd-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceConfigCmd-3.0
  Libs/AceGUI-3.0:
    url: https://repos.curseforge.com/wow/ace3/trunk/AceGUI-3.0
```

The CurseForge packager automatically pulls these during build. Add `Libs/` to `.gitignore` if using this method.

### Option B — Manual Download

1. Download Ace3 from https://www.curseforge.com/wow/addons/ace3 or clone the repo.
2. Copy the individual library folders into `Libs/`.
3. Commit them into your repo (they are small).

### embeds.xml

Create `embeds.xml` in the addon root:

```xml
<Ui xmlns="http://www.blizzard.com/wow/ui/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.blizzard.com/wow/ui/ ..\FrameXML\UI.xsd">

    <Script file="Libs\LibStub\LibStub.lua"/>
    <Include file="Libs\CallbackHandler-1.0\CallbackHandler-1.0.xml"/>
    <Include file="Libs\AceAddon-3.0\AceAddon-3.0.xml"/>
    <Include file="Libs\AceEvent-3.0\AceEvent-3.0.xml"/>
    <Include file="Libs\AceDB-3.0\AceDB-3.0.xml"/>
    <Include file="Libs\AceDBOptions-3.0\AceDBOptions-3.0.xml"/>
    <Include file="Libs\AceConsole-3.0\AceConsole-3.0.xml"/>
    <Include file="Libs\AceGUI-3.0\AceGUI-3.0.xml"/>
    <Include file="Libs\AceConfig-3.0\AceConfig-3.0.xml"/>
    <Include file="Libs\AceConfigDialog-3.0\AceConfigDialog-3.0.xml"/>
    <Include file="Libs\AceConfigRegistry-3.0\AceConfigRegistry-3.0.xml"/>
    <Include file="Libs\AceConfigCmd-3.0\AceConfigCmd-3.0.xml"/>

</Ui>
```

### .toc Update

```toc
## Interface: 110100
## Title: WowStatTarget
## SavedVariables: WowStatTargetDB

embeds.xml

Data.lua
Core.lua
UI.lua
Settings.lua
```

## 5. Example — Core.lua After Migration

```lua
local addonName, ns = ...

-- Create the addon object with mixins
local WowStatTarget = LibStub("AceAddon-3.0"):NewAddon(
    addonName, "AceConsole-3.0", "AceEvent-3.0"
)
ns.addon = WowStatTarget  -- expose to other files via shared namespace

-- AceDB defaults (replaces all manual nil-checking)
local defaults = {
    profile = {
        class = nil,
        spec = nil,
        targets = { crit = 0, haste = 0, mastery = 0, versa = 0 },
        layout = "A",
        fontSize = 12,
        thresholds = { low = 70, high = 90, overcap = 100 },
        colors = {
            gray   = { r = 0.53, g = 0.53, b = 0.53 },
            yellow = { r = 1.0,  g = 0.8,  b = 0.0  },
            green  = { r = 0.0,  g = 1.0,  b = 0.0  },
            red    = { r = 1.0,  g = 0.27, b = 0.27 },
        },
        window = { visible = true, x = 0, y = 0 },
    },
}

function WowStatTarget:OnInitialize()
    -- Initialize database with defaults; "true" = use "Default" profile
    self.db = LibStub("AceDB-3.0"):New("WowStatTargetDB", defaults, true)

    -- Register options (defined in Settings.lua)
    ns.SetupOptions(self)

    -- Register slash command
    self:RegisterChatCommand("wst", "SlashCommand")
end

function WowStatTarget:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "UpdateStats")
    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", "UpdateStats")
    self:RegisterEvent("COMBAT_RATING_UPDATE", "UpdateStats")
    self:RegisterEvent("UNIT_AURA_CHANGED", "OnAuraChanged")

    -- Create/show the floating window (UI.lua)
    ns.CreateFloatingWindow(self)
end

function WowStatTarget:OnAuraChanged(event, unit)
    if unit == "player" then
        self:UpdateStats()
    end
end

function WowStatTarget:UpdateStats()
    local p = self.db.profile
    local stats = {
        crit    = GetCritChance(),
        haste   = UnitSpellHaste("player"),
        mastery = GetMasteryEffect(),
        versa   = GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE),
    }
    ns.RefreshFloatingWindow(stats, p.targets, p)
end

function WowStatTarget:SlashCommand(input)
    input = (input or ""):trim():lower()
    if input == "toggle" then
        ns.ToggleFloatingWindow()
    elseif input == "reset" then
        self.db:ResetProfile()
        self:Print("Settings reset to defaults.")
    elseif input == "help" then
        self:Print("/wst — open settings")
        self:Print("/wst toggle — show/hide window")
        self:Print("/wst reset — reset settings")
    else
        LibStub("AceConfigDialog-3.0"):Open("WowStatTarget")
    end
end
```

## 6. Pros and Cons

### Pros

- **Profile system for free.** Switch settings per character, per spec, copy between characters — zero custom code.
- **Settings UI for free.** AceConfig generates dropdowns, sliders, color pickers, and groups from a table. The current `Settings.lua` manual frame code (often 200+ lines) shrinks to ~80 lines of declarative config.
- **Cleaner event handling.** No raw frame, no `SetScript`, no manual dispatcher. Just `self:RegisterEvent("EVENT", "Method")`.
- **Standard patterns.** Anyone who has worked on a WoW addon recognizes AceAddon lifecycle hooks. Lower barrier for contributors.
- **Easier to extend.** Adding a new option = adding one entry to the options table. No frame layout math.
- **Profiles UI widget.** `AceDBOptions-3.0` gives you a ready-made profile management panel with copy/delete/reset.

### Cons

- **Added weight.** Embedding Ace3 adds ~150 KB to the addon folder. Negligible for disk, but it is not zero.
- **Learning curve.** AceConfig options tables have their own syntax and quirks (ordering, get/set callbacks, handler references). Initial setup takes time.
- **Floating window stays custom.** Ace3 does not help with the HUD overlay window. `UI.lua` remains hand-rolled `CreateFrame` code — Ace3 only helps with the settings panel side.
- **Migration effort.** Rewriting `Core.lua` and `Settings.lua` is not trivial. There will be bugs during the transition. Existing users' SavedVariables need a one-time migration path.
- **Overkill for small addons.** If the addon never grows beyond 4 stat displays and a simple config, the current approach is already clean enough.

## 7. When to Migrate

Migrate when **any** of these become true:

- You want **per-character or per-spec profiles** (the most common trigger).
- The settings panel is growing and maintaining manual UI code is painful.
- You plan to add features like minimap button (LibDBIcon), data broker (LibDataBroker), or localization (AceLocale) — all integrate cleanly with an Ace3 addon.
- Contributors expect Ace3 patterns and are confused by the hand-rolled approach.

**Do not migrate** if the addon is feature-complete, stable, and you have no plans to extend it. The current monolithic approach has fewer moving parts and is easier to reason about for a solo developer.

### Recommended Migration Order

1. AceAddon + AceEvent first (smallest change, biggest cleanup).
2. AceDB second (enables profiles, simplifies defaults).
3. AceConfig + AceConsole last (biggest rewrite, but settings panel code shrinks dramatically).

Each phase can be done independently and tested before moving to the next.
