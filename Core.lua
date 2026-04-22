-- =============================================================================
-- WowStatTarget — Core.lua
-- =============================================================================
-- This is the core initialization and stat-reading module for WowStatTarget.
-- It handles:
--   1. Addon initialization and SavedVariables loading
--   2. Event registration and handling
--   3. Reading current player stats from the WoW API
--   4. Utility functions for formatting and color calculation
--   5. Slash command registration
--
-- LEARNING NOTES are marked with [LEARN] throughout this file.
-- =============================================================================

-- =============================================================================
-- [LEARN] THE ADDON SHARED TABLE PATTERN
-- =============================================================================
-- When WoW loads a Lua file that belongs to an addon, it passes two arguments:
--   1. addonName (string) — the folder name of the addon (e.g. "WowStatTarget")
--   2. ns (table)         — a private namespace table shared across ALL Lua
--                           files of THIS addon (and only this addon).
--
-- This namespace table (ns) is the backbone of inter-file communication.
-- Any value you attach to `ns` in Core.lua can be read in UI.lua, Settings.lua,
-- etc., because WoW passes the exact same table reference to every file listed
-- in the .toc manifest.
--
-- This avoids polluting the global Lua environment and prevents name collisions
-- with other addons. Think of `ns` as your addon's private "module system."
-- =============================================================================
local addonName, ns = ...

-- =============================================================================
-- [LEARN] SECRET VALUES (WoW 12.0.5+)
-- =============================================================================
-- Starting with patch 12.0.5 (Midnight, April 2026), Blizzard tightened the
-- "Secret Values" system: APIs that return player stats (GetCritChance,
-- UnitSpellHaste, GetMasteryEffect, GetCombatRatingBonus) will return a
-- *secret number* whenever the player's auras are considered secret (e.g. in
-- certain combat encounters).
--
-- You CAN store or pass a secret number around, but any numeric operation on
-- it (math.floor, +, -, string.format with %d, etc.) while execution is
-- "tainted" by an addon throws:
--   "attempt to perform numeric conversion on a secret number value"
--
-- The global `issecretvalue(v)` is the safe way to check before doing math.
-- On older clients this global doesn't exist, so we fall back to a stub that
-- always reports "not secret" (the old behavior).
-- =============================================================================
local issecretvalue = _G.issecretvalue or function() return false end

-- =============================================================================
-- DEFAULT SETTINGS
-- =============================================================================
-- These defaults are used when the addon is installed for the first time (no
-- SavedVariables file exists yet) or when the user resets to defaults.
--
-- [LEARN] SAVEDVARIABLES
-- WoW has a built-in persistence mechanism called SavedVariables. In your .toc
-- file, you declare a global variable name (e.g. WowStatTargetDB). WoW will:
--   1. On login/reload: load the saved data from disk into that global variable
--      BEFORE your addon's Lua files execute.
--   2. On logout/reload: serialize that global variable back to disk.
--
-- The saved data lives in:
--   WTF/Account/<ACCOUNT>/SavedVariables/WowStatTarget.lua
--
-- If the file doesn't exist yet (fresh install), the global variable will be
-- nil, and we need to initialize it with sensible defaults.
-- =============================================================================
local defaults = {
    class = nil,        -- Player's class (e.g. "MAGE"), nil = not set
    spec = nil,         -- Player's spec (e.g. "Fire"), nil = not set
    targets = {
        crit    = 20,   -- Target crit percentage (default example values)
        haste   = 20,   -- Target haste percentage
        mastery = 20,   -- Target mastery percentage
        versa   = 20,   -- Target versatility percentage
    },
    -- Per-spec saved targets. When the player configures targets for a spec,
    -- they are stored here keyed by "CLASS-Spec" (e.g. "MONK-Windwalker").
    -- When switching specs, the addon looks up saved targets here.
    -- If no entry exists for the new spec, targets reset to defaults and
    -- a warning is printed in chat.
    specTargets = {},
    layout = "A",       -- Layout mode: "A" (compact), "B" (bars), "C" (minimal)
    fontSize = 12,      -- Font size in points
    thresholds = {
        low     = 70,   -- Below this % of target → gray
        high    = 90,   -- Between low and high → yellow; above high → green
        overcap = 100,  -- Above this % of target → red (overcapped)
    },
    colors = {
        -- Colors are stored as RGB float tables (0-1 range), which is what
        -- WoW's API expects for SetTextColor(), SetColorTexture(), etc.
        gray   = { 0.53, 0.53, 0.53 },  -- #888888 — far from target
        yellow = { 1.0,  0.8,  0.0  },  -- #ffcc00 — approaching target
        green  = { 0.0,  1.0,  0.0  },  -- #00ff00 — at or near target
        red    = { 1.0,  0.27, 0.27 },  -- #ff4444 — overcapped
    },
    window = {
        visible = true, -- Whether the floating window is shown
        x = 0,          -- Horizontal offset from center of screen
        y = 0,          -- Vertical offset from center of screen
    },
}

-- =============================================================================
-- DEEP COPY UTILITY
-- =============================================================================
-- We need a deep copy function to duplicate the defaults table. A simple
-- assignment (local copy = defaults) would only copy the reference — both
-- variables would point to the same table in memory. Changes to one would
-- affect the other.
--
-- Deep copy recursively duplicates every nested table so we get a truly
-- independent copy.
-- =============================================================================
local function DeepCopy(source)
    if type(source) ~= "table" then
        return source
    end
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = DeepCopy(value)
    end
    return copy
end

-- =============================================================================
-- MERGE TABLES (defaults into existing saved data)
-- =============================================================================
-- When the addon updates and adds new settings, the user's existing
-- SavedVariables won't have those new keys. This function walks the defaults
-- table and fills in any missing keys in the destination table, without
-- overwriting values the user has already customized.
--
-- Example: if we add a new setting "showTooltip = true" in a future version,
-- this merge will add it to the user's existing DB without touching their
-- other settings.
-- =============================================================================
local function MergeDefaults(destination, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            -- If the destination doesn't have this key or it's not a table,
            -- create a fresh table for it
            if type(destination[key]) ~= "table" then
                destination[key] = {}
            end
            -- Recurse into nested tables
            MergeDefaults(destination[key], value)
        else
            -- Only fill in the value if the destination doesn't have it yet
            if destination[key] == nil then
                destination[key] = value
            end
        end
    end
end

-- =============================================================================
-- [LEARN] EVENT FRAMES — THE HEART OF WOW ADDON DEVELOPMENT
-- =============================================================================
-- WoW addons are event-driven. You don't run code in a loop — instead, you
-- create a Frame, register for specific game events, and WoW calls your
-- OnEvent handler whenever those events fire.
--
-- A Frame is a UI element (even if invisible) that can receive events.
-- Think of it as a "listener" that the game engine notifies.
--
-- The flow is:
--   1. CreateFrame()           → create the frame object
--   2. RegisterEvent("EVENT")  → tell WoW "I care about this event"
--   3. SetScript("OnEvent", fn)→ define what happens when an event fires
--
-- WoW fires MANY events per second during gameplay. By registering only for
-- specific events, we ensure our code runs only when relevant game state
-- changes (gear swap, buff change, etc.) — not every frame.
-- =============================================================================

-- Create an invisible frame to receive events. The frame doesn't need to be
-- visible or have any size — it's purely an event receiver.
local eventFrame = CreateFrame("Frame", "WowStatTargetEventFrame", UIParent)

-- =============================================================================
-- EVENT REGISTRATION
-- =============================================================================
-- We register for four events that indicate the player's stats may have changed:
--
-- PLAYER_ENTERING_WORLD
--   Fires when: the player first logs in, reloads the UI (/reload), enters an
--   instance, or changes zones. This is the main "initialization" event.
--   We use it to load SavedVariables and set up the addon.
--
-- PLAYER_EQUIPMENT_CHANGED
--   Fires when: the player equips or unequips any item. Gear directly affects
--   secondary stats (crit, haste, mastery, versatility on gear).
--   Args: equipmentSlot, hasCurrent — we don't need them, we just re-read stats.
--
-- COMBAT_RATING_UPDATE
--   Fires when: combat ratings change for any reason — gems socketed, enchants
--   applied, set bonuses activated, or rating diminishing returns recalculated.
--   This catches changes that PLAYER_EQUIPMENT_CHANGED might miss.
--
-- UNIT_AURA
--   Fires when: a buff or debuff is applied, removed, or refreshed on any unit.
--   We filter for unit == "player" because we only care about the player's own
--   buffs (e.g. Power Infusion, Bloodlust, food buffs, flask buffs).
--   These temporary effects change stat percentages.
-- =============================================================================
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("COMBAT_RATING_UPDATE")
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

-- =============================================================================
-- CURRENT STATS STORAGE
-- =============================================================================
-- This table holds the player's current stat percentages, updated every time
-- an event fires. Other files (UI.lua, Settings.lua) read from ns.currentStats
-- to display values.
-- =============================================================================
ns.currentStats = {
    crit    = 0,
    haste   = 0,
    mastery = 0,
    versa   = 0,
}

-- =============================================================================
-- ns:UpdateStats() — READ CURRENT PLAYER STATS FROM THE WOW API
-- =============================================================================
-- This function queries the WoW API for the player's current secondary stat
-- percentages and stores them in ns.currentStats.
--
-- [LEARN] WOW STAT API FUNCTIONS:
--
-- GetCritChance()
--   Returns: number — the player's total critical strike chance as a percentage.
--   This includes base crit, crit from rating on gear, crit from buffs, and
--   any other sources. Example return: 28.45 (meaning 28.45% crit chance).
--
-- UnitSpellHaste("player")
--   Returns: number — the player's total spell haste as a percentage.
--   Despite the name "SpellHaste", this returns the general haste value that
--   affects both spells and melee for most classes in modern WoW.
--   Example return: 25.12 (meaning 25.12% haste).
--
-- GetMasteryEffect()
--   Returns: masteryEffect, bonusCoefficient — two numbers.
--   masteryEffect is the total mastery percentage (what we want).
--   bonusCoefficient is the spec-specific scaling factor (we ignore it).
--   Example return: 48.30, 2.5
--   We use select(1, ...) or just take the first value.
--
-- GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE)
--   Returns: number — the versatility damage bonus percentage.
--   CR_VERSATILITY_DAMAGE_DONE is a global constant defined by WoW that
--   identifies the versatility combat rating for damage output.
--   Note: versatility has two components — damage done and damage reduction.
--   The damage reduction is always half of the damage bonus. We track the
--   damage bonus since that's what players typically optimize for.
--   Example return: 2.15 (meaning 2.15% bonus damage from versatility).
-- =============================================================================
function ns:UpdateStats()
    -- [LEARN] 12.0.5 SECRET-VALUE GUARD
    -- Each of these APIs may now return a "secret number" (see the note at
    -- the top of this file). We read the return value into a local first,
    -- check if it is secret, and only overwrite our stored stat when it is
    -- a plain number. If it *is* secret, we keep the last known good value,
    -- so the UI shows slightly stale — but always renderable — data.
    local crit = GetCritChance()
    if not issecretvalue(crit) then
        self.currentStats.crit = crit
    end

    local haste = UnitSpellHaste("player")
    if not issecretvalue(haste) then
        self.currentStats.haste = haste
    end

    -- GetMasteryEffect() returns two values; we only want the first one.
    -- The parentheses around the call discard the second return value.
    local mastery = (GetMasteryEffect())
    if not issecretvalue(mastery) then
        self.currentStats.mastery = mastery
    end

    -- CR_VERSATILITY_DAMAGE_DONE is a WoW global constant (number).
    -- GetCombatRatingBonus() converts a combat rating into its percentage bonus.
    local versa = GetCombatRatingBonus(CR_VERSATILITY_DAMAGE_DONE)
    if not issecretvalue(versa) then
        self.currentStats.versa = versa
    end
end

-- =============================================================================
-- ns:GetStatColor(current, target) — DETERMINE COLOR BASED ON THRESHOLDS
-- =============================================================================
-- Compares the current stat value against the target and returns the
-- appropriate color (r, g, b) based on the user's threshold settings.
--
-- The ratio formula: (current / target) * 100
--   - Below 'low' threshold (default 70%)  → gray  (far from target)
--   - Between 'low' and 'high' (70-90%)    → yellow (approaching)
--   - Between 'high' and 'overcap' (90-100%) → green (at target)
--   - Above 'overcap' (>100%)              → red   (overcapped, wasted stats)
--
-- Returns: r, g, b (three floats 0-1) or nil if target is 0.
--
-- When target is 0, returning nil signals to the UI that this stat should
-- be hidden entirely (avoids division by zero and indicates the user hasn't
-- set a target for this stat).
-- =============================================================================
function ns:GetStatColor(current, target)
    -- If target is 0, the stat is not configured — return nil to hide it
    if target == 0 then
        return nil
    end

    -- Calculate how close the player is to their target (as a percentage)
    local ratio = (current / target) * 100

    -- Read threshold values from the user's saved settings
    local thresholds = self.db.thresholds
    local colors     = self.db.colors

    -- Determine which color band the ratio falls into
    if ratio >= thresholds.overcap then
        -- Player has MORE than the target — stats are wasted ("overcapped")
        return colors.red[1], colors.red[2], colors.red[3]
    elseif ratio >= thresholds.high then
        -- Player is close to or at the target — good shape
        return colors.green[1], colors.green[2], colors.green[3]
    elseif ratio >= thresholds.low then
        -- Player is approaching the target but not there yet
        return colors.yellow[1], colors.yellow[2], colors.yellow[3]
    else
        -- Player is far below the target
        return colors.gray[1], colors.gray[2], colors.gray[3]
    end
end

-- =============================================================================
-- ns:FormatStatValue(value) — FORMAT A SINGLE STAT NUMBER
-- =============================================================================
-- Formats a numeric stat value according to the addon's display rules:
--   - Minimum 2 digits (values < 10 get a leading zero: 5 → "05")
--   - Maximum 3 digits (values >= 1000 are clamped to 999: 1234 → "999")
--   - No decimal places — we floor the value to an integer
--   - No spaces — just the raw digits
--
-- Examples:
--   FormatStatValue(5.7)    → "05"
--   FormatStatValue(28.45)  → "28"
--   FormatStatValue(100.1)  → "100"
--   FormatStatValue(1500)   → "999"
-- =============================================================================
function ns:FormatStatValue(value)
    -- Floor to integer — we don't show decimal places
    local intValue = math.floor(value)

    -- Clamp to maximum of 999 (3-digit display limit)
    if intValue > 999 then
        intValue = 999
    end

    -- Ensure negative values don't produce weird output (shouldn't happen
    -- with WoW stats, but defensive programming is good practice)
    if intValue < 0 then
        intValue = 0
    end

    -- Format with leading zero for single-digit values (%02d = at least 2
    -- digits, zero-padded), but allow 3 digits naturally
    if intValue >= 100 then
        -- 3-digit number: no padding needed
        return string.format("%d", intValue)
    else
        -- 1 or 2-digit number: pad to exactly 2 digits with leading zero
        return string.format("%02d", intValue)
    end
end

-- =============================================================================
-- ns:FormatStatPair(current, target) — FORMAT A "CURRENT/TARGET %" STRING
-- =============================================================================
-- Produces a display string like "  28/31 %" for showing in the floating window.
--
-- The format rules are:
--   - Slash is tight against both numbers (no spaces around the slash)
--   - A " %" suffix with a space before the percent sign
--   - Left-padded with spaces so that the result is right-aligned
--   - Total width is consistent: the "current/target" portion is right-aligned
--     within a 7-character field (e.g. "  28/31" or "100/148" or "  05/02")
--
-- The 7-character width accommodates the widest case: "999/999" (3+1+3 = 7).
-- Shorter values get leading spaces for alignment.
--
-- Examples:
--   FormatStatPair(28.4, 31)   → "  28/31 %"
--   FormatStatPair(100.1, 148) → "100/148 %"
--   FormatStatPair(5.7, 2.1)   → "  05/02 %"
-- =============================================================================
function ns:FormatStatPair(current, target)
    -- Format each number individually using our rules
    local currentStr = self:FormatStatValue(current)
    local targetStr  = self:FormatStatValue(target)

    -- Build the "current/target" portion
    local pair = currentStr .. "/" .. targetStr

    -- Right-align the pair within a 7-character field, then append " %"
    -- %7s = right-align the string within 7 characters, padding with spaces
    return string.format("%7s %%", pair)
end

-- =============================================================================
-- EVENT HANDLER
-- =============================================================================
-- This is the central event dispatcher. WoW calls this function every time one
-- of our registered events fires. The first argument is always `self` (the
-- frame), the second is the event name (string), and subsequent arguments are
-- event-specific payload data.
--
-- [LEARN] HOW THE EVENT SYSTEM WORKS:
-- When you call frame:SetScript("OnEvent", handler), WoW stores a reference
-- to your handler function. Every time a registered event fires, WoW's C++
-- engine calls your Lua handler with:
--   handler(self, event, ...)
-- where `...` are event-specific arguments (e.g., for UNIT_AURA,
-- the first arg is the unitID like "player" or "target").
--
-- You typically use an if/elseif chain or a dispatch table to route each
-- event to the appropriate logic.
--
-- [LEARN] THROTTLING:
-- Events like UNIT_AURA and COMBAT_RATING_UPDATE can fire dozens of times
-- per second (e.g. entering a group, receiving buffs). Updating the UI on
-- every single event would waste CPU. We use a simple throttle: schedule
-- one update 0.1s in the future and ignore events until it runs.
-- =============================================================================
local pendingUpdate = false

local function ScheduleStatUpdate()
    if pendingUpdate then return end
    pendingUpdate = true
    C_Timer.After(0.1, function()
        pendingUpdate = false
        if ns.UpdateStats then ns:UpdateStats() end
        if ns.UpdateUI then ns:UpdateUI() end
    end)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        -- =================================================================
        -- INITIALIZATION
        -- =================================================================
        -- [LEARN] PLAYER_ENTERING_WORLD fires on login, /reload, AND every
        -- zone transition (entering dungeons, joining groups, etc.).
        -- We use a flag to distinguish the first load from subsequent ones.
        -- SavedVariables init and spec detection only run ONCE.
        -- Stats + UI refresh run every time (stats may change with zone).
        -- =================================================================

        if not ns._initialized then
            -- ---- FIRST LOAD ONLY ----
            ns._initialized = true

            if WowStatTargetDB == nil then
                WowStatTargetDB = DeepCopy(defaults)
            else
                MergeDefaults(WowStatTargetDB, defaults)
            end

            ns.db = WowStatTargetDB

            -- Auto-detect class and spec on login.
            local specIndex = GetSpecialization()
            if specIndex then
                local _, specName, _, _, _, classFile = GetSpecializationInfo(specIndex)
                if classFile and specName then
                    ns.db.class = classFile
                    ns.db.spec  = specName

                    -- Load per-spec targets if they exist (silently).
                    local specKey = classFile .. "-" .. specName
                    ns.db.specTargets = ns.db.specTargets or {}
                    if ns.db.specTargets[specKey] then
                        ns.db.targets = DeepCopy(ns.db.specTargets[specKey])
                    end
                end
            end
        end

        -- ---- EVERY LOAD (including zone changes) ----
        -- Re-read stats and refresh UI. Stats can change between zones
        -- (e.g. buffs falling off).
        ns:UpdateStats()

        -- Create the floating window once; skip on subsequent loads.
        if ns.CreateMainWindow and not ns.mainFrame then
            ns:CreateMainWindow()
        end

        if ns.UpdateUI then
            ns:UpdateUI()
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- =================================================================
        -- SPEC CHANGE DETECTION
        -- =================================================================
        -- [LEARN] PLAYER_SPECIALIZATION_CHANGED fires whenever ANY unit the
        -- client knows about switches specialization — the player themselves,
        -- AND every party/raid member whose spec info streams in (e.g. as
        -- they come into range, join the group, or zone in).
        --
        -- The first variadic argument is the unitID of the unit that changed.
        -- We must filter on it, otherwise every raid member's spec update
        -- triggers a "Loaded saved targets" message for OUR spec.
        --
        -- Same pattern as UNIT_AURA below.
        --
        -- We use this to:
        --   1. Save the current targets under the OLD spec key
        --   2. Detect the new class/spec
        --   3. Look up saved targets for the new spec
        --   4. If found → load them; if not → reset to defaults + warn
        -- =================================================================

        local unit = ...
        if unit ~= "player" then
            return  -- Spec change on some other raid/party member — ignore.
        end

        if ns.db then
            -- Save current targets under the old spec key before switching.
            -- The key format is "CLASS-Spec" (e.g. "MONK-Windwalker").
            local oldClass = ns.db.class
            local oldSpec  = ns.db.spec
            if oldClass and oldSpec then
                local oldKey = oldClass .. "-" .. oldSpec
                ns.db.specTargets = ns.db.specTargets or {}
                ns.db.specTargets[oldKey] = DeepCopy(ns.db.targets)
            end

            -- Detect new class and spec using WoW API.
            -- GetSpecialization() returns the current spec INDEX (1, 2, 3, or 4).
            -- GetSpecializationInfo() returns details about that spec.
            local specIndex = GetSpecialization()
            if specIndex then
                local _, newSpecName, _, _, _, newClassFile = GetSpecializationInfo(specIndex)
                local newKey = newClassFile .. "-" .. newSpecName

                -- Update class/spec in saved settings.
                ns.db.class = newClassFile
                ns.db.spec  = newSpecName

                -- Look up saved targets for the new spec.
                ns.db.specTargets = ns.db.specTargets or {}
                if ns.db.specTargets[newKey] then
                    -- Found saved targets for this spec — load them.
                    ns.db.targets = DeepCopy(ns.db.specTargets[newKey])
                    print("|cff00ccffWowStatTarget:|r Loaded saved targets for " .. newSpecName .. ".")
                else
                    -- No saved targets for this spec — reset to defaults and warn.
                    ns.db.targets = DeepCopy(defaults.targets)
                    print("|cffff4444WowStatTarget:|r No saved targets for |cffffffff" .. newSpecName .. "|r. Using defaults — configure via /wst")
                end
            end

            -- Re-read stats (they change with spec) and refresh UI.
            ns:UpdateStats()
            if ns.UpdateUI then
                ns:UpdateUI()
            end

            -- Refresh settings panel if open.
            if ns.RefreshSettingsValues then
                ns:RefreshSettingsValues()
            end
        end

    elseif event == "UNIT_AURA" then
        -- =================================================================
        -- BUFF/DEBUFF CHANGE
        -- =================================================================
        -- UNIT_AURA fires for ALL units (player, target, party
        -- members, etc.). We only care about the player's own auras.
        --
        -- The first variadic argument (...) is the unitID that was affected.
        -- We destructure it and check if it's "player" before proceeding.
        -- =================================================================
        local unit = ...
        if unit ~= "player" then
            return  -- Not the player's aura — ignore this event
        end

        -- Player's buffs/debuffs changed — schedule a throttled update.
        ScheduleStatUpdate()

    else
        -- =================================================================
        -- PLAYER_EQUIPMENT_CHANGED / COMBAT_RATING_UPDATE
        -- =================================================================
        -- Both of these events can fire rapidly (e.g. equipping a full set,
        -- entering a group and receiving many buffs). We throttle updates
        -- to avoid unnecessary CPU usage.
        -- =================================================================
        ScheduleStatUpdate()
    end
end)

-- =============================================================================
-- RESET TO DEFAULTS
-- =============================================================================
-- Replaces the current saved settings with a fresh copy of the defaults.
-- Called when the user types "/wst reset".
-- =============================================================================
function ns:ResetToDefaults()
    -- Wipe the existing SavedVariables and replace with fresh defaults
    WowStatTargetDB = DeepCopy(defaults)

    -- Update our reference to point to the new table
    self.db = WowStatTargetDB

    -- Refresh everything with the new settings
    self:UpdateStats()
    if self.UpdateUI then
        self:UpdateUI()
    end

    print("|cff00ccffWowStatTarget:|r Settings reset to defaults.")
end

-- =============================================================================
-- [LEARN] SLASH COMMANDS
-- =============================================================================
-- WoW's slash command system is simpler than you might expect. To register a
-- slash command, you:
--   1. Set SLASH_COMMANDNAME1 = "/yourcommand"
--      (the global variable name MUST follow the pattern SLASH_<NAME><NUMBER>)
--      You can register multiple aliases: SLASH_COMMANDNAME1, SLASH_COMMANDNAME2
--   2. Set SlashCmdList["COMMANDNAME"] = function(msg) ... end
--      The function receives the text typed after the command as `msg`.
--
-- For example, if the user types "/wst toggle", msg will be "toggle".
-- If they type "/wst" with nothing after it, msg will be "" (empty string).
--
-- The name "WOWSTATTARGET" in SLASH_WOWSTATTARGET1 and
-- SlashCmdList["WOWSTATTARGET"] must match exactly (case-sensitive).
-- =============================================================================

-- Register the slash command "/wst"
SLASH_WOWSTATTARGET1 = "/wst"

SlashCmdList["WOWSTATTARGET"] = function(msg)
    -- Normalize the input: trim whitespace and convert to lowercase
    -- This way "Toggle", "TOGGLE", and "toggle" all work the same.
    msg = (msg or ""):trim():lower()

    if msg == "" then
        -- =====================================================================
        -- No arguments: open the settings panel
        -- =====================================================================
        -- ns:OpenSettings() is defined in Settings.lua. If it hasn't been
        -- loaded yet (shouldn't happen, but defensive), we print a message.
        if ns.OpenSettings then
            ns:OpenSettings()
        else
            print("|cff00ccffWowStatTarget:|r Settings panel not loaded yet.")
        end

    elseif msg == "toggle" then
        -- =====================================================================
        -- Toggle the floating window visibility
        -- =====================================================================
        if ns.db then
            ns.db.window.visible = not ns.db.window.visible
        end
        if ns.UpdateUI then
            ns:UpdateUI()
        end
        -- Feedback to the user
        local state = (ns.db and ns.db.window.visible) and "shown" or "hidden"
        print("|cff00ccffWowStatTarget:|r Window " .. state .. ".")

    elseif msg == "reset" then
        -- =====================================================================
        -- Reset all settings to defaults
        -- =====================================================================
        ns:ResetToDefaults()

    elseif msg == "help" then
        -- =====================================================================
        -- Print available commands
        -- =====================================================================
        -- The |cff______ codes are WoW's inline color escape sequences:
        --   |cffRRGGBB = start coloring text with hex color RRGGBB
        --   |r         = reset to default color
        -- 00ccff = cyan-ish blue, ffcc00 = yellow
        print("|cff00ccffWowStatTarget|r commands:")
        print("  |cffffcc00/wst|r — Open settings panel")
        print("  |cffffcc00/wst toggle|r — Show/hide the floating window")
        print("  |cffffcc00/wst reset|r — Reset all settings to defaults")
        print("  |cffffcc00/wst help|r — Show this help message")

    else
        -- =====================================================================
        -- Unknown subcommand — nudge the user toward /wst help
        -- =====================================================================
        print("|cff00ccffWowStatTarget:|r Unknown command '" .. msg .. "'. Type |cffffcc00/wst help|r for a list of commands.")
    end
end

-- =============================================================================
-- EXPOSE DEFAULTS FOR OTHER MODULES
-- =============================================================================
-- Other files (e.g., Settings.lua) might need access to the original defaults
-- for comparison or for building UI elements. We store a reference on the
-- namespace table. Note: these are the ORIGINAL defaults, not a copy — don't
-- modify them directly.
-- =============================================================================
ns.defaults = defaults

-- =============================================================================
-- END OF Core.lua
-- =============================================================================
-- At this point, the addon is fully initialized:
--   - The event frame is listening for stat-changing events
--   - The namespace (ns) has all core functions attached
--   - The slash command /wst is registered
--
-- When PLAYER_ENTERING_WORLD fires (shortly after login), the event handler
-- will load SavedVariables, read stats, and trigger the first UI update.
--
-- The flow continues in UI.lua (floating window) and Settings.lua (options).
-- =============================================================================
