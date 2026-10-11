-- DevPanel (LocalScript en StarterPlayerScripts)
-- Panel de desarrollador dentro del juego. Como en "A Correr": botones en
-- pantalla abajo a la izquierda (🛠️ DEV, 🎥 CÁMARA, ⚡ ACCIONES) que despliegan
-- sus paneles con animación. F2 abre/cierra el panel DEV, F3 oculta los botones.
-- Solo aparece en Studio o para el dueño del juego (atributo ArenaDev).
-- Todo lo que cambias aquí se guarda en el bridge (settings.json).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local startedWaiting = os.clock()
while player:GetAttribute("ArenaDev") == nil and os.clock() - startedWaiting < 15 do
	task.wait(0.25)
end
if not player:GetAttribute("ArenaDev") then
	return
end

local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local settingsFolder = arena:WaitForChild("Settings")
local stateFolder = arena:WaitForChild("State")
local devCommand = arena:WaitForChild("Remotes"):WaitForChild("DevCommand")

local WHITE = Color3.new(1, 1, 1)
local BG = Color3.fromRGB(14, 14, 20)
local CARD = Color3.fromRGB(26, 26, 36)
local ACCENT = Color3.fromRGB(120, 190, 255)
local MUTED = Color3.fromRGB(160, 160, 180)
local GOOD = Color3.fromRGB(90, 220, 140)
local BAD = Color3.fromRGB(255, 90, 90)
local HERO = Shared.TEAMS.hero.color
local VILLAIN = Shared.TEAMS.villain.color

local function setting(key)
	local value = settingsFolder:GetAttribute(key)
	if value == nil then
		value = Shared.DEFAULT_SETTINGS[key]
	end
	return value
end

local function send(action, args)
	devCommand:FireServer(action, args or {})
end

local function setSetting(key, value)
	send("setSetting", { key = key, value = value })
end

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

local function tween(inst, seconds, goal, style)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local t = TweenService:Create(inst, info, goal)
	t:Play()
	return t
end

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
end

local function label(props)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	})
	for key, value in pairs(props) do
		if key ~= "Parent" then
			l[key] = value
		end
	end
	l.Parent = props.Parent
	return l
end

-- ===== VENTANA =====

local gui = new("ScreenGui", {
	Name = "ArenaDevPanel",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

-- Ventana desplegable. Es un CanvasGroup para poder desvanecer todo su contenido a la vez.
local WINDOW_HOME = UDim2.new(0, 14, 1, -70) -- justo encima de los botones de abajo
local windowHome = WINDOW_HOME
local window = new("CanvasGroup", {
	Size = UDim2.fromOffset(620, 700),
	Position = WINDOW_HOME,
	AnchorPoint = Vector2.new(0, 1),
	BackgroundColor3 = BG,
	BackgroundTransparency = 0.04,
	BorderSizePixel = 0,
	GroupTransparency = 1,
	Visible = false,
	Parent = gui,
}, { corner(14), new("UIStroke", { Color = ACCENT, Thickness = 1.5, Transparency = 0.4 }) })
local windowScale = new("UIScale", { Parent = window })

local header = new("Frame", {
	Size = UDim2.new(1, 0, 0, 46),
	BackgroundColor3 = Color3.fromRGB(22, 22, 32),
	BorderSizePixel = 0,
	Parent = window,
}, { corner(14) })
label({
	Size = UDim2.new(1, -120, 1, 0),
	Position = UDim2.fromOffset(16, 0),
	Font = Enum.Font.GothamBlack,
	TextSize = 18,
	Text = "🥊 PANEL DEV — ¡A LA TROMPA!",
	Parent = header,
})
local statusDot = label({
	Size = UDim2.new(0, 110, 1, 0),
	Position = UDim2.new(1, -150, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Right,
	TextSize = 13,
	TextColor3 = MUTED,
	Text = "",
	Parent = header,
})
local closeButton = new("TextButton", {
	Size = UDim2.fromOffset(32, 32),
	Position = UDim2.new(1, -8, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	BackgroundColor3 = Color3.fromRGB(60, 30, 40),
	Font = Enum.Font.GothamBlack,
	TextSize = 16,
	TextColor3 = WHITE,
	Text = "✕",
	Parent = header,
}, { corner(8) })

local tabBar = new("Frame", {
	Size = UDim2.new(1, -20, 0, 34),
	Position = UDim2.fromOffset(10, 52),
	BackgroundTransparency = 1,
	Parent = window,
}, {
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
})

local pages = new("Frame", {
	Size = UDim2.new(1, -20, 1, -130),
	Position = UDim2.fromOffset(10, 92),
	BackgroundTransparency = 1,
	Parent = window,
})

local footer = label({
	Size = UDim2.new(1, -24, 0, 28),
	Position = UDim2.new(0, 12, 1, -32),
	TextSize = 12,
	Font = Enum.Font.Gotham,
	TextColor3 = MUTED,
	Text = "F2 abre/cierra • F3 oculta los botones de abajo • arrastra la barra de arriba para mover • se guarda en el bridge",
	Parent = window,
})

-- Arrastrar la ventana
do
	local dragging, dragStart, startPosition
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPosition = window.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			window.Position = startPosition + UDim2.fromOffset(delta.X, delta.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if dragging then
				windowHome = window.Position -- recuerda dónde la dejaste
			end
			dragging = false
		end
	end)
end

-- ===== PESTAÑAS =====

local tabs = {}
local currentTab

local function selectTab(name)
	currentTab = name
	for tabName, tab in pairs(tabs) do
		local active = tabName == name
		tab.page.Visible = active
		tab.button.BackgroundColor3 = active and ACCENT or CARD
		tab.button.TextColor3 = active and Color3.fromRGB(10, 10, 16) or WHITE
	end
end

local function addTab(name, order)
	local button = new("TextButton", {
		Size = UDim2.new(1 / 8, -4, 1, 0),
		BackgroundColor3 = CARD,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = WHITE,
		Text = name,
		LayoutOrder = order,
		AutoButtonColor = true,
		Parent = tabBar,
	}, { corner(8) })
	local page = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = ACCENT,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = pages,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", { PaddingRight = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }),
	})
	tabs[name] = { button = button, page = page, order = 0 }
	button.MouseButton1Click:Connect(function()
		selectTab(name)
	end)
	return page
end

local function nextOrder(page)
	for _, tab in pairs(tabs) do
		if tab.page == page then
			tab.order += 1
			return tab.order
		end
	end
	return 0
end

-- ===== CONTROLES =====

local settingListeners = {} -- key -> { function(value) }

local function onSetting(key, callback)
	settingListeners[key] = settingListeners[key] or {}
	table.insert(settingListeners[key], callback)
	callback(setting(key))
end

settingsFolder.AttributeChanged:Connect(function(key)
	for _, callback in ipairs(settingListeners[key] or {}) do
		callback(setting(key))
	end
end)

local function section(page, text)
	label({
		Size = UDim2.new(1, 0, 0, 26),
		Font = Enum.Font.GothamBlack,
		TextSize = 14,
		TextColor3 = ACCENT,
		Text = string.upper(text),
		LayoutOrder = nextOrder(page),
		Parent = page,
	})
end

local function hint(page, text)
	label({
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = MUTED,
		Text = text,
		LayoutOrder = nextOrder(page),
		Parent = page,
	})
end

local function flashButton(button)
	local original = button.BackgroundColor3
	button.BackgroundColor3 = WHITE
	TweenService:Create(button, TweenInfo.new(0.3), { BackgroundColor3 = original }):Play()
end

-- Fila de botones: { { text, color, callback }, ... }
local function buttonRow(page, buttons, height)
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, height or 38),
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(page),
		Parent = page,
	}, {
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local created = {}
	for index, data in ipairs(buttons) do
		local button = new("TextButton", {
			Size = UDim2.new(1 / #buttons, -6 * (#buttons - 1) / #buttons, 1, 0),
			BackgroundColor3 = data[2] or CARD,
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextColor3 = WHITE,
			TextWrapped = true,
			Text = data[1],
			LayoutOrder = index,
			Parent = row,
		}, { corner(8), new("UIStroke", { Color = WHITE, Transparency = 0.85, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) })
		button.MouseButton1Click:Connect(function()
			flashButton(button)
			data[3]()
		end)
		table.insert(created, button)
	end
	return created
end

local function textBox(page, placeholder, default)
	local box = new("TextBox", {
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundColor3 = CARD,
		Font = Enum.Font.GothamMedium,
		TextSize = 15,
		TextColor3 = WHITE,
		PlaceholderText = placeholder,
		PlaceholderColor3 = MUTED,
		Text = default or "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = nextOrder(page),
		Parent = page,
	}, { corner(8), new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })
	return box
end

local function toggle(page, key, text)
	local row = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = CARD,
		Text = "",
		AutoButtonColor = true,
		LayoutOrder = nextOrder(page),
		Parent = page,
	}, { corner(8) })
	label({ Size = UDim2.new(1, -80, 1, 0), Position = UDim2.fromOffset(12, 0), Text = text, Parent = row })
	local track = new("Frame", {
		Size = UDim2.fromOffset(46, 22),
		Position = UDim2.new(1, -12, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = Color3.fromRGB(60, 60, 75),
		Parent = row,
	}, { corner(11) })
	local knob = new("Frame", {
		Size = UDim2.fromOffset(18, 18),
		Position = UDim2.new(0, 2, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = WHITE,
		Parent = track,
	}, { corner(9) })
	onSetting(key, function(value)
		track.BackgroundColor3 = value and GOOD or Color3.fromRGB(60, 60, 75)
		TweenService:Create(knob, TweenInfo.new(0.15), { Position = value and UDim2.new(1, -20, 0.5, 0) or UDim2.new(0, 2, 0.5, 0) }):Play()
	end)
	row.MouseButton1Click:Connect(function()
		setSetting(key, not setting(key))
	end)
end

local function slider(page, key, text, minValue, maxValue, step, format)
	format = format or function(value)
		return tostring(value)
	end
	local frame = new("Frame", {
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundColor3 = CARD,
		LayoutOrder = nextOrder(page),
		Parent = page,
	}, { corner(8) })
	label({ Size = UDim2.new(0.7, 0, 0, 24), Position = UDim2.fromOffset(12, 2), Text = text, Parent = frame })
	local valueLabel = label({
		Size = UDim2.new(0.3, -12, 0, 24),
		Position = UDim2.new(0.7, 0, 0, 2),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = ACCENT,
		Parent = frame,
	})
	local bar = new("Frame", {
		Size = UDim2.new(1, -24, 0, 8),
		Position = UDim2.fromOffset(12, 34),
		BackgroundColor3 = Color3.fromRGB(50, 50, 65),
		Parent = frame,
	}, { corner(4) })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = ACCENT, Parent = bar }, { corner(4) })
	local knob = new("Frame", {
		Size = UDim2.fromOffset(16, 16),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = WHITE,
		Parent = bar,
	}, { corner(8) })
	local hitArea = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1,
		Text = "",
		Parent = bar,
	})

	local function render(value)
		local ratio = math.clamp((value - minValue) / (maxValue - minValue), 0, 1)
		fill.Size = UDim2.fromScale(ratio, 1)
		knob.Position = UDim2.fromScale(ratio, 0.5)
		valueLabel.Text = format(value)
	end
	local dragging = false
	onSetting(key, function(value)
		if not dragging then
			render(value)
		end
	end)

	local lastSent = 0
	local pendingValue
	local function valueFromInput(input)
		local ratio = math.clamp((input.Position.X - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local value = minValue + ratio * (maxValue - minValue)
		value = math.floor(value / step + 0.5) * step
		return math.clamp(value, minValue, maxValue)
	end
	local function update(input, final)
		local value = valueFromInput(input)
		render(value)
		pendingValue = value
		if final or os.clock() - lastSent > 0.12 then
			lastSent = os.clock()
			setSetting(key, value)
			pendingValue = nil
		end
	end
	hitArea.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			update(input, false)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input, false)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if pendingValue then
				setSetting(key, pendingValue)
				pendingValue = nil
			end
		end
	end)
end

local function choice(page, key, text, options, labels)
	if text then
		label({ Size = UDim2.new(1, 0, 0, 20), Text = text, TextColor3 = MUTED, TextSize = 13, LayoutOrder = nextOrder(page), Parent = page })
	end
	local buttons = {}
	local perRow = math.min(#options, 4)
	for startIndex = 1, #options, perRow do
		local rowData = {}
		for index = startIndex, math.min(startIndex + perRow - 1, #options) do
			local option = options[index]
			table.insert(rowData, { labels and labels[index] or option, CARD, function()
				setSetting(key, option)
			end })
		end
		local created = buttonRow(page, rowData, 36)
		for offset, button in ipairs(created) do
			buttons[options[startIndex + offset - 1]] = button
		end
	end
	onSetting(key, function(value)
		for option, button in pairs(buttons) do
			local active = option == value
			button.BackgroundColor3 = active and ACCENT or CARD
			button.TextColor3 = active and Color3.fromRGB(10, 10, 16) or WHITE
		end
	end)
end

local function percent(value)
	return math.floor(value * 100 + 0.5) .. "%"
end

local function multiplier(value)
	return string.format("x%.2f", value)
end

-- ===== PESTAÑA: SIMULAR =====

local simPage = addTab("Simular", 1)
section(simPage, "Espectador de TikTok (prueba sin live)")
local nameBox = textBox(simPage, "Nombre de TikTok para las pruebas", "Tester")
local function simName()
	local text = nameBox.Text
	return text ~= "" and text or "Tester"
end
buttonRow(simPage, {
	{ "🧪 Meter HÉROE", Color3.fromRGB(110, 85, 10), function() send("simJoin", { name = simName(), team = "hero" }) end },
	{ "🧪 Meter VILLANO", Color3.fromRGB(70, 30, 100), function() send("simJoin", { name = simName(), team = "villain" }) end },
	{ "🎲 Meter (auto)", CARD, function() send("simJoin", { name = simName() }) end },
})
buttonRow(simPage, {
	{ "🤖 +4 bots", CARD, function() send("simBots", { count = 4 }) end },
	{ "🤖 +8 bots", CARD, function() send("simBots", { count = 8 }) end },
	{ "🤖 +20 bots", CARD, function() send("simBots", { count = 20 }) end },
})

section(simPage, "Regalos (usa el nombre de arriba)")
local countBox = textBox(simPage, "Cantidad (combo)", "1")
local function giftGrid(team)
	local grid = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = nextOrder(simPage),
		Parent = simPage,
	}, {
		new("UIGridLayout", { CellSize = UDim2.new(1 / 6, -5, 0, 96), CellPadding = UDim2.fromOffset(5, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	-- (se rehace si cambian los regalos desde el panel web)
	local function fill()
	for _, child in ipairs(grid:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for index, giftId in ipairs(Shared.GIFT_ORDER[team]) do
		local info = Shared.GIFTS[giftId]
		local button = new("TextButton", {
			Size = UDim2.new(1 / 6, -5, 1, 0),
			BackgroundColor3 = Shared.TEAMS[team].dark,
			Text = "",
			LayoutOrder = index,
			Parent = grid,
		}, { corner(8), new("UIStroke", { Color = Shared.TEAMS[team].color, Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) })
		new("ImageLabel", {
			Size = UDim2.new(1, -16, 0, 50),
			Position = UDim2.new(0.5, 0, 0, 6),
			AnchorPoint = Vector2.new(0.5, 0),
			BackgroundTransparency = 1,
			Image = info.image,
			ScaleType = Enum.ScaleType.Fit,
			Parent = button,
		})
		label({
			Size = UDim2.new(1, -6, 0, 32),
			Position = UDim2.new(0.5, 0, 1, -34),
			AnchorPoint = Vector2.new(0.5, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextSize = 11,
			Text = info.gift,
			Parent = button,
		})
		button.MouseButton1Click:Connect(function()
			flashButton(button)
			send("simGift", { name = simName(), giftId = giftId, count = tonumber(countBox.Text) or 1 })
		end)
	end
	end
	fill()
	Shared.giftsChanged.Event:Connect(fill)
end
giftGrid("hero")
giftGrid("villain")
buttonRow(simPage, {
	{ "🎁 Otro regalo (5💎)", CARD, function() send("simGift", { name = simName(), giftId = 1, giftName = "Regalo sorpresa", diamonds = 5, count = tonumber(countBox.Text) or 1 }) end },
})

section(simPage, "Likes y seguidores (un like o seguir te mete a pelear)")
buttonRow(simPage, {
	{ "❤ +50 likes", Color3.fromRGB(110, 30, 70), function() send("simLikes", { name = simName(), count = 50 }) end },
	{ "❤ +250 likes", Color3.fromRGB(110, 30, 70), function() send("simLikes", { name = simName(), count = 250 }) end },
	{ "❤ +1000 likes", Color3.fromRGB(110, 30, 70), function() send("simLikes", { name = simName(), count = 1000 }) end },
})
buttonRow(simPage, {
	{ "💖 Seguir", CARD, function() send("simFollow", { name = simName() }) end },
})

-- ===== PESTAÑA: EVENTOS =====

local eventsPage = addTab("Eventos", 2)
section(eventsPage, "Lluvias de guantes")
buttonRow(eventsPage, {
	{ "🌟 Lluvia DORADA (daña villanos)", Color3.fromRGB(110, 85, 10), function() send("rain", { kind = "gold", name = simName() }) end },
	{ "🌑 Lluvia OSCURA (daña héroes)", Color3.fromRGB(70, 30, 100), function() send("rain", { kind = "dark", name = simName() }) end },
}, 46)
section(eventsPage, "Metas de likes")
buttonRow(eventsPage, {
	{ "🔥 Modo FURIA", Color3.fromRGB(120, 50, 10), function() send("fury") end },
	{ "💖 Lluvia de corazones", Color3.fromRGB(120, 30, 80), function() send("hearts") end },
})
section(eventsPage, "Peleadores")
buttonRow(eventsPage, {
	{ "⚡ Cargar SÚPER a todos", CARD, function() send("chargeAll") end },
	{ "❤ Curar a todos", CARD, function() send("healAll") end },
	{ "💀 K.O. al azar", Color3.fromRGB(90, 25, 25), function() send("koRandom") end },
})
section(eventsPage, "Entradas de cine (pausan el juego)")
buttonRow(eventsPage, {
	{ "🎬 Entrada ÉLITE", Color3.fromRGB(110, 85, 10), function() send("testEntrance", { kind = "elite" }) end },
	{ "🎬 Entrada DEFINITIVA", Color3.fromRGB(70, 30, 100), function() send("testEntrance", { kind = "definitive" }) end },
}, 42)
hint(eventsPage, "Entran solos cuando alguien con regalo Élite/Legendario o Definitivo pasa al ring. Estos botones meten a un peleador de prueba ya mismo.")
section(eventsPage, "Anuncio en pantalla")
local announceBox = textBox(eventsPage, "Texto del anuncio grande", "")
buttonRow(eventsPage, {
	{ "📢 Anunciar", Color3.fromRGB(30, 70, 110), function() send("announce", { text = announceBox.Text }) end },
})

-- ===== PESTAÑA: ARENA =====

local arenaPage = addTab("Arena", 3)
section(arenaPage, "Juego")
toggle(arenaPage, "Paused", "⏸ Pausar (no entran ni se emparejan nuevos)")
slider(arenaPage, "MaxFighters", "Peleadores en el ring", 2, 8, 1)
slider(arenaPage, "DamageScale", "Daño global", 0.25, 4, 0.05, multiplier)
slider(arenaPage, "CritChance", "Probabilidad de crítico", 0, 0.6, 0.01, percent)
slider(arenaPage, "BlockChance", "Probabilidad de bloqueo", 0, 0.6, 0.01, percent)
slider(arenaPage, "DodgeChance", "Probabilidad de esquiva", 0, 0.5, 0.01, percent)
toggle(arenaPage, "SameTeamSparring", "🤜🤛 Práctica entre compañeros si no hay rival")
toggle(arenaPage, "LikeJoins", "❤ Un like te mete a pelear")
toggle(arenaPage, "FollowJoins", "➕ Seguir te mete a pelear (con vida extra)")
slider(arenaPage, "LikeGoal", "Likes por meta (furia / corazones)", 50, 10000, 50, Shared.formatNumber)

section(arenaPage, "Mensaje del título")
local messageBox = textBox(arenaPage, "Mensaje personalizado", setting("Message"))
onSetting("Message", function(value)
	if not messageBox:IsFocused() then
		messageBox.Text = value
	end
end)
buttonRow(arenaPage, {
	{ "✔ Aplicar mensaje", Color3.fromRGB(30, 90, 60), function() setSetting("Message", messageBox.Text) end },
})
for _, preset in ipairs({
	"🥊 DALE LIKE, SIGUE O ENVÍA UN REGALO PARA PELEAR",
	"👑 ÉLITE Y DEFINITIVO ENTRAN AL RING CON ENTRADA DE CINE",
	"🎁 CADA REGALO TE HACE MÁS FUERTE — ¡Y TE SALTAS LA FILA!",
	"❤ DALE LIKES: CURAN A TU PELEADOR Y LLENAN LA META",
	"🌧 CISNE = LLUVIA DORADA • SOMBRERO = LLUVIA OSCURA",
	"🔥 ¿QUIÉN GANA HOY? ¡HÉROES O VILLANOS!",
}) do
	buttonRow(arenaPage, { { preset, CARD, function() setSetting("Message", preset) end } }, 32)
end

section(arenaPage, "Reseteos")
buttonRow(arenaPage, {
	{ "Peleadores", Color3.fromRGB(80, 30, 30), function() send("resetFighters") end },
	{ "Cola", Color3.fromRGB(80, 30, 30), function() send("resetQueue") end },
	{ "Marcador", Color3.fromRGB(80, 30, 30), function() send("resetScore") end },
	{ "TODO", Color3.fromRGB(130, 30, 30), function() send("resetAll") end },
})

-- ===== PESTAÑA: CÁMARA =====

local cameraPage = addTab("Cámara", 4)
section(cameraPage, "Modo de cámara")
choice(cameraPage, "CameraMode", nil, Shared.SETTING_CHOICES.CameraMode, {
	"🎬 Director", "🔄 Órbita", "🏟 General", "🥊 Acción", "⬇ Cenital", "🎞 Cinemática", "🎮 Libre",
})
hint(cameraPage, "Director cambia de plano solo y corta a los KO, súper golpes, regalos y rachas. Libre: mantén clic derecho para mirar, WASD para moverte, Q/E bajar/subir, Shift rápido.")
section(cameraPage, "Efectos")
toggle(cameraPage, "CameraEventFocus", "Cortar a los momentos importantes")
toggle(cameraPage, "CameraShake", "Sacudidas de cámara")
slider(cameraPage, "CameraShakeStrength", "Fuerza de las sacudidas", 0, 3, 0.1, multiplier)
toggle(cameraPage, "ScreenFlashes", "Destellos y desenfoque en impactos")
slider(cameraPage, "CameraFov", "Campo de visión (FOV)", 30, 110, 1)
slider(cameraPage, "CameraSpeed", "Velocidad de movimientos", 0.2, 3, 0.1, multiplier)
section(cameraPage, "Peleadores")
toggle(cameraPage, "FighterAuras", "🔥 Auras de poder, anillos y brillos")
toggle(cameraPage, "PunchTrails", "🌈 Estelas de color en los puños")
hint(cameraPage, "Las auras crecen con los regalos: brillo → llamas y anillo de runas → aura gigante con rayos. Con el SÚPER cargado los puños brillan; con racha de 3+ sale una corona dorada.")

-- ===== PESTAÑA: HUD =====

local hudPage = addTab("HUD", 5)
section(hudPage, "Diseño")
choice(hudPage, "HudLayout", nil, Shared.SETTING_CHOICES.HudLayout, { "🔁 Auto", "🖥 Horizontal", "📱 Vertical" })
hint(hudPage, "Auto usa Vertical si la ventana es más alta que ancha (ideal para capturar la ventana de Roblox en 9:16 para TikTok).")
slider(hudPage, "HudScale", "Tamaño del HUD", 0.4, 2, 0.05, multiplier)
section(hudPage, "Márgenes seguros (que TikTok no tape el HUD)")
slider(hudPage, "HudSafeTop", "Margen arriba", 0, 600, 10)
slider(hudPage, "HudSafeBottom", "Margen abajo", 0, 900, 10)
slider(hudPage, "HudSafeSide", "Margen a los lados", 0, 300, 5)
section(hudPage, "Qué se ve")
toggle(hudPage, "HudShowTitle", "Título / mensaje")
toggle(hudPage, "HudShowScore", "Marcador Héroes vs Villanos")
toggle(hudPage, "HudShowLikes", "Meta de likes")
toggle(hudPage, "HudShowGifts", "Paneles de regalos")
toggle(hudPage, "HudShowQueue", "Próximos en la fila")
toggle(hudPage, "HudShowTop", "Top campeones")
toggle(hudPage, "HudShowFeed", "Feed de K.O.")
toggle(hudPage, "HudShowOverheads", "Nombres y barras de vida")
toggle(hudPage, "HudShowPopups", "Textos flotantes (daño, crítico...)")

-- ===== PESTAÑA: SONIDO Y LUZ =====

local soundPage = addTab("Audio/Luz", 6)
section(soundPage, "Sonido")
toggle(soundPage, "MusicEnabled", "🎵 Música")
slider(soundPage, "MusicVolume", "Volumen música", 0, 1, 0.05, percent)
slider(soundPage, "SfxVolume", "Volumen efectos", 0, 1, 0.05, percent)
toggle(soundPage, "CrowdEnabled", "📣 Ambiente de público")
slider(soundPage, "CrowdVolume", "Volumen público", 0, 1, 0.05, percent)
section(soundPage, "Iluminación del escenario")
choice(soundPage, "LightingPreset", nil, Shared.SETTING_CHOICES.LightingPreset, { "☀ Original", "🌅 Atardecer", "🌙 Noche", "🟣 Neón" })
toggle(soundPage, "StageLights", "💡 Focos del ring (destellan en KO y regalos)")
section(soundPage, "Ajustes")
buttonRow(soundPage, {
	{ "↺ Restaurar TODOS los ajustes por defecto", Color3.fromRGB(80, 50, 20), function() send("resetSettings") end },
})

-- ===== PESTAÑA: BATALLA =====

local battlePage = addTab("⚔ Batalla", 8)
section(battlePage, "Modo de juego")
choice(battlePage, "GameMode", nil, Shared.SETTING_CHOICES.GameMode, { "🥊 Solo (como siempre)", "⚔ Batalla (batallas de TikTok)" })
hint(battlePage, "En modo Batalla, cuando empiezas una batalla en TikTok el ring se vacía y pelean tu campeón (dorado) y el del rival (morado). Cada vez que un lado recibe puntos, su campeón golpea y con más puntos le sale fuego y humo. Nadie cae hasta que TikTok termina la batalla: el ganador lanza el ATAQUE FINAL. Después sigue el juego normal hasta la próxima batalla.")
section(battlePage, "Tu usuario de TikTok (opcional)")
local battleMeBox = textBox(battlePage, "@tu_usuario (para saber cuál de los dos eres)", setting("BattleMe"))
onSetting("BattleMe", function(value)
	if not battleMeBox:IsFocused() then
		battleMeBox.Text = value
	end
end)
buttonRow(battlePage, {
	{ "✔ Guardar usuario", Color3.fromRGB(30, 90, 60), function() setSetting("BattleMe", battleMeBox.Text) end },
})
toggle(battlePage, "BattleSwap", "🔄 Mi campeón sale del lado del rival (cambiar lados)")
slider(battlePage, "BattleLikeGoal", "❤ Likes para el GOLPE DEL PÚBLICO", 20, 3000, 10, Shared.formatNumber)
hint(battlePage, "Normalmente el bridge sabe solo cuál eres (por los regalos que recibes). Si en una batalla salen al revés, escribe tu @usuario o activa \"cambiar lados\".")

section(battlePage, "Probar sin live")
buttonRow(battlePage, {
	{ "⚔ Empezar batalla de prueba", Color3.fromRGB(120, 30, 30), function() send("simBattleStart", { meName = simName() }) end },
}, 42)
buttonRow(battlePage, {
	{ "🦸 +10 pts yo", Color3.fromRGB(110, 85, 10), function() send("simBattlePoints", { side = "me", amount = 10 }) end },
	{ "🦸 +100", Color3.fromRGB(110, 85, 10), function() send("simBattlePoints", { side = "me", amount = 100 }) end },
	{ "🦸 +1000", Color3.fromRGB(110, 85, 10), function() send("simBattlePoints", { side = "me", amount = 1000 }) end },
})
buttonRow(battlePage, {
	{ "🦹 +10 pts rival", Color3.fromRGB(70, 30, 100), function() send("simBattlePoints", { side = "rival", amount = 10 }) end },
	{ "🦹 +100", Color3.fromRGB(70, 30, 100), function() send("simBattlePoints", { side = "rival", amount = 100 }) end },
	{ "🦹 +1000", Color3.fromRGB(70, 30, 100), function() send("simBattlePoints", { side = "rival", amount = 1000 }) end },
})
section(battlePage, "Regalos de tu live en la batalla (ataques especiales)")
buttonRow(battlePage, {
	{ "Nv1 ¡Combo!", CARD, function() send("simBattleGift", { level = 1, name = simName() }) end },
	{ "Nv2 Gancho de fuego", CARD, function() send("simBattleGift", { level = 2, name = simName() }) end },
	{ "Nv3 Súper directo", CARD, function() send("simBattleGift", { level = 3, name = simName() }) end },
})
buttonRow(battlePage, {
	{ "Nv4 Uppercut relámpago", CARD, function() send("simBattleGift", { level = 4, name = simName() }) end },
	{ "Nv5 Ataque meteoro", CARD, function() send("simBattleGift", { level = 5, name = simName() }) end },
	{ "🌧 Lluvia de guantes", CARD, function() send("simBattleGift", { level = 6, name = simName() }) end },
})
hint(battlePage, "El nivel es el del regalo en el editor de regalos del panel web (Experimentado = 1 ... Definitivo = 5; lluvias = lluvia de guantes). Un regalo que no está en ningún puesto ataca según lo que cuesta.")
section(battlePage, "Likes y seguidores en la batalla")
buttonRow(battlePage, {
	{ "❤ +50 likes", Color3.fromRGB(110, 30, 70), function() send("simLikes", { name = simName(), count = 50 }) end },
	{ "❤ +300 likes", Color3.fromRGB(110, 30, 70), function() send("simLikes", { name = simName(), count = 300 }) end },
	{ "➕ Seguir (cura)", Color3.fromRGB(30, 90, 60), function() send("simFollow", { name = simName() .. math.random(100, 999) }) end },
})
section(battlePage, "Terminar la batalla (ataque final)")
buttonRow(battlePage, {
	{ "🏆 Gano yo", Color3.fromRGB(110, 85, 10), function() send("simBattleEnd", { winner = "me" }) end },
	{ "💀 Gana el rival", Color3.fromRGB(70, 30, 100), function() send("simBattleEnd", { winner = "rival" }) end },
	{ "📊 Por puntos", CARD, function() send("simBattleEnd", {}) end },
	{ "🤝 Empate", CARD, function() send("simBattleEnd", { winner = "tie" }) end },
})
hint(battlePage, "\"Terminar\" también sirve en una batalla de verdad si TikTok no avisara del final.")

-- ===== PESTAÑA: ESTADO =====

local statePage = addTab("Estado", 7)
section(statePage, "Conexión")
local stateLabel = label({
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Font = Enum.Font.Code,
	TextSize = 15,
	RichText = true,
	LayoutOrder = nextOrder(statePage),
	Parent = statePage,
})
hint(statePage, "Si el bridge sale en rojo: abre una terminal en la carpeta 'A La Trompa' y ejecuta npm start. La primera vez te pide el token en una ventana; después el juego lo recibe solo (para cambiarlo: npm run token).")

local fps = 60
RunService.RenderStepped:Connect(function(dt)
	fps = fps * 0.95 + (1 / math.max(dt, 1 / 240)) * 0.05
end)

local function dot(ok)
	return ok and '<font color="#5ADC8C">● ONLINE</font>' or '<font color="#FF5A5A">● OFFLINE</font>'
end

task.spawn(function()
	while true do
		local bridge = stateFolder:GetAttribute("BridgeOnline") == true
		local tikfinity = stateFolder:GetAttribute("TikfinityOnline") == true
		statusDot.Text = bridge and (tikfinity and "🟢 TikTok conectado" or "🟡 Bridge sin Tikfinity") or "🔴 Bridge apagado"
		if window.Visible and currentTab == "Estado" then
			local viewport = Workspace.CurrentCamera.ViewportSize
			local layout = setting("HudLayout")
			if layout == "Auto" then
				layout = "Auto (" .. (viewport.Y > viewport.X and "Vertical" or "Horizontal") .. ")"
			end
			stateLabel.Text = table.concat({
				"Bridge (Node)      " .. dot(bridge),
				"Tikfinity          " .. dot(tikfinity),
				"",
				"Peleadores ring    " .. tostring(stateFolder:GetAttribute("Fighters") or 0),
				"En espera          " .. tostring(stateFolder:GetAttribute("Waiting") or 0),
				"Likes totales      " .. Shared.formatNumber(stateFolder:GetAttribute("TotalLikes") or 0),
				"Espectadores live  " .. Shared.formatNumber(stateFolder:GetAttribute("Viewers") or 0),
				"Avatares cargados  " .. tostring(stateFolder:GetAttribute("Avatars") or "-"),
				"",
				"FPS                " .. math.floor(fps + 0.5),
				"Resolución         " .. math.floor(viewport.X) .. " x " .. math.floor(viewport.Y),
				"Diseño HUD         " .. layout,
				"Cámara             " .. tostring(setting("CameraMode")),
				"Modo de juego      " .. tostring(setting("GameMode")) .. (if stateFolder:GetAttribute("BattleActive") then "  ⚔ EN BATALLA" else ""),
				"Servidor           " .. (if stateFolder:GetAttribute("OnlineMode") then ("online · @" .. tostring(stateFolder:GetAttribute("OnlineUser") or "?")) else "bridge local"),
			}, "\n")
		end
		task.wait(0.5)
	end
end)

-- ===== BOTONES EN PANTALLA (como en "A Correr") =====

local IDLE_STROKE = Color3.fromRGB(120, 120, 160)
local PILL_BG = Color3.fromRGB(25, 25, 45)
local POP_BG = Color3.fromRGB(20, 20, 38)
local ROW_BG = Color3.fromRGB(38, 38, 62)
local BLUE = Color3.fromRGB(70, 130, 255)

local bar = new("Frame", {
	Name = "DevBar",
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 14, 1, -14),
	Size = UDim2.fromOffset(0, 44),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundTransparency = 1,
	Parent = gui,
}, {
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	}),
})
local barScale = new("UIScale", { Parent = bar })
local barLift = 0 -- cuánto se sube la barra para no tapar el HUD (meta de likes, etc.)

local function pill(text, width, order)
	local button = new("TextButton", {
		Size = UDim2.fromOffset(width, 42),
		BackgroundColor3 = PILL_BG,
		Font = Enum.Font.GothamBold,
		TextSize = 17,
		TextColor3 = WHITE,
		Text = text,
		LayoutOrder = order,
		Parent = bar,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local stroke = new("UIStroke", { Thickness = 2, Color = IDLE_STROKE, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })
	return button, stroke
end

local devButton, devStroke = pill("🛠️ DEV", 110, 1)
local camButton, camStroke = pill("🎥 CÁMARA", 134, 2)
local quickButton, quickStroke = pill("⚡ ACCIONES", 146, 3)

-- Panel pequeño que se despliega encima de su botón
local function popover(width, title)
	local pop = new("CanvasGroup", {
		AnchorPoint = Vector2.new(0, 1),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = POP_BG,
		BackgroundTransparency = 0.05,
		GroupTransparency = 1,
		Visible = false,
		Parent = gui,
	}, {
		corner(16),
		new("UIPadding", {
			PaddingTop = UDim.new(0, 12),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	new("UIScale", { Parent = pop })
	label({
		Size = UDim2.new(1, 0, 0, 24),
		Text = title,
		Font = Enum.Font.GothamBlack,
		TextSize = 16,
		LayoutOrder = 0,
		Parent = pop,
	})
	return pop
end

local function gridOf(parent, columns, cellHeight, order)
	return new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = parent,
	}, {
		new("UIGridLayout", {
			CellSize = UDim2.new(1 / columns, -6, 0, cellHeight),
			CellPadding = UDim2.new(0, 8, 0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
end

local function popButton(parent, text, order, color)
	local button = new("TextButton", {
		BackgroundColor3 = color or ROW_BG,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = WHITE,
		TextWrapped = true,
		Text = text,
		LayoutOrder = order,
		Parent = parent,
	}, { corner(10) })
	local stroke = new("UIStroke", { Thickness = 2, Color = IDLE_STROKE, Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })
	return button, stroke
end

-- ===== PANEL 🎥 CÁMARA =====
local camPop = popover(300, "🎥 CÁMARA")
local camGrid = gridOf(camPop, 3, 46, 1)
local CAMERA_LABELS = {
	Director = "🎬\nDirector", Orbita = "🔄\nÓrbita", General = "🏟\nGeneral", Accion = "🥊\nAcción",
	Cenital = "⬇\nCenital", Cinematica = "🎞\nCine", Libre = "🎮\nLibre",
}
local modeStrokes = {}
for index, mode in ipairs(Shared.SETTING_CHOICES.CameraMode) do
	local button, stroke = popButton(camGrid, CAMERA_LABELS[mode] or mode, index)
	button.TextSize = 13
	modeStrokes[mode] = stroke
	button.Activated:Connect(function()
		setSetting("CameraMode", mode)
	end)
end
onSetting("CameraMode", function(value)
	for mode, stroke in pairs(modeStrokes) do
		stroke.Color = if mode == value then GOOD else IDLE_STROKE
		stroke.Transparency = if mode == value then 0 else 0.5
	end
end)

-- Fila de zoom: [ − ]  FOV 70  [ + ]
local fovRow = new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, LayoutOrder = 2, Parent = camPop })
local fovLabel = label({
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0.5, 0, 1, 0),
	TextXAlignment = Enum.TextXAlignment.Center,
	Parent = fovRow,
})
for _, data in ipairs({ { "−", 0, -5 }, { "+", 1, 5 } }) do
	local button = new("TextButton", {
		AnchorPoint = Vector2.new(data[2], 0.5),
		Position = UDim2.fromScale(data[2], 0.5),
		Size = UDim2.fromOffset(58, 38),
		BackgroundColor3 = BLUE,
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		TextColor3 = WHITE,
		Text = data[1],
		Parent = fovRow,
	}, { corner(10) })
	button.Activated:Connect(function()
		setSetting("CameraFov", setting("CameraFov") + data[3])
	end)
end
onSetting("CameraFov", function(value)
	fovLabel.Text = "🔍 FOV " .. math.floor(value + 0.5)
end)
label({
	Size = UDim2.new(1, 0, 0, 16),
	Text = "−  acerca     +  aleja",
	Font = Enum.Font.Gotham,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Center,
	TextColor3 = MUTED,
	LayoutOrder = 3,
	Parent = camPop,
})

-- Interruptores rápidos (muestran ON / OFF)
local function quickToggle(parent, key, text, order)
	local button, stroke = popButton(parent, text, order)
	onSetting(key, function(value)
		button.Text = text .. (if value then "  ON" else "  OFF")
		button.TextTransparency = if value then 0 else 0.35
		stroke.Color = if value then GOOD else IDLE_STROKE
		stroke.Transparency = if value then 0 else 0.5
	end)
	button.Activated:Connect(function()
		setSetting(key, not setting(key))
	end)
	return button
end
local camToggles = gridOf(camPop, 2, 38, 4)
quickToggle(camToggles, "CameraShake", "📳 Sacudir", 1)
quickToggle(camToggles, "CameraEventFocus", "🎯 Cortes", 2)
quickToggle(camToggles, "FighterAuras", "🔥 Auras", 3)
quickToggle(camToggles, "PunchTrails", "🌈 Estelas", 4)

-- ===== PANEL ⚡ ACCIONES (lo más usado durante el live) =====
local quickPop = popover(320, "⚡ ACCIONES RÁPIDAS")
local quickGrid = gridOf(quickPop, 2, 40, 1)
local QUICK = {
	{ "🤖 +4 bots", ROW_BG, function() send("simBots", { count = 4 }) end },
	{ "🤖 +8 bots", ROW_BG, function() send("simBots", { count = 8 }) end },
	{ "🌟 Lluvia dorada", Color3.fromRGB(110, 85, 10), function() send("rain", { kind = "gold", name = simName() }) end },
	{ "🌑 Lluvia oscura", Color3.fromRGB(70, 30, 100), function() send("rain", { kind = "dark", name = simName() }) end },
	{ "🔥 Modo FURIA", Color3.fromRGB(120, 50, 10), function() send("fury") end },
	{ "💖 Corazones", Color3.fromRGB(120, 30, 80), function() send("hearts") end },
	{ "⚡ SÚPER a todos", ROW_BG, function() send("chargeAll") end },
	{ "❤ Curar a todos", ROW_BG, function() send("healAll") end },
	{ "💀 K.O. al azar", Color3.fromRGB(90, 25, 25), function() send("koRandom") end },
	{ "🎬 Entrada Élite", Color3.fromRGB(110, 85, 10), function() send("testEntrance", { kind = "elite" }) end },
	{ "🎬 Entrada Definitiva", Color3.fromRGB(70, 30, 100), function() send("testEntrance", { kind = "definitive" }) end },
	{ "⚔ Batalla de prueba", Color3.fromRGB(120, 30, 30), function() send("simBattleStart", {}) end },
	{ "🏁 Terminar batalla", Color3.fromRGB(120, 30, 30), function() send("simBattleEnd", {}) end },
}
for index, data in ipairs(QUICK) do
	local button, stroke = popButton(quickGrid, data[1], index, data[2])
	button.Activated:Connect(function()
		data[3]()
		-- destello de confirmación
		stroke.Color = GOOD
		stroke.Transparency = 0
		button.BackgroundColor3 = data[2]:Lerp(WHITE, 0.35)
		tween(button, 0.35, { BackgroundColor3 = data[2] })
		task.delay(0.35, function()
			stroke.Color = IDLE_STROKE
			stroke.Transparency = 0.5
		end)
	end)
end
local pauseButton = quickToggle(quickGrid, "Paused", "⏸ Pausa", #QUICK + 1)
pauseButton.LayoutOrder = #QUICK + 1

-- ===== ABRIR / CERRAR =====

local function fitWindow()
	local viewport = Workspace.CurrentCamera.ViewportSize
	windowScale.Scale = math.clamp(math.min(viewport.X / 700, (viewport.Y - 80) / 760), 0.45, 1.25)
	local small = math.clamp(math.min(viewport.X / 820, viewport.Y / 640), 0.6, 1.2)
	if viewport.X > viewport.Y then
		small *= 0.82 -- en horizontal, lo más discreto posible
	end
	barScale.Scale = small
	for _, pop in ipairs({ camPop, quickPop }) do
		pop:FindFirstChildOfClass("UIScale").Scale = small
	end
end
fitWindow()
Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitWindow)

-- Despliega (sube un poco y aparece) o pliega (baja y se desvanece)
local function animate(frame, home, open)
	frame:SetAttribute("Open", open)
	if open then
		frame.Visible = true
		frame.GroupTransparency = 1
		frame.Position = home + UDim2.fromOffset(0, 16)
		tween(frame, 0.25, { GroupTransparency = 0, Position = home }, Enum.EasingStyle.Back)
	else
		tween(frame, 0.2, { GroupTransparency = 1, Position = home + UDim2.fromOffset(0, 16) })
		task.delay(0.2, function()
			if frame:GetAttribute("Open") ~= true then
				frame.Visible = false
			end
		end)
	end
end

-- Posición encima de su botón
local function homeAbove(button)
	local x = button.AbsolutePosition.X - gui.AbsolutePosition.X
	return UDim2.new(0, x, 1, -(14 + barLift + 54 * barScale.Scale))
end

local panels = {
	dev = { frame = window, button = devButton, stroke = devStroke },
	cam = { frame = camPop, button = camButton, stroke = camStroke },
	quick = { frame = quickPop, button = quickButton, stroke = quickStroke },
}

local function isOpen(name)
	return panels[name].frame:GetAttribute("Open") == true
end

local function setOpen(name, open)
	local panel = panels[name]
	if open == isOpen(name) then
		return
	end
	if open then
		-- solo uno abierto a la vez
		for other in pairs(panels) do
			if other ~= name and isOpen(other) then
				setOpen(other, false)
			end
		end
		fitWindow()
	end
	local home
	if name == "dev" then
		home = if windowHome == WINDOW_HOME then UDim2.new(0, 14, 1, -(14 + barLift + 54 * barScale.Scale)) else windowHome
		windowHome = home
		WINDOW_HOME = home
	else
		home = homeAbove(panel.button)
	end
	animate(panel.frame, home, open)
	if name ~= "dev" then
		tween(panel.stroke, 0.2, { Color = if open then ACCENT else IDLE_STROKE })
	end
end

devButton.Activated:Connect(function()
	setOpen("dev", not isOpen("dev"))
end)
camButton.Activated:Connect(function()
	setOpen("cam", not isOpen("cam"))
end)
quickButton.Activated:Connect(function()
	setOpen("quick", not isOpen("quick"))
end)
closeButton.MouseButton1Click:Connect(function()
	setOpen("dev", false)
end)

UserInputService.InputBegan:Connect(function(input)
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == Enum.KeyCode.F2 then
		setOpen("dev", not isOpen("dev"))
	elseif input.KeyCode == Enum.KeyCode.F3 then
		-- botones fuera de cámara para una captura limpia (F3 los vuelve a mostrar)
		local show = not bar.Visible
		bar.Visible = show
		if not show then
			for name in pairs(panels) do
				setOpen(name, false)
			end
		end
	end
end)

-- Si un panel del HUD (meta de likes, marcador...) queda debajo de la barra, la barra se sube encima de él
local function hudLift()
	local hud = playerGui:FindFirstChild("ArenaHUD")
	local root = hud and hud:FindFirstChild("Root")
	local safe = root and root:FindFirstChild("Safe")
	if not safe or not bar.Visible then
		return 0
	end
	local left = gui.AbsolutePosition.X + 14
	local right = left + bar.AbsoluteSize.X
	local bottom = gui.AbsolutePosition.Y + gui.AbsoluteSize.Y
	local barTop = bottom - 14 - bar.AbsoluteSize.Y
	local lift = 0
	local panels = safe:GetChildren()
	local battleHud = playerGui:FindFirstChild("ArenaBattleHUD")
	local battleSafe = battleHud and battleHud.Enabled and battleHud:FindFirstChild("Safe", true)
	if battleSafe then
		for _, panel in ipairs(battleSafe:GetChildren()) do
			table.insert(panels, panel)
		end
	end
	for _, panel in ipairs(panels) do
		if panel:IsA("GuiObject") and panel.Visible and panel.AbsoluteSize.Y < gui.AbsoluteSize.Y * 0.45 then
			local pos, size = panel.AbsolutePosition, panel.AbsoluteSize
			if pos.X < right and pos.X + size.X > left and pos.Y + size.Y > barTop - 4 then
				lift = math.max(lift, bottom - pos.Y - 14 + 8)
			end
		end
	end
	return math.clamp(lift, 0, gui.AbsoluteSize.Y * 0.4)
end

task.spawn(function()
	while true do
		local ok, lift = pcall(hudLift)
		if ok and math.abs(lift - barLift) > 1 then
			barLift = lift
			tween(bar, 0.25, { Position = UDim2.new(0, 14, 1, -14 - barLift) })
		end
		task.wait(0.5)
	end
end)

-- El botón DEV brilla según la conexión: verde = TikTok conectado, amarillo = bridge sin Tikfinity, rojo = bridge apagado
task.spawn(function()
	while true do
		local bridge = stateFolder:GetAttribute("BridgeOnline") == true
		local tikfinity = stateFolder:GetAttribute("TikfinityOnline") == true
		local color = if bridge and tikfinity then GOOD elseif bridge then Color3.fromRGB(255, 200, 60) else BAD
		tween(devStroke, 0.3, { Color = color })
		task.wait(1)
	end
end)

selectTab("Simular")
