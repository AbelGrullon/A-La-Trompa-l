-- ModeSelect (LocalScript en StarterPlayerScripts)
-- Al entrar al juego, el streamer elige cómo jugar:
--   🥊 SOLO    : como siempre (regalos, likes y follows de tu live).
--   ⚔️ BATALLA : lo mismo y, además, cuando hagas una batalla en TikTok tu
--               campeón pelea contra el del otro streamer con los puntos de
--               la batalla (ver ArenaManager → MODO BATALLA).
-- Se guarda en el ajuste GameMode (también se cambia en el panel DEV → ⚔ Batalla
-- y en el panel web). Si nadie elige, a los 20 s se queda el de la última vez.
-- Solo lo ve el streamer (Studio o dueño del juego: atributo ArenaDev).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

-- Modo online: primero hay que conectar el TikTok (pantalla OnlineConnect)
do
	local stateFolder = arena:WaitForChild("State")
	while stateFolder:GetAttribute("OnlineMode") and not stateFolder:GetAttribute("OnlineLinked") do
		stateFolder:GetAttributeChangedSignal("OnlineLinked"):Wait()
	end
end
local settingsFolder = arena:WaitForChild("Settings")
local devCommand = arena:WaitForChild("Remotes"):WaitForChild("DevCommand")

local AUTO_SECONDS = 20
local WHITE = Color3.new(1, 1, 1)
local MUTED = Color3.fromRGB(175, 175, 195)

local function setting(key)
	local value = settingsFolder:GetAttribute(key)
	if value == nil then
		value = Shared.DEFAULT_SETTINGS[key]
	end
	return value
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

local function tween(inst, seconds, goal, style, direction)
	local t = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

local function text(props, children)
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		TextScaled = true,
		TextWrapped = true,
	})
	for key, value in pairs(props) do
		if key ~= "Parent" then
			label[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = label
	end
	label.Parent = props.Parent
	return label
end

-- ===== PANTALLA =====
local gui = new("ScreenGui", {
	Name = "ArenaModeSelect",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 200, -- encima de todo (también del panel dev)
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})
local blur = new("BlurEffect", { Name = "ModeSelectBlur", Size = 0, Parent = Lighting })
tween(blur, 0.5, { Size = 18 })

local overlay = new("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(6, 6, 12),
	BackgroundTransparency = 1,
	Parent = gui,
})
tween(overlay, 0.4, { BackgroundTransparency = 0.3 })

-- Todo el menú se dibuja a 1000 x 640 y se escala a la pantalla
local holder = new("Frame", {
	Size = UDim2.fromOffset(1000, 640),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundTransparency = 1,
	Parent = overlay,
})
local holderScale = new("UIScale", { Scale = 0.6, Parent = holder })

text({
	Size = UDim2.new(1, 0, 0, 70),
	Font = Enum.Font.GothamBlack,
	Text = "🥊 ¡A LA TROMPA!",
	TextStrokeTransparency = 0.3,
	Parent = holder,
})
text({
	Size = UDim2.new(1, 0, 0, 34),
	Position = UDim2.fromOffset(0, 76),
	Font = Enum.Font.GothamBold,
	TextColor3 = Color3.fromRGB(220, 220, 235),
	Text = "¿Cómo quieres jugar hoy?",
	Parent = holder,
})

local cardsFrame = new("Frame", {
	Size = UDim2.new(1, 0, 0, 380),
	Position = UDim2.fromOffset(0, 130),
	BackgroundTransparency = 1,
	Parent = holder,
})
local cardsLayout = new("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 40),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = cardsFrame,
})

local footer = text({
	Size = UDim2.new(1, 0, 0, 26),
	Position = UDim2.new(0, 0, 1, -110),
	Font = Enum.Font.GothamMedium,
	TextColor3 = MUTED,
	Text = "",
	Parent = holder,
})
text({
	Size = UDim2.new(1, 0, 0, 22),
	Position = UDim2.new(0, 0, 1, -78),
	Font = Enum.Font.Gotham,
	TextColor3 = MUTED,
	Text = "Puedes cambiarlo cuando quieras en el panel DEV → ⚔ Batalla",
	Parent = holder,
})

local MODES = {
	{
		id = "Solo",
		emoji = "🥊",
		title = "SOLO",
		body = "Como siempre: tus espectadores entran al ring con regalos, likes y follows.",
		color = Color3.fromRGB(255, 205, 40),
	},
	{
		id = "Batalla",
		emoji = "⚔️",
		title = "MODO BATALLA",
		body = "Todo lo de Solo y, cuando hagas una batalla en TikTok, tu campeón pelea contra el del otro streamer con los puntos. ¡El ganador lanza el ataque final!",
		color = Color3.fromRGB(255, 80, 80),
	},
}

local cards = {}
local chosen = false

local function choose(mode)
	if chosen then
		return
	end
	chosen = true
	devCommand:FireServer("setSetting", { key = "GameMode", value = mode })
	for id, card in pairs(cards) do
		if id == mode then
			tween(card.scale, 0.25, { Scale = 1.08 }, Enum.EasingStyle.Back)
		else
			tween(card.frame, 0.25, { BackgroundTransparency = 1 })
			tween(card.scale, 0.25, { Scale = 0.85 })
		end
	end
	task.wait(0.35)
	tween(holderScale, 0.3, { Scale = holderScale.Scale * 0.9 })
	tween(overlay, 0.35, { BackgroundTransparency = 1 })
	tween(blur, 0.35, { Size = 0 })
	for _, item in ipairs(holder:GetDescendants()) do
		if item:IsA("TextLabel") then
			tween(item, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
		elseif item:IsA("Frame") or item:IsA("TextButton") then
			tween(item, 0.3, { BackgroundTransparency = 1 })
		elseif item:IsA("UIStroke") then
			tween(item, 0.3, { Transparency = 1 })
		end
	end
	task.wait(0.4)
	gui:Destroy()
	blur:Destroy()
end

for index, mode in ipairs(MODES) do
	local card = new("TextButton", {
		Size = UDim2.fromOffset(440, 350),
		BackgroundColor3 = Color3.fromRGB(20, 20, 32),
		BackgroundTransparency = 0.05,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = index,
		Parent = cardsFrame,
	}, { new("UICorner", { CornerRadius = UDim.new(0, 22) }) })
	local stroke = new("UIStroke", {
		Color = mode.color,
		Thickness = 3,
		Transparency = 0.55,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = card,
	})
	local scale = new("UIScale", { Scale = 0.7, Parent = card })
	text({ Size = UDim2.new(1, 0, 0, 96), Position = UDim2.fromOffset(0, 18), Text = mode.emoji, TextStrokeTransparency = 1, Parent = card })
	text({
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.fromOffset(20, 120),
		Font = Enum.Font.GothamBlack,
		TextColor3 = mode.color,
		TextStrokeTransparency = 0.3,
		Text = mode.title,
		Parent = card,
	})
	text({
		Size = UDim2.new(1, -56, 0, 96),
		Position = UDim2.fromOffset(28, 170),
		Font = Enum.Font.GothamMedium,
		TextColor3 = Color3.fromRGB(215, 215, 230),
		Text = mode.body,
		Parent = card,
	}, { new("UITextSizeConstraint", { MaxTextSize = 26 }) })
	local pick = new("Frame", {
		Size = UDim2.new(1, -80, 0, 50),
		Position = UDim2.new(0.5, 0, 1, -22),
		AnchorPoint = Vector2.new(0.5, 1),
		BackgroundColor3 = mode.color,
		Parent = card,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	text({
		Size = UDim2.new(1, -20, 0.6, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = Enum.Font.GothamBlack,
		TextColor3 = Color3.fromRGB(20, 12, 4),
		Text = "JUGAR " .. mode.title,
		Parent = pick,
	})
	local badge = text({
		Size = UDim2.fromOffset(150, 26),
		Position = UDim2.new(1, -14, 0, 14),
		AnchorPoint = Vector2.new(1, 0),
		Font = Enum.Font.GothamBlack,
		TextColor3 = mode.color,
		Text = "ÚLTIMA VEZ",
		Visible = false,
		Parent = card,
	})
	cards[mode.id] = { frame = card, stroke = stroke, scale = scale, badge = badge }
	task.delay(0.08 * index, function()
		tween(scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	card.MouseEnter:Connect(function()
		if not chosen then
			tween(scale, 0.15, { Scale = 1.04 })
			tween(stroke, 0.15, { Transparency = 0 })
		end
	end)
	card.MouseLeave:Connect(function()
		if not chosen then
			tween(scale, 0.15, { Scale = 1 })
			tween(stroke, 0.15, { Transparency = if setting("GameMode") == mode.id then 0.1 else 0.55 })
		end
	end)
	card.Activated:Connect(function()
		choose(mode.id)
	end)
end

-- El modo guardado (llega del bridge al empezar) se marca como "última vez"
local function markSaved()
	local saved = setting("GameMode")
	for id, card in pairs(cards) do
		card.badge.Visible = id == saved
		card.stroke.Transparency = if id == saved then 0.1 else 0.55
	end
end
markSaved()
settingsFolder:GetAttributeChangedSignal("GameMode"):Connect(function()
	if not chosen then
		markSaved()
	end
end)

-- Tamaño según la pantalla (en vertical las tarjetas van una encima de otra)
local function fit()
	local viewport = Workspace.CurrentCamera.ViewportSize
	local portrait = viewport.Y > viewport.X
	cardsLayout.FillDirection = if portrait then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal
	cardsLayout.Padding = UDim.new(0, if portrait then 24 else 40)
	holder.Size = if portrait then UDim2.fromOffset(560, 1060) else UDim2.fromOffset(1000, 640)
	cardsFrame.Size = if portrait then UDim2.new(1, 0, 0, 740) else UDim2.new(1, 0, 0, 380)
	local base = if portrait then math.min(viewport.X / 600, viewport.Y / 1100) else math.min(viewport.X / 1080, viewport.Y / 700)
	if not chosen then
		holderScale.Scale = math.clamp(base, 0.35, 1.6)
	end
end
fit()
Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)

-- Cuenta atrás: si nadie elige, se queda el modo de la última vez
task.spawn(function()
	for left = AUTO_SECONDS, 1, -1 do
		if chosen then
			return
		end
		local saved = setting("GameMode")
		footer.Text = "Se elige solo en " .. left .. " s  (última vez: " .. (if saved == "Batalla" then "⚔️ Batalla" else "🥊 Solo") .. ")"
		task.wait(1)
	end
	choose(setting("GameMode"))
end)
