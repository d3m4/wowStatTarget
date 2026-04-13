-- =============================================================================
-- Data.lua — Class & Spec lookup tables for WowStatTarget
-- =============================================================================
--
-- PURPOSE:
--   This file defines every playable class and specialization in WoW Retail.
--   Other files in the addon (like Settings.lua) read this data to build
--   dropdown menus, validate user choices, etc.
--
--   It contains NO logic — only data. Keeping data separate from code makes
--   the addon easier to maintain: when Blizzard adds a new spec you only
--   touch this one file.
--
-- HOW WOW ADDON FILES COMMUNICATE:
--   Every .lua file listed in your .toc is executed in order by the WoW client.
--   They all receive two implicit arguments via the special `...` (varargs):
--
--     1. addonName  – a string with the addon folder name ("WowStatTarget")
--     2. ns         – a shared table (namespace) that is the SAME object in
--                     every file of your addon. Anything you store on `ns` in
--                     one file is visible in every file loaded after it.
--
--   This is the standard pattern for sharing data between addon files WITHOUT
--   polluting the global Lua environment (which all addons share).
-- =============================================================================

-- Unpack the two implicit arguments that WoW passes to every addon file.
--   `addonName` — the string name of the addon (matches the folder name).
--   `ns`        — the shared namespace table. We attach our data here so
--                 other files (Settings.lua, Core.lua, etc.) can access it.
local addonName, ns = ...

-- =============================================================================
-- ns.ClassSpecData
-- =============================================================================
-- This is the single table that holds everything about classes and specs.
--
-- It has two keys:
--
--   classOrder — An ordered list of class tokens. Lua tables with string keys
--                have NO guaranteed iteration order, so we keep a separate
--                array to control the order items appear in dropdown menus.
--
--   classes    — A dictionary keyed by the class TOKEN (e.g. "DEATHKNIGHT").
--                Tokens are the internal uppercase identifiers WoW uses in its
--                own API (UnitClass, RAID_CLASS_COLORS, etc.). We use them as
--                keys because they are locale-independent — they stay the same
--                whether the player's client is in English, Korean, or French.
--                Each entry contains:
--                  • name  — the human-readable class name (English)
--                  • specs — an ordered list of specialization display names
-- =============================================================================

ns.ClassSpecData = {

    ---------------------------------------------------------------------------
    -- classOrder: controls the sequence of classes in dropdown menus.
    -- We follow roughly alphabetical order here, but you could reorder this
    -- list however you like — the dropdown will respect this sequence.
    ---------------------------------------------------------------------------
    classOrder = {
        "DEATHKNIGHT",
        "DEMONHUNTER",
        "DRUID",
        "EVOKER",
        "HUNTER",
        "MAGE",
        "MONK",
        "PALADIN",
        "PRIEST",
        "ROGUE",
        "SHAMAN",
        "WARLOCK",
        "WARRIOR",
    },

    ---------------------------------------------------------------------------
    -- classes: one entry per playable class.
    --
    -- The KEY is the class token — an all-caps, no-spaces identifier that
    -- matches what WoW's own API functions return. For example:
    --     local _, classToken = UnitClass("player")  -->  "MAGE"
    --
    -- Using tokens as keys lets us do fast lookups and keeps everything
    -- independent of the player's display language.
    ---------------------------------------------------------------------------
    classes = {

        -- =====================================================================
        -- Death Knight — Hero class introduced in Wrath of the Lich King.
        -- Specs: Blood (tank), Frost (melee DPS), Unholy (melee DPS).
        -- =====================================================================
        DEATHKNIGHT = {
            name = "Death Knight",
            specs = {
                "Blood",       -- Tank spec, uses self-healing and shields
                "Frost",       -- Melee DPS, dual-wield or two-handed frost
                "Unholy",      -- Melee DPS, diseases and undead pets
            },
        },

        -- =====================================================================
        -- Demon Hunter — Hero class introduced in Legion.
        -- Only two specs (the only class with just two).
        -- =====================================================================
        DEMONHUNTER = {
            name = "Demon Hunter",
            specs = {
                "Havoc",       -- Melee DPS, high mobility
                "Vengeance",   -- Tank spec, self-healing and sigils
            },
        },

        -- =====================================================================
        -- Druid — The original hybrid class. Four specs covering every role.
        -- =====================================================================
        DRUID = {
            name = "Druid",
            specs = {
                "Balance",     -- Ranged caster DPS (Moonkin form)
                "Feral",       -- Melee DPS (Cat form)
                "Guardian",    -- Tank (Bear form)
                "Restoration", -- Healer
            },
        },

        -- =====================================================================
        -- Evoker — Dracthyr-exclusive class introduced in Dragonflight.
        -- Three specs, including the mid-range Augmentation support spec.
        -- =====================================================================
        EVOKER = {
            name = "Evoker",
            specs = {
                "Devastation",  -- Ranged DPS, fire and blue magic
                "Preservation", -- Healer, time-based healing
                "Augmentation", -- Support DPS, buffs allies' damage
            },
        },

        -- =====================================================================
        -- Hunter — Ranged physical DPS with pets (except Marksmanship).
        -- =====================================================================
        HUNTER = {
            name = "Hunter",
            specs = {
                "Beast Mastery", -- Ranged DPS, strong pet focus
                "Marksmanship",  -- Ranged DPS, precision shots
                "Survival",      -- Melee DPS (changed from ranged in Legion)
            },
        },

        -- =====================================================================
        -- Mage — Pure DPS caster class. Three elemental specs.
        -- =====================================================================
        MAGE = {
            name = "Mage",
            specs = {
                "Arcane", -- Ranged DPS, mana management
                "Fire",   -- Ranged DPS, critical-strike focused
                "Frost",  -- Ranged DPS, slows and shatter combos
            },
        },

        -- =====================================================================
        -- Monk — Introduced in Mists of Pandaria. Covers all three roles.
        -- =====================================================================
        MONK = {
            name = "Monk",
            specs = {
                "Brewmaster", -- Tank, stagger damage over time
                "Mistweaver", -- Healer, melee-range healing
                "Windwalker", -- Melee DPS, martial arts combos
            },
        },

        -- =====================================================================
        -- Paladin — Plate-wearing hybrid. Tank, healer, or melee DPS.
        -- =====================================================================
        PALADIN = {
            name = "Paladin",
            specs = {
                "Holy",        -- Healer, strong single-target healing
                "Protection",  -- Tank, shields and consecration
                "Retribution", -- Melee DPS, holy damage
            },
        },

        -- =====================================================================
        -- Priest — Cloth-wearing caster. Two healing specs and one DPS.
        -- =====================================================================
        PRIEST = {
            name = "Priest",
            specs = {
                "Discipline", -- Healer, absorbs and atonement
                "Holy",       -- Healer, traditional direct healing
                "Shadow",     -- Ranged DPS, void/shadow magic
            },
        },

        -- =====================================================================
        -- Rogue — Pure melee DPS class. Stealth and combo points.
        -- =====================================================================
        ROGUE = {
            name = "Rogue",
            specs = {
                "Assassination", -- Melee DPS, poisons and bleeds
                "Outlaw",        -- Melee DPS, swashbuckler (formerly Combat)
                "Subtlety",      -- Melee DPS, shadow and stealth
            },
        },

        -- =====================================================================
        -- Shaman — Hybrid class with totems. Ranged DPS, melee DPS, healer.
        -- =====================================================================
        SHAMAN = {
            name = "Shaman",
            specs = {
                "Elemental",   -- Ranged DPS, lightning and lava
                "Enhancement", -- Melee DPS, empowered weapons
                "Restoration", -- Healer, water and nature magic
            },
        },

        -- =====================================================================
        -- Warlock — Pure ranged DPS caster. Demons and damage-over-time.
        -- =====================================================================
        WARLOCK = {
            name = "Warlock",
            specs = {
                "Affliction",  -- Ranged DPS, damage-over-time specialist
                "Demonology",  -- Ranged DPS, summons demon army
                "Destruction", -- Ranged DPS, direct fire damage
            },
        },

        -- =====================================================================
        -- Warrior — Plate-wearing melee class. Two DPS specs and one tank.
        -- =====================================================================
        WARRIOR = {
            name = "Warrior",
            specs = {
                "Arms",       -- Melee DPS, big two-handed weapon hits
                "Fury",       -- Melee DPS, dual-wield frenzy
                "Protection", -- Tank, shield and sword
            },
        },
    },
}
