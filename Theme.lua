local ADDON, ns = ...

-- The look, in one place: the website's own palette, its two typefaces when
-- they ship, and the rounded cards and pills that every window is built from.
-- Nothing here knows what a ladder or a match is; the modules ask for a card,
-- a heading, a button, and get the same answer everywhere.
--
-- Colours are the site's CSS variables, hex for hex, so the addon and the
-- page never drift apart. The rounded corners are textures generated from
-- the same colours (tools\..\Media\ui, drawn by a script rather than by hand)
-- because WoW has no corner radius: an edge texture of eight tiles carries
-- the curve, with the fill baked inside it so nothing square shows through.
--
-- The typefaces are optional. Saira Condensed for headings and Barlow for
-- text load when the .ttf files are in Media\fonts; when they are not, the
-- client's own narrow face stands in for the display font and its default
-- face for the rest, and the layout does not change. SetFont says whether a
-- file loaded, so the choice is made once at load and never guessed at.

local T = {}
ns.Theme = T

local MEDIA = "Interface\\AddOns\\ArenaPlus\\Media\\ui\\"
local FONTS = "Interface\\AddOns\\ArenaPlus\\Media\\fonts\\"

local function rgb(hex)
	local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)$")
	return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255
end

-- :root of style.css.
T.colour = {
	ground   = { rgb("#0b0d12") },
	surface  = { rgb("#12161e") },
	raised   = { rgb("#191e28") },
	line     = { rgb("#242b37") },
	lineSoft = { rgb("#1b212b") },
	text     = { rgb("#e7e9ee") },
	muted    = { rgb("#a0a8b8") },
	faint    = { rgb("#8e97a8") },
	gold     = { rgb("#f2c94c") },
	win      = { rgb("#4ade80") },
	loss     = { rgb("#f87171") },
}

function T.RGB(name)
	local c = T.colour[name] or T.colour.text
	return c[1], c[2], c[3]
end

-- Colour a font string by name: T.Text(fs, "muted").
function T.Text(fs, name)
	fs:SetTextColor(T.RGB(name))
	return fs
end

-- Colour a texture by name, with an alpha: T.Fill(tex, "gold", 0.1).
function T.Fill(tex, name, alpha)
	local r, g, b = T.RGB(name)
	tex:SetColorTexture(r, g, b, alpha or 1)
	return tex
end

-- ------------------------------------------------------------------ fonts

T.FONT_DISPLAY = FONTS .. "SairaCondensed-SemiBold.ttf"
T.FONT_BODY    = FONTS .. "Barlow-Medium.ttf"
T.FONT_BODY_BOLD = FONTS .. "Barlow-SemiBold.ttf"

-- Whether each face loads, asked once, through a Font object. Measured on
-- the 5.5.4 client, 2026-09-15: FontString:SetFont answers false to every
-- addon font and keeps the client's own (another addon's shipped font too),
-- while a Font object made with CreateFont takes the same file and reports
-- it back from GetFont. So the theme never sets a face on a string directly
-- -- it gives the string a Font object -- and the probe asks the same way.
-- Under pcall, because the Anniversary client throws for a missing file.
local probe = CreateFont("ArenaPlusThemeProbe")
local function loads(path)
	pcall(probe.SetFont, probe, path, 12, "")
	return probe:GetFont() == path
end
T.haveDisplay = loads(T.FONT_DISPLAY)
T.haveBody = loads(T.FONT_BODY)
T.haveBodyBold = loads(T.FONT_BODY_BOLD)

-- The face for a role, shipped or standing in. ARIALN is the client's own
-- condensed face, the nearest thing it has to Saira Condensed.
function T.Face(role)
	if role == "display" then
		return T.haveDisplay and T.FONT_DISPLAY or "Fonts\\ARIALN.TTF"
	elseif role == "bold" then
		return T.haveBodyBold and T.FONT_BODY_BOLD or (T.haveBody and T.FONT_BODY) or STANDARD_TEXT_FONT
	end
	return T.haveBody and T.FONT_BODY or STANDARD_TEXT_FONT
end

-- Set a font string's face and size: T.Font(fs, "display", 22). Through a
-- Font object (see the probe): the string's own colour is set afterwards
-- by whoever asked, and stays.
function T.Font(fs, role, size, flags)
	fs:SetFontObject(T.FontObject(role, size, "text", flags))
	return fs
end

-- A named font object for a role and size, made once, for templates and
-- buttons that take an object rather than a face.
local objects = {}
function T.FontObject(role, size, colour, flags)
	local name = ("ArenaPlusTheme_%s_%d_%s_%s"):format(role, size, colour or "text", flags or "")
	if objects[name] then return objects[name] end
	local font = CreateFont(name)
	if not pcall(font.SetFont, font, T.Face(role), size, flags or "") then
		font:SetFont(role == "display" and "Fonts\\ARIALN.TTF" or STANDARD_TEXT_FONT, size, flags or "")
	end
	font:SetTextColor(T.RGB(colour or "text"))
	objects[name] = font
	return font
end

-- ------------------------------------------------------------------ cards

-- A card is nine textures of the frame's own: a fill in two bands (so the
-- corners stay clear), four hairlines, and one corner texture placed four
-- times, mirrored through its coordinates. Nothing goes through SetBackdrop:
-- its edge-strip format rotates the top and bottom tiles and the two clients
-- did not agree on how, which left the first version of this window with
-- its side edges and nothing else. Textures placed by hand look the same
-- everywhere, and the fill is a colour rather than a file.
local KINDS = {
	card     = { fill = "surface", line = "line",     corner = MEDIA .. "corner-card.tga",      radius = 16 },
	raised   = { fill = "raised",  line = "lineSoft", corner = MEDIA .. "corner-raised.tga",    radius = 16 },
	pill     = { fill = "raised",  line = "line",     corner = MEDIA .. "corner-pill.tga",      radius = 8 },
	pillGold = { fill = "raised",  line = "gold",     corner = MEDIA .. "corner-pill-gold.tga", radius = 8 },
	-- An input: the ground colour, so a box reads as a box on the raised band it sits on.
	input    = { fill = "ground",  line = "line",     corner = MEDIA .. "corner-input.tga",     radius = 8 },
}

-- The four corners as texture coordinates: the file holds the top-left one.
local CORNERS = {
	{ "TOPLEFT",     0, 1, 0, 1 },
	{ "TOPRIGHT",    1, 0, 0, 1 },
	{ "BOTTOMLEFT",  0, 1, 1, 0 },
	{ "BOTTOMRIGHT", 1, 0, 1, 0 },
}

-- If the old Blizzard backdrop is on the frame, it goes.
local function clearBackdrop(frame)
	if frame.SetBackdrop then
		pcall(frame.SetBackdrop, frame, nil)
	end
end

-- Give a frame a rounded card of a kind: "card" for a window, "raised" for
-- a panel inside one, "pill" for a control, "pillGold" for the active one.
-- Called again with another kind, the same textures are recoloured.
function T.Backdrop(frame, kind)
	local k = KINDS[kind] or KINDS.card
	local r = k.radius
	local parts = frame.themeParts
	if not parts then
		clearBackdrop(frame)
		parts = { corners = {}, lines = {} }
		frame.themeParts = parts
		parts.across = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
		parts.down = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
		for i = 1, 4 do
			parts.corners[i] = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
			parts.lines[i] = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
		end
	end
	-- The fill: a band across, inset by the radius left and right, and a
	-- band down, inset top and bottom; between them they cover everything
	-- but the corners, which the corner textures fill for themselves.
	T.Fill(parts.across, k.fill, 1)
	parts.across:ClearAllPoints()
	parts.across:SetPoint("TOPLEFT", frame, "TOPLEFT", r, -1)
	parts.across:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -r, 1)
	T.Fill(parts.down, k.fill, 1)
	parts.down:ClearAllPoints()
	parts.down:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -r)
	parts.down:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, r)
	-- The hairlines, between the corners.
	local top, bottom, left, right = parts.lines[1], parts.lines[2], parts.lines[3], parts.lines[4]
	for _, line in ipairs(parts.lines) do
		T.Fill(line, k.line, 1)
		line:ClearAllPoints()
	end
	top:SetPoint("TOPLEFT", frame, "TOPLEFT", r, 0)
	top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -r, 0)
	top:SetHeight(1)
	bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", r, 0)
	bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -r, 0)
	bottom:SetHeight(1)
	left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -r)
	left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, r)
	left:SetWidth(1)
	right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -r)
	right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, r)
	right:SetWidth(1)
	-- The corners.
	for i, c in ipairs(CORNERS) do
		local tex = parts.corners[i]
		tex:SetTexture(k.corner)
		tex:SetTexCoord(c[2], c[3], c[4], c[5])
		tex:SetSize(r, r)
		tex:ClearAllPoints()
		tex:SetPoint(c[1], frame, c[1], 0, 0)
	end
	return frame
end

-- A window: the card, and nothing of Blizzard's dialog art. Drawn at its
-- own alpha whatever the UI's is: a card that goes see-through with a
-- 70% UIParent (measured 2026-09-15: everything under it was) reads as
-- broken, where the site's cards are solid.
function T.Panel(frame)
	if frame.SetIgnoreParentAlpha then frame:SetIgnoreParentAlpha(true) end
	return T.Backdrop(frame, "card")
end

-- ------------------------------------------------------------------ text roles

-- A column heading: small, muted, in capitals, as the site's table heads.
-- Capitals by wrapping SetText, so the modules go on writing their words.
function T.Heading(fs)
	T.Font(fs, "bold", 11)
	T.Text(fs, "faint")
	if not fs.themedHeading then
		fs.themedHeading = true
		local setText = fs.SetText
		fs.SetText = function(self, text, ...)
			return setText(self, text and strupper(text) or text, ...)
		end
		local current = fs:GetText()
		if current then setText(fs, strupper(current)) end
	end
	return fs
end

-- A window's title: the display face, big and bright.
function T.Title(fs, size)
	T.Font(fs, "display", size or 24)
	T.Text(fs, "text")
	return fs
end

-- ------------------------------------------------------------------ buttons

-- Strip a templated button of its art: every texture region goes, the
-- font string stays.
local function bare(button)
	for _, region in ipairs({ button:GetRegions() }) do
		if region:IsObjectType("Texture") then
			region:SetTexture(nil)
			region:Hide()
		end
	end
	if button.SetNormalTexture then button:SetNormalTexture("") end
	if button.SetPushedTexture then button:SetPushedTexture("") end
	if button.SetDisabledTexture then button:SetDisabledTexture("") end
	if button.SetHighlightTexture then button:SetHighlightTexture("") end
end

local function paint(button)
	local on = button.themeActive
	T.Backdrop(button, on and "pillGold" or "pill")
	local label = button.GetFontString and button:GetFontString()
	if label then
		if on then
			T.Text(label, "gold")
		elseif not button:IsEnabled() then
			T.Text(label, "faint")
		elseif button.themeHover then
			T.Text(label, "text")
		else
			T.Text(label, "muted")
		end
	end
end

-- The site's button: a dark pill with a thin line, muted text that brightens
-- under the pointer, gold line and text when it is the active choice.
-- Works on a UIPanelButtonTemplate button or a plain one with a font string.
--
-- The pill is drawn on the button's own BACKGROUND layer, under its label.
-- It was a child frame one level below at first, which put it level with
-- the window; and within a level the window's header band (BORDER) is drawn
-- over anything at BACKGROUND, so on the band the pill never showed
-- (2026-09-15, Activity and the search box).
function T.Button(button, size)
	if button.themed then return button end
	button.themed = true
	bare(button)

	local label = button.GetFontString and button:GetFontString()
	if label then
		T.Font(label, "bold", size or 12)
		label:ClearAllPoints()
		label:SetPoint("CENTER", 0, 0)
	end
	-- The template swaps font objects on hover and disable, which would put
	-- Blizzard gold back; one object for every state, colours painted here.
	if button.SetNormalFontObject then
		local object = T.FontObject("bold", size or 12, "muted")
		button:SetNormalFontObject(object)
		if button.SetHighlightFontObject then button:SetHighlightFontObject(object) end
		if button.SetDisabledFontObject then button:SetDisabledFontObject(object) end
	end

	button:HookScript("OnEnter", function(self) self.themeHover = true; paint(self) end)
	button:HookScript("OnLeave", function(self) self.themeHover = nil; paint(self) end)
	button:HookScript("OnEnable", paint)
	button:HookScript("OnDisable", paint)
	paint(button)
	return button
end

-- Mark a themed button as the active choice, or not.
function T.Active(button, on)
	if not button.themed then T.Button(button) end
	button.themeActive = on and true or nil
	paint(button)
end

-- ------------------------------------------------------------------ inputs

-- A search box: the template's art goes, the field is drawn on the box
-- itself (see T.Button for why not on a frame under it).
function T.Search(box)
	if box.themed then return box end
	box.themed = true
	for _, region in ipairs({ box:GetRegions() }) do
		if region:IsObjectType("Texture") then
			region:SetTexture(nil)
			region:SetAlpha(0)
			region:Hide()
		end
	end
	T.Backdrop(box, "input")
	T.Font(box, "body", 12)
	box:SetTextColor(T.RGB("text"))
	if box.Instructions then
		T.Font(box.Instructions, "body", 12)
		T.Text(box.Instructions, "muted")
	end
	return box
end

-- ------------------------------------------------------------------ rows

-- The alternate-row wash and the hover wash, as the site's table has them.
function T.Stripe(tex)
	tex:SetColorTexture(1, 1, 1, 0.03)
	return tex
end

function T.Hover(tex)
	local r, g, b = T.RGB("gold")
	tex:SetColorTexture(r, g, b, 0.10)
	return tex
end

-- A hairline in the line colour.
function T.Line(tex, soft)
	local r, g, b = T.RGB(soft and "lineSoft" or "line")
	tex:SetColorTexture(r, g, b, 1)
	return tex
end

-- ------------------------------------------------------------------ diagnosis

-- /arenaplus theme: what the skin found and what it drew on the ladder
-- window, in chat, for when a screenshot says something is missing.
if ns.SlashCommands then
ns.SlashCommands["theme"] = function()
	print(("ArenaPlus theme: display font %s, text font %s"):format(
		T.haveDisplay and "shipped" or "client fallback", T.haveBody and "shipped" or "client fallback"))
	-- What the font loader itself says, word for word.
	pcall(probe.SetFont, probe, T.FONT_DISPLAY, 12, "")
	print("  display probe wears: " .. tostring(probe:GetFont()))
	pcall(probe.SetFont, probe, T.FONT_BODY, 12, "")
	print("  text probe wears: " .. tostring(probe:GetFont()))
	local tex = UIParent:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\AddOns\\ArenaPlus\\Media\\fonts\\OFL-Barlow.txt")
	print("  a text file in the fonts folder, as a texture: " .. tostring(tex:GetTexture()) .. " (a number means the folder is seen)")
	tex:Hide()
	local r, g, b = T.RGB("surface")
	print(("  surface colour %.3f %.3f %.3f"):format(r or -1, g or -1, b or -1))
	local window = _G["ArenaPlus_ArenaLadder"]
	local parts = window and window.themeParts
	if not parts then
		print("  ladder window: " .. (window and "no theme parts on it" or "not built yet"))
		return
	end
	local function describe(name, tex)
		local r, g, b, a = tex:GetVertexColor()
		print(("  %s: shown %s, %dx%d, layer %s/%s, colour %.2f %.2f %.2f a%.2f, texture %s"):format(
			name, tostring(tex:IsShown()), tex:GetWidth() or 0, tex:GetHeight() or 0, tostring(tex:GetDrawLayer()),
			tostring(select(2, tex:GetDrawLayer())), r or 0, g or 0, b or 0, a or 0, tostring(tex:GetTexture())))
	end
	describe("fill across", parts.across)
	describe("fill down", parts.down)
	describe("top line", parts.lines[1])
	describe("corner", parts.corners[1])
	-- The search box: what is left of the template's art, and what the theme drew.
	local box = window.search
	if box then
		print(("  search: %dx%d, level %d (window %d), themed %s"):format(box:GetWidth(), box:GetHeight(),
			box:GetFrameLevel(), window:GetFrameLevel(), tostring(box.themed)))
		for _, region in ipairs({ box:GetRegions() }) do
			if region:IsObjectType("Texture") then
				local isOurs = false
				local bp = box.themeParts
				if bp then
					if region == bp.across or region == bp.down then isOurs = true end
					for i = 1, 4 do if region == bp.lines[i] or region == bp.corners[i] then isOurs = true end end
				end
				if not isOurs then
					print(("    template texture: shown %s, alpha %.2f, %dx%d, texture %s, atlas %s"):format(
						tostring(region:IsShown()), region:GetAlpha(), region:GetWidth() or 0, region:GetHeight() or 0,
						tostring(region:GetTexture()), tostring(region.GetAtlas and region:GetAtlas())))
				end
			end
		end
		if box.themeParts then
			describe("search fill", box.themeParts.across)
			describe("search corner", box.themeParts.corners[1])
		end
	end
	local act = window.activityButton
	if act and act.themeParts then
		print(("  activity button: level %d, shown %s"):format(act:GetFrameLevel(), tostring(act:IsShown())))
		describe("activity fill", act.themeParts.across)
	end
	local parent = window:GetParent()
	print(("  window alpha %.2f, effective %.2f, parent %s (alpha %.2f), strata %s, level %d, size %dx%d, backdrop %s"):format(
		window:GetAlpha(), window.GetEffectiveAlpha and window:GetEffectiveAlpha() or -1,
		parent and (parent:GetName() or "unnamed") or "none", parent and parent:GetAlpha() or -1,
		tostring(window:GetFrameStrata()), window:GetFrameLevel(), window:GetWidth(), window:GetHeight(),
		tostring(window.GetBackdrop and window:GetBackdrop() ~= nil)))
	print(("  fill across own alpha %.2f, blend %s; band? %s"):format(parts.across:GetAlpha(), tostring(parts.across:GetBlendMode()),
		tostring(window.themeParts ~= nil)))
end
end

-- ------------------------------------------------------------------ safety

-- Every entry point above runs guarded: a fault in the skin is reported the
-- way any error is, and the window it was dressing goes on being built with
-- whatever it had. A theme that can take a window down with it is worse
-- than no theme -- the history window was left half built by exactly that
-- on the Anniversary client on 2026-09-15.
for _, name in ipairs({ "Backdrop", "Panel", "Heading", "Title", "Button", "Active", "Search", "Font", "Text", "Fill", "Stripe", "Hover", "Line" }) do
	local plain = T[name]
	T[name] = function(...)
		local ok, result = pcall(plain, ...)
		if not ok then
			geterrorhandler()(("ArenaPlus theme (%s): %s"):format(name, tostring(result)))
			return (...)
		end
		return result
	end
end
