-- ============================================================================
-- UI.lua — WowStatTarget Floating Comparison Window
-- ============================================================================
--
-- This file creates and manages the main floating window that displays the
-- player's current secondary stats compared to their target values.
--
-- HOW WOW ADDON UI WORKS (high-level):
--
--   WoW's UI is built on "frames" — invisible rectangles that can contain
--   textures (images/colors), font strings (text), and other frames. Every
--   visible element on screen is a frame or lives inside one.
--
--   Frames are positioned using an "anchor" system: you pick a point on your
--   frame (e.g., "TOPLEFT") and attach it to a point on another frame (the
--   parent or any other frame). This is done via :SetPoint().
--
--   Frames are drawn in layers called "strata" (BACKGROUND, LOW, MEDIUM,
--   HIGH, DIALOG, FULLSCREEN, TOOLTIP). Higher strata draw on top of lower
--   ones. Within a strata, frames can have a "level" for fine-grained
--   ordering.
--
--   All UI updates happen on the main thread — WoW is single-threaded for
--   Lua addons. You respond to game events and update frames accordingly.
--
-- ============================================================================

-- Retrieve the addon name and the shared namespace table.
-- Every .lua file listed in the .toc receives these two values via `...`.
-- `addonName` is the folder name ("WowStatTarget").
-- `ns` is a private table shared ONLY between files of this addon — it's how
-- we pass data and functions between Core.lua, UI.lua, Settings.lua, etc.
local addonName, ns = ...

-- ============================================================================
-- CONSTANTS
-- ============================================================================

-- The font file path. FRIZQT__.TTF is Blizzard's default UI font, bundled
-- with every WoW installation. It's not truly monospace, but it's the
-- standard choice. For a real monospace font you could use
-- "Fonts\\ARIALN.TTF" but FRIZQT is more readable at small sizes.
local FONT_FILE = "Fonts\\FRIZQT__.TTF"

-- Default font size — will be overridden by ns.db.fontSize at runtime.
local DEFAULT_FONT_SIZE = 12

-- The four stats we track, in display order. Each entry has:
--   key    = the key used in ns.currentStats and ns.db.targets
--   label  = full name shown in layouts A and B
--   abbrev = single letter shown in layout C
local STAT_DEFS = {
    { key = "crit",    label = "Crit",    abbrev = "C" },
    { key = "haste",   label = "Haste",   abbrev = "H" },
    { key = "mastery", label = "Mastery", abbrev = "M" },
    { key = "versa",   label = "Versa",   abbrev = "V" },
}

-- Padding and spacing constants (in pixels).
local WINDOW_PADDING     = 10   -- space between window edge and content
local ROW_HEIGHT         = 18   -- height of each stat row
local ROW_SPACING        = 4    -- vertical gap between rows
local BAR_HEIGHT         = 2    -- height of progress bar in layout B
local BAR_SPACING        = 2    -- gap between text and bar in layout B
local TITLE_HEIGHT       = 16   -- height reserved for the title text
local TITLE_BOTTOM_GAP   = 6    -- gap between title and first stat row
local CLOSE_BUTTON_SIZE  = 16   -- width/height of the close (X) button
local MIN_WINDOW_WIDTH   = 140  -- minimum window width

-- ============================================================================
-- HELPER: Create a backdrop table for the window background
-- ============================================================================
--
-- HOW BACKDROP / TRANSPARENCY WORKS:
--
--   In WoW Retail (since 9.0), the old SetBackdrop() API was deprecated.
--   Now you must use the "BackdropTemplateMixin" — you create your frame
--   with "BackdropTemplate" as an inherits template, then call
--   frame:SetBackdrop() to define the look, and frame:SetBackdropColor()
--   to set the color and alpha (transparency).
--
--   The alpha channel (4th value in SetBackdropColor) controls opacity:
--   0 = fully transparent, 1 = fully opaque. We use 0.6 for 60% opacity.
--
--   The backdrop table defines:
--     bgFile   = path to a texture used as the background fill
--     edgeFile = path to a texture used for the border
--     edgeSize = thickness of the border in pixels
--     insets   = how far the background is inset from the border
--
local BACKDROP_INFO = {
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true,
    tileSize = 16,
    edgeSize = 12,
    insets   = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- ============================================================================
-- ns:CreateMainWindow()
-- ============================================================================
-- Builds the floating frame that displays stat comparisons.
-- Called once from Core.lua after saved variables are loaded.
--
-- FRAME HIERARCHY:
--   WowStatTargetMainFrame (main container)
--     ├── titleText (FontString — "WOWSTATTARGET")
--     ├── noTargetsText (FontString — "No targets set")
--     ├── closeButton (Button — the X)
--     └── statRows[1..4] (sub-frames, one per stat)
--           ├── labelText (FontString — stat name or abbreviation)
--           ├── arrowText (FontString — "→", layout A only)
--           ├── valueText (FontString — " 28/31 %")
--           └── barTexture (Texture — progress bar, layout B only)
--
function ns:CreateMainWindow()
    -- -----------------------------------------------------------------
    -- 1. CREATE THE MAIN FRAME
    -- -----------------------------------------------------------------
    --
    -- CreateFrame(frameType, name, parent, template)
    --   frameType  = "Frame" is the basic container type. Others include
    --                "Button", "EditBox", "ScrollFrame", etc.
    --   name       = a global name so other addons/macros can reference it.
    --                Convention: "AddonNameSomething". Becomes _G["name"].
    --   parent     = the frame this is a child of. UIParent is the root
    --                of all visible UI. If the parent hides, children hide.
    --   template   = XML template to inherit. "BackdropTemplate" gives us
    --                the SetBackdrop/SetBackdropColor API.
    --
    local frame = CreateFrame("Frame", "WowStatTargetMainFrame", UIParent,
                              "BackdropTemplate")

    -- -----------------------------------------------------------------
    -- FRAME STRATA
    -- -----------------------------------------------------------------
    --
    -- Frame strata controls the broad draw order. From back to front:
    --   WORLD < BACKGROUND < LOW < MEDIUM < HIGH < DIALOG <
    --   FULLSCREEN < FULLSCREEN_DIALOG < TOOLTIP
    --
    -- We use "MEDIUM" so our window floats above most game UI but below
    -- popups, dialogs, and tooltips. "HIGH" would also work but might
    -- overlap important Blizzard windows.
    --
    frame:SetFrameStrata("MEDIUM")

    -- Give it a specific level within the strata for fine-grained ordering.
    -- Higher numbers draw on top of lower numbers within the same strata.
    frame:SetFrameLevel(10)

    -- -----------------------------------------------------------------
    -- BACKDROP (BACKGROUND + BORDER)
    -- -----------------------------------------------------------------
    --
    -- Apply the backdrop definition we created above, then set its color.
    -- SetBackdropColor(r, g, b, a) — the 4th value is alpha/opacity.
    -- 0.6 = 60% opaque = 40% see-through, giving a nice dark tint.
    --
    frame:SetBackdrop(BACKDROP_INFO)
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.8)

    -- Set a starting size. We'll auto-resize later based on visible rows.
    frame:SetSize(MIN_WINDOW_WIDTH, 100)

    -- -----------------------------------------------------------------
    -- POSITIONING (ANCHOR SYSTEM)
    -- -----------------------------------------------------------------
    --
    -- HOW SetPoint / ANCHORING WORKS:
    --
    --   frame:SetPoint(point, relativeTo, relativePoint, offsetX, offsetY)
    --
    --   This says: "Take the `point` corner/edge of THIS frame and attach
    --   it to the `relativePoint` corner/edge of `relativeTo` frame, then
    --   offset it by (offsetX, offsetY) pixels."
    --
    --   Common points: "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER",
    --   "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT"
    --
    --   Example: frame:SetPoint("CENTER", UIParent, "CENTER", 100, -50)
    --   means "put my center 100px right and 50px down from UIParent's center"
    --
    --   If relativeTo is nil, it defaults to the parent frame.
    --
    -- We restore saved position, defaulting to screen center (0, 0 offset).
    --
    local savedX = (ns.db and ns.db.window and ns.db.window.x) or 0
    local savedY = (ns.db and ns.db.window and ns.db.window.y) or 0
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", savedX, savedY)

    -- -----------------------------------------------------------------
    -- DRAG / MOVE BEHAVIOR
    -- -----------------------------------------------------------------
    --
    -- HOW DRAG/MOVE WORKS IN WOW:
    --
    --   By default, frames are fixed in place. To make one draggable:
    --
    --   1. frame:SetMovable(true) — tells WoW this frame CAN be moved.
    --   2. frame:EnableMouse(true) — lets the frame receive mouse events.
    --   3. frame:RegisterForDrag("LeftButton") — specifies which mouse
    --      button initiates a drag. Usually left-click.
    --   4. Set "OnDragStart" script to call frame:StartMoving() — this
    --      tells WoW to follow the cursor with this frame.
    --   5. Set "OnDragStop" script to call frame:StopMovingOrSizing() —
    --      this finalizes the position when the user releases the button.
    --
    --   After StopMovingOrSizing(), we read the frame's new position via
    --   GetPoint() and save it to our database so it persists across
    --   sessions (via SavedVariables).
    --
    --   SetClampedToScreen(true) prevents the user from dragging the
    --   window completely off-screen where they can't reach it.
    --
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    frame:SetScript("OnDragStart", function(self)
        -- StartMoving() makes the frame follow the mouse cursor.
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        -- StopMovingOrSizing() finalizes the frame's position.
        self:StopMovingOrSizing()

        -- Save the new position so it persists across /reload and logouts.
        -- We re-anchor to CENTER of UIParent and store the offset.
        -- GetPoint() returns: point, relativeTo, relativePoint, xOfs, yOfs
        -- But after dragging, the anchors can get messy, so we calculate
        -- the offset from UIParent's center manually.
        local centerX = self:GetLeft() + (self:GetWidth() / 2)
        local centerY = self:GetBottom() + (self:GetHeight() / 2)
        local parentCenterX = UIParent:GetWidth() / 2
        local parentCenterY = UIParent:GetHeight() / 2

        local offsetX = centerX - parentCenterX
        local offsetY = centerY - parentCenterY

        -- Persist to saved variables.
        if ns.db and ns.db.window then
            ns.db.window.x = offsetX
            ns.db.window.y = offsetY
        end

        -- Re-anchor cleanly to CENTER so future SetPoint calls are predictable.
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", offsetX, offsetY)
    end)

    -- -----------------------------------------------------------------
    -- CLOSE BUTTON (X)
    -- -----------------------------------------------------------------
    --
    -- We create a small button at the top-right corner. When clicked, it
    -- hides the window and saves the "visible = false" state.
    --
    -- "UIPanelCloseButton" is a Blizzard template that provides a
    -- pre-made X button with hover/click textures. We resize it to be
    -- small and unobtrusive.
    --
    -- Alternatively we could use "UIPanelCloseButtonNoScripts" and add
    -- our own OnClick, but the standard template works fine — we just
    -- override OnClick.
    --
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetSize(CLOSE_BUTTON_SIZE + 4, CLOSE_BUTTON_SIZE + 4)

    -- Anchor the close button's TOPRIGHT to the frame's TOPRIGHT,
    -- offset slightly inward so it doesn't overflow.
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)

    closeBtn:SetScript("OnClick", function()
        -- Hide the main frame.
        frame:Hide()

        -- Persist the hidden state so it stays hidden after /reload.
        if ns.db and ns.db.window then
            ns.db.window.visible = false
        end
    end)

    -- -----------------------------------------------------------------
    -- TITLE TEXT
    -- -----------------------------------------------------------------
    --
    -- HOW FONT STRINGS WORK:
    --
    --   A FontString is a region that displays text. You create one via
    --   frame:CreateFontString(name, layer, template).
    --
    --   Parameters:
    --     name     = global name (nil for anonymous)
    --     layer    = draw layer WITHIN the frame: "BACKGROUND", "BORDER",
    --                "ARTWORK" (default), "OVERLAY", "HIGHLIGHT"
    --     template = optional font template to inherit
    --
    --   After creating, you configure the font with:
    --     :SetFont(fontFile, size, flags) — flags like "OUTLINE", "THICKOUTLINE"
    --     :SetText("string") — the displayed text
    --     :SetTextColor(r, g, b, a) — color with optional alpha
    --     :SetJustifyH("LEFT" | "CENTER" | "RIGHT") — horizontal alignment
    --     :SetPoint(...) — position within parent frame
    --
    --   Font strings automatically resize to fit their text unless you
    --   set a fixed width, in which case text wraps or truncates.
    --
    local titleText = frame:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT_FILE, 10, "OUTLINE")
    titleText:SetText("WOWSTATTARGET")
    -- Dim white color for the title — subtle, not distracting.
    titleText:SetTextColor(0.5, 0.5, 0.5, 0.8)
    titleText:SetJustifyH("LEFT")
    titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", WINDOW_PADDING, -WINDOW_PADDING)

    -- Store reference so we can show/hide per layout.
    frame.titleText = titleText

    -- -----------------------------------------------------------------
    -- "NO TARGETS SET" MESSAGE
    -- -----------------------------------------------------------------
    --
    -- Shown when all four target values are 0 (or unset).
    --
    local noTargetsText = frame:CreateFontString(nil, "OVERLAY")
    noTargetsText:SetFont(FONT_FILE, DEFAULT_FONT_SIZE, "OUTLINE")
    noTargetsText:SetText("No targets set")
    noTargetsText:SetTextColor(0.6, 0.6, 0.6, 1.0)
    noTargetsText:SetJustifyH("CENTER")
    noTargetsText:SetPoint("CENTER", frame, "CENTER", 0, 0)
    noTargetsText:Hide() -- hidden by default; shown only when needed

    frame.noTargetsText = noTargetsText

    -- -----------------------------------------------------------------
    -- STAT ROWS
    -- -----------------------------------------------------------------
    --
    -- We create 4 rows, one for each stat. Each row is a sub-frame
    -- containing font strings for the label, arrow, and value, plus a
    -- texture for the progress bar.
    --
    frame.statRows = {}

    for i, statDef in ipairs(STAT_DEFS) do
        -- Create a child frame for this row. Using a sub-frame keeps
        -- things organized and makes it easy to show/hide individual rows.
        local row = CreateFrame("Frame", nil, frame)
        row:SetHeight(ROW_HEIGHT)

        -- We'll set the row width dynamically later when we resize.
        -- For now, anchor it across the full width of the parent with padding.
        -- Using LEFT and RIGHT anchors stretches the row to fill available width.
        -- (We don't set explicit width — the two-point anchor does it.)

        -- Position: each row goes below the previous one.
        -- We'll reposition rows dynamically in UpdateUI to skip hidden ones.

        -- ----- LABEL TEXT (stat name or abbreviation) -----
        local labelText = row:CreateFontString(nil, "OVERLAY")
        labelText:SetFont(FONT_FILE, DEFAULT_FONT_SIZE, "OUTLINE")
        labelText:SetText(statDef.label)
        labelText:SetJustifyH("LEFT")
        -- Anchor to the left side of the row.
        labelText:SetPoint("LEFT", row, "LEFT", 0, 0)

        -- ----- ARROW TEXT ("→", used in layout A only) -----
        local arrowText = row:CreateFontString(nil, "OVERLAY")
        arrowText:SetFont(FONT_FILE, DEFAULT_FONT_SIZE, "OUTLINE")
        arrowText:SetText("\226\134\146") -- UTF-8 for → (U+2192)
        arrowText:SetJustifyH("CENTER")
        -- Positioned right after the label. We'll adjust in UpdateUI.
        arrowText:SetPoint("LEFT", labelText, "RIGHT", 4, 0)

        -- ----- VALUE TEXT (formatted stat pair, e.g., "  28/31 %") -----
        local valueText = row:CreateFontString(nil, "OVERLAY")
        valueText:SetFont(FONT_FILE, DEFAULT_FONT_SIZE, "OUTLINE")
        valueText:SetText("")
        valueText:SetJustifyH("RIGHT")
        -- Anchor to the right side of the row.
        valueText:SetPoint("RIGHT", row, "RIGHT", 0, 0)

        -- ----- PROGRESS BAR TEXTURE (used in layout B only) -----
        --
        -- HOW TEXTURES WORK:
        --
        --   A Texture is a region that displays an image or solid color.
        --   Created via frame:CreateTexture(name, layer).
        --
        --   For a solid color bar, we use :SetColorTexture(r, g, b, a)
        --   which fills the texture region with a flat color.
        --
        --   The texture's size and position are set just like frames,
        --   using :SetSize() for dimensions and :SetPoint() for placement.
        --
        --   We'll dynamically set the width based on the stat ratio
        --   (current / target) to create a progress bar effect.
        --
        local barBg = row:CreateTexture(nil, "ARTWORK")
        barBg:SetColorTexture(0.2, 0.2, 0.2, 0.5)
        barBg:SetHeight(BAR_HEIGHT)
        -- The background bar spans the full row width, anchored below the text.
        barBg:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        barBg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        barBg:Hide()

        local barFill = row:CreateTexture(nil, "OVERLAY")
        barFill:SetColorTexture(1, 1, 1, 1) -- color set dynamically
        barFill:SetHeight(BAR_HEIGHT)
        -- The fill bar starts at the left and its width is set dynamically.
        barFill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        barFill:Hide()

        -- Store references on the row for easy access in UpdateUI.
        row.labelText = labelText
        row.arrowText = arrowText
        row.valueText = valueText
        row.barBg     = barBg
        row.barFill   = barFill
        row.statKey   = statDef.key
        row.statLabel = statDef.label
        row.statAbbrev = statDef.abbrev

        frame.statRows[i] = row
    end

    -- -----------------------------------------------------------------
    -- STORE THE FRAME REFERENCE
    -- -----------------------------------------------------------------
    -- We keep a reference on the namespace so other files (Core.lua,
    -- Settings.lua) can access it. For example, Core.lua calls
    -- ns:UpdateUI() after reading new stat values.
    --
    ns.mainFrame = frame

    -- -----------------------------------------------------------------
    -- INITIAL VISIBILITY
    -- -----------------------------------------------------------------
    -- Show or hide based on saved preference.
    if ns.db and ns.db.window and ns.db.window.visible == false then
        frame:Hide()
    else
        frame:Show()
    end

    -- Do an initial layout/update.
    ns:UpdateUI()
end

-- ============================================================================
-- ns:UpdateUI()
-- ============================================================================
-- Refreshes the floating window to reflect current data and settings.
--
-- This function is called:
--   - After CreateMainWindow() finishes (initial draw)
--   - After any game event that changes stats (gear swap, buff, etc.)
--   - After the user changes settings (layout, font size, targets, etc.)
--
-- It reads ns.currentStats (populated by Core.lua) and ns.db.targets,
-- calculates ratios, applies colors, and arranges rows based on the
-- active layout mode.
--
function ns:UpdateUI()
    local frame = ns.mainFrame
    if not frame then return end

    -- -----------------------------------------------------------------
    -- READ SETTINGS
    -- -----------------------------------------------------------------
    local db       = ns.db or {}
    local targets  = db.targets or {}
    local layout   = db.layout or "A"
    local fontSize = db.fontSize or DEFAULT_FONT_SIZE
    local stats    = ns.currentStats or {}

    -- -----------------------------------------------------------------
    -- CHECK IF ANY TARGETS ARE SET
    -- -----------------------------------------------------------------
    -- If ALL targets are 0 (or nil), we show the "No targets set" message
    -- instead of stat rows.
    --
    local anyTargetSet = false
    for _, def in ipairs(STAT_DEFS) do
        local t = targets[def.key] or 0
        if t > 0 then
            anyTargetSet = true
            break
        end
    end

    if not anyTargetSet then
        -- Hide all stat rows and show the "no targets" message.
        for _, row in ipairs(frame.statRows) do
            row:Hide()
        end
        frame.noTargetsText:SetFont(FONT_FILE, fontSize, "OUTLINE")
        frame.noTargetsText:Show()
        frame.titleText:Hide()

        -- Resize window to fit just the message.
        local msgWidth = frame.noTargetsText:GetStringWidth() + (WINDOW_PADDING * 2)
        local windowWidth = math.max(MIN_WINDOW_WIDTH, msgWidth)
        frame:SetSize(windowWidth, WINDOW_PADDING * 2 + fontSize + 4)
        frame.noTargetsText:ClearAllPoints()
        frame.noTargetsText:SetPoint("CENTER", frame, "CENTER", 0, 0)
        return
    end

    -- If we reach here, at least one target is set.
    frame.noTargetsText:Hide()

    -- -----------------------------------------------------------------
    -- LAYOUT-SPECIFIC CONFIGURATION
    -- -----------------------------------------------------------------
    -- Determine whether to show the title, arrows, bars, and which
    -- label style to use (full name vs. single letter).
    --
    local showTitle = (layout == "A" or layout == "B")
    local showArrow = (layout == "A")
    local showBars  = (layout == "B")
    local useAbbrev = (layout == "C")

    -- Show/hide the title text.
    if showTitle then
        frame.titleText:Show()
        frame.titleText:SetFont(FONT_FILE, math.max(9, fontSize - 2), "OUTLINE")
    else
        frame.titleText:Hide()
    end

    -- -----------------------------------------------------------------
    -- CALCULATE AND POSITION EACH ROW
    -- -----------------------------------------------------------------
    -- We iterate over all 4 stats. If a stat's target is 0, that row
    -- is hidden. Visible rows are stacked vertically, skipping hidden ones.
    --
    local visibleCount = 0
    local maxLabelWidth = 0
    local maxValueWidth = 0

    -- First pass: update text content and measure widths.
    for i, row in ipairs(frame.statRows) do
        local def     = STAT_DEFS[i]
        local current = stats[def.key] or 0
        local target  = targets[def.key] or 0

        if target <= 0 then
            -- Target is 0 — hide this row entirely (avoids division by zero).
            row:Hide()
        else
            row:Show()
            visibleCount = visibleCount + 1

            -- Get the formatted value string via Core.lua's helper.
            local valueStr = ns.FormatStatPair
                             and ns:FormatStatPair(current, target)
                             or string.format("%3d/%3d %%",
                                              math.min(math.floor(current + 0.5), 999),
                                              math.min(math.floor(target + 0.5), 999))

            -- Get the color for this stat's ratio via Core.lua's helper.
            local r, g, b = 1, 1, 1
            if ns.GetStatColor then
                r, g, b = ns:GetStatColor(current, target)
            end

            -- Store computed values on the row for the positioning pass.
            row._current  = current
            row._target   = target
            row._valueStr = valueStr
            row._colorR   = r
            row._colorG   = g
            row._colorB   = b

            -- Set the label text depending on layout.
            local labelStr = useAbbrev and def.abbrev or def.label
            row.labelText:SetText(labelStr)
            row.labelText:SetFont(FONT_FILE, fontSize, "OUTLINE")

            -- Set arrow text (always update font, visibility set later).
            row.arrowText:SetFont(FONT_FILE, fontSize, "OUTLINE")
            row.arrowText:SetText("\226\134\146") -- →

            -- Set value text.
            row.valueText:SetText(valueStr)
            row.valueText:SetFont(FONT_FILE, fontSize, "OUTLINE")

            -- ----- APPLY COLORS PER LAYOUT -----
            if layout == "A" then
                -- Layout A: label is dim white, arrow + value in stat color.
                row.labelText:SetTextColor(0.6, 0.6, 0.6, 1.0)
                row.arrowText:SetTextColor(r, g, b, 1.0)
                row.valueText:SetTextColor(r, g, b, 1.0)
            elseif layout == "B" then
                -- Layout B: everything in stat color.
                row.labelText:SetTextColor(r, g, b, 1.0)
                row.valueText:SetTextColor(r, g, b, 1.0)
            else
                -- Layout C: values in stat color, label in stat color too.
                row.labelText:SetTextColor(r, g, b, 1.0)
                row.valueText:SetTextColor(r, g, b, 1.0)
            end

            -- Show/hide arrow based on layout.
            if showArrow then
                row.arrowText:Show()
            else
                row.arrowText:Hide()
            end

            -- Show/hide progress bar based on layout.
            if showBars then
                row.barBg:Show()
                row.barFill:Show()
                -- Set bar fill color to match the stat color.
                row.barFill:SetColorTexture(r, g, b, 0.9)
            else
                row.barBg:Hide()
                row.barFill:Hide()
            end

            -- Measure text widths for later sizing.
            local lw = row.labelText:GetStringWidth()
            local vw = row.valueText:GetStringWidth()
            if lw > maxLabelWidth then maxLabelWidth = lw end
            if vw > maxValueWidth then maxValueWidth = vw end
        end
    end

    -- -----------------------------------------------------------------
    -- CALCULATE WINDOW DIMENSIONS
    -- -----------------------------------------------------------------
    --
    -- The window width is based on the widest label + arrow + value + padding.
    -- The height is based on how many rows are visible.
    --
    local arrowWidth = 0
    if showArrow then
        -- Measure the arrow string width (it's the same for all rows).
        -- We just grab it from the first visible row.
        for _, row in ipairs(frame.statRows) do
            if row:IsShown() then
                arrowWidth = row.arrowText:GetStringWidth() + 8  -- +8 for gaps
                break
            end
        end
    end

    -- Content width = label + gap + arrow + gap + value.
    local contentWidth = maxLabelWidth + arrowWidth + maxValueWidth + 8
    local windowWidth  = math.max(MIN_WINDOW_WIDTH, contentWidth + (WINDOW_PADDING * 2))

    -- Content height = title (if shown) + rows + gaps + bars (if shown).
    local barExtraPerRow = showBars and (BAR_HEIGHT + BAR_SPACING) or 0
    local effectiveRowHeight = ROW_HEIGHT + barExtraPerRow

    local contentHeight = 0
    if showTitle then
        contentHeight = contentHeight + TITLE_HEIGHT + TITLE_BOTTOM_GAP
    end
    contentHeight = contentHeight
                  + (visibleCount * effectiveRowHeight)
                  + (math.max(0, visibleCount - 1) * ROW_SPACING)

    local windowHeight = contentHeight + (WINDOW_PADDING * 2)

    frame:SetSize(windowWidth, windowHeight)

    -- -----------------------------------------------------------------
    -- POSITION EACH VISIBLE ROW
    -- -----------------------------------------------------------------
    --
    -- We anchor rows relative to the top of the content area, stacking
    -- them downward. The Y offset starts below the title (if present).
    --
    local yOffset = -WINDOW_PADDING
    if showTitle then
        yOffset = yOffset - TITLE_HEIGHT - TITLE_BOTTOM_GAP
    end

    -- The available width for each row (inside the padding).
    local rowWidth = windowWidth - (WINDOW_PADDING * 2)

    local rowIndex = 0
    for i, row in ipairs(frame.statRows) do
        if row:IsShown() then
            -- Clear previous anchors to avoid conflicts.
            row:ClearAllPoints()

            -- Anchor the row inside the frame at the current vertical offset.
            row:SetPoint("TOPLEFT", frame, "TOPLEFT", WINDOW_PADDING, yOffset)
            row:SetSize(rowWidth, ROW_HEIGHT)

            -- Set the progress bar fill width based on the stat ratio.
            if showBars and row._target and row._target > 0 then
                local ratio = math.min(row._current / row._target, 1.0)
                local barWidth = math.max(1, ratio * rowWidth)
                row.barFill:SetWidth(barWidth)
            end

            -- Move yOffset down for the next row.
            yOffset = yOffset - effectiveRowHeight - ROW_SPACING
            rowIndex = rowIndex + 1
        end
    end
end
