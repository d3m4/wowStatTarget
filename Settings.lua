-- =============================================================================
-- Settings.lua — Settings / Options Panel for WowStatTarget
-- =============================================================================
--
-- PURPOSE:
--   Creates the addon's configuration UI. This panel lets the user choose a
--   class/spec, set target stat percentages, pick a layout mode, tweak colors
--   and thresholds, and adjust font size. Every change is saved immediately to
--   the SavedVariables database (ns.db) and the floating window is refreshed.
--
-- HOW IT'S OPENED:
--   1. The slash command `/wst` (registered in Core.lua) calls ns:OpenSettings()
--   2. Blizzard's Interface → AddOns → WowStatTarget also opens this panel
--   3. Pressing Escape closes it (we add the frame to UISpecialFrames)
--
-- WIDGET OVERVIEW (for learning):
--   WoW provides several built-in widget types. This file uses:
--
--   • Frame            — A generic container. Our settings panel IS a Frame.
--   • UIDropDownMenu   — A dropdown selector. Uses a two-step pattern:
--                         1. Create with CreateFrame("Frame", name, parent,
--                            "UIDropDownMenuTemplate")
--                         2. Set an "initialize" function via
--                            UIDropDownMenu_Initialize(). This function is
--                            called every time the menu opens, and it builds
--                            the list of items by creating "info" tables and
--                            passing them to UIDropDownMenu_AddButton().
--                         3. Each info table has fields like .text, .value,
--                            .func (click handler), .checked, etc.
--                         4. UIDropDownMenu_SetSelectedValue() updates the
--                            displayed text after a selection.
--   • EditBox           — A text input field. Key scripts:
--                         - OnTextChanged: fires every keystroke
--                         - OnEnterPressed: fires when user hits Enter
--                         - OnEscapePressed: fires when user hits Escape
--                           (convention: clear focus so keyboard goes back
--                            to the game)
--                         - SetNumeric(true): restricts input to digits only
--   • Slider            — A draggable bar for numeric ranges. Key methods:
--                         - SetMinMaxValues(min, max)
--                         - SetValueStep(step)
--                         - SetObeyStepOnDrag(true): snaps to step increments
--                         - OnValueChanged script: fires when the user drags
--   • Button            — A clickable button. We use the standard
--                         "UIPanelButtonTemplate" for consistent look.
--   • FontString         — A text label. Created via frame:CreateFontString().
--   • Texture            — An image/color swatch. Created via
--                         frame:CreateTexture().
--
-- REGISTERING WITH BLIZZARD'S OPTIONS (Retail 10.x+ / 11.x):
--   Retail WoW replaced the old InterfaceOptions system with a new Settings
--   API. The pattern is:
--     1. Create a Settings.RegisterCanvasLayoutCategory() or use the newer
--        Settings.RegisterAddOnCategory() depending on the exact build.
--     2. However, for maximum compatibility (10.0 through 11.x), many addons
--        still use the older InterfaceOptions_AddCategory() fallback if the
--        new API is unavailable.
--   In this file we use the modern Settings API with a fallback.
--
-- ESCAPE-TO-CLOSE:
--   WoW has a global table called `UISpecialFrames`. Any frame whose NAME
--   (a global string) is inserted into this table will automatically close
--   when the player presses Escape. Two requirements:
--     1. The frame must have a GLOBAL name (the second arg to CreateFrame)
--     2. That name string must be inserted into UISpecialFrames
--   We do both in CreateSettingsPanel().
-- =============================================================================

local addonName, ns = ...

-- =============================================================================
-- UTILITY: Hex ↔ RGB Conversion
-- =============================================================================

--- Converts a hex color string to WoW RGB floats (0.0 – 1.0).
-- Accepts formats: "#ff0000", "ff0000", "#FF0000", "FF0000"
--
-- How it works:
--   1. Strip the leading "#" if present.
--   2. Use tonumber(str, 16) to parse each 2-char hex pair as base-16.
--   3. Divide by 255 to get a float in the 0–1 range that WoW expects.
--
-- @param hex string — The hex color (e.g. "#ff0000")
-- @return number, number, number — Red, Green, Blue as floats (0.0 – 1.0)
function ns:HexToRGB(hex)
    -- Remove the "#" prefix if present
    hex = hex:gsub("^#", "")

    -- Parse each pair of hex digits.
    -- string.sub extracts 2 characters at a time (positions 1-2, 3-4, 5-6).
    -- tonumber(..., 16) converts the hex string to a decimal integer.
    local r = tonumber(hex:sub(1, 2), 16) or 0
    local g = tonumber(hex:sub(3, 4), 16) or 0
    local b = tonumber(hex:sub(5, 6), 16) or 0

    -- WoW color APIs expect floats 0.0–1.0, not 0–255
    return r / 255, g / 255, b / 255
end

--- Converts WoW RGB floats (0.0 – 1.0) to a hex color string.
-- This is the inverse of HexToRGB.
--
-- How it works:
--   1. Multiply each float by 255 and round to the nearest integer.
--   2. Use string.format with %02x to produce a zero-padded 2-digit hex.
--   3. Prepend "#" for consistency.
--
-- @param r number — Red (0.0 – 1.0)
-- @param g number — Green (0.0 – 1.0)
-- @param b number — Blue (0.0 – 1.0)
-- @return string — Hex color (e.g. "#ff0000")
function ns:RGBToHex(r, g, b)
    -- math.floor(x + 0.5) is a common rounding trick in Lua 5.1 (WoW's Lua).
    -- Lua 5.1 doesn't have a built-in math.round().
    local ri = math.floor((r or 0) * 255 + 0.5)
    local gi = math.floor((g or 0) * 255 + 0.5)
    local bi = math.floor((b or 0) * 255 + 0.5)

    -- %02x = at least 2 hex digits, zero-padded, lowercase
    return string.format("#%02x%02x%02x", ri, gi, bi)
end

-- =============================================================================
-- HELPER: Create a standard section label (title/header inside the panel)
-- =============================================================================
-- This is a small factory function to avoid repeating label-creation code.
-- It creates a FontString with the "GameFontNormalLarge" template, which is
-- one of WoW's built-in font styles (bold, slightly larger than body text).
--
-- @param parent  Frame  — The parent frame to attach the label to
-- @param text    string — The label text
-- @param anchor  table  — A table of anchor arguments: {point, relativeTo,
--                          relativePoint, x, y}
-- @return FontString — The created label
local function CreateSectionLabel(parent, text, anchor)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint(unpack(anchor))
    label:SetText(text)
    return label
end

-- =============================================================================
-- HELPER: Create a labeled numeric EditBox
-- =============================================================================
-- Many of our settings use the same pattern: a label + a small numeric input.
-- This factory creates both and returns the EditBox so the caller can hook
-- up OnTextChanged logic.
--
-- HOW EDITBOX WORKS:
--   An EditBox is a Frame subtype that accepts keyboard input. Key concepts:
--   - SetNumeric(true) restricts the user to typing digits only (0-9).
--     Unfortunately SetNumeric does NOT allow decimal points, so if you need
--     decimals you'd use SetScript("OnTextChanged") to validate instead.
--   - SetAutoFocus(false) prevents the EditBox from stealing keyboard focus
--     when the panel opens. Without this the player couldn't move with WASD
--     because the EditBox would be capturing all keys.
--   - SetMaxLetters(n) limits input length (we use 3 for stat percents).
--   - Scripts:
--       OnEscapePressed → convention is to call :ClearFocus() so the user's
--                          keyboard returns to normal game control.
--       OnEnterPressed  → same convention: clear focus after confirming.
--       OnTextChanged   → fires on every keystroke; this is where we save
--                          the value and update the UI.
--
-- @param parent  Frame    — Parent frame
-- @param label   string   — The text label shown above or beside the input
-- @param anchor  table    — Anchor arguments for the LABEL position
-- @param width   number   — Width of the EditBox in pixels
-- @param maxLen  number   — Max number of characters allowed
-- @return FontString, EditBox — The label and the EditBox
local function CreateLabeledEditBox(parent, labelText, anchor, width, maxLen)
    -- Create the text label using a standard WoW font template.
    -- "GameFontHighlight" is white body text — good for field labels.
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint(unpack(anchor))
    label:SetText(labelText)

    -- Create the EditBox using WoW's built-in template.
    -- "InputBoxTemplate" gives us a bordered input field with standard visuals.
    -- The first arg (nil) means no global name — we don't need one since we
    -- won't reference this EditBox from other addons or XML.
    local editBox = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    editBox:SetSize(width, 22)
    -- Position the EditBox to the right of its label
    editBox:SetPoint("LEFT", label, "RIGHT", 8, 0)
    editBox:SetAutoFocus(false)  -- IMPORTANT: don't steal keyboard on show
    editBox:SetMaxLetters(maxLen or 3)

    -- Standard Escape/Enter behavior: release keyboard focus
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    return label, editBox
end

-- =============================================================================
-- HELPER: Create a small color swatch (Texture)
-- =============================================================================
-- A swatch is a tiny colored square that previews a color. We create it as a
-- Texture object attached to the parent frame.
--
-- Textures in WoW can either display an image file or a solid color.
-- SetColorTexture(r, g, b, a) fills the texture with a flat color — no image
-- file needed. This is perfect for color previews.
--
-- @param parent  Frame  — Parent frame
-- @param size    number — Width and height in pixels
-- @param r, g, b number — Initial color (WoW floats 0–1)
-- @return Texture — The created swatch
local function CreateColorSwatch(parent, size, r, g, b)
    local swatch = parent:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(size, size)
    -- SetColorTexture fills the texture with a flat solid color.
    -- Arguments: red, green, blue, alpha (all 0.0–1.0).
    swatch:SetColorTexture(r or 0.5, g or 0.5, b or 0.5, 1.0)
    return swatch
end

-- =============================================================================
-- HELPER: Validate a hex color string
-- =============================================================================
-- Returns true if the string is a valid 6-digit hex color (with or without #).
-- We use a Lua pattern: %x matches any hexadecimal digit (0-9, a-f, A-F).
--
-- @param hex string — The string to validate
-- @return boolean — true if valid hex color
local function IsValidHex(hex)
    if not hex or type(hex) ~= "string" then return false end
    -- Strip leading #
    local clean = hex:gsub("^#", "")
    -- Must be exactly 6 hex digits
    return #clean == 6 and clean:match("^%x%x%x%x%x%x$") ~= nil
end

-- =============================================================================
-- ns:OpenSettings()
-- =============================================================================
-- Shows the settings panel. If it hasn't been created yet, we build it first.
-- Called from Core.lua when the user types `/wst`.
function ns:OpenSettings()
    -- Lazy initialization: only build the panel the first time it's needed.
    -- This avoids doing UI work at addon load time, which can slow login.
    if not ns.settingsPanel then
        ns:CreateSettingsPanel()
    end

    -- Show the panel and bring it to the front
    ns.settingsPanel:Show()
    ns.settingsPanel:Raise()

    -- Refresh all input fields to match current saved values.
    -- This ensures that if the user changed something via slash commands or
    -- another path, the panel shows the up-to-date state.
    ns:RefreshSettingsValues()
end

-- =============================================================================
-- ns:CreateSettingsPanel()
-- =============================================================================
-- Builds the entire settings UI. This is a large function because it creates
-- every widget and wires up all the event handlers. It is called ONCE, the
-- first time the user opens settings.
--
-- The panel is a standard WoW Frame that floats in the center of the screen.
-- It is NOT embedded inside Blizzard's Settings window — instead, we register
-- a category that opens our standalone panel when clicked in Interface Options.
function ns:CreateSettingsPanel()

    -- =========================================================================
    -- 1. CREATE THE MAIN FRAME
    -- =========================================================================
    -- CreateFrame(frameType, globalName, parent, template)
    --   - "Frame" is the base frame type (a simple container)
    --   - "WowStatTargetSettingsPanel" is a GLOBAL name. We need a global name
    --     for two reasons:
    --       a) UISpecialFrames requires it (Escape-to-close)
    --       b) It helps with debugging (/fstack shows global names)
    --   - UIParent is the root frame that covers the entire screen
    --   - "BasicFrameTemplateWithInset" gives us a title bar, close button,
    --     border, and a slightly inset content area — all for free
    local panel = CreateFrame("Frame", "WowStatTargetSettingsPanel", UIParent,
                              "BasicFrameTemplateWithInset")

    -- Set the panel size. 520 wide is enough for our controls; 620 tall to
    -- fit everything without scrolling.
    panel:SetSize(520, 640)

    -- Center the panel on screen. The user can reposition it by dragging.
    panel:SetPoint("CENTER")

    -- Start hidden — we show it only when the user opens settings.
    panel:Hide()

    -- =========================================================================
    -- ESCAPE TO CLOSE
    -- =========================================================================
    -- UISpecialFrames is a global Lua table maintained by Blizzard's UI code.
    -- During the Escape key handler, WoW iterates this table and hides any
    -- frame whose global name matches an entry. By inserting our frame's name,
    -- pressing Escape will hide our settings panel.
    --
    -- Requirements:
    --   1. The frame MUST have a global name (second arg to CreateFrame)
    --   2. You insert the NAME (a string), not the frame object itself
    tinsert(UISpecialFrames, "WowStatTargetSettingsPanel")

    -- =========================================================================
    -- MAKE THE PANEL DRAGGABLE
    -- =========================================================================
    -- To make a frame draggable, we need three things:
    --   1. SetMovable(true) — tells the frame it's allowed to move
    --   2. EnableMouse(true) — lets the frame receive mouse events
    --   3. Mouse scripts that call StartMoving/StopMovingOrSizing
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)

    -- =========================================================================
    -- TITLE BAR TEXT
    -- =========================================================================
    -- BasicFrameTemplateWithInset creates a TitleBg region but no text.
    -- We add our own title FontString.
    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    panel.title:SetPoint("TOP", panel.TitleBg, "TOP", 0, -3)
    panel.title:SetText("WowStatTarget Settings")

    -- Store the panel on the namespace so other files can reference it.
    ns.settingsPanel = panel

    -- =========================================================================
    -- CONTENT AREA
    -- =========================================================================
    -- We'll use panel.InsetBg (or panel.Inset) as the visual content area.
    -- All our widgets are children of `panel` but positioned relative to the
    -- Inset so they sit inside the bordered area.
    -- We'll define a content anchor for positioning: top-left of the inset
    -- with some padding.

    -- Starting Y offset from the top of the panel for our first widget.
    -- We leave room for the title bar (~30px).
    local contentTop = -35
    local leftMargin = 20
    local lineSpacing = 30  -- vertical space between rows of controls (was 45)

    -- =========================================================================
    -- CONTENT CONTAINER
    -- =========================================================================
    -- All widgets are placed directly inside the panel (no scroll frame).
    -- We keep spacing tight so everything fits without scrolling.
    local scrollChild = panel  -- alias so we don't rename every widget reference

    -- currentY tracks the vertical offset as we add widgets top-to-bottom.
    local currentY = contentTop - 5

    -- =========================================================================
    -- 2. CLASS DROPDOWN
    -- =========================================================================
    -- Section label
    CreateSectionLabel(scrollChild, "Class & Specialization", {"TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY})
    currentY = currentY - 25

    -- -------------------------------------------------------------------
    -- HOW UIDropDownMenu WORKS (detailed explanation):
    -- -------------------------------------------------------------------
    -- UIDropDownMenu is WoW's built-in dropdown widget. It works differently
    -- from most UI frameworks — it uses a CALLBACK pattern:
    --
    -- Step 1: Create the dropdown frame with the "UIDropDownMenuTemplate".
    --         This gives you the visual button with an arrow.
    --
    -- Step 2: Call UIDropDownMenu_Initialize(dropdown, initFunc).
    --         `initFunc` is a function that WoW calls EVERY TIME the dropdown
    --         menu needs to display its items (when clicked open). Inside this
    --         function you:
    --           a) Create an "info" table via UIDropDownMenu_CreateInfo()
    --           b) Set fields on the info table:
    --              - info.text     = display string
    --              - info.value    = internal value (stored, not displayed)
    --              - info.func     = function called when this item is clicked
    --              - info.checked  = whether to show a checkmark
    --              - info.arg1/arg2 = extra data passed to info.func
    --           c) Call UIDropDownMenu_AddButton(info) to add the item
    --           d) Repeat for each item
    --
    -- Step 3: In the click handler (info.func), you typically:
    --           a) Call UIDropDownMenu_SetSelectedValue(dropdown, value)
    --              to update the displayed text
    --           b) Save the selected value to your database
    --           c) Do any side effects (like refreshing another dropdown)
    --
    -- Note: UIDropDownMenu_SetSelectedValue vs UIDropDownMenu_SetText:
    --   - SetSelectedValue stores a .selectedValue and updates display
    --   - SetText only changes the displayed text, no stored value
    --   Either works; SetSelectedValue is more "correct" for data-bound menus.
    -- -------------------------------------------------------------------

    -- Create the class dropdown frame
    local classDropdown = CreateFrame("Frame", "WSTClassDropdown", scrollChild, "UIDropDownMenuTemplate")
    classDropdown:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftMargin - 16, currentY)
    -- Note: UIDropDownMenu template adds ~16px left padding internally,
    -- so we offset by -16 to align visually with other controls.

    -- Set dropdown width (the displayed area, not the menu width)
    UIDropDownMenu_SetWidth(classDropdown, 180)

    -- We'll store references for later use (RefreshSettingsValues needs them)
    panel.classDropdown = classDropdown

    -- The spec dropdown needs to exist before the class init function runs
    -- (because class selection triggers a spec refresh), so we create both
    -- dropdowns now and initialize them after.

    -- Create a label for the class dropdown
    local classLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    classLabel:SetPoint("BOTTOMLEFT", classDropdown, "TOPLEFT", 18, 2)
    classLabel:SetText("Class")

    -- =========================================================================
    -- 3. SPEC DROPDOWN
    -- =========================================================================
    local specDropdown = CreateFrame("Frame", "WSTSpecDropdown", scrollChild, "UIDropDownMenuTemplate")
    specDropdown:SetPoint("LEFT", classDropdown, "RIGHT", 10, 0)
    UIDropDownMenu_SetWidth(specDropdown, 180)
    panel.specDropdown = specDropdown

    local specLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    specLabel:SetPoint("BOTTOMLEFT", specDropdown, "TOPLEFT", 18, 2)
    specLabel:SetText("Specialization")

    -- -------------------------------------------------------------------
    -- Spec dropdown initialization function.
    -- This is called every time the spec dropdown opens. It reads the
    -- currently selected class and builds items from that class's spec list.
    -- -------------------------------------------------------------------
    local function InitSpecDropdown(self, level)
        -- Determine which class is selected by reading the saved value
        local selectedClass = ns.db and ns.db.class

        -- If no class is selected, show a placeholder message
        if not selectedClass or not ns.ClassSpecData.classes[selectedClass] then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Select a class first"
            info.disabled = true     -- Grayed out, not clickable
            info.notCheckable = true -- No checkmark space
            UIDropDownMenu_AddButton(info)
            return
        end

        -- Get the spec list for the selected class
        local specList = ns.ClassSpecData.classes[selectedClass].specs

        -- Build one menu item per spec
        for i, specName in ipairs(specList) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = specName
            info.value = specName

            -- The .func is called when the user clicks this item.
            -- Arguments: self (the button), arg1, arg2, checked (bool)
            info.func = function(self, arg1, arg2, checked)
                -- Update the dropdown's displayed text
                UIDropDownMenu_SetSelectedValue(specDropdown, specName)
                -- Save to database
                if ns.db then
                    ns.db.spec = specName
                end
            end

            -- Show a checkmark on the currently selected spec
            info.checked = (ns.db and ns.db.spec == specName)

            UIDropDownMenu_AddButton(info)
        end
    end

    -- -------------------------------------------------------------------
    -- Class dropdown initialization function.
    -- Builds one item per class from ns.ClassSpecData.classOrder.
    -- When a class is selected, it resets the spec dropdown.
    -- -------------------------------------------------------------------
    local function InitClassDropdown(self, level)
        for i, classToken in ipairs(ns.ClassSpecData.classOrder) do
            local classData = ns.ClassSpecData.classes[classToken]
            local info = UIDropDownMenu_CreateInfo()
            info.text = classData.name
            info.value = classToken   -- Store the token, not the display name

            info.func = function(self, arg1, arg2, checked)
                -- Update displayed text to show the class name
                UIDropDownMenu_SetSelectedValue(classDropdown, classToken)
                UIDropDownMenu_SetText(classDropdown, classData.name)

                -- Save the class selection
                if ns.db then
                    ns.db.class = classToken
                    ns.db.spec = nil  -- Reset spec when class changes
                end

                -- Reinitialize the spec dropdown to show specs for the new class.
                -- UIDropDownMenu_Initialize re-runs the init function, which
                -- rebuilds the menu items. We also set the display text to
                -- a prompt since the old spec is no longer valid.
                UIDropDownMenu_Initialize(specDropdown, InitSpecDropdown)
                UIDropDownMenu_SetText(specDropdown, "Select spec...")
            end

            -- Checkmark on the currently selected class
            info.checked = (ns.db and ns.db.class == classToken)

            UIDropDownMenu_AddButton(info)
        end
    end

    -- Wire up the initialization functions.
    -- These are called immediately (to set the initial state) and again
    -- every time the user clicks the dropdown to open it.
    UIDropDownMenu_Initialize(classDropdown, InitClassDropdown)
    UIDropDownMenu_Initialize(specDropdown, InitSpecDropdown)

    -- Set initial display text from saved values
    if ns.db and ns.db.class and ns.ClassSpecData.classes[ns.db.class] then
        UIDropDownMenu_SetText(classDropdown, ns.ClassSpecData.classes[ns.db.class].name)
    else
        UIDropDownMenu_SetText(classDropdown, "Select class...")
    end

    if ns.db and ns.db.spec then
        UIDropDownMenu_SetText(specDropdown, ns.db.spec)
    else
        UIDropDownMenu_SetText(specDropdown, "Select spec...")
    end

    currentY = currentY - lineSpacing - 5

    -- =========================================================================
    -- 4. TARGET STATS (4 numeric EditBoxes)
    -- =========================================================================
    -- These let the user input their target percentages for Crit, Haste,
    -- Mastery, and Versatility. Values are stored in ns.db.targets.
    CreateSectionLabel(scrollChild, "Target Stats", {"TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY})
    currentY = currentY - 28

    -- We define the 4 stats in a table so we can loop over them.
    -- Each entry maps a display label to a key in ns.db.targets.
    local statDefs = {
        { label = "Crit %",    key = "crit" },
        { label = "Haste %",   key = "haste" },
        { label = "Mastery %", key = "mastery" },
        { label = "Versa %",   key = "versa" },
    }

    -- Store references to the EditBoxes so RefreshSettingsValues can update them.
    panel.statEditBoxes = {}

    -- Create two rows of two stat inputs each for a compact layout.
    for i, stat in ipairs(statDefs) do
        -- Calculate position: 2 per row
        local col = ((i - 1) % 2)  -- 0 or 1
        local row = math.floor((i - 1) / 2)  -- 0 or 1
        local xOff = leftMargin + col * 200
        local yOff = currentY - row * 35

        local lbl, editBox = CreateLabeledEditBox(
            scrollChild, stat.label,
            {"TOPLEFT", scrollChild, "TOPLEFT", xOff, yOff},
            60, 3  -- 60px wide, max 3 digits
        )

        -- Restrict to numeric input only.
        -- SetNumeric(true) prevents the user from typing anything except
        -- digits 0-9. The EditBox will silently ignore other keys.
        editBox:SetNumeric(true)

        -- Set the initial value from the database
        local initialVal = (ns.db and ns.db.targets and ns.db.targets[stat.key]) or 0
        editBox:SetText(tostring(initialVal))

        -- OnTextChanged fires on EVERY keystroke. We use it to save the value
        -- immediately and refresh the floating window.
        -- The second argument `userInput` is true only when the change was
        -- caused by actual typing (not programmatic SetText calls). We check
        -- this to avoid infinite loops when RefreshSettingsValues calls SetText.
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end  -- Ignore programmatic changes

            local val = self:GetNumber()  -- GetNumber() returns 0 for empty/invalid
            if ns.db and ns.db.targets then
                ns.db.targets[stat.key] = val

                -- Also save to per-spec storage so targets persist across spec changes.
                if ns.db.class and ns.db.spec then
                    local specKey = ns.db.class .. "-" .. ns.db.spec
                    ns.db.specTargets = ns.db.specTargets or {}
                    if not ns.db.specTargets[specKey] then
                        ns.db.specTargets[specKey] = {}
                    end
                    ns.db.specTargets[specKey][stat.key] = val
                end

                -- Refresh the floating window to reflect the new target
                if ns.UpdateStats then ns:UpdateStats() end
                if ns.UpdateUI then ns:UpdateUI() end
            end
        end)

        -- Store reference for later refresh
        panel.statEditBoxes[stat.key] = editBox
    end

    -- Account for the 2 rows of stats
    currentY = currentY - 80

    -- =========================================================================
    -- 5. LAYOUT DROPDOWN
    -- =========================================================================
    CreateSectionLabel(scrollChild, "Layout", {"TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY})
    currentY = currentY - 25

    local layoutDropdown = CreateFrame("Frame", "WSTLayoutDropdown", scrollChild, "UIDropDownMenuTemplate")
    layoutDropdown:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftMargin - 16, currentY)
    UIDropDownMenu_SetWidth(layoutDropdown, 200)
    panel.layoutDropdown = layoutDropdown

    -- Layout options: each has an internal value and a display label.
    local layoutOptions = {
        { value = "A", text = "A - Compact" },
        { value = "B", text = "B - With Bars" },
        { value = "C", text = "C - Ultra Minimal" },
    }

    -- Initialization function for the layout dropdown
    local function InitLayoutDropdown(self, level)
        for _, opt in ipairs(layoutOptions) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.text
            info.value = opt.value
            info.func = function(self, arg1, arg2, checked)
                UIDropDownMenu_SetSelectedValue(layoutDropdown, opt.value)
                UIDropDownMenu_SetText(layoutDropdown, opt.text)
                if ns.db then
                    ns.db.layout = opt.value
                    if ns.UpdateUI then ns:UpdateUI() end
                end
            end
            info.checked = (ns.db and ns.db.layout == opt.value)
            UIDropDownMenu_AddButton(info)
        end
    end

    UIDropDownMenu_Initialize(layoutDropdown, InitLayoutDropdown)

    -- Set initial display text
    local currentLayout = ns.db and ns.db.layout or "A"
    for _, opt in ipairs(layoutOptions) do
        if opt.value == currentLayout then
            UIDropDownMenu_SetText(layoutDropdown, opt.text)
            break
        end
    end

    currentY = currentY - lineSpacing

    -- =========================================================================
    -- 6. FONT SIZE SLIDER
    -- =========================================================================
    -- -------------------------------------------------------------------
    -- HOW SLIDER WORKS (detailed explanation):
    -- -------------------------------------------------------------------
    -- A Slider is a horizontal (or vertical) bar with a draggable thumb.
    -- WoW provides "OptionsSliderTemplate" which gives us:
    --   - A background track
    --   - A draggable thumb button
    --   - Min/Max text labels at the ends (.Low and .High FontStrings)
    --
    -- Key methods:
    --   SetMinMaxValues(min, max) — The range of allowed values
    --   SetValue(val)            — Set the current position
    --   SetValueStep(step)       — The increment between valid positions
    --   SetObeyStepOnDrag(true)  — Forces the thumb to snap to step
    --                              increments instead of sliding smoothly
    --   GetValue()               — Returns the current numeric value
    --
    -- Key script:
    --   OnValueChanged(self, value) — Fires when the value changes, either
    --                                 from dragging or from SetValue().
    --                                 `value` is the new numeric value.
    -- -------------------------------------------------------------------

    CreateSectionLabel(scrollChild, "Font Size", {"TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY})
    currentY = currentY - 28

    local fontSlider = CreateFrame("Slider", "WSTFontSizeSlider", scrollChild, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY)
    fontSlider:SetWidth(200)
    fontSlider:SetHeight(17)

    -- Configure the slider range and step
    fontSlider:SetMinMaxValues(8, 24)  -- Font size 8 to 24
    fontSlider:SetValueStep(1)         -- Integer steps
    fontSlider:SetObeyStepOnDrag(true) -- Snap to whole numbers

    -- The OptionsSliderTemplate creates .Low and .High FontStrings for the
    -- min/max labels at either end of the slider track.
    fontSlider.Low = fontSlider.Low or _G[fontSlider:GetName() .. "Low"]
    fontSlider.High = fontSlider.High or _G[fontSlider:GetName() .. "High"]
    fontSlider.Text = fontSlider.Text or _G[fontSlider:GetName() .. "Text"]

    if fontSlider.Low then fontSlider.Low:SetText("8") end
    if fontSlider.High then fontSlider.High:SetText("24") end
    if fontSlider.Text then fontSlider.Text:SetText("Font Size") end

    -- Set initial value from database
    local initFontSize = (ns.db and ns.db.fontSize) or 12
    fontSlider:SetValue(initFontSize)

    -- Create a value display label that shows the current number next to the slider
    local fontValueLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fontValueLabel:SetPoint("LEFT", fontSlider, "RIGHT", 15, 0)
    fontValueLabel:SetText(tostring(initFontSize))
    panel.fontValueLabel = fontValueLabel

    -- OnValueChanged fires when the slider is dragged or when SetValue is called.
    fontSlider:SetScript("OnValueChanged", function(self, value)
        -- Round to integer (just in case)
        value = math.floor(value + 0.5)
        fontValueLabel:SetText(tostring(value))
        if ns.db then
            ns.db.fontSize = value
            if ns.UpdateUI then ns:UpdateUI() end
        end
    end)

    panel.fontSlider = fontSlider
    currentY = currentY - lineSpacing

    -- =========================================================================
    -- 7. THRESHOLD INPUTS
    -- =========================================================================
    -- Thresholds control the color coding. The formula is:
    --   ratio = (current / target) * 100
    --   if ratio < low  → gray
    --   if ratio < high → yellow
    --   if ratio <= overcap → green
    --   if ratio > overcap → red
    CreateSectionLabel(scrollChild, "Color Thresholds", {"TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY})
    currentY = currentY - 28

    local thresholdDefs = {
        { label = "Low %",     key = "low",     default = 70 },
        { label = "High %",    key = "high",    default = 90 },
        { label = "Overcap %", key = "overcap", default = 100 },
    }

    panel.thresholdEditBoxes = {}

    for i, thr in ipairs(thresholdDefs) do
        local xOff = leftMargin + (i - 1) * 140
        local lbl, editBox = CreateLabeledEditBox(
            scrollChild, thr.label,
            {"TOPLEFT", scrollChild, "TOPLEFT", xOff, currentY},
            50, 3
        )
        editBox:SetNumeric(true)

        local initialVal = (ns.db and ns.db.thresholds and ns.db.thresholds[thr.key]) or thr.default
        editBox:SetText(tostring(initialVal))

        editBox:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            local val = self:GetNumber()
            if ns.db and ns.db.thresholds then
                ns.db.thresholds[thr.key] = val
                if ns.UpdateUI then ns:UpdateUI() end
            end
        end)

        panel.thresholdEditBoxes[thr.key] = editBox
    end

    currentY = currentY - lineSpacing

    -- =========================================================================
    -- 8. COLOR INPUTS (hex EditBoxes + swatches)
    -- =========================================================================
    -- Each color field has:
    --   - A label (e.g. "Gray")
    --   - An EditBox for the hex code (e.g. "#888888")
    --   - A small color swatch (Texture) showing the current color
    --
    -- When the user types a valid hex code, we:
    --   1. Convert it to RGB floats via ns:HexToRGB()
    --   2. Save the RGB values to ns.db.colors
    --   3. Update the swatch preview
    --   4. Refresh the floating window
    CreateSectionLabel(scrollChild, "Colors", {"TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY})
    currentY = currentY - 28

    local colorDefs = {
        { label = "Gray",   key = "gray",   default = { 0.53, 0.53, 0.53 } },
        { label = "Yellow", key = "yellow", default = { 1.0,  0.8,  0.0  } },
        { label = "Green",  key = "green",  default = { 0.0,  1.0,  0.0  } },
        { label = "Red",    key = "red",    default = { 1.0,  0.27, 0.27 } },
    }

    panel.colorEditBoxes = {}
    panel.colorSwatches = {}

    for i, clr in ipairs(colorDefs) do
        -- Two per row
        local col = ((i - 1) % 2)
        local row = math.floor((i - 1) / 2)
        local xOff = leftMargin + col * 230
        local yOff = currentY - row * 35

        local lbl, editBox = CreateLabeledEditBox(
            scrollChild, clr.label,
            {"TOPLEFT", scrollChild, "TOPLEFT", xOff, yOff},
            80, 7  -- 80px wide, max 7 chars (#rrggbb)
        )

        -- Color EditBoxes accept text (not numeric), so we do NOT call
        -- SetNumeric(true). Instead we validate the hex format manually.

        -- Get the current color from the database (or use defaults)
        local dbColor = (ns.db and ns.db.colors and ns.db.colors[clr.key]) or clr.default
        local hexStr = ns:RGBToHex(dbColor[1], dbColor[2], dbColor[3])
        editBox:SetText(hexStr)

        -- Create the color swatch preview — a small square showing the color
        local swatch = CreateColorSwatch(scrollChild, 16, dbColor[1], dbColor[2], dbColor[3])
        swatch:SetPoint("LEFT", editBox, "RIGHT", 6, 0)

        -- OnTextChanged for color: validate hex, update swatch and db
        editBox:SetScript("OnTextChanged", function(self, userInput)
            if not userInput then return end
            local text = self:GetText()

            -- Only save if the user has typed a valid hex color
            if IsValidHex(text) then
                local r, g, b = ns:HexToRGB(text)
                -- Update the swatch preview immediately
                swatch:SetColorTexture(r, g, b, 1.0)
                -- Save to database
                if ns.db and ns.db.colors then
                    ns.db.colors[clr.key] = { r, g, b }
                    if ns.UpdateUI then ns:UpdateUI() end
                end
            end
            -- If invalid, we just leave the old color — no error shown.
            -- The swatch serves as visual feedback: if it doesn't change,
            -- the user knows their input isn't valid yet.
        end)

        panel.colorEditBoxes[clr.key] = editBox
        panel.colorSwatches[clr.key] = swatch
    end

    -- Account for the 2 rows of color inputs
    currentY = currentY - 80

    -- =========================================================================
    -- 9. RESET BUTTON
    -- =========================================================================
    -- A simple button that restores ALL settings to their default values.
    -- Uses WoW's "UIPanelButtonTemplate" for consistent look with other
    -- Blizzard UI buttons.

    currentY = currentY - 10

    -- Reset to Defaults button
    local resetButton = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
    resetButton:SetSize(160, 26)
    resetButton:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", leftMargin, currentY)
    resetButton:SetText("Reset to Defaults")

    resetButton:SetScript("OnClick", function()
        if not ns.db then return end

        ns.db.class = nil
        ns.db.spec = nil
        ns.db.targets = { crit = 0, haste = 0, mastery = 0, versa = 0 }
        ns.db.layout = "A"
        ns.db.fontSize = 12
        ns.db.thresholds = { low = 70, high = 90, overcap = 100 }
        ns.db.colors = {
            gray   = { 0.53, 0.53, 0.53 },
            yellow = { 1.0,  0.8,  0.0  },
            green  = { 0.0,  1.0,  0.0  },
            red    = { 1.0,  0.27, 0.27 },
        }

        ns:RefreshSettingsValues()
        if ns.UpdateStats then ns:UpdateStats() end
        if ns.UpdateUI then ns:UpdateUI() end
        print("|cff00ff00WowStatTarget:|r Settings reset to defaults.")
    end)

    -- Show Window button — lets the user re-show the floating window
    -- without needing to type /wst toggle in chat.
    local showButton = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
    showButton:SetSize(140, 26)
    showButton:SetPoint("LEFT", resetButton, "RIGHT", 10, 0)
    showButton:SetText("Show Window")

    showButton:SetScript("OnClick", function()
        if ns.db and ns.db.window then
            ns.db.window.visible = true
        end
        if ns.UpdateUI then ns:UpdateUI() end
        print("|cff00ccffWowStatTarget:|r Window shown.")
    end)

    -- =========================================================================
    -- 10. REGISTER WITH BLIZZARD'S INTERFACE OPTIONS
    -- =========================================================================
    -- -------------------------------------------------------------------
    -- HOW BLIZZARD ADDON SETTINGS REGISTRATION WORKS (Retail 10.x+):
    -- -------------------------------------------------------------------
    -- In WoW Retail (10.0+), Blizzard introduced a new Settings API:
    --
    --   1. Settings.RegisterCanvasLayoutCategory(frame, name)
    --      Creates a category that embeds your frame directly into the
    --      Settings window canvas. Good for simple panels.
    --
    --   2. Settings.RegisterAddOnCategory(category)
    --      Registers the category object so it appears under
    --      Interface → AddOns in the game settings.
    --
    -- The older API (InterfaceOptions_AddCategory) was removed in 11.0.
    -- For maximum compatibility across 10.x and 11.x, we try the new API
    -- first and fall back to the old one.
    --
    -- Our approach: We don't embed our panel inside Blizzard's settings
    -- canvas. Instead, when the user clicks our addon in Interface Options,
    -- we open our standalone panel. This gives us full control over layout
    -- and avoids canvas size constraints.
    -- -------------------------------------------------------------------

    -- Try the modern Settings API (WoW 10.0+)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        -- Create a small "proxy" frame that sits inside Blizzard's options.
        -- It just shows a message telling the user to use /wst, and has a
        -- button to open our real settings panel.
        local proxyFrame = CreateFrame("Frame")
        proxyFrame.name = addonName

        -- Add a helpful message inside the Blizzard options page
        local proxyLabel = proxyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        proxyLabel:SetPoint("TOPLEFT", 16, -16)
        proxyLabel:SetText("WowStatTarget")

        local proxyDesc = proxyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        proxyDesc:SetPoint("TOPLEFT", proxyLabel, "BOTTOMLEFT", 0, -10)
        proxyDesc:SetText("Use |cff00ff00/wst|r to open the settings panel,\nor click the button below.")

        local openButton = CreateFrame("Button", nil, proxyFrame, "UIPanelButtonTemplate")
        openButton:SetSize(200, 30)
        openButton:SetPoint("TOPLEFT", proxyDesc, "BOTTOMLEFT", 0, -15)
        openButton:SetText("Open Settings Panel")
        openButton:SetScript("OnClick", function()
            -- Hide the Blizzard settings window first, then open ours
            if SettingsPanel then SettingsPanel:Hide() end
            ns:OpenSettings()
        end)

        -- Register with the new Settings API
        local category = Settings.RegisterCanvasLayoutCategory(proxyFrame, addonName)
        category.ID = addonName
        Settings.RegisterAddOnCategory(category)

    -- Fallback for older builds (shouldn't be needed on Retail 10.x+,
    -- but included for robustness)
    elseif InterfaceOptions_AddCategory then
        local proxyFrame = CreateFrame("Frame")
        proxyFrame.name = addonName

        local proxyLabel = proxyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        proxyLabel:SetPoint("TOPLEFT", 16, -16)
        proxyLabel:SetText("WowStatTarget — Use /wst to open settings")

        InterfaceOptions_AddCategory(proxyFrame)
    end
end

-- =============================================================================
-- ns:RefreshSettingsValues()
-- =============================================================================
-- Updates ALL input fields in the settings panel to reflect the current
-- values in ns.db. Called when:
--   1. The settings panel is opened (to sync with any external changes)
--   2. After a reset-to-defaults
--   3. After any programmatic change to ns.db
--
-- This function does the REVERSE of what the OnTextChanged handlers do:
-- instead of reading from the UI and writing to the database, it reads from
-- the database and writes to the UI.
function ns:RefreshSettingsValues()
    local panel = ns.settingsPanel
    if not panel or not ns.db then return end

    -- -----------------------------------------------------------------
    -- Class & Spec dropdowns
    -- -----------------------------------------------------------------
    if panel.classDropdown then
        if ns.db.class and ns.ClassSpecData.classes[ns.db.class] then
            UIDropDownMenu_SetText(panel.classDropdown, ns.ClassSpecData.classes[ns.db.class].name)
        else
            UIDropDownMenu_SetText(panel.classDropdown, "Select class...")
        end
    end

    if panel.specDropdown then
        -- Re-initialize the spec dropdown so its menu items match the current class
        UIDropDownMenu_Initialize(panel.specDropdown, function(self, level)
            local selectedClass = ns.db.class
            if not selectedClass or not ns.ClassSpecData.classes[selectedClass] then
                local info = UIDropDownMenu_CreateInfo()
                info.text = "Select a class first"
                info.disabled = true
                info.notCheckable = true
                UIDropDownMenu_AddButton(info)
                return
            end
            local specList = ns.ClassSpecData.classes[selectedClass].specs
            for i, specName in ipairs(specList) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = specName
                info.value = specName
                info.func = function(self, arg1, arg2, checked)
                    UIDropDownMenu_SetSelectedValue(panel.specDropdown, specName)
                    ns.db.spec = specName
                end
                info.checked = (ns.db.spec == specName)
                UIDropDownMenu_AddButton(info)
            end
        end)

        if ns.db.spec then
            UIDropDownMenu_SetText(panel.specDropdown, ns.db.spec)
        else
            UIDropDownMenu_SetText(panel.specDropdown, "Select spec...")
        end
    end

    -- -----------------------------------------------------------------
    -- Target stat EditBoxes
    -- -----------------------------------------------------------------
    if panel.statEditBoxes then
        for key, editBox in pairs(panel.statEditBoxes) do
            local val = (ns.db.targets and ns.db.targets[key]) or 0
            editBox:SetText(tostring(val))
        end
    end

    -- -----------------------------------------------------------------
    -- Layout dropdown
    -- -----------------------------------------------------------------
    if panel.layoutDropdown then
        local layout = ns.db.layout or "A"
        local layoutTexts = {
            A = "A - Compact",
            B = "B - With Bars",
            C = "C - Ultra Minimal",
        }
        UIDropDownMenu_SetText(panel.layoutDropdown, layoutTexts[layout] or layoutTexts["A"])
    end

    -- -----------------------------------------------------------------
    -- Font size slider
    -- -----------------------------------------------------------------
    if panel.fontSlider then
        local fontSize = ns.db.fontSize or 12
        panel.fontSlider:SetValue(fontSize)
        if panel.fontValueLabel then
            panel.fontValueLabel:SetText(tostring(fontSize))
        end
    end

    -- -----------------------------------------------------------------
    -- Threshold EditBoxes
    -- -----------------------------------------------------------------
    if panel.thresholdEditBoxes then
        local defaults = { low = 70, high = 90, overcap = 100 }
        for key, editBox in pairs(panel.thresholdEditBoxes) do
            local val = (ns.db.thresholds and ns.db.thresholds[key]) or defaults[key]
            editBox:SetText(tostring(val))
        end
    end

    -- -----------------------------------------------------------------
    -- Color EditBoxes + swatches
    -- -----------------------------------------------------------------
    if panel.colorEditBoxes then
        local defaults = {
            gray   = { 0.53, 0.53, 0.53 },
            yellow = { 1.0,  0.8,  0.0  },
            green  = { 0.0,  1.0,  0.0  },
            red    = { 1.0,  0.27, 0.27 },
        }
        for key, editBox in pairs(panel.colorEditBoxes) do
            local color = (ns.db.colors and ns.db.colors[key]) or defaults[key]
            local hex = ns:RGBToHex(color[1], color[2], color[3])
            editBox:SetText(hex)

            -- Also update the swatch preview
            if panel.colorSwatches and panel.colorSwatches[key] then
                panel.colorSwatches[key]:SetColorTexture(color[1], color[2], color[3], 1.0)
            end
        end
    end
end
