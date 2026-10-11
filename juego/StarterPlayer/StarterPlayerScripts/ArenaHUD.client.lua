-- ArenaHUD (LocalScript en StarterPlayerScripts)
-- HUD del stream con dos diseños: HORIZONTAL (16:9) y VERTICAL (9:16 para
-- TikTok). "Auto" elige según la forma de la ventana. Escala, márgenes
-- seguros y qué paneles se ven se ajustan en vivo desde el panel dev.
-- También dibuja: barras de vida sobre los peleadores, nombres en las
-- gradas y los textos flotantes (daño, CRÍTICO, K.O., etc.).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local settingsFolder = arena:WaitForChild("Settings")
local remotes = arena:WaitForChild("Remotes")
local hudEvent = remotes:WaitForChild("HudEvent")
local fxEvent = remotes:WaitForChild("FxEvent")
local devCommand = remotes:WaitForChild("DevCommand")

local activeFighters = Workspace:WaitForChild("ActiveFighters")
local waitingFighters = Workspace:WaitForChild("WaitingFighters")

local TEAMS = Shared.TEAMS
local FONT_BLACK = Enum.Font.GothamBlack
local FONT_BOLD = Enum.Font.GothamBold
local FONT = Enum.Font.GothamMedium
local WHITE = Color3.new(1, 1, 1)
local PANEL_BG = Color3.fromRGB(12, 12, 18)

local function setting(key)
	local value = settingsFolder:GetAttribute(key)
	if value == nil then
		value = Shared.DEFAULT_SETTINGS[key]
	end
	return value
end

-- Esconde la interfaz de Roblox (lista de jugadores, chat, menú...)
task.spawn(function()
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
		end)
		if ok then
			break
		end
		task.wait(0.5)
	end
end)

-- ===== HELPERS =====

local function new(className, props, children)
	local inst = Instance.new(className)
	local parent
	for key, value in pairs(props or {}) do
		if key == "Parent" then
			parent = value
		else
			inst[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 12) })
end

local function stroke(color, thickness, transparency)
	return new("UIStroke", {
		Color = color or WHITE,
		Thickness = thickness or 2,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function textLabel(props)
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = FONT_BOLD,
		TextColor3 = WHITE,
		TextScaled = true,
		TextStrokeTransparency = 0.55,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	for key, value in pairs(props) do
		if key ~= "Parent" then
			label[key] = value
		end
	end
	label.Parent = props.Parent
	return label
end

local function panel(props)
	local frame = new("Frame", {
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
	})
	corner(14).Parent = frame
	for key, value in pairs(props) do
		if key ~= "Parent" then
			frame[key] = value
		end
	end
	frame.Parent = props.Parent
	return frame
end

local function tween(inst, duration, props, style, direction)
	local t = TweenService:Create(inst, TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function hex(color)
	return string.format("#%02X%02X%02X", math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255))
end

local function escape(text)
	text = string.gsub(tostring(text), "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	return text
end

local function colored(text, color)
	return '<font color="' .. hex(color) .. '">' .. escape(text) .. "</font>"
end

-- Gradientes que giran (bordes "mágicos"): un solo bucle para todos
local spinningGradients = {}
RunService.RenderStepped:Connect(function(dt)
	for gradient in pairs(spinningGradients) do
		if gradient.Parent then
			gradient.Rotation = (gradient.Rotation + dt * 60) % 360
		else
			spinningGradients[gradient] = nil
		end
	end
end)

local function spinningStroke(parent, colors, thickness)
	local s = stroke(WHITE, thickness or 2)
	s.Parent = parent
	local gradient = new("UIGradient", { Color = colors, Parent = s })
	spinningGradients[gradient] = true
	return s, gradient
end

local function teamSequence(team)
	local info = TEAMS[team]
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, info.color),
		ColorSequenceKeypoint.new(0.5, info.dark),
		ColorSequenceKeypoint.new(1, info.color),
	})
end

-- ===== RAÍZ DEL HUD (escalado a resolución de referencia) =====

local camera = Workspace.CurrentCamera

local gui = new("ScreenGui", {
	Name = "ArenaHUD",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 10,
	Parent = playerGui,
})
local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Parent = gui })
local rootScale = new("UIScale", { Parent = root })
local safe = new("Frame", { Name = "Safe", BackgroundTransparency = 1, Parent = root })

local overheadFolder = new("Folder", { Name = "ArenaOverheads", Parent = playerGui })
local popupFolder = new("Folder", { Name = "ArenaPopups", Parent = playerGui })

local function isVertical()
	local layout = setting("HudLayout")
	if layout == "Vertical" then
		return true
	elseif layout == "Horizontal" then
		return false
	end
	local viewport = camera.ViewportSize
	return viewport.Y > viewport.X
end

local function computeScale()
	local viewport = camera.ViewportSize
	local base
	if isVertical() then
		base = math.min(viewport.X / 1080, viewport.Y / 1920)
	else
		base = math.min(viewport.X / 1920, viewport.Y / 1080)
	end
	return math.clamp(base * setting("HudScale"), 0.2, 3)
end

local currentScale = 1

-- En vertical (móvil) los textos flotantes y etiquetas se agrandan un poco para que se lean
local function textBoost()
	return if isVertical() then 1.3 else 1
end

-- ===== TÍTULO / LLAMADO A LA ACCIÓN =====

local title = panel({ Name = "Title", AnchorPoint = Vector2.new(0.5, 0), Parent = safe })
title:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0)
spinningStroke(title, ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 200, 255)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 120, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 200, 80)),
}), 2.5)
local titleLabel = textLabel({
	Size = UDim2.new(1, -40, 0.78, 0),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BLACK,
	TextStrokeTransparency = 0.3,
	Parent = title,
})
local titleScale = new("UIScale", { Parent = titleLabel }) -- (el UIScale del panel lo usa el editor)
tween(titleScale, 1.6, { Scale = 1.025 }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
TweenService:Create(titleScale, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.025 }):Play()

-- ===== MARCADOR VILLANOS vs HÉROES =====

local score = panel({ Name = "Score", Parent = safe })
stroke(Color3.fromRGB(90, 90, 110), 1.5, 0.4).Parent = score

local function scoreSide(team, alignRight)
	local info = TEAMS[team]
	local xAlign = alignRight and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
	local anchorX = alignRight and 1 or 0
	local posX = alignRight and UDim.new(1, -18) or UDim.new(0, 18)
	local name = textLabel({
		Size = UDim2.new(0.5, -60, 0, 24),
		Position = UDim2.new(posX, UDim.new(0, 8)),
		AnchorPoint = Vector2.new(anchorX, 0),
		Font = FONT_BLACK,
		TextXAlignment = xAlign,
		TextColor3 = info.color,
		Text = alignRight and (info.name .. " " .. info.emoji) or (info.emoji .. " " .. info.name),
		Parent = score,
	})
	local wins = textLabel({
		Size = UDim2.new(0.5, -60, 0, 42),
		Position = UDim2.new(posX, UDim.new(0, 32)),
		AnchorPoint = Vector2.new(anchorX, 0),
		Font = FONT_BLACK,
		TextXAlignment = xAlign,
		TextStrokeTransparency = 0.2,
		Text = "0",
		Parent = score,
	})
	local alive = textLabel({
		Size = UDim2.new(0.5, -60, 0, 16),
		Position = UDim2.new(posX, UDim.new(0, 74)),
		AnchorPoint = Vector2.new(anchorX, 0),
		Font = FONT,
		TextXAlignment = xAlign,
		TextColor3 = Color3.fromRGB(200, 200, 215),
		Text = "0 en el ring",
		Parent = score,
	})
	return { name = name, wins = wins, alive = alive, scale = new("UIScale", { Parent = wins }) }
end

local villainScore = scoreSide("villain", false)
local heroScore = scoreSide("hero", true)

local vsBadge = new("TextLabel", {
	Size = UDim2.fromOffset(58, 58),
	Position = UDim2.new(0.5, 0, 0, 12),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = Color3.fromRGB(20, 20, 28),
	Font = FONT_BLACK,
	TextScaled = true,
	TextColor3 = WHITE,
	Text = "VS",
	Parent = score,
}, { corner(29) })
spinningStroke(vsBadge, ColorSequence.new({
	ColorSequenceKeypoint.new(0, TEAMS.villain.color),
	ColorSequenceKeypoint.new(0.5, TEAMS.hero.color),
	ColorSequenceKeypoint.new(1, TEAMS.villain.color),
}), 3)
new("UIPadding", {
	PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	Parent = vsBadge,
})

local scoreBar = new("Frame", {
	Size = UDim2.new(1, -36, 0, 9),
	Position = UDim2.new(0.5, 0, 1, -10),
	AnchorPoint = Vector2.new(0.5, 1),
	BackgroundColor3 = TEAMS.hero.color,
	BorderSizePixel = 0,
	Parent = score,
}, { corner(5) })
local scoreFill = new("Frame", {
	Size = UDim2.fromScale(0.5, 1),
	BackgroundColor3 = TEAMS.villain.color,
	BorderSizePixel = 0,
	Parent = scoreBar,
}, { corner(5) })

local lastWins = { hero = 0, villain = 0 }
local function updateScore(data)
	villainScore.wins.Text = tostring(data.villain or 0)
	heroScore.wins.Text = tostring(data.hero or 0)
	villainScore.alive.Text = (data.aliveVillain or 0) .. " en el ring"
	heroScore.alive.Text = (data.aliveHero or 0) .. " en el ring"
	local total = (data.villain or 0) + (data.hero or 0)
	local ratio = total > 0 and (data.villain / total) or 0.5
	tween(scoreFill, 0.5, { Size = UDim2.fromScale(ratio, 1) })
	for team, side in pairs({ hero = heroScore, villain = villainScore }) do
		if (data[team] or 0) > lastWins[team] then
			side.scale.Scale = 1.35
			tween(side.scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		lastWins[team] = data[team] or 0
	end
end

-- ===== META DE LIKES =====

local likes = panel({ Name = "Likes", Parent = safe })
stroke(Color3.fromRGB(255, 90, 160), 1.5, 0.35).Parent = likes
local likesHeart = textLabel({
	Size = UDim2.fromOffset(46, 46),
	Position = UDim2.new(0, 12, 0.5, 0),
	AnchorPoint = Vector2.new(0, 0.5),
	Text = "❤️",
	TextStrokeTransparency = 1,
	Parent = likes,
})
local likesHeartScale = new("UIScale", { Parent = likesHeart })
local likesTitle = textLabel({
	Size = UDim2.new(1, -76, 0, 22),
	Position = UDim2.fromOffset(66, 8),
	Font = FONT_BLACK,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "META DE LIKES → MODO FURIA",
	Parent = likes,
})
local likesBar = new("Frame", {
	Size = UDim2.new(1, -78, 0, 16),
	Position = UDim2.fromOffset(66, 34),
	BackgroundColor3 = Color3.fromRGB(40, 20, 35),
	BorderSizePixel = 0,
	Parent = likes,
}, { corner(8) })
local likesFill = new("Frame", {
	Size = UDim2.fromScale(0, 1),
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Parent = likesBar,
}, {
	corner(8),
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 70, 140), Color3.fromRGB(255, 170, 90)),
	}),
})
local likesCount = textLabel({
	Size = UDim2.new(1, -78, 0, 18),
	Position = UDim2.fromOffset(66, 54),
	Font = FONT,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = Color3.fromRGB(230, 210, 225),
	Text = "0 / 1000",
	Parent = likes,
})

local likesState = { total = 0, progress = 0, goal = 1000, nextEvent = "MODO FURIA" }
local viewerCount = 0
local function renderLikes()
	likesTitle.Text = "META DE LIKES → " .. tostring(likesState.nextEvent)
	likesCount.Text = Shared.formatNumber(likesState.progress) .. " / " .. Shared.formatNumber(likesState.goal)
		.. "   •   ❤ " .. Shared.formatNumber(likesState.total)
		.. (viewerCount > 0 and ("   •   👁 " .. Shared.formatNumber(viewerCount)) or "")
	tween(likesFill, 0.35, { Size = UDim2.fromScale(math.clamp(likesState.progress / math.max(likesState.goal, 1), 0, 1), 1) })
end
local function updateLikes(data)
	local previous = likesState.total
	likesState = data
	renderLikes()
	if (data.total or 0) > previous then
		likesHeartScale.Scale = 1.35
		tween(likesHeartScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

-- ===== PANELES DE REGALOS =====

local giftPanels = {
	villain = panel({ Name = "VillainGifts", Parent = safe }),
	hero = panel({ Name = "HeroGifts", Parent = safe }),
}
for team, frame in pairs(giftPanels) do
	spinningStroke(frame, teamSequence(team), 2)
end

local function buildGiftPanel(team, horizontalRow)
	local frame = giftPanels[team]
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local info = TEAMS[team]

	local headerHeight = horizontalRow and 34 or 90
	textLabel({
		Size = UDim2.new(1, -16, 0, horizontalRow and 30 or 46),
		Position = UDim2.fromOffset(8, 4),
		Font = FONT_BLACK,
		TextColor3 = info.color,
		TextStrokeTransparency = 0.2,
		Text = horizontalRow and (info.emoji .. " " .. info.name .. "  ·  envía para ser " .. info.single .. ":") or (info.emoji .. " " .. info.name),
		Parent = frame,
	})
	if not horizontalRow then
		textLabel({
			Size = UDim2.new(1, -16, 0, 30),
			Position = UDim2.fromOffset(8, 54),
			Font = FONT,
			TextColor3 = Color3.fromRGB(200, 200, 215),
			Text = "envía para ser " .. info.single .. ":",
			Parent = frame,
		})
	end

	local holder = new("Frame", {
		Size = UDim2.new(1, -12, 1, -(headerHeight + 8)),
		Position = UDim2.fromOffset(6, headerHeight + 2),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	new("UIListLayout", {
		FillDirection = horizontalRow and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = holder,
	})

	local order = Shared.GIFT_ORDER[team]
	for index, giftId in ipairs(order) do
		local gift = Shared.GIFTS[giftId]
		local card = new("Frame", {
			Size = horizontalRow and UDim2.new(1 / #order, -6, 1, 0) or UDim2.new(1, 0, 1 / #order, -6),
			BackgroundColor3 = Color3.fromRGB(24, 24, 32),
			BackgroundTransparency = 0.2,
			LayoutOrder = index,
			Parent = holder,
		}, { corner(10) })
		local cardStroke = stroke(info.color, 1.5, 0.65)
		cardStroke.Parent = card
		if gift.action == "rain" then
			cardStroke.Transparency = 0.1
			card.BackgroundColor3 = info.dark
		end
		local cardScale = new("UIScale", { Scale = 0, Parent = card })
		task.delay(index * 0.08, function()
			tween(cardScale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
		end)

		local image = new("ImageLabel", {
			BackgroundTransparency = 1,
			Image = gift.image,
			ScaleType = Enum.ScaleType.Fit,
			Parent = card,
		})
		local imageScale = new("UIScale", { Parent = image })
		TweenService:Create(imageScale, TweenInfo.new(1.1 + index * 0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.1 }):Play()

		local nameLabel = textLabel({ Font = FONT_BLACK, Text = gift.gift, Parent = card })
		local effectLabel = textLabel({
			Font = FONT_BOLD,
			TextColor3 = gift.action == "rain" and Color3.fromRGB(255, 200, 200) or info.light,
			Text = (not horizontalRow and gift.action ~= "rain" and gift.tier) or Shared.giftEffectText(gift),
			Parent = card,
		})
		if horizontalRow then
			image.Size = UDim2.new(0.62, 0, 0.5, 0)
			image.Position = UDim2.new(0.5, 0, 0, 6)
			image.AnchorPoint = Vector2.new(0.5, 0)
			nameLabel.Size = UDim2.new(1, -8, 0.2, 0)
			nameLabel.Position = UDim2.new(0.5, 0, 0.56, 0)
			nameLabel.AnchorPoint = Vector2.new(0.5, 0)
			effectLabel.Size = UDim2.new(1, -8, 0.17, 0)
			effectLabel.Position = UDim2.new(0.5, 0, 0.78, 0)
			effectLabel.AnchorPoint = Vector2.new(0.5, 0)
		else
			image.Size = UDim2.new(0, 84, 1, -12)
			image.Position = UDim2.new(0, 6, 0.5, 0)
			image.AnchorPoint = Vector2.new(0, 0.5)
			nameLabel.Size = UDim2.new(1, -102, 0.56, 0)
			nameLabel.Position = UDim2.new(0, 96, 0.04, 0)
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextWrapped = true
			effectLabel.Size = UDim2.new(1, -102, 0.3, 0)
			effectLabel.Position = UDim2.new(0, 96, 0.64, 0)
			effectLabel.TextXAlignment = Enum.TextXAlignment.Left
		end
	end
end

-- Si cambian los regalos desde el panel web, los paneles se rehacen al momento
Shared.giftsChanged.Event:Connect(function()
	buildGiftPanel("villain", false)
	buildGiftPanel("hero", false)
end)

-- ===== COLA DE ESPERA =====

local queuePanel = panel({ Name = "Queue", Parent = safe })
stroke(Color3.fromRGB(120, 200, 255), 1.5, 0.45).Parent = queuePanel
local queueData = { entries = {}, total = 0 }

local function renderQueue()
	for _, child in ipairs(queuePanel:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local row = isVertical()
	local header = textLabel({
		Font = FONT_BLACK,
		Text = "⏳ PRÓXIMOS · " .. tostring(queueData.total or 0),
		TextXAlignment = row and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
		Parent = queuePanel,
	})
	local holder = new("Frame", { BackgroundTransparency = 1, Parent = queuePanel })
	local list = new("UIListLayout", {
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = holder,
	})
	if row then
		header.Size = UDim2.new(0, 210, 1, -16)
		header.Position = UDim2.new(0, 10, 0.5, 0)
		header.AnchorPoint = Vector2.new(0, 0.5)
		holder.Size = UDim2.new(1, -236, 1, -16)
		holder.Position = UDim2.new(0, 226, 0.5, 0)
		holder.AnchorPoint = Vector2.new(0, 0.5)
		list.FillDirection = Enum.FillDirection.Horizontal
		list.VerticalAlignment = Enum.VerticalAlignment.Center
	else
		header.Size = UDim2.new(1, -24, 0, 30)
		header.Position = UDim2.fromOffset(12, 8)
		holder.Size = UDim2.new(1, -24, 1, -48)
		holder.Position = UDim2.fromOffset(12, 42)
	end

	local entries = queueData.entries or {}
	if #entries == 0 then
		textLabel({
			Size = row and UDim2.new(1, 0, 0.7, 0) or UDim2.new(1, 0, 0, 24),
			Font = FONT,
			TextColor3 = Color3.fromRGB(180, 180, 195),
			Text = "¡Dale ❤ like, sigue o envía un regalo para entrar!",
			Parent = holder,
		})
		return
	end
	local maxEntries = row and 5 or 7
	for index = 1, math.min(maxEntries, #entries) do
		local data = entries[index]
		local info = TEAMS[data.team] or TEAMS.hero
		local item = new("Frame", {
			Size = row and UDim2.new(1 / maxEntries, -6, 1, 0) or UDim2.new(1, 0, 0, 26),
			BackgroundColor3 = info.dark,
			BackgroundTransparency = 0.35,
			LayoutOrder = index,
			Parent = holder,
		}, { corner(8) })
		local label = textLabel({
			Size = UDim2.new(1, -12, 0.8, 0),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			TextXAlignment = row and Enum.TextXAlignment.Center or Enum.TextXAlignment.Left,
			TextColor3 = info.light,
			Text = index .. ". " .. info.emoji .. " " .. data.name .. (data.boosted and " ⭐" or ""),
			Parent = item,
		})
		label.TextTransparency = 1
		task.delay((index - 1) * 0.04, function()
			tween(label, 0.25, { TextTransparency = 0 })
		end)
	end
end

-- ===== TOP CAMPEONES =====

local topPanel = panel({ Name = "Top", Parent = safe })
stroke(Color3.fromRGB(255, 205, 60), 1.5, 0.4).Parent = topPanel
local topData = { entries = {} }
local MEDALS = { "🥇", "🥈", "🥉", "4.", "5." }

local function renderTop()
	for _, child in ipairs(topPanel:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	textLabel({
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, 8),
		Font = FONT_BLACK,
		TextColor3 = Color3.fromRGB(255, 215, 80),
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "🏆 TOP CAMPEONES",
		Parent = topPanel,
	})
	local entries = topData.entries or {}
	if #entries == 0 then
		textLabel({
			Size = UDim2.new(1, -24, 0, 22),
			Position = UDim2.fromOffset(12, 46),
			Font = FONT,
			TextColor3 = Color3.fromRGB(180, 180, 195),
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "Nadie ha ganado todavía...",
			Parent = topPanel,
		})
		return
	end
	for index, data in ipairs(entries) do
		local info = TEAMS[data.team] or TEAMS.hero
		local rowFrame = new("Frame", {
			Size = UDim2.new(1, -24, 0, 32),
			Position = UDim2.fromOffset(12, 42 + (index - 1) * 38),
			BackgroundColor3 = index == 1 and Color3.fromRGB(70, 55, 10) or Color3.fromRGB(26, 26, 34),
			BackgroundTransparency = 0.3,
			Parent = topPanel,
		}, { corner(8) })
		textLabel({
			Size = UDim2.new(0, 34, 0.8, 0),
			Position = UDim2.new(0, 4, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Text = MEDALS[index],
			Parent = rowFrame,
		})
		textLabel({
			Size = UDim2.new(1, -110, 0.72, 0),
			Position = UDim2.new(0, 42, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = info.color,
			Text = data.name,
			Parent = rowFrame,
		})
		textLabel({
			Size = UDim2.new(0, 64, 0.72, 0),
			Position = UDim2.new(1, -8, 0.5, 0),
			AnchorPoint = Vector2.new(1, 0.5),
			TextXAlignment = Enum.TextXAlignment.Right,
			Font = FONT_BLACK,
			Text = data.wins .. " 🏆",
			Parent = rowFrame,
		})
	end
end

-- ===== FEED DE K.O. =====

local feed = new("Frame", { Name = "Feed", BackgroundTransparency = 1, Parent = safe })
new("UIListLayout", {
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	Parent = feed,
})
local feedCounter = 0

local function addFeed(data)
	feedCounter += 1
	local winnerColor = TEAMS[data.winnerTeam] and TEAMS[data.winnerTeam].color or Color3.fromRGB(255, 120, 120)
	local loserColor = TEAMS[data.loserTeam] and TEAMS[data.loserTeam].color or WHITE
	local text = colored(data.winner or "?", winnerColor) .. "  🥊  " .. colored(data.loser or "?", loserColor)
	if (data.streak or 0) >= 2 then
		text ..= "  " .. colored("🔥" .. data.streak, Color3.fromRGB(255, 160, 60))
	end
	local entry = new("Frame", {
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = PANEL_BG,
		BackgroundTransparency = 0.2,
		LayoutOrder = -feedCounter,
		Parent = feed,
	}, { corner(10) })
	new("Frame", {
		Size = UDim2.new(0, 6, 1, -10),
		Position = UDim2.new(0, 5, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = winnerColor,
		BorderSizePixel = 0,
		Parent = entry,
	}, { corner(3) })
	local label = textLabel({
		Size = UDim2.new(1, -26, 0.7, 0),
		Position = UDim2.new(0, 18, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		Parent = entry,
	})
	local entryScale = new("UIScale", { Scale = 0.6, Parent = entry })
	tween(entryScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)

	local entries = {}
	for _, child in ipairs(feed:GetChildren()) do
		if child:IsA("Frame") then
			table.insert(entries, child)
		end
	end
	table.sort(entries, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 6, #entries do
		entries[i]:Destroy()
	end
	task.delay(8, function()
		if entry.Parent then
			tween(entry, 0.4, { BackgroundTransparency = 1 })
			tween(label, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
			Debris:AddItem(entry, 0.45)
		end
	end)
end

-- ===== AVISOS PEQUEÑOS (quién se unió / entró) =====

local toasts = new("Frame", { Name = "Toasts", BackgroundTransparency = 1, Parent = safe })
new("UIListLayout", {
	Padding = UDim.new(0, 5),
	SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	Parent = toasts,
})
local toastCounter = 0
local toastScale = new("UIScale", { Parent = toasts }) -- más grandes en vertical

local function addToast(data)
	if setting("GameMode") == "Batalla" then
		return -- (en modo Batalla los avisos los da el HUD de batalla)
	end
	toastCounter += 1
	local info = TEAMS[data.team]
	local big = data.big == true
	local pill = new("Frame", {
		Size = UDim2.new(big and 0.95 or 0.8, 0, 0, big and 42 or 32),
		BackgroundColor3 = info and info.dark or PANEL_BG,
		BackgroundTransparency = 0.15,
		LayoutOrder = toastCounter,
		Parent = toasts,
	}, { corner(21) })
	if info then
		stroke(info.color, big and 2 or 1.2, big and 0 or 0.4).Parent = pill
	end
	local label = textLabel({
		Size = UDim2.new(1, -24, 0.72, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = big and FONT_BLACK or FONT_BOLD,
		TextColor3 = info and info.light or WHITE,
		Text = data.text or "",
		Parent = pill,
	})
	local pillScale = new("UIScale", { Scale = 0.5, Parent = pill })
	tween(pillScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)

	local list = {}
	for _, child in ipairs(toasts:GetChildren()) do
		if child:IsA("Frame") then
			table.insert(list, child)
		end
	end
	table.sort(list, function(a, b)
		return a.LayoutOrder > b.LayoutOrder
	end)
	for i = 5, #list do
		list[i]:Destroy()
	end
	task.delay(big and 3 or 2.6, function()
		if pill.Parent then
			tween(pill, 0.35, { BackgroundTransparency = 1 })
			tween(label, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 })
			for _, child in ipairs(pill:GetChildren()) do
				if child:IsA("UIStroke") then
					tween(child, 0.35, { Transparency = 1 })
				end
			end
			Debris:AddItem(pill, 0.4)
		end
	end)
end

-- ===== ANUNCIOS GRANDES (regalos, rachas, lluvias, seguidores...) =====

local announce = new("Frame", {
	Name = "Announce",
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Visible = false,
	ZIndex = 3,
	Parent = safe,
}, { corner(22) })
local announceGradient = new("UIGradient", { Rotation = 0, Parent = announce })
local announceStroke = stroke(WHITE, 3, 0)
announceStroke.Parent = announce
local announceScale = new("UIScale", { Parent = announce })
local announceImage = new("ImageLabel", {
	BackgroundTransparency = 1,
	ScaleType = Enum.ScaleType.Fit,
	Size = UDim2.new(0, 120, 0.8, 0),
	Position = UDim2.new(0, 18, 0.5, 0),
	AnchorPoint = Vector2.new(0, 0.5),
	Parent = announce,
})
local announceTitle = textLabel({ Font = FONT_BLACK, TextStrokeTransparency = 0.1, Parent = announce })
local announceSubtitle = textLabel({ Font = FONT_BOLD, TextColor3 = Color3.fromRGB(235, 235, 245), Parent = announce })

local announceQueue = {}
local currentAnnounce = nil

-- Fundido de todo el anuncio (0 = visible, 1 = invisible)
local function setAnnounceFade(alpha, duration)
	local info = TweenInfo.new(duration or 0.2, Enum.EasingStyle.Quad)
	local function go(inst, props)
		if duration and duration > 0 then
			TweenService:Create(inst, info, props):Play()
		else
			for key, value in pairs(props) do
				inst[key] = value
			end
		end
	end
	go(announce, { BackgroundTransparency = 0.05 + alpha * 0.95 })
	go(announceStroke, { Transparency = alpha })
	go(announceTitle, { TextTransparency = alpha, TextStrokeTransparency = 0.1 + alpha * 0.9 })
	go(announceSubtitle, { TextTransparency = alpha, TextStrokeTransparency = 0.55 + alpha * 0.45 })
	go(announceImage, { ImageTransparency = alpha })
end

local function announceTitleText(data)
	if data.kind == "gift" then
		return "🎁 " .. tostring(data.user) .. " envió " .. tostring(data.gift) .. ((data.count or 1) > 1 and (" x" .. data.count) or "")
	end
	return tostring(data.title or "")
end

local function renderAnnounce(data)
	local color = data.color or (TEAMS[data.team] and TEAMS[data.team].color) or Color3.fromRGB(120, 200, 255)
	local dark = TEAMS[data.team] and TEAMS[data.team].dark or color:Lerp(Color3.new(0, 0, 0), 0.75)
	announceGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, dark),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(14, 14, 20)),
		ColorSequenceKeypoint.new(1, dark),
	})
	announceStroke.Color = color
	local hasImage = data.image ~= nil and data.image ~= ""
	announceImage.Visible = hasImage
	announceImage.Image = hasImage and data.image or ""
	local left = hasImage and 150 or 24
	announceTitle.Size = UDim2.new(1, -(left + 24), 0.46, 0)
	announceTitle.Position = UDim2.new(0, left, 0.1, 0)
	announceTitle.TextColor3 = color:Lerp(WHITE, 0.25)
	announceTitle.Text = announceTitleText(data)
	announceSubtitle.Size = UDim2.new(1, -(left + 24), 0.28, 0)
	announceSubtitle.Position = UDim2.new(0, left, 0.6, 0)
	announceSubtitle.Text = tostring(data.subtitle or "")
end

local function pushAnnounce(data)
	local battleState = arena:FindFirstChild("State")
	if setting("GameMode") == "Batalla" and battleState and battleState:GetAttribute("BattleActive") then
		return -- (en plena batalla, los anuncios los da el HUD de batalla)
	end
	if data.mergeKey then
		if currentAnnounce and currentAnnounce.data.mergeKey == data.mergeKey then
			currentAnnounce.data.count = (currentAnnounce.data.count or 1) + (data.count or 1)
			announceTitle.Text = announceTitleText(currentAnnounce.data)
			currentAnnounce.untilTime = math.max(currentAnnounce.untilTime, os.clock() + 1.4)
			announceScale.Scale = 1.06
			tween(announceScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
			return
		end
		for _, queued in ipairs(announceQueue) do
			if queued.mergeKey == data.mergeKey then
				queued.count = (queued.count or 1) + (data.count or 1)
				return
			end
		end
	end
	if #announceQueue >= 6 then
		table.remove(announceQueue, 1)
	end
	table.insert(announceQueue, data)
end

task.spawn(function()
	while true do
		if currentAnnounce then
			if os.clock() >= currentAnnounce.untilTime then
				setAnnounceFade(1, 0.25)
				tween(announceScale, 0.25, { Scale = 0.85 })
				task.wait(0.27)
				announce.Visible = false
				currentAnnounce = nil
			end
		elseif #announceQueue > 0 then
			local data = table.remove(announceQueue, 1)
			-- si hay mucha fila, se muestran más rápido
			local duration = (data.duration or 2.5) * (#announceQueue > 2 and 0.6 or 1)
			currentAnnounce = { data = data, untilTime = os.clock() + duration }
			renderAnnounce(data)
			announce.Visible = true
			setAnnounceFade(1, 0)
			announceScale.Scale = 0.4
			setAnnounceFade(0, 0.2)
			tween(announceScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		task.wait(0.05)
	end
end)

-- ===== ALERTA DE LLUVIA (imagen temblando) =====

local function showAlert(data)
	local image = new("ImageLabel", {
		Size = UDim2.fromOffset(300 * textBoost(), 300 * textBoost()),
		Position = UDim2.fromScale(0.5, 0.45),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Image = data.image or "",
		ScaleType = Enum.ScaleType.Fit,
		ZIndex = 5,
		Parent = root,
	})
	task.spawn(function()
		local startedAt = os.clock()
		while os.clock() - startedAt < 2.5 and image.Parent do
			image.Position = UDim2.new(0.5, math.random(-22, 22), 0.45, math.random(-22, 22))
			image.Rotation = math.random(-9, 9)
			task.wait(0.04)
		end
		tween(image, 0.5, { ImageTransparency = 1 })
		Debris:AddItem(image, 0.55)
	end)
end

-- ===== DISEÑO: HORIZONTAL / VERTICAL =====

local VISIBILITY = {
	{ title, "HudShowTitle" },
	{ score, "HudShowScore" },
	{ likes, "HudShowLikes" },
	{ giftPanels.villain, "HudShowGifts" },
	{ giftPanels.hero, "HudShowGifts" },
	{ queuePanel, "HudShowQueue" },
	{ topPanel, "HudShowTop" },
	{ feed, "HudShowFeed" },
}

local function place(frame, anchor, position, size)
	frame.AnchorPoint = anchor
	frame.Position = position
	frame.Size = size
end

local lastVertical = nil

-- Marcador: en vertical las letras son más grandes
local function styleScore(vertical)
	local function setY(label, y, h)
		label.Position = UDim2.new(label.Position.X.Scale, label.Position.X.Offset, 0, y)
		label.Size = UDim2.new(label.Size.X.Scale, label.Size.X.Offset, 0, h)
	end
	for _, side in ipairs({ villainScore, heroScore }) do
		if vertical then
			setY(side.name, 8, 34)
			setY(side.wins, 42, 58)
			setY(side.alive, 102, 26)
		else
			setY(side.name, 8, 24)
			setY(side.wins, 32, 42)
			setY(side.alive, 74, 16)
		end
	end
	local badge = if vertical then 76 else 58
	vsBadge.Size = UDim2.fromOffset(badge, badge)
	vsBadge.Position = UDim2.new(0.5, 0, 0, if vertical then 14 else 12)
	local badgeCorner = vsBadge:FindFirstChildOfClass("UICorner")
	if badgeCorner then
		badgeCorner.CornerRadius = UDim.new(0.5, 0)
	end
end

-- ===== SECCIONES MOVIBLES (las mueve el editor del HUD, abajo a la derecha) =====
-- Cada sección guarda, por diseño (H = horizontal, V = vertical), cuánto se movió
-- (x, y en unidades del HUD), su tamaño (s) y si está oculta. Se guarda en el
-- ajuste HudCustom del bridge, así queda igual en el próximo live.
local SECTIONS = { title, score, likes, giftPanels.villain, giftPanels.hero, queuePanel, topPanel, feed }
local SECTION_LABELS = {
	Title = "Título", Score = "Marcador", Likes = "Meta de likes", VillainGifts = "Regalos villanos",
	HeroGifts = "Regalos héroes", Queue = "Próximos", Top = "Top campeones", Feed = "Feed de K.O.",
}
local DEFAULT_SCALE = { H = { Likes = 0.72 }, V = { Likes = 1.25, Top = 1.2 } }
local userScales = {}
for _, frame in ipairs(SECTIONS) do
	userScales[frame] = new("UIScale", { Name = "UserScale", Parent = frame })
end

local custom = { H = {}, V = {} }
local customDirty = false -- hay cambios locales sin guardar todavía

local function loadCustom()
	if customDirty then
		return
	end
	custom = { H = {}, V = {} }
	local ok, data = pcall(HttpService.JSONDecode, HttpService, setting("HudCustom"))
	if ok and type(data) == "table" then
		for _, key in ipairs({ "H", "V" }) do
			if type(data[key]) == "table" then
				custom[key] = data[key]
			end
		end
	end
end

local function layoutKey()
	return if isVertical() then "V" else "H"
end

local function applyCustom()
	loadCustom()
	local key = layoutKey()
	for _, frame in ipairs(SECTIONS) do
		local entry = custom[key][frame.Name]
		local scale = (DEFAULT_SCALE[key][frame.Name] or 1) * (if entry then tonumber(entry.s) or 1 else 1)
		userScales[frame].Scale = scale
		if entry then
			frame.Position += UDim2.fromOffset(tonumber(entry.x) or 0, tonumber(entry.y) or 0)
			if entry.hide then
				frame.Visible = false
			end
		end
	end
end

local function applyLayout()
	local viewport = camera.ViewportSize
	local vertical = isVertical()
	currentScale = computeScale()
	rootScale.Scale = currentScale
	root.Size = UDim2.fromOffset(viewport.X / currentScale, viewport.Y / currentScale)

	local side = setting("HudSafeSide")
	local top = setting("HudSafeTop")
	local bottom = setting("HudSafeBottom")
	safe.Position = UDim2.fromOffset(side, top)
	safe.Size = UDim2.new(1, -side * 2, 1, -(top + bottom))

	if not vertical then
		place(title, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 14), UDim2.fromOffset(780, 56))
		place(toasts, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 150), UDim2.fromOffset(560, 200))
		place(giftPanels.villain, Vector2.new(0, 0), UDim2.fromOffset(16, 86), UDim2.fromOffset(236, 600))
		place(giftPanels.hero, Vector2.new(1, 0), UDim2.new(1, -16, 0, 86), UDim2.fromOffset(236, 600))
		place(topPanel, Vector2.new(0, 0), UDim2.fromOffset(268, 86), UDim2.fromOffset(310, 240))
		place(feed, Vector2.new(1, 0), UDim2.new(1, -268, 0, 86), UDim2.fromOffset(440, 250))
		place(announce, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.4), UDim2.fromOffset(820, 150))
		place(score, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -16), UDim2.fromOffset(660, 118))
		-- meta de likes pequeña, arriba al centro (abajo a la izquierda quedan los botones dev)
		place(likes, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 76), UDim2.fromOffset(420, 80))
		place(queuePanel, Vector2.new(1, 1), UDim2.new(1, -268, 1, -16), UDim2.fromOffset(310, 250))
	else
		place(title, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 20), UDim2.fromOffset(1010, 84))
		place(score, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 114), UDim2.fromOffset(980, 150))
		place(likes, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 274), UDim2.fromOffset(780, 80))
		place(feed, Vector2.new(0, 0), UDim2.fromOffset(24, 388), UDim2.fromOffset(500, 260))
		place(topPanel, Vector2.new(1, 0), UDim2.new(1, -24, 0, 388), UDim2.fromOffset(400, 240))
		-- el aviso grande va debajo de las columnas de regalos para no taparlas
		place(announce, Vector2.new(0.5, 0.5), UDim2.new(0.5, 0, 0, 1470), UDim2.fromOffset(1000, 180))
		-- regalos en columna, uno a cada lado; la fila de "próximos" abajo del todo
		place(giftPanels.villain, Vector2.new(0, 0), UDim2.fromOffset(16, 694), UDim2.fromOffset(350, 680))
		place(giftPanels.hero, Vector2.new(1, 0), UDim2.new(1, -16, 0, 694), UDim2.fromOffset(350, 680))
		place(toasts, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -110), UDim2.fromOffset(840, 170))
		place(queuePanel, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -16), UDim2.fromOffset(1040, 78))
	end

	styleScore(vertical)
	toastScale.Scale = if vertical then 1.25 else 1

	if vertical ~= lastVertical then
		lastVertical = vertical
		buildGiftPanel("villain", false)
		buildGiftPanel("hero", false)
		renderQueue()
	end

	for _, entry in ipairs(VISIBILITY) do
		-- (en modo Batalla manda el HUD de batalla: StarterPlayerScripts.BattleHUD)
		entry[1].Visible = setting(entry[2]) == true and setting("GameMode") ~= "Batalla"
	end
	titleLabel.Text = setting("Message")
	applyCustom()
end

-- ===== EDITOR DEL HUD (solo dev): arrastrar secciones + panel abajo a la derecha =====
task.spawn(function()
	local startedWaiting = os.clock()
	while player:GetAttribute("ArenaDev") == nil and os.clock() - startedWaiting < 15 do
		task.wait(0.25)
	end
	if not player:GetAttribute("ArenaDev") then
		return
	end

	local selected = nil
	local dragging = nil
	local handles = {}
	local saveToken = 0

	local function entryFor(frame)
		local list = custom[layoutKey()]
		local entry = list[frame.Name]
		if not entry then
			entry = { x = 0, y = 0, s = 1 }
			list[frame.Name] = entry
		end
		return entry
	end

	local function save()
		customDirty = true
		saveToken += 1
		local token = saveToken
		task.delay(0.6, function()
			if token == saveToken then
				devCommand:FireServer("setSetting", { key = "HudCustom", value = HttpService:JSONEncode(custom) })
				task.delay(1.5, function()
					if token == saveToken then
						customDirty = false
					end
				end)
			end
		end)
	end

	-- ===== Panel pequeño abajo a la derecha =====
	local editorGui = new("ScreenGui", {
		Name = "ArenaHudEditor",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 60,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	local box = new("Frame", {
		ZIndex = 10,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -14),
		Size = UDim2.fromOffset(260, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(20, 20, 38),
		BackgroundTransparency = 0.08,
		Parent = editorGui,
	}, {
		corner(14),
		stroke(Color3.fromRGB(120, 120, 160), 1.5, 0.3),
		new("UIPadding", {
			PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		}),
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local boxScale = new("UIScale", { Parent = box })

	local headerRow = new("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = 0, Parent = box })
	local header = new("TextLabel", {
		Size = UDim2.new(1, -28, 1, 0),
		BackgroundTransparency = 1,
		Font = FONT_BOLD,
		TextSize = 13,
		TextColor3 = WHITE,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "✋ Toca una sección del HUD",
		Parent = headerRow,
	})
	local collapse = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(24, 22),
		BackgroundColor3 = Color3.fromRGB(38, 38, 62),
		Font = FONT_BOLD,
		TextSize = 14,
		TextColor3 = WHITE,
		Text = "–",
		Parent = headerRow,
	}, { corner(6) })

	local body = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = box,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local function row(order, height)
		return new("Frame", {
			Size = UDim2.new(1, 0, 0, height or 30),
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Parent = body,
		}, { new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	end

	local function button(parent, text, widthScale, order, color)
		local b = new("TextButton", {
			Size = UDim2.new(widthScale, -4, 1, 0),
			BackgroundColor3 = color or Color3.fromRGB(38, 38, 62),
			Font = FONT_BOLD,
			TextSize = 12,
			TextColor3 = WHITE,
			TextWrapped = true,
			Text = text,
			LayoutOrder = order,
			Parent = parent,
		}, { corner(8) })
		return b
	end

	local row1 = row(1, 34)
	local hideButton = button(row1, "🙈\nOcultar", 0.25, 1)
	local smallButton = button(row1, "🔽\nPequeño", 0.25, 2)
	local centerButton = button(row1, "🎯\nCentrar", 0.25, 3)
	local outButton = button(row1, "↔\nSacar", 0.25, 4)
	for _, b in ipairs({ hideButton, smallButton, centerButton, outButton }) do
		b.TextSize = 11
	end

	local row2 = row(2, 30)
	local minusButton = button(row2, "−", 0.25, 1, Color3.fromRGB(70, 130, 255))
	minusButton.TextSize = 20
	local sizeLabel = new("TextLabel", {
		Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundTransparency = 1,
		Font = FONT_BOLD,
		TextSize = 13,
		TextColor3 = WHITE,
		Text = "Tamaño —",
		LayoutOrder = 2,
		Parent = row2,
	})
	local plusButton = button(row2, "+", 0.25, 3, Color3.fromRGB(70, 130, 255))
	plusButton.TextSize = 20

	local row3 = row(3, 26)
	local resetButton = button(row3, "🔄 Restaurar", 0.5, 1)
	local showAllButton = button(row3, "👁 Mostrar todo", 0.5, 2)

	local function refreshEditor()
		for frame, handle in pairs(handles) do
			handle.SelectStroke.Enabled = frame == selected
		end
		if selected then
			local entry = custom[layoutKey()][selected.Name]
			local s = if entry then tonumber(entry.s) or 1 else 1
			header.Text = "✋ " .. (SECTION_LABELS[selected.Name] or selected.Name) .. (if isVertical() then "  (vertical)" else "  (horizontal)")
			sizeLabel.Text = "Tamaño " .. math.floor(s * 100 + 0.5) .. "%"
		else
			header.Text = "✋ Toca una sección del HUD"
			sizeLabel.Text = "Tamaño —"
		end
	end

	local setCollapsed -- (se define más abajo)
	local function select(frame)
		selected = frame
		if frame and setCollapsed then
			setCollapsed(false)
		end
		refreshEditor()
	end

	local function changed()
		customDirty = true -- (si no, applyLayout recargaría lo guardado y pisaría el cambio)
		applyLayout()
		refreshEditor()
		save()
	end

	-- Asas invisibles encima de cada sección (en su propia capa, siguen al panel):
	-- clic para elegirla, arrastrar para moverla
	local handleLayer = new("Frame", {
		Name = "Handles",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Parent = editorGui,
	})
	for _, frame in ipairs(SECTIONS) do
		local handle = new("TextButton", {
			Name = frame.Name,
			BackgroundTransparency = 1,
			Text = "",
			AutoButtonColor = false,
			Parent = handleLayer,
		})
		new("UIStroke", {
			Name = "SelectStroke",
			Color = Color3.fromRGB(90, 225, 255),
			Thickness = 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Enabled = false,
			Parent = handle,
		})
		handles[frame] = handle
		handle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				local top = playerGui:GetGuiObjectsAtPosition(input.Position.X, input.Position.Y)[1]
				if top ~= handle then
					return
				end
				select(frame)
				local entry = entryFor(frame)
				dragging = { frame = frame, start = input.Position, x = tonumber(entry.x) or 0, y = tonumber(entry.y) or 0, entry = entry }
			end
		end)
	end

	RunService.RenderStepped:Connect(function()
		local origin = editorGui.AbsolutePosition
		for frame, handle in pairs(handles) do
			local shown = frame.Visible and gui.Enabled
			handle.Visible = shown
			if shown then
				handle.Position = UDim2.fromOffset(frame.AbsolutePosition.X - origin.X, frame.AbsolutePosition.Y - origin.Y)
				handle.Size = UDim2.fromOffset(frame.AbsoluteSize.X, frame.AbsoluteSize.Y)
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = (input.Position - dragging.start) / math.max(currentScale, 0.01)
			dragging.entry.x = math.floor(dragging.x + delta.X + 0.5)
			dragging.entry.y = math.floor(dragging.y + delta.Y + 0.5)
			customDirty = true
			applyLayout()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = nil
			save()
		end
	end)

	local function withSelected(callback)
		return function()
			if selected then
				callback(selected, entryFor(selected))
				changed()
			end
		end
	end

	hideButton.Activated:Connect(withSelected(function(_, entry)
		entry.hide = true
		selected = nil
	end))
	smallButton.Activated:Connect(withSelected(function(_, entry)
		entry.s = if (tonumber(entry.s) or 1) > 0.75 then 0.7 else 1
	end))
	centerButton.Activated:Connect(withSelected(function(frame, entry)
		local screenCenter = gui.AbsolutePosition.X + gui.AbsoluteSize.X / 2
		local frameCenter = frame.AbsolutePosition.X + frame.AbsoluteSize.X / 2
		entry.x = math.floor((tonumber(entry.x) or 0) + (screenCenter - frameCenter) / currentScale + 0.5)
	end))
	outButton.Activated:Connect(withSelected(function(frame, entry)
		-- lo pega al borde más cercano (izquierdo o derecho)
		local left = gui.AbsolutePosition.X
		local right = left + gui.AbsoluteSize.X
		local frameLeft = frame.AbsolutePosition.X
		local frameRight = frameLeft + frame.AbsoluteSize.X
		local move
		if frameLeft + frame.AbsoluteSize.X / 2 < left + gui.AbsoluteSize.X / 2 then
			move = (left + 8) - frameLeft
		else
			move = (right - 8) - frameRight
		end
		entry.x = math.floor((tonumber(entry.x) or 0) + move / currentScale + 0.5)
	end))
	minusButton.Activated:Connect(withSelected(function(_, entry)
		entry.s = math.clamp((tonumber(entry.s) or 1) - 0.1, 0.3, 2.5)
	end))
	plusButton.Activated:Connect(withSelected(function(_, entry)
		entry.s = math.clamp((tonumber(entry.s) or 1) + 0.1, 0.3, 2.5)
	end))
	resetButton.Activated:Connect(function()
		if selected then
			custom[layoutKey()][selected.Name] = nil
			changed()
		end
	end)
	showAllButton.Activated:Connect(function()
		for _, entry in pairs(custom[layoutKey()]) do
			entry.hide = nil
		end
		changed()
	end)

	-- Plegar el panel para que se vea lo menos posible
	local collapsed = false
	setCollapsed = function(value)
		collapsed = value
		body.Visible = not collapsed
		collapse.Text = if collapsed then "+" else "–"
		box.Size = UDim2.fromOffset(if collapsed then 200 else 260, 0)
	end
	collapse.Activated:Connect(function()
		setCollapsed(not collapsed)
	end)
	setCollapsed(true)

	-- F3 lo oculta junto con los botones de abajo (captura limpia)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F3 and not UserInputService:GetFocusedTextBox() then
			box.Visible = not box.Visible
			handleLayer.Visible = box.Visible
			if not box.Visible then
				select(nil)
			end
		end
	end)

	local editorLift = 0
	local function fitEditor()
		local viewport = camera.ViewportSize
		boxScale.Scale = math.clamp(math.min(viewport.X / 820, viewport.Y / 640), 0.6, 1.2)
		local origin = editorGui.AbsolutePosition
		local bottom = origin.Y + editorGui.AbsoluteSize.Y
		local right = origin.X + editorGui.AbsoluteSize.X - 14
		local left = right - box.AbsoluteSize.X
		local baseTop = bottom - 14 - box.AbsoluteSize.Y -- dónde quedaría sin subirlo
		local lift = 0
		for _, frame in ipairs(SECTIONS) do
			if frame.Visible and frame.AbsoluteSize.Y < editorGui.AbsoluteSize.Y * 0.2 then
				local pos, size = frame.AbsolutePosition, frame.AbsoluteSize
				if pos.X < right and pos.X + size.X > left and pos.Y + size.Y > baseTop - 4 then
					lift = math.max(lift, bottom - pos.Y - 14 + 8)
				end
			end
		end
		lift = math.clamp(lift, 0, editorGui.AbsoluteSize.Y * 0.3)
		if math.abs(lift - editorLift) > 1 then
			editorLift = lift
			tween(box, 0.25, { Position = UDim2.new(1, -14, 1, -14 - editorLift) })
		end
		refreshEditor()
	end
	fitEditor()
	task.spawn(function()
		while true do
			task.wait(1)
			fitEditor()
		end
	end)
end)

-- ===== BARRAS DE VIDA SOBRE LOS PELEADORES =====

local tracked = {}

-- Al aplicar el avatar, Roblox reemplaza la cabeza del NPC: la etiqueta se
-- vuelve a enganchar a la cabeza nueva cada vez que aparece una.
local function bindHead(npc, gui, connections)
	local function attach()
		local head = npc:FindFirstChild("Head")
		if head then
			gui.Adornee = head
		end
	end
	attach()
	table.insert(connections, npc.ChildAdded:Connect(function(child)
		if child.Name == "Head" then
			task.defer(attach)
		end
	end))
end

local function untrack(npc)
	local entry = tracked[npc]
	if entry then
		for _, connection in ipairs(entry.connections) do
			connection:Disconnect()
		end
		entry.gui:Destroy()
		tracked[npc] = nil
	end
end

local function trackFighter(npc)
	local head = npc:WaitForChild("Head", 5)
	if not head or npc.Parent ~= activeFighters or tracked[npc] then
		return
	end
	local s = currentScale
	local gui = new("BillboardGui", {
		Name = "FighterTag",
		Adornee = head,
		Size = UDim2.fromOffset(160 * s * textBoost(), 50 * s * textBoost()),
		StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0),
		AlwaysOnTop = true,
		MaxDistance = 320,
		LightInfluence = 0,
		Enabled = setting("HudShowOverheads"),
		Parent = overheadFolder,
	})
	local nameLabel = textLabel({
		Size = UDim2.fromScale(1, 0.42),
		Font = FONT_BLACK,
		TextStrokeTransparency = 0,
		Parent = gui,
	})
	local hpBack = new("Frame", {
		Size = UDim2.fromScale(0.9, 0.28),
		Position = UDim2.fromScale(0.05, 0.46),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BorderSizePixel = 0,
		Parent = gui,
	}, { corner(4), stroke(Color3.new(0, 0, 0), 1, 0.2) })
	local hpLag = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(255, 240, 240),
		BorderSizePixel = 0,
		Parent = hpBack,
	}, { corner(4) })
	local hpFill = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		Parent = hpBack,
	}, {
		corner(4),
		new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 0.35) }),
		}),
	})
	local hpText = textLabel({
		Size = UDim2.fromScale(1, 1),
		Font = FONT_BLACK,
		TextStrokeTransparency = 0,
		ZIndex = 2,
		Parent = hpBack,
	})
	local energyBack = new("Frame", {
		Size = UDim2.fromScale(0.9, 0.12),
		Position = UDim2.fromScale(0.05, 0.8),
		BackgroundColor3 = Color3.fromRGB(18, 18, 24),
		BorderSizePixel = 0,
		Parent = gui,
	}, { corner(3) })
	local energyFill = new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.fromRGB(90, 225, 255),
		BorderSizePixel = 0,
		Parent = energyBack,
	}, { corner(3) })

	local lastRatio = 1
	local function refresh(attribute)
		local team = npc:GetAttribute("Team")
		local color = Shared.teamColor(team)
		local health = npc:GetAttribute("Health") or 0
		local maxHealth = math.max(1, npc:GetAttribute("MaxHealth") or 100)
		local ratio = math.clamp(health / maxHealth, 0, 1)
		local streak = npc:GetAttribute("Streak") or 0
		nameLabel.Text = (streak >= 3 and ("👑" .. streak .. " ") or "") .. tostring(npc:GetAttribute("DisplayName") or npc.Name)
		nameLabel.TextColor3 = color
		hpFill.BackgroundColor3 = ratio < 0.3 and Color3.fromRGB(255, 70, 70) or color
		hpText.Text = tostring(math.ceil(health))
		if attribute == nil then
			hpFill.Size = UDim2.fromScale(ratio, 1)
			hpLag.Size = UDim2.fromScale(ratio, 1)
		elseif ratio ~= lastRatio then
			tween(hpFill, 0.15, { Size = UDim2.fromScale(ratio, 1) })
			if ratio < lastRatio then
				TweenService:Create(hpLag, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, 0.35), { Size = UDim2.fromScale(ratio, 1) }):Play()
			else
				hpLag.Size = UDim2.fromScale(ratio, 1)
			end
		end
		lastRatio = ratio
		local energy = math.clamp((npc:GetAttribute("Energy") or 0) / 100, 0, 1)
		tween(energyFill, 0.2, { Size = UDim2.fromScale(energy, 1) })
		energyFill.BackgroundColor3 = energy >= 1 and Color3.fromRGB(160, 245, 255) or Color3.fromRGB(90, 225, 255)
	end
	refresh(nil)

	local entry = { gui = gui, connections = {}, kind = "fighter" }
	bindHead(npc, gui, entry.connections)
	table.insert(entry.connections, npc.AttributeChanged:Connect(function(attribute)
		if attribute == "Health" or attribute == "MaxHealth" or attribute == "Energy" or attribute == "Streak" or attribute == "Team" or attribute == "DisplayName" then
			refresh(attribute)
		end
	end))
	tracked[npc] = entry
end

local function trackSpectator(npc)
	local head = npc:WaitForChild("Head", 5)
	if not head or npc.Parent ~= waitingFighters or tracked[npc] then
		return
	end
	local s = currentScale
	local gui = new("BillboardGui", {
		Name = "SpectatorTag",
		Adornee = head,
		Size = UDim2.fromOffset(130 * s * textBoost(), 24 * s * textBoost()),
		StudsOffsetWorldSpace = Vector3.new(0, 2.8, 0),
		AlwaysOnTop = true,
		MaxDistance = 260,
		LightInfluence = 0,
		Enabled = setting("HudShowOverheads"),
		Parent = overheadFolder,
	})
	local label = textLabel({
		Size = UDim2.fromScale(1, 1),
		Font = FONT_BLACK,
		TextStrokeTransparency = 0,
		Parent = gui,
	})
	local function refresh()
		local boosted = (npc:GetAttribute("MaxHealth") or 100) > 100 or (npc:GetAttribute("DamageMultiplier") or 1) > 1
		label.Text = tostring(npc:GetAttribute("DisplayName") or npc.Name) .. (boosted and " ⭐" or "")
		label.TextColor3 = Shared.teamColor(npc:GetAttribute("Team"))
	end
	refresh()
	local entry = { gui = gui, connections = {}, kind = "spectator" }
	bindHead(npc, gui, entry.connections)
	table.insert(entry.connections, npc.AttributeChanged:Connect(refresh))
	tracked[npc] = entry
end

local function watchFolder(folder, trackFunction)
	folder.ChildAdded:Connect(function(npc)
		task.spawn(trackFunction, npc)
	end)
	folder.ChildRemoved:Connect(untrack)
	for _, npc in ipairs(folder:GetChildren()) do
		task.spawn(trackFunction, npc)
	end
end
watchFolder(activeFighters, trackFighter)
watchFolder(waitingFighters, trackSpectator)

local function refreshOverheads()
	local enabled = setting("HudShowOverheads")
	for _, entry in pairs(tracked) do
		entry.gui.Enabled = enabled
		if entry.kind == "fighter" then
			entry.gui.Size = UDim2.fromOffset(160 * currentScale * textBoost(), 50 * currentScale * textBoost())
		else
			entry.gui.Size = UDim2.fromOffset(130 * currentScale * textBoost(), 24 * currentScale * textBoost())
		end
	end
end

-- ===== TEXTOS FLOTANTES (daño, CRÍTICO, K.O....) =====

local function popupAnchor(target)
	if not target or not target.Parent then
		return nil
	end
	if target:IsA("BasePart") then
		return target
	end
	return target:FindFirstChild("Head") or target:FindFirstChild("HumanoidRootPart")
end

local function showPopup(data)
	if not setting("HudShowPopups") then
		return
	end
	local anchor = popupAnchor(data.target)
	if not anchor then
		return
	end
	local size = data.size or 1
	local style = data.style or "rise"
	if style == "ko" then
		size = math.max(size, 3)
	end
	local s = currentScale
	local fullSize = UDim2.fromOffset(170 * size * s * textBoost(), 44 * size * s * textBoost())
	local offset = Vector3.new((math.random() - 0.5) * 2.4, 4.4 + math.random() * 0.8, 0)
	local gui = new("BillboardGui", {
		Adornee = anchor,
		Size = style == "rise" and fullSize or UDim2.fromOffset(0, 0),
		StudsOffsetWorldSpace = offset,
		AlwaysOnTop = true,
		MaxDistance = 400,
		LightInfluence = 0,
		Parent = popupFolder,
	})
	local label = textLabel({
		Size = UDim2.fromScale(1, 1),
		Font = FONT_BLACK,
		Text = tostring(data.text or ""),
		TextColor3 = data.color or WHITE,
		TextStrokeTransparency = 0,
		Parent = gui,
	})

	if style == "rise" then
		tween(gui, 0.9, { StudsOffsetWorldSpace = offset + Vector3.new(0, 3, 0) })
		task.delay(0.5, function()
			tween(label, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end)
		Debris:AddItem(gui, 1)
		return
	end

	local hold = style == "ko" and 1.1 or 0.7
	tween(gui, 0.22, { Size = fullSize }, Enum.EasingStyle.Back)
	if style == "shake" or style == "ko" then
		task.spawn(function()
			for _ = 1, 8 do
				if not label.Parent then
					break
				end
				label.Rotation = math.random(-12, 12)
				task.wait(0.04)
			end
			label.Rotation = 0
		end)
	end
	task.delay(hold, function()
		tween(gui, 0.35, { StudsOffsetWorldSpace = offset + Vector3.new(0, 1.5, 0) })
		tween(label, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 })
	end)
	Debris:AddItem(gui, hold + 0.4)
end

local function showIcon(data)
	if not setting("HudShowPopups") then
		return
	end
	local anchor = popupAnchor(data.target)
	if not anchor then
		return
	end
	local duration = data.duration or 0.6
	local s = currentScale
	local gui = new("BillboardGui", {
		Adornee = anchor,
		Size = UDim2.fromOffset(0, 0),
		StudsOffsetWorldSpace = Vector3.new(0, 3.9, 0),
		AlwaysOnTop = true,
		MaxDistance = 300,
		LightInfluence = 0,
		Parent = popupFolder,
	})
	local image = new("ImageLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = data.image or "",
		Parent = gui,
	})
	tween(gui, 0.15, { Size = UDim2.fromOffset(54 * s * textBoost(), 54 * s * textBoost()) }, Enum.EasingStyle.Back)
	if data.spin then
		TweenService:Create(image, TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1), { Rotation = 360 }):Play()
	end
	task.delay(math.max(duration - 0.25, 0), function()
		tween(image, 0.25, { ImageTransparency = 1 })
	end)
	Debris:AddItem(gui, duration + 0.05)
end

-- ===== CONEXIONES =====

hudEvent.OnClientEvent:Connect(function(kind, data)
	if kind == "snapshot" then
		queueData = data.queue or queueData
		renderQueue()
		updateScore(data.score or {})
		topData = data.top or topData
		renderTop()
		viewerCount = data.viewers or 0
		updateLikes(data.likes or likesState)
	elseif kind == "queue" then
		queueData = data
		renderQueue()
	elseif kind == "score" then
		updateScore(data)
	elseif kind == "top" then
		topData = data
		renderTop()
	elseif kind == "likes" then
		updateLikes(data)
	elseif kind == "viewers" then
		viewerCount = tonumber(data) or 0
		renderLikes()
	elseif kind == "feed" then
		addFeed(data)
	elseif kind == "toast" then
		addToast(data)
	elseif kind == "announce" then
		pushAnnounce(data)
	elseif kind == "alert" then
		showAlert(data)
	end
end)

fxEvent.OnClientEvent:Connect(function(kind, data)
	if kind == "popup" then
		showPopup(data)
	elseif kind == "icon" then
		showIcon(data)
	end
end)

settingsFolder.AttributeChanged:Connect(function(key)
	if string.sub(key, 1, 3) == "Hud" or key == "Message" or key == "GameMode" then
		applyLayout()
		refreshOverheads()
	end
end)

local function watchCamera()
	camera = Workspace.CurrentCamera
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		applyLayout()
		refreshOverheads()
	end)
end
watchCamera()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	watchCamera()
	applyLayout()
end)

applyLayout()
renderTop()
renderLikes()
devCommand:FireServer("hello")
