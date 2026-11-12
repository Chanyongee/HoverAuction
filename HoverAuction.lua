-- HoverAuction
-- 경매장이 열려 있을 때 가방 아이템 위에 마우스를 올린 채 지정 키(기본 스페이스)를 누르면
-- 해당 아이템이 판매 슬롯에 올라가고, 같은 아이템 위에 계속 올려둔 채 한 번 더 누르면 등록된다.
--
-- [설계 제약] 이 애드온은 경매장 UI에 '쓰기'를 하지 않는다.
-- 애드온(비보안 실행)이 AuctionHouseFrame:SetPostItem() 이나 판매 버튼 :Click() 을 직접 부르면
-- 경매장 UI 상태에 taint 가 묻고, 그 뒤 가방 아이템을 우클릭할 때
-- ContainerFrame.lua 의 보호된 함수 UseContainerItem() 호출이 차단된다.
--   [ADDON_ACTION_FORBIDDEN] 'HoverAuction' ... 'UseContainerItem()'
--
-- 그래서 애드온은 '무엇을 클릭할지'만 보안 버튼에 지정하고,
-- 실제 클릭과 그에 딸린 모든 동작은 블리자드 코드가 보안 실행에서 직접 수행한다.
-- 경매장 상태는 읽기만 한다(:GetItem(), :IsEnabled(), :GetQuantity() 등).

local ADDON_NAME = ...

local PREFIX = "|cff33ff99HoverAuction|r: "
local function Print(fmt, ...)
	print(PREFIX .. (select("#", ...) > 0 and fmt:format(...) or fmt))
end

local DEFAULTS = {
	enabled = true,
	key = "SPACE",
	quantity = "one",   -- one(블리자드 기본 1개) | all(최대 수량 단계를 한 번 더 거침)
	priceGuard = true,  -- 시세 조회가 끝나기 전 등록 방지
	guardWindow = 1.5,  -- 시세 조회를 기다리는 최대 시간(초)
}

local db = {}
for k, v in pairs(DEFAULTS) do db[k] = v end

--------------------------------------------------------------------------------
-- 가방 슬롯 탐지
--------------------------------------------------------------------------------

local MAX_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5

local function ValidBagSlot(bag, slot)
	if type(bag) ~= "number" or bag < 0 or bag > MAX_BAG then return false end
	if type(slot) ~= "number" or slot < 1 then return false end
	local numSlots = C_Container.GetContainerNumSlots(bag)
	if not numSlots or numSlots == 0 or slot > numSlots then return false end
	return C_Container.GetContainerItemID(bag, slot) ~= nil
end

-- GetMouseFoci() 는 애드온이 건드리면 안 되는 forbidden 프레임을 돌려줄 수 있다.
-- 그런 프레임은 IsForbidden() 외의 메서드를 호출하는 순간 차단 오류가 난다.
local function IsUsableFrame(frame)
	if type(frame) ~= "table" then return false end
	if type(frame.IsForbidden) ~= "function" then return false end
	local ok, forbidden = pcall(frame.IsForbidden, frame)
	return ok and not forbidden
end

-- 아무 프레임이나 (bag, slot) 으로 오인하지 않도록 아이템 버튼처럼 보이는지 먼저 확인한다.
local function LooksLikeItemButton(frame)
	local objType = frame:GetObjectType()
	if objType ~= "Button" and objType ~= "CheckButton" and objType ~= "ItemButton" then
		return false
	end
	return frame.icon ~= nil
		or frame.Icon ~= nil
		or frame.IconTexture ~= nil
		or frame.hasItem ~= nil
		or type(frame.GetItemLocation) == "function"
		or type(frame.GetBagID) == "function"
		or frame.bagID ~= nil
end

local function BagSlotFromFrame(frame)
	if type(frame.GetObjectType) ~= "function" then return end
	if not LooksLikeItemButton(frame) then return end

	-- 1) 블리자드 가방 버튼 및 대부분의 가방 애드온
	local bag
	if type(frame.GetBagID) == "function" then
		local ok, value = pcall(frame.GetBagID, frame)
		if ok then bag = value end
	end
	if bag == nil then bag = frame.bagID or frame.bagId or frame.bag end

	local slot = frame.slotIndex or frame.slotID
	if slot == nil and type(frame.GetID) == "function" then slot = frame:GetID() end

	-- 2) 예전 방식: 부모 프레임의 ID 가 가방 번호
	if bag == nil then
		local parent = frame:GetParent()
		if IsUsableFrame(parent) and type(parent.GetID) == "function" then bag = parent:GetID() end
	end

	if ValidBagSlot(bag, slot) then return bag, slot end

	-- 3) 마지막 수단: ItemLocation 을 직접 노출하는 버튼
	if type(frame.GetItemLocation) == "function" then
		local ok, loc = pcall(frame.GetItemLocation, frame)
		if ok and type(loc) == "table" and loc.IsBagAndSlot and loc:IsBagAndSlot() then
			bag, slot = loc:GetBagAndSlot()
			if ValidBagSlot(bag, slot) then return bag, slot end
		end
	end
end

-- 마우스가 올라가 있는 가방 아이템 버튼. (프레임, 가방, 칸) 을 돌려준다.
local function GetHoveredItemButton()
	local foci
	if GetMouseFoci then
		foci = GetMouseFoci()
	elseif GetMouseFocus then
		foci = { GetMouseFocus() }
	end
	if not foci then return end

	for i = 1, #foci do
		local frame = foci[i]
		for _ = 1, 2 do -- 자식 텍스처에 포커스가 잡힌 경우를 위해 한 단계까지 위로
			if not IsUsableFrame(frame) then break end
			local bag, slot = BagSlotFromFrame(frame)
			if bag then return frame, bag, slot end
			frame = type(frame.GetParent) == "function" and frame:GetParent() or nil
		end
	end
end

--------------------------------------------------------------------------------
-- 경매장 프레임 읽기 (읽기만 한다. 쓰면 taint 가 묻는다.)
--------------------------------------------------------------------------------

local function GetAuctionHouse()
	local ah = AuctionHouseFrame
	if ah and ah.IsShown and ah:IsShown() then return ah end
end

local function GetActiveSellFrame()
	local ah = GetAuctionHouse()
	if not ah then return end
	local frames = { ah.ItemSellFrame, ah.CommoditiesSellFrame }
	for i = 1, #frames do
		local frame = frames[i]
		if frame and frame:IsShown() then return frame end
	end
end

-- 판매 슬롯에 올라가 있는 아이템. (판매 프레임, ItemLocation) 을 돌려준다.
local function GetSellFrameItem()
	local sellFrame = GetActiveSellFrame()
	if not sellFrame then return end
	local loc = sellFrame:GetItem()
	if loc and loc:IsValid() and C_Item.DoesItemExist(loc) then
		return sellFrame, loc
	end
	return sellFrame
end

-- 마우스가 올라간 가방 아이템 중 경매 등록이 가능한 것만 돌려준다.
local function GetSellableHover()
	local frame, bag, slot = GetHoveredItemButton()
	if not frame then return end

	local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
	if not loc:IsValid() or not C_Item.DoesItemExist(loc) then return end

	local itemID = C_Item.GetItemID(loc)
	if itemID and C_WowTokenPublic and C_WowTokenPublic.IsAuctionableWowToken(itemID) then
		return -- 토큰은 취급하지 않는다
	end
	if not C_AuctionHouse.IsSellItemValid(loc, false) then return end

	return frame, loc
end

local function SameLocation(a, b)
	if not a or not b then return false end
	if not a:IsBagAndSlot() or not b:IsBagAndSlot() then return false end
	local aBag, aSlot = a:GetBagAndSlot()
	local bBag, bSlot = b:GetBagAndSlot()
	return aBag == bBag and aSlot == bSlot
end

--------------------------------------------------------------------------------
-- 보안 클릭 버튼
--------------------------------------------------------------------------------

-- 이 버튼이 실제 동작을 수행한다. 애드온은 대상만 지정하고,
-- 클릭 자체는 블리자드의 보안 코드가 실행하므로 taint 가 생기지 않는다.
local clicker = CreateFrame("Button", "HoverAuctionClicker", UIParent, "SecureActionButtonTemplate")
clicker:SetSize(1, 1)
clicker:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
clicker:EnableMouse(false)
clicker:RegisterForClicks("AnyUp", "AnyDown")
clicker:SetAttribute("useOnKeyDown", true)
clicker:Show()

-- 전투 중에 위임이 남아 있지 않도록 하는 이중 안전장치.
RegisterAttributeDriver(clicker, "type", "[combat] none; click")
RegisterAttributeDriver(clicker, "type2", "[combat] none; click")

-- 전투가 시작되면 스페이스가 곧바로 점프로 돌아와야 하는데,
-- 전투 중에는 애드온 코드가 바인딩 API를 호출할 수 없다(보호됨).
-- 그래서 바인딩 관리 전체를 보안 핸들러 스니펫에 맡긴다. 스니펫은 전투 중에도 실행된다.
--
-- 주의: SecureHandlerStateTemplate 은 이름이 'state-' 로 시작하는 속성이 바뀔 때만
-- 대응하는 _onstate-<이름> 스니펫을 실행한다. 일반 속성에 반응하는 _onattributechanged 는
-- SecureHandlerAttributeTemplate 쪽 기능이라 여기서는 동작하지 않는다.
-- 그래서 바인딩을 다시 걸라는 신호도 state 속성으로 보낸다.
local header = CreateFrame("Frame", "HoverAuctionHeader", UIParent, "SecureHandlerStateTemplate")
header:SetAttribute("clickername", clicker:GetName())

header:SetAttribute("_onstate-armed", [[
	self:ClearBindings()

	if newstate == "off" then return end
	if self:GetAttribute("state-combat") == "combat" then return end

	local key = self:GetAttribute("bindkey")
	local mouse = self:GetAttribute("bindmouse")
	if key and mouse then
		self:SetBindingClick(true, key, self:GetAttribute("clickername"), mouse)
	end
]])

-- 전투 진입 = 애드온 정지. 바인딩을 즉시 풀어서 스페이스를 점프로 돌려준다.
-- 전투가 끝나도 스스로 다시 걸지 않는다. 전투 중에 경매장이 닫혔을 수도 있으므로,
-- 애드온이 상황을 다시 확인한 뒤에만 복구한다.
header:SetAttribute("_onstate-combat", [[
	if newstate == "combat" then
		self:ClearBindings()
		self:SetAttribute("state-armed", "off")
	end
]])

RegisterStateDriver(header, "combat", "[combat] combat; nocombat")

local driver = CreateFrame("Frame", "HoverAuctionDriver", UIParent)

local active = false
local currentTarget, currentMouse
local bindSerial = 0

local function SetTarget(target, mouse)
	if InCombatLockdown() then return end
	if target == currentTarget and mouse == currentMouse then return end
	currentTarget, currentMouse = target, mouse

	if target then
		-- 보안 버튼은 마우스 버튼별로 속성을 따로 본다. (왼쪽: clickbutton, 오른쪽: clickbutton2)
		clicker:SetAttribute("clickbutton", mouse == "LeftButton" and target or nil)
		clicker:SetAttribute("clickbutton2", mouse == "RightButton" and target or nil)

		header:SetAttribute("bindkey", db.key)
		header:SetAttribute("bindmouse", mouse)
		-- 값이 매번 달라야 스니펫이 확실히 실행된다.
		bindSerial = bindSerial + 1
		header:SetAttribute("state-armed", "on" .. bindSerial)
	else
		clicker:SetAttribute("clickbutton", nil)
		clicker:SetAttribute("clickbutton2", nil)
		header:SetAttribute("state-armed", "off")
	end
end

-- 다음 판단에서 처음부터 다시 결정하게 만든다.
local function ForceRetarget()
	currentTarget, currentMouse = nil, nil
	if not InCombatLockdown() then header:SetAttribute("state-armed", "off") end
end

--------------------------------------------------------------------------------
-- 무엇을 클릭할지 결정
--------------------------------------------------------------------------------

local pending = { time = 0, ready = false, signature = nil }

local function LocationSignature(loc)
	if not loc or not loc:IsBagAndSlot() then return nil end
	local bag, slot = loc:GetBagAndSlot()
	return bag .. ":" .. slot
end

local function GetPopupAcceptButton()
	if not StaticPopup_FindVisible then return end
	local dialog = StaticPopup_FindVisible("AUCTION_HOUSE_POST_WARNING")
	if not dialog then return end

	if type(dialog.GetButton1) == "function" then
		local ok, button = pcall(dialog.GetButton1, dialog)
		if ok and button then return button end
	end
	if dialog.button1 then return dialog.button1 end
	local name = dialog.GetName and dialog:GetName()
	if name then return _G[name .. "Button1"] end
end

-- '최대' 버튼을 한 번 거쳐야 하는 상황인지. (수량 입력은 애드온이 직접 쓸 수 없다.)
--
-- 묶음 상품에서만 쓴다. 장비 같은 개별 아이템을 수량 2개 이상으로 올리면
-- 블리자드의 다중 판매 경로를 타는데, 그쪽 ClearPost 는 수량이 1일 때만 판매창을 비운다.
-- 그래서 등록이 끝나도 판매창이 이미 사라진 가방 칸을 계속 가리키고,
-- 다음 시세 조회 결과가 도착하면 블리자드 코드가 거기서 오류를 낸다.
--   Blizzard_AuctionHouseItemSellFrame.lua:202
--   bad argument #1 to 'GetCurrentItemLevel'
-- 상품 판매창은 수량과 무관하게 항상 비우므로 안전하다.
local function NeedsMaxQuantityStep(sellFrame)
	if db.quantity ~= "all" then return false end

	local ah = GetAuctionHouse()
	if not ah or sellFrame ~= ah.CommoditiesSellFrame then return false end

	local input = sellFrame.QuantityInput
	if not input or not input:IsShown() then return false end

	local maxButton = input.MaxButton
	if not maxButton or not maxButton:IsShown() or not maxButton:IsEnabled() then return false end

	local quantity = sellFrame:GetQuantity()
	local maxQuantity = sellFrame:GetMaxQuantity()
	if type(quantity) ~= "number" or type(maxQuantity) ~= "number" then return false end

	-- 사용자가 수량을 직접 입력했으면 그 값을 존중한다.
	-- 블리자드는 아이템을 판매창에 올릴 때 수량칸을 1로 되돌리므로,
	-- 1 이 아니라는 건 사용자가 직접 바꿨다는 뜻이다.
	-- 이 검사가 없으면 일부만 올리려고 입력한 수량을 '최대'가 덮어쓴다.
	if quantity ~= 1 then return false end

	return maxQuantity > 1
end

local function UpdateTarget()
	if not active or not db.enabled or InCombatLockdown() then return SetTarget(nil) end
	if not GetAuctionHouse() then return SetTarget(nil) end
	if GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() then return SetTarget(nil) end

	-- 블리자드 경고창이 떠 있으면 같은 키로 수락한다.
	local accept = GetPopupAcceptButton()
	if accept then return SetTarget(accept, "LeftButton") end

	local hoveredFrame, hoveredLoc = GetSellableHover()
	if not hoveredFrame then return SetTarget(nil) end

	local sellFrame, current = GetSellFrameItem()

	-- 판매 슬롯의 아이템이 바뀌면 시세 조회가 다시 시작된 것으로 본다.
	local signature = LocationSignature(current)
	if signature ~= pending.signature then
		pending.signature = signature
		pending.time = GetTime()
		pending.ready = false
	end

	if current and SameLocation(current, hoveredLoc) then
		-- 수량을 최대로 맞춰야 한다면 '최대' 버튼을 한 번 거친다.
		if NeedsMaxQuantityStep(sellFrame) then
			return SetTarget(sellFrame.QuantityInput.MaxButton, "LeftButton")
		end

		-- 같은 아이템 위에서 한 번 더 -> 등록 버튼
		local postButton = sellFrame and sellFrame.PostButton
		if not postButton or not postButton:IsEnabled() then return SetTarget(nil) end

		-- 판매창 가격은 경매장 검색 결과가 도착한 뒤에야 시세로 채워진다.
		-- 그 전에 등록하면 상인 판매가 기준의 기본값으로 올라가므로 잠깐 막는다.
		if db.priceGuard and not pending.ready and (GetTime() - pending.time) < db.guardWindow then
			return SetTarget(nil)
		end

		return SetTarget(postButton, "LeftButton")
	end

	-- 처음 올렸거나 다른 아이템 -> 가방 버튼 우클릭.
	-- 블리자드의 ContainerFrameItemButton_OnClick 이 AuctionHouseFrame:SetPostItem() 을 부른다.
	return SetTarget(hoveredFrame, "RightButton")
end

--------------------------------------------------------------------------------
-- 구동
--------------------------------------------------------------------------------

local THROTTLE = 0.1
local elapsed = 0

local function OnUpdate(_, delta)
	elapsed = elapsed + delta
	if elapsed < THROTTLE then return end
	elapsed = 0
	UpdateTarget()
end

-- 경매장이 닫혔다는 신호는 이벤트 하나에만 의존하지 않는다.
local function Disarm()
	active = false
	driver:SetScript("OnUpdate", nil)
	pending.signature = nil
	pending.ready = false

	-- 전투 중이라 속성을 못 건드리더라도 기억은 지워 둔다.
	-- 전투가 끝난 뒤 다시 판단할 때 '변경 없음'으로 걸러지면 안 되기 때문이다.
	currentTarget, currentMouse = nil, nil
	if not InCombatLockdown() then
		clicker:SetAttribute("clickbutton", nil)
		clicker:SetAttribute("clickbutton2", nil)
		header:SetAttribute("state-armed", "off")
	end
end

local hookedAuctionHouse = false
local function Arm()
	active = true
	pending.signature = nil
	pending.time = GetTime()
	pending.ready = false
	driver:SetScript("OnUpdate", OnUpdate)

	if not hookedAuctionHouse and AuctionHouseFrame then
		hookedAuctionHouse = true
		AuctionHouseFrame:HookScript("OnHide", Disarm)
	end
end

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("AUCTION_HOUSE_SHOW")
driver:RegisterEvent("AUCTION_HOUSE_CLOSED")
driver:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("PLAYER_LEAVING_WORLD")
driver:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
driver:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")

driver:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		HoverAuctionDB = HoverAuctionDB or {}
		for k, v in pairs(DEFAULTS) do
			if HoverAuctionDB[k] == nil then HoverAuctionDB[k] = v end
		end
		-- 애드온이 수량 입력칸에 직접 쓰던 시절의 값. 이제 one/all 만 쓴다.
		if HoverAuctionDB.quantity == "stack" then HoverAuctionDB.quantity = "all" end
		HoverAuctionDB.announce = nil
		HoverAuctionDB.confirmPopup = nil
		db = HoverAuctionDB
		self:UnregisterEvent("ADDON_LOADED")
	elseif event == "AUCTION_HOUSE_SHOW" then
		Arm()
	elseif event == "AUCTION_HOUSE_CLOSED" or event == "PLAYER_LEAVING_WORLD" then
		Disarm()
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- 바인딩 해제는 보안 스니펫이 맡는다. 여기서는 판단 루프만 멈춘다.
		Disarm()
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- 전투 중에 경매장이 닫혔을 수도 있으니 확인한 뒤에만 복귀한다.
		if GetAuctionHouse() then Arm() else Disarm() end
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
		local auctioneer = Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer
		if auctioneer == nil or arg1 == auctioneer then Disarm() end
	else -- 검색 결과 도착 = 판매창 가격이 시세로 갱신됨
		pending.ready = true
	end
end)

--------------------------------------------------------------------------------
-- 슬래시 명령
--------------------------------------------------------------------------------

local QUANTITY_LABEL = {
	one = "1개 (블리자드 기본)",
	all = "묶음 상품만 최대 (키를 한 번 더 누름)",
}

local function OnOff(value)
	return value and "|cff40ff40켜짐|r" or "|cffff4040꺼짐|r"
end

local function PrintStatus()
	Print("상태 %s / 키 |cffffd100%s|r / 수량 %s / 시세 보호 %s",
		OnOff(db.enabled), db.key, QUANTITY_LABEL[db.quantity] or db.quantity, OnOff(db.priceGuard))
end

SLASH_HOVERAUCTION1 = "/ha"
SLASH_HOVERAUCTION2 = "/hoverauction"
SlashCmdList.HOVERAUCTION = function(msg)
	local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	arg = arg or ""

	if cmd == "on" then
		db.enabled = true
		ForceRetarget()
		PrintStatus()
	elseif cmd == "off" then
		db.enabled = false
		ForceRetarget()
		PrintStatus()
	elseif cmd == "key" then
		if arg == "" then
			Print("사용법: /ha key SPACE")
		else
			db.key = arg:upper()
			ForceRetarget()
			PrintStatus()
		end
	elseif cmd == "qty" then
		if QUANTITY_LABEL[arg:lower()] then
			db.quantity = arg:lower()
			ForceRetarget()
			PrintStatus()
		else
			Print("사용법: /ha qty one | all")
		end
	elseif cmd == "guard" then
		db.priceGuard = (arg:lower() ~= "off")
		PrintStatus()
	elseif cmd == "" or cmd == "status" then
		PrintStatus()
	else
		Print("명령어")
		print("  |cffffd100/ha|r - 현재 설정 보기")
		print("  |cffffd100/ha on|r, |cffffd100/ha off|r - 사용 여부")
		print("  |cffffd100/ha key SPACE|r - 사용할 키 변경")
		print("  |cffffd100/ha qty one|r / |cffffd100all|r - 등록 수량 방식")
		print("  |cffffd100/ha guard off|r - 시세 조회 대기 보호 해제")
	end
end
