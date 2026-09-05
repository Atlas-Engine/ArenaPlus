local ADDON_NAME, ns = ...
local L = ns.L

-- A button on the minimap, wearing the gladiator helmet the ladder button uses.
--
-- Hand-rolled rather than pulled in through LibDBIcon: this addon carries no
-- libraries at all, and the whole of a minimap button is an angle, a texture
-- and a ring. The arrangement below -- a small button with the icon as its
-- normal texture, and the ring in a frame of its own offset over the top -- is
-- the one AtlasProfiler uses, and it is what stops the icon spilling outside
-- the ring at odd sizes.
local module = ns.RegisterModule("minimap",{
	title       = L.MINIMAP_TITLE,
	enableLabel = L.MINIMAP_ENABLE,
	desc        = L.MINIMAP_DESC,
	group       = "arena",
	-- Bottom right of the minimap, clear of the tracking and calendar buttons.
	defaults    = { enabled=true, angle=-40 },
})

-- Our own art, not the game's.
--
-- This was Interface\Iconschievement_featsofstrength_gladiator_01, which
-- is achievement-era art: the Anniversary client does not have it and drew
-- nothing at all. Shipping the picture removes the question of which client
-- happens to hold which texture.
--
-- Converted from tools\ArenaPlusDashboard.ico, so the taskbar, the dashboard
-- and this button all wear the same helmet. 64x64 because it draws at 17.
local ICON = "Interface\\AddOns\\ArenaPlus\\Media\\minimap"

local button

----------------------------------------------------------------
-- Where it sits
----------------------------------------------------------------

-- Around the edge, wherever it was left.
--
-- The radius is measured from the minimap rather than written down: the frame
-- is resized by other addons often enough that a fixed number ends up either
-- inside the map or floating off it.
local function Reposition()
	if not (button and Minimap) then return end

	local radius=((Minimap.GetWidth and Minimap:GetWidth()) or 140)/2+5
	local radians=math.rad(module.db.angle or -40)

	button:ClearAllPoints()
	button:SetPoint("CENTER",Minimap,"CENTER",
		math.cos(radians)*radius,math.sin(radians)*radius)
end

-- Dragging moves it around the ring rather than across the screen, which is
-- what every other minimap button does and the only thing that stays put when
-- the minimap itself moves.
local function FollowCursor(self)
	local scale=UIParent:GetEffectiveScale()
	local x,y=GetCursorPosition()
	x,y=x/scale,y/scale

	local mx,my=Minimap:GetCenter()
	if not (mx and my) then return end

	module.db.angle=math.deg(math.atan2(y-my,x-mx))
	Reposition()
end

----------------------------------------------------------------
-- Building it
----------------------------------------------------------------

local function Create()
	if button or not Minimap then return button end

	button=CreateFrame("Button","ArenaPlus_MinimapButton",Minimap)

	-- The measurements every minimap button uses: a 31 point button, a 17 point
	-- icon inset to the top left, and a 53 point ring drawn from the very
	-- corner. They look arbitrary because they are -- the ring art is mostly
	-- transparent and sits off-centre inside its own bounds, so the numbers are
	-- what line the hole in it up with the icon.
	--
	-- The first attempt copied AtlasProfiler's, which are different because its
	-- icon is a round texture drawn to fit. A square spell icon in that layout
	-- comes out as a square with no ring around it, which is what you saw.
	button:SetSize(31,31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetMovable(true)
	button:EnableMouse(true)
	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("LeftButtonUp","RightButtonUp","MiddleButtonUp")

	-- Behind the icon, so the corners the round crop cuts away are dark rather
	-- than showing the map through them.
	local backdrop=button:CreateTexture(nil,"BACKGROUND")
	backdrop:SetSize(20,20)
	backdrop:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	backdrop:SetPoint("TOPLEFT",7,-5)

	button.icon=button:CreateTexture(nil,"ARTWORK")
	button.icon:SetSize(17,17)
	button.icon:SetPoint("TOPLEFT",7,-6)
	button.icon:SetTexture(ICON)
	-- Drawn whole. The 8% trim that used to be here is for BLIZZARD icons,
	-- whose art includes a border; ours has none, so trimming it just cut the
	-- helmet.

	local ring=button:CreateTexture(nil,"OVERLAY")
	ring:SetSize(53,53)
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	ring:SetPoint("TOPLEFT")

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local highlight=button:GetHighlightTexture()
	if highlight then highlight:SetBlendMode("ADD") end

	button:SetScript("OnDragStart",function(self)
		self:SetScript("OnUpdate",FollowCursor)
	end)

	button:SetScript("OnDragStop",function(self)
		self:SetScript("OnUpdate",nil)
		Reposition()
	end)

	button:SetScript("OnEnter",function(self)
		GameTooltip:SetOwner(self,"ANCHOR_LEFT")
		GameTooltip:SetText(L.ADDON_NAME)
		GameTooltip:AddLine(L.MINIMAP_TIP_LEFT,1,1,1)
		GameTooltip:AddLine(L.MINIMAP_TIP_RIGHT,1,1,1)
		GameTooltip:AddLine(L.MINIMAP_TIP_MIDDLE,1,1,1)
		GameTooltip:AddLine(L.MINIMAP_TIP_DRAG,0.7,0.7,0.7)
		GameTooltip:Show()
	end)

	button:SetScript("OnLeave",function() GameTooltip:Hide() end)

	button:SetScript("OnClick",function(_,click)
		if click=="MiddleButton" then
			return ns.ToggleConfig and ns.ToggleConfig()
		end
		if click=="RightButton" then
			return ns.ToggleLadder and ns.ToggleLadder()
		end
		if ns.ToggleArenaHistory then ns.ToggleArenaHistory() end
	end)

	Reposition()
	return button
end

----------------------------------------------------------------
-- Switching it on and off
----------------------------------------------------------------

local function Apply()
	if not module.db.enabled then
		if button then button:Hide() end
		return
	end

	if Create() then
		Reposition()
		button:Show()
	end
end

function module:OnEnable()
	Apply()
end

-- Hooks cannot be removed, so a switched-off tweak hides rather than tears
-- down -- the same rule the rest of the addon follows.
function module:OnToggle()
	Apply()
end
