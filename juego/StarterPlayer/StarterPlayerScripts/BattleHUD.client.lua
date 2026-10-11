-- BattleHUD (LocalScript en StarterPlayerScripts)
-- HUD propio del MODO BATALLA (GameMode = "Batalla"). En ese modo el HUD
-- normal (ArenaHUD) se esconde y este ocupa la pantalla:
--   • BARRA DE LA BATALLA: los dos streamers, puntos que suben contando, la
--     barra que se empuja con un choque de rayos, reloj con anillo de luces,
--     niveles de poder, combos, corona para el que va ganando y ¡REMONTADA!
--   • ¿CÓMO AYUDAR?: qué pueden hacer los espectadores (cada fila se ilumina
--     cuando alguien lo hace).
--   • ATAQUES ESPECIALES: qué regalo lanza qué ataque (sale del editor de regalos).
--   • ENERGÍA DEL PÚBLICO (likes → golpe del público) y MVP de la batalla.
--   • Tarjetas de lo que pasa, pantalla VS al empezar, cuenta atrás final y
--     pantalla de victoria.
-- Sin batalla en curso muestra la sala de espera del modo batalla.
-- Datos: hudEvent "battle" (Battle.payload) y "battleEvent" (ArenaManager →
-- MODO BATALLA). Diseñado a 1920x1080 (horizontal) y 1080x1920 (vertical),
-- con la escala y los márgenes seguros del HUD normal (HudScale, HudSafe*).
-- Durante las cinemáticas (entradas y ataque final) se esconde.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local settingsFolder = arena:WaitForChild("Settings")
local stateFolder = arena:WaitForChild("State")
local remotes = arena:WaitForChild("Remotes")
local hudEvent = remotes:WaitForChild("HudEvent")
local devCommand = remotes:WaitForChild("DevCommand")

local TEAMS = Shared.TEAMS
local BATTLE = Shared.BATTLE
local FONT_BLACK = Enum.Font.GothamBlack
local FONT_BOLD = Enum.Font.GothamBold
local FONT = Enum.Font.GothamMedium
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local RED = Color3.fromRGB(255, 70, 70)
local GOLD = Color3.fromRGB(255, 205, 60)
local PINK = Color3.fromRGB(255, 90, 165)
local GREEN = Color3.fromRGB(110, 240, 150)
local MUTED = Color3.fromRGB(190, 185, 210)
local LEVEL_COLORS = {
	Color3.fromRGB(150, 200, 255),
	Color3.fromRGB(255, 140, 40),
	Color3.fromRGB(80, 225, 255),
	Color3.fromRGB(255, 230, 80),
	Color3.fromRGB(255, 80, 220),
	rain = GOLD,
	crowd = PINK,
}

-- ===== AYUDANTES =====
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

local function loop(inst, seconds, goal, style)
	local t = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), goal)
	t:Play()
	return t
end

local function corner(radius)
	return new("UICorner", { CornerRadius = if radius then UDim.new(0, radius) else UDim.new(1, 0) })
end

local function stroke(color, thickness, transparency)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 2,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function text(props)
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = FONT_BOLD,
		TextColor3 = WHITE,
		TextScaled = true,
		TextWrapped = true,
		TextStrokeColor3 = BLACK,
		TextStrokeTransparency = 0.45,
	})
	for key, value in pairs(props) do
		if key ~= "Parent" then
			label[key] = value
		end
	end
	label.Parent = props.Parent
	return label
end

local function seq(...)
	local points = { ... }
	local keys = {}
	for i, color in ipairs(points) do
		table.insert(keys, ColorSequenceKeypoint.new((i - 1) / math.max(1, #points - 1), color))
	end
	return ColorSequence.new(keys)
end

-- Bordes con degradado que gira (un solo bucle para todos)
local spinning = {}
RunService.RenderStepped:Connect(function(dt)
	for item, speed in pairs(spinning) do
		if item:IsDescendantOf(game) then
			item.Rotation = (item.Rotation + dt * speed) % 360
		else
			spinning[item] = nil
		end
	end
end)

local function spinStroke(parent, colors, thickness, speed)
	local s = stroke(WHITE, thickness or 3, 0)
	s.Parent = parent
	spinning[new("UIGradient", { Color = colors, Parent = s })] = speed or 80
	return s
end

-- Franja de brillo que cruza un panel una y otra vez
local function shine(parent, radius, period, zIndex)
	local overlay = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = zIndex or 2,
		Parent = parent,
	}, { corner(radius) })
	local gradient = new("UIGradient", {
		Rotation = 18,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.4, 1),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(0.6, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = overlay,
	})
	TweenService:Create(gradient, TweenInfo.new(period or 1.4, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1, false, 1.6), { Offset = Vector2.new(1, 0) }):Play()
	return overlay
end

local function pop(scaleObject, amount, seconds)
	scaleObject.Scale = amount or 1.25
	tween(scaleObject, seconds or 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function panelFrame(name, accent)
	local frame = new("Frame", {
		Name = name,
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Parent = nil,
	}, { corner(20) })
	new("UIGradient", { Color = seq(Color3.fromRGB(30, 24, 44), Color3.fromRGB(10, 10, 16)), Rotation = 90, Parent = frame })
	stroke(accent, 2, 0.3).Parent = frame
	return frame
end

-- ===== PANTALLA =====
local camera = Workspace.CurrentCamera
local gui = new("ScreenGui", {
	Name = "ArenaBattleHUD",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 11, -- (encima del HUD normal, debajo de las cinemáticas y del panel dev)
	Enabled = false,
	Parent = playerGui,
})
local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Parent = gui })
local rootScale = new("UIScale", { Parent = root })
local safe = new("Frame", { Name = "Safe", BackgroundTransparency = 1, ZIndex = 1, Parent = root })
local overlay = new("Frame", { Name = "Overlay", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = root })

local function isVertical()
	local layout = setting("HudLayout")
	if layout == "Vertical" then
		return true
	elseif layout == "Horizontal" then
		return false
	end
	return camera.ViewportSize.Y > camera.ViewportSize.X
end

local data = { active = false, mode = "Solo" } -- último Battle.payload
local view = { leader = nil, lastSecond = nil, resultShown = false, phase = nil }

-- ===== BARRA DE LA BATALLA =====
local Bar = {}
Bar.frame = new("Frame", {
	Name = "BattleBar",
	BackgroundColor3 = WHITE,
	BackgroundTransparency = 0.1,
	BorderSizePixel = 0,
	Visible = false,
	Parent = safe,
}, { corner(26) })
new("UIGradient", { Color = seq(TEAMS.hero.dark, Color3.fromRGB(16, 10, 24), TEAMS.villain.dark), Parent = Bar.frame })
spinStroke(Bar.frame, seq(TEAMS.hero.color, RED, TEAMS.villain.color, RED, TEAMS.hero.color), 3, 60)
Bar.scale = new("UIScale", { Parent = Bar.frame })

-- Etiqueta que cuelga del borde de arriba ("🔴 BATALLA EN VIVO")
Bar.tag = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = Color3.fromRGB(200, 30, 50),
	BorderSizePixel = 0,
	ZIndex = 6,
	Parent = Bar.frame,
}, { corner() })
stroke(WHITE, 2, 0.3).Parent = Bar.tag
new("UIGradient", { Color = seq(Color3.fromRGB(255, 90, 90), Color3.fromRGB(170, 20, 40)), Rotation = 90, Parent = Bar.tag })
Bar.tagText = text({
	Size = UDim2.new(1, -24, 0.72, 0),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BLACK,
	Text = "🔴 BATALLA EN VIVO",
	ZIndex = 7,
	Parent = Bar.tag,
})
loop(Bar.tagText, 0.7, { TextTransparency = 0.25 })

local function makeSide(team, right)
	local info = TEAMS[team]
	local s = { team = team, right = right, info = info, combo = 0, lastHitAt = 0 }
	s.crest = new("Frame", { BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 3, Parent = Bar.frame }, { corner() })
	new("UIGradient", { Color = seq(info.color:Lerp(WHITE, 0.25), info.dark), Rotation = 90, Parent = s.crest })
	stroke(info.color, 4, 0).Parent = s.crest
	s.crestScale = new("UIScale", { Parent = s.crest })
	s.emoji = text({
		Size = UDim2.fromScale(0.66, 0.66),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = info.emoji,
		TextStrokeTransparency = 1,
		ZIndex = 4,
		Parent = s.crest,
	})
	loop(s.emoji, 1.1 + (right and 0.2 or 0), { Rotation = right and -8 or 8 })
	s.crown = text({
		Size = UDim2.fromScale(0.62, 0.62),
		Position = UDim2.fromScale(right and 0.18 or 0.82, 0.05),
		AnchorPoint = Vector2.new(0.5, 0.8),
		Rotation = right and -20 or 20,
		Text = "👑",
		TextStrokeTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = s.crest,
	})
	loop(s.crown, 0.6, { Position = UDim2.fromScale(right and 0.18 or 0.82, -0.02) })
	s.comboLabel = text({
		Size = UDim2.fromScale(1.6, 0.36),
		Position = UDim2.fromScale(0.5, 1.02),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextColor3 = Color3.fromRGB(255, 190, 60),
		TextStrokeTransparency = 0,
		Text = "",
		Visible = false,
		ZIndex = 6,
		Parent = s.crest,
	})
	s.comboScale = new("UIScale", { Parent = s.comboLabel })
	local align = right and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
	s.name = text({ Font = FONT_BLACK, TextColor3 = info.color, TextXAlignment = align, TextStrokeTransparency = 0.2, ZIndex = 3, Parent = Bar.frame })
	s.points = text({ Font = FONT_BLACK, TextXAlignment = align, TextStrokeTransparency = 0.05, Text = "0", ZIndex = 3, Parent = Bar.frame })
	s.pointsScale = new("UIScale", { Parent = s.points })
	s.value = new("NumberValue", { Value = 0 })
	s.value.Changed:Connect(function(value)
		s.points.Text = Shared.formatNumber(value)
	end)
	s.pct = text({ Font = FONT_BLACK, TextXAlignment = align, TextColor3 = info.light, Text = "50%", ZIndex = 3, Parent = Bar.frame })
	-- Poder: texto + 4 bolitas + lo que falta para el siguiente nivel
	s.powerRow = new("Frame", { BackgroundTransparency = 1, ZIndex = 3, Parent = Bar.frame })
	s.powerText = text({
		Size = UDim2.fromScale(0.42, 0.9),
		Position = UDim2.fromScale(right and 1 or 0, 0.5),
		AnchorPoint = Vector2.new(right and 1 or 0, 0.5),
		Font = FONT_BLACK,
		TextXAlignment = align,
		TextColor3 = Color3.fromRGB(255, 170, 70),
		Text = "🔥 PODER 0",
		ZIndex = 3,
		Parent = s.powerRow,
	})
	s.pips = {}
	for i = 1, 4 do
		local x = if right then 0.56 - (i - 1) * 0.095 else 0.44 + (i - 1) * 0.095
		local pip = new("Frame", {
			Size = UDim2.fromScale(0.075, 0.62),
			Position = UDim2.fromScale(x, 0.5),
			AnchorPoint = Vector2.new(right and 1 or 0, 0.5),
			BackgroundColor3 = Color3.fromRGB(60, 50, 70),
			BorderSizePixel = 0,
			ZIndex = 3,
			Parent = s.powerRow,
		}, { corner(6) })
		s.pips[i] = { frame = pip, scale = new("UIScale", { Parent = pip }) }
	end
	s.nextText = text({
		Size = UDim2.fromScale(0.2, 0.8),
		Position = UDim2.fromScale(right and 0 or 1, 0.5),
		AnchorPoint = Vector2.new(right and 0 or 1, 0.5),
		Font = FONT_BOLD,
		TextXAlignment = right and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		TextColor3 = MUTED,
		Text = "",
		ZIndex = 3,
		Parent = s.powerRow,
	})
	return s
end
Bar.me = makeSide("hero", false)
Bar.rival = makeSide("villain", true)

-- Reloj (círculo con anillo de luces que se van apagando)
Bar.timer = new("Frame", { BackgroundColor3 = Color3.fromRGB(10, 8, 18), BorderSizePixel = 0, ZIndex = 4, Parent = Bar.frame }, { corner() })
Bar.timerStroke = stroke(Color3.fromRGB(255, 120, 120), 3, 0.15)
Bar.timerStroke.Parent = Bar.timer
Bar.timerScale = new("UIScale", { Parent = Bar.timer })
Bar.time = text({
	Size = UDim2.fromScale(0.7, 0.34),
	Position = UDim2.fromScale(0.5, 0.45),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BLACK,
	Text = "--:--",
	TextStrokeTransparency = 0.2,
	ZIndex = 6,
	Parent = Bar.timer,
})
Bar.timeCaption = text({
	Size = UDim2.fromScale(0.56, 0.14),
	Position = UDim2.fromScale(0.5, 0.7),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BOLD,
	TextColor3 = MUTED,
	Text = "TIEMPO",
	ZIndex = 6,
	Parent = Bar.timer,
})
Bar.dots = {}
for i = 1, 40 do
	local angle = (i - 1) / 40 * math.pi * 2 - math.pi / 2
	Bar.dots[i] = new("Frame", {
		Size = UDim2.fromScale(0.075, 0.075),
		Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.42, 0.5 + math.sin(angle) * 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = Bar.timer,
	}, { corner() })
end

-- La barra que se empuja
Bar.track = new("Frame", { BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 3, Parent = Bar.frame }, { corner() })
new("UIGradient", { Color = seq(TEAMS.villain.color:Lerp(WHITE, 0.2), TEAMS.villain.dark), Rotation = 90, Parent = Bar.track })
stroke(BLACK, 2, 0.4).Parent = Bar.track
Bar.fill = new("Frame", { Size = UDim2.fromScale(0.5, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 4, Parent = Bar.track }, { corner() })
new("UIGradient", { Color = seq(Color3.fromRGB(255, 245, 190), TEAMS.hero.color, Color3.fromRGB(190, 110, 0)), Rotation = 90, Parent = Bar.fill })
shine(Bar.fill, nil, 1.2, 5)
Bar.middle = new("Frame", {
	Size = UDim2.new(0, 3, 1, 0),
	Position = UDim2.fromScale(0.5, 0),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = WHITE,
	BackgroundTransparency = 0.45,
	BorderSizePixel = 0,
	ZIndex = 6,
	Parent = Bar.track,
})
-- El choque: un rayo con brillo en el punto donde se empujan
Bar.clash = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, ZIndex = 7, Parent = Bar.frame })
Bar.clashScale = new("UIScale", { Parent = Bar.clash })
for i, layer in ipairs({ { 1.25, RED, 0.75 }, { 0.9, Color3.fromRGB(255, 200, 80), 0.45 }, { 0.5, WHITE, 0.1 } }) do
	local glow = new("Frame", {
		Size = UDim2.fromScale(layer[1], layer[1]),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = layer[2],
		BackgroundTransparency = layer[3],
		BorderSizePixel = 0,
		ZIndex = 7 + i,
		Parent = Bar.clash,
	}, { corner() })
	loop(glow, 0.35 + i * 0.12, { Size = UDim2.fromScale(layer[1] * 1.25, layer[1] * 1.25), BackgroundTransparency = math.min(1, layer[3] + 0.15) })
end
Bar.bolt = text({
	Size = UDim2.fromScale(1.1, 1.1),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Text = "⚡",
	TextStrokeTransparency = 1,
	ZIndex = 11,
	Parent = Bar.clash,
})
loop(Bar.bolt, 0.18, { Rotation = 16 })
Bar.ratio = new("NumberValue", { Value = 0.5 })
Bar.geom = { x = 0, y = 0, w = 100, h = 10 }
local function placeClash()
	local g = Bar.geom
	local ratio = Bar.ratio.Value
	Bar.fill.Size = UDim2.fromScale(ratio, 1)
	Bar.clash.Position = UDim2.fromOffset(g.x + ratio * g.w, g.y + g.h / 2)
end
Bar.ratio.Changed:Connect(placeClash)

-- Chispas que salen del choque
function Bar.sparks(color, amount)
	local origin = Bar.clash.Position
	for _ = 1, amount or 8 do
		local size = math.random(5, 11)
		local spark = new("Frame", {
			Size = UDim2.fromOffset(size, size),
			Position = origin,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = color:Lerp(WHITE, math.random() * 0.5),
			BorderSizePixel = 0,
			Rotation = math.random(0, 90),
			ZIndex = 12,
			Parent = Bar.frame,
		})
		local angle = math.random() * math.pi * 2
		local distance = math.random(40, 110)
		tween(spark, 0.5 + math.random() * 0.3, {
			Position = origin + UDim2.fromOffset(math.cos(angle) * distance, math.sin(angle) * distance * 0.7),
			BackgroundTransparency = 1,
			Rotation = spark.Rotation + 180,
		})
		Debris:AddItem(spark, 0.85)
	end
end

-- "+N" que sube desde los puntos de un lado
function Bar.floater(s, amount)
	local label = text({
		Size = UDim2.fromOffset(s.points.Size.X.Offset * 0.6, s.points.Size.Y.Offset * 0.6),
		Position = s.points.Position + UDim2.fromOffset(0, -8),
		AnchorPoint = s.points.AnchorPoint,
		Font = FONT_BLACK,
		TextXAlignment = s.points.TextXAlignment,
		TextColor3 = s.info.color:Lerp(WHITE, 0.35),
		TextStrokeTransparency = 0,
		Text = "+" .. Shared.formatNumber(amount),
		ZIndex = 12,
		Parent = Bar.frame,
	})
	tween(label, 1, { Position = label.Position - UDim2.fromOffset(0, 46) })
	task.delay(0.55, function()
		tween(label, 0.45, { TextTransparency = 1, TextStrokeTransparency = 1 })
	end)
	Debris:AddItem(label, 1.1)
end

-- Coloca todo dentro de la barra según su tamaño (w x h en unidades del HUD)
function Bar.layout(w, h)
	local pad = math.floor(h * 0.08)
	local crest = math.floor(h * 0.46)
	local timerSize = math.floor(crest * 1.2)
	local textX = pad + crest + 16
	local textW = w / 2 - textX - timerSize / 2 - 12
	local nameH = crest * 0.36
	for _, s in ipairs({ Bar.me, Bar.rival }) do
		s.crest.Size = UDim2.fromOffset(crest, crest)
		s.crest.Position = UDim2.fromOffset(if s.right then w - pad - crest else pad, pad)
		local x = if s.right then w - textX else textX
		s.name.AnchorPoint = Vector2.new(if s.right then 1 else 0, 0)
		s.name.Position = UDim2.fromOffset(x, pad)
		s.name.Size = UDim2.fromOffset(textW, nameH)
		s.points.AnchorPoint = s.name.AnchorPoint
		s.points.Position = UDim2.fromOffset(x, pad + nameH)
		s.points.Size = UDim2.fromOffset(textW, crest - nameH)
	end
	Bar.timer.Size = UDim2.fromOffset(timerSize, timerSize)
	Bar.timer.AnchorPoint = Vector2.new(0.5, 0)
	Bar.timer.Position = UDim2.fromOffset(w / 2, pad - crest * 0.08)
	local trackY = pad + crest + math.floor(h * 0.05)
	local trackH = math.floor(h * 0.16)
	Bar.geom = { x = pad, y = trackY, w = w - pad * 2, h = trackH }
	Bar.track.Position = UDim2.fromOffset(pad, trackY)
	Bar.track.Size = UDim2.fromOffset(w - pad * 2, trackH)
	Bar.clash.Size = UDim2.fromOffset(trackH * 1.9, trackH * 1.9)
	local rowY = trackY + trackH + math.floor(h * 0.03)
	local rowH = h - rowY - pad * 0.5
	for _, s in ipairs({ Bar.me, Bar.rival }) do
		s.pct.AnchorPoint = Vector2.new(if s.right then 1 else 0, 0)
		s.pct.Position = UDim2.fromOffset(if s.right then w - pad else pad, rowY)
		s.pct.Size = UDim2.fromOffset(w * 0.07, rowH)
		s.powerRow.AnchorPoint = s.pct.AnchorPoint
		s.powerRow.Position = UDim2.fromOffset(if s.right then w - pad - w * 0.08 else pad + w * 0.08, rowY)
		s.powerRow.Size = UDim2.fromOffset(w * 0.36, rowH)
	end
	Bar.tag.Size = UDim2.fromOffset(h * 1.35, h * 0.17)
	Bar.tag.Position = UDim2.fromOffset(w / 2, 0)
	placeClash()
end

-- ===== SALA DE ESPERA (modo batalla sin batalla) =====
local Lobby = {}
Lobby.frame = new("Frame", {
	Name = "BattleLobby",
	BackgroundColor3 = WHITE,
	BackgroundTransparency = 0.12,
	BorderSizePixel = 0,
	Visible = false,
	Parent = safe,
}, { corner(26) })
new("UIGradient", { Color = seq(TEAMS.hero.dark, Color3.fromRGB(30, 8, 16), TEAMS.villain.dark), Parent = Lobby.frame })
spinStroke(Lobby.frame, seq(TEAMS.hero.color, RED, TEAMS.villain.color, RED, TEAMS.hero.color), 3, 50)
Lobby.title = text({
	Size = UDim2.fromScale(0.6, 0.38),
	Position = UDim2.fromScale(0.5, 0.08),
	AnchorPoint = Vector2.new(0.5, 0),
	Font = FONT_BLACK,
	Text = "⚔️ MODO BATALLA",
	TextStrokeTransparency = 0.2,
	ZIndex = 3,
	Parent = Lobby.frame,
})
Lobby.titleGradient = new("UIGradient", { Color = seq(GOLD, WHITE, RED, TEAMS.villain.light, GOLD), Parent = Lobby.title })
TweenService:Create(Lobby.titleGradient, TweenInfo.new(3, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1), { Offset = Vector2.new(1, 0) }):Play()
Lobby.sub = text({
	Size = UDim2.fromScale(0.6, 0.18),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0),
	Font = FONT_BOLD,
	TextColor3 = Color3.fromRGB(240, 225, 235),
	Text = "Esperando una batalla en TikTok",
	ZIndex = 3,
	Parent = Lobby.frame,
})
Lobby.record = text({
	Size = UDim2.fromScale(0.6, 0.16),
	Position = UDim2.fromScale(0.5, 0.74),
	AnchorPoint = Vector2.new(0.5, 0),
	Font = FONT_BLACK,
	TextColor3 = GOLD,
	Text = "",
	ZIndex = 3,
	Parent = Lobby.frame,
})
-- Los dos escudos: el tuyo listo y el del rival con un "?" (con ondas de radar)
Lobby.crests = {}
for index, team in ipairs({ "hero", "villain" }) do
	local info = TEAMS[team]
	local crest = new("Frame", {
		Size = UDim2.fromScale(0.62, 0.62),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Position = UDim2.fromScale(if index == 1 then 0.1 else 0.9, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = Lobby.frame,
	}, { corner() })
	new("UIGradient", { Color = seq(info.color:Lerp(WHITE, 0.25), info.dark), Rotation = 90, Parent = crest })
	stroke(info.color, 4, 0).Parent = crest
	local label = text({
		Size = UDim2.fromScale(0.64, 0.64),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = if index == 1 then info.emoji else "❓",
		TextStrokeTransparency = 1,
		ZIndex = 4,
		Parent = crest,
	})
	loop(label, 0.9 + index * 0.2, { Rotation = if index == 1 then 10 else -10 })
	Lobby.crests[index] = { frame = crest, color = info.color }
end

-- ===== ¿CÓMO AYUDAR? =====
local Guide = { rows = {}, lastFlash = {} }
Guide.frame = panelFrame("BattleGuide", GOLD)
Guide.frame.Visible = false
Guide.frame.Parent = safe
text({
	Size = UDim2.new(1, -24, 0, 0),
	Position = UDim2.fromOffset(12, 10),
	Font = FONT_BLACK,
	TextColor3 = GOLD,
	Text = "🙌 ¿CÓMO AYUDAR?",
	Name = "Header",
	Parent = Guide.frame,
})
Guide.body = new("Frame", { BackgroundTransparency = 1, Parent = Guide.frame })
new("UIListLayout", { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Guide.body })
Guide.ROWS = {
	{ key = "gift", icon = "🎁", title = "REGALA", short = "REGALO = GOLPE", desc = "Cada regalo suma puntos y tu campeón golpea al rival", color = GOLD },
	{ key = "special", icon = "⚡", title = "REGALOS ESPECIALES", short = "ESPECIAL = ATAQUE", desc = "Lanzan ataques de película: mira la lista →", color = Color3.fromRGB(120, 205, 255) },
	{ key = "likes", icon = "❤️", title = "DALE LIKE", short = "LIKE = ENERGÍA", desc = "Llenas la ENERGÍA DEL PÚBLICO: ¡golpe del público!", color = PINK },
	{ key = "follow", icon = "➕", title = "SIGUE", short = "SEGUIR = CURA", desc = "Curas a tu campeón (+10% de vida)", color = GREEN },
	{ key = "power", icon = "🔥", title = "MÁS PUNTOS, MÁS PODER", short = "PUNTOS = PODER", desc = "Fuego y humo a los 100 · 1K · 5K · 20K", color = Color3.fromRGB(255, 140, 50) },
}
for index, def in ipairs(Guide.ROWS) do
	local row = new("Frame", {
		Size = UDim2.new(1, 0, 1 / #Guide.ROWS, -7),
		BackgroundColor3 = Color3.fromRGB(34, 30, 50),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		LayoutOrder = index,
		Parent = Guide.body,
	}, { corner(14) })
	local rowStroke = stroke(def.color, 2, 0.75)
	rowStroke.Parent = row
	local scale = new("UIScale", { Parent = row })
	local icon = new("Frame", {
		Size = UDim2.fromScale(0.7, 0.7),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Position = UDim2.new(0, 8, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = def.color:Lerp(BLACK, 0.55),
		BorderSizePixel = 0,
		Parent = row,
	}, { corner() })
	stroke(def.color, 2, 0.2).Parent = icon
	local iconLabel = text({
		Size = UDim2.fromScale(0.68, 0.68),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = def.icon,
		TextStrokeTransparency = 1,
		Parent = icon,
	})
	task.delay(index * 0.15, function()
		loop(iconLabel, 0.8, { Position = UDim2.fromScale(0.5, 0.42) })
	end)
	local title = text({
		Size = UDim2.fromScale(0.7, 0.36),
		Position = UDim2.fromScale(0.28, 0.1),
		Font = FONT_BLACK,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = def.color,
		Text = def.title,
		Parent = row,
	})
	local desc = text({
		Size = UDim2.fromScale(0.7, 0.44),
		Position = UDim2.fromScale(0.28, 0.48),
		Font = FONT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Color3.fromRGB(225, 220, 235),
		TextStrokeTransparency = 0.8,
		Text = def.desc,
		Parent = row,
	})
	Guide.rows[def.key] = { frame = row, stroke = rowStroke, scale = scale, icon = icon, color = def.color, title = title, desc = desc, def = def }
end

-- En vertical (móvil) cada fila es una frase corta y grande; en horizontal, título + explicación
function Guide.setCompact(compact)
	for _, row in pairs(Guide.rows) do
		row.title.Text = if compact then row.def.short else row.def.title
		row.title.Position = if compact then UDim2.fromScale(0.28, 0.14) else UDim2.fromScale(0.28, 0.1)
		row.title.Size = if compact then UDim2.fromScale(0.7, 0.72) else UDim2.fromScale(0.7, 0.36)
		row.desc.Visible = not compact
	end
end

-- Ilumina una fila (cuando alguien hace eso)
function Guide.flash(key, strong)
	local row = Guide.rows[key]
	local now = os.clock()
	if not row or (Guide.lastFlash[key] and now - Guide.lastFlash[key] < 0.5) then
		return
	end
	Guide.lastFlash[key] = now
	row.stroke.Transparency = 0
	row.stroke.Thickness = 3
	row.frame.BackgroundColor3 = row.color:Lerp(BLACK, 0.45)
	tween(row.stroke, 0.9, { Transparency = 0.75, Thickness = 2 })
	tween(row.frame, 0.9, { BackgroundColor3 = Color3.fromRGB(34, 30, 50) })
	pop(row.scale, if strong then 1.12 else 1.06, 0.4)
end

-- Si nadie hace nada, las filas se van iluminando suave por turnos (llaman la atención)
task.spawn(function()
	local index = 0
	while true do
		task.wait(2.2)
		if gui.Enabled then
			index = index % #Guide.ROWS + 1
			local row = Guide.rows[Guide.ROWS[index].key]
			if not Guide.lastFlash[Guide.ROWS[index].key] or os.clock() - Guide.lastFlash[Guide.ROWS[index].key] > 3 then
				row.stroke.Transparency = 0.2
				tween(row.stroke, 1.2, { Transparency = 0.75 })
			end
		end
	end
end)

-- ===== ATAQUES ESPECIALES (regalo → ataque) =====
local Attacks = { rows = {} }
Attacks.ORDER = { 1, 2, 3, 4, 5, "rain", "crowd" }
Attacks.frame = panelFrame("BattleAttacks", Color3.fromRGB(120, 205, 255))
Attacks.frame.Visible = false
Attacks.frame.Parent = safe
text({
	Name = "Header",
	Font = FONT_BLACK,
	TextColor3 = Color3.fromRGB(140, 215, 255),
	Text = "⚡ ATAQUES ESPECIALES",
	Parent = Attacks.frame,
})
Attacks.body = new("Frame", { BackgroundTransparency = 1, Parent = Attacks.frame })
new("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder, Parent = Attacks.body })
Attacks.footer = text({
	Name = "Footer",
	Font = FONT,
	TextColor3 = MUTED,
	TextStrokeTransparency = 0.8,
	Text = "Otros regalos: 30💎 🔥 · 100💎 💥 · 300💎 ⚡ · 1K💎 ☄️",
	Parent = Attacks.frame,
})

local function giftsOfLevel(level)
	local list = {}
	for _, team in ipairs({ "hero", "villain" }) do
		for _, giftId in ipairs(Shared.GIFT_ORDER[team]) do
			local info = Shared.GIFTS[giftId]
			if info and ((level == "rain" and info.action == "rain") or (info.action ~= "rain" and info.level == level)) then
				table.insert(list, info)
			end
		end
	end
	return list
end

function Attacks.build()
	for _, child in ipairs(Attacks.body:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	table.clear(Attacks.rows)
	for index, level in ipairs(Attacks.ORDER) do
		local attack = BATTLE.ATTACKS[level]
		local color = LEVEL_COLORS[level]
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 1 / #Attacks.ORDER, -5),
			BackgroundColor3 = Color3.fromRGB(32, 30, 48),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			LayoutOrder = index,
			Parent = Attacks.body,
		}, { corner(12) })
		local rowStroke = stroke(color, 2, 0.7)
		rowStroke.Parent = row
		local scale = new("UIScale", { Parent = row })
		local pics = new("Frame", {
			Size = UDim2.fromScale(0.26, 0.86),
			Position = UDim2.fromScale(0.02, 0.5),
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			Parent = row,
		})
		local gifts = if level == "crowd" then {} else giftsOfLevel(level)
		local names = {}
		if level == "crowd" then
			text({ Size = UDim2.fromScale(1, 1), Text = "❤️", TextStrokeTransparency = 1, Parent = pics })
		elseif #gifts == 0 then
			text({ Size = UDim2.fromScale(1, 0.6), Position = UDim2.fromScale(0, 0.2), Text = "—", TextColor3 = MUTED, Parent = pics })
		else
			local shown = math.min(2, #gifts)
			for i = 1, shown do
				local image = new("ImageLabel", {
					Size = UDim2.fromScale(1 / shown, 1),
					Position = UDim2.fromScale((i - 1) / shown, 0),
					BackgroundTransparency = 1,
					Image = gifts[i].image or "",
					ScaleType = Enum.ScaleType.Fit,
					Parent = pics,
				})
				loop(image, 0.9 + i * 0.2 + index * 0.05, { Rotation = 6 })
			end
		end
		for i = 1, math.min(3, #gifts) do
			table.insert(names, gifts[i].gift)
		end
		local title = text({
			Size = UDim2.fromScale(0.56, 0.5),
			Position = UDim2.fromScale(0.3, 0.06),
			Font = FONT_BLACK,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = color,
			TextStrokeTransparency = 0.3,
			Text = attack.emoji .. " " .. attack.name,
			Parent = row,
		})
		local defaultSub = if level == "crowd"
			then ("cada " .. Shared.formatNumber(tonumber(data.likeGoal) or setting("BattleLikeGoal")) .. " likes")
			elseif #names > 0 then table.concat(names, " · ")
			else "Sin regalo asignado"
		local sub = text({
			Size = UDim2.fromScale(0.56, 0.36),
			Position = UDim2.fromScale(0.3, 0.58),
			Font = FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.fromRGB(215, 210, 230),
			TextStrokeTransparency = 0.8,
			Text = defaultSub,
			Parent = row,
		})
		local tagFrame = new("Frame", {
			Size = UDim2.fromScale(0.12, 0.5),
			Position = UDim2.fromScale(0.98, 0.5),
			AnchorPoint = Vector2.new(1, 0.5),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = row,
		}, { corner() })
		text({
			Size = UDim2.fromScale(0.8, 0.75),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Font = FONT_BLACK,
			TextColor3 = Color3.fromRGB(20, 14, 26),
			TextStrokeTransparency = 1,
			Text = if type(level) == "number" then ("Nv" .. level) elseif level == "rain" then "🌧" else "❤",
			Parent = tagFrame,
		})
		Attacks.rows[level] = { frame = row, stroke = rowStroke, scale = scale, title = title, sub = sub, defaultSub = defaultSub, color = color }
	end
	Attacks.setCompact(Attacks.compact)
end

-- En vertical (móvil) cada fila muestra solo el ataque en grande; al salir, dice quién lo lanzó
function Attacks.arrange(row)
	local compact = Attacks.compact
	local both = not compact or row.flashing
	row.title.Visible = not (compact and row.flashing)
	row.sub.Visible = both
	if compact and row.flashing then
		row.sub.Position = UDim2.fromScale(0.3, 0.1)
		row.sub.Size = UDim2.fromScale(0.56, 0.8)
	else
		row.sub.Position = UDim2.fromScale(0.3, 0.58)
		row.sub.Size = UDim2.fromScale(0.56, 0.36)
	end
	row.title.Position = if compact then UDim2.fromScale(0.3, 0.1) else UDim2.fromScale(0.3, 0.06)
	row.title.Size = if compact then UDim2.fromScale(0.56, 0.8) else UDim2.fromScale(0.56, 0.5)
end

function Attacks.setCompact(compact)
	Attacks.compact = compact
	for _, row in pairs(Attacks.rows) do
		Attacks.arrange(row)
	end
end
Shared.giftsChanged.Event:Connect(function()
	Attacks.build()
end)

Attacks.build()

-- Un ataque acaba de salir: su fila brilla y dice quién lo lanzó
function Attacks.flash(level, user)
	local row = Attacks.rows[level]
	if not row then
		return
	end
	row.stroke.Transparency = 0
	row.stroke.Thickness = 4
	row.frame.BackgroundColor3 = row.color:Lerp(BLACK, 0.35)
	row.sub.Text = "¡AHORA! por " .. tostring(user or "?")
	row.sub.TextColor3 = WHITE
	row.sub.Font = FONT_BLACK
	row.flashing = true
	Attacks.arrange(row)
	pop(row.scale, 1.12, 0.45)
	task.spawn(function()
		for i = 1, 6 do
			row.frame.Rotation = if i % 2 == 0 then 1.5 else -1.5
			task.wait(0.04)
		end
		row.frame.Rotation = 0
	end)
	tween(row.stroke, 1.6, { Transparency = 0.7, Thickness = 2 })
	tween(row.frame, 1.6, { BackgroundColor3 = Color3.fromRGB(32, 30, 48) })
	task.delay(2.6, function()
		if row.frame.Parent then
			row.sub.Text = row.defaultSub
			row.sub.TextColor3 = Color3.fromRGB(215, 210, 230)
			row.sub.Font = FONT
			row.flashing = false
			Attacks.arrange(row)
		end
	end)
end

-- ===== ENERGÍA DEL PÚBLICO (likes) =====
local Crowd = {}
Crowd.frame = panelFrame("BattleCrowd", PINK)
Crowd.frame.Visible = false
Crowd.frame.Parent = safe
Crowd.scale = new("UIScale", { Parent = Crowd.frame })
Crowd.title = text({
	Size = UDim2.fromScale(0.62, 0.34),
	Position = UDim2.fromScale(0.04, 0.09),
	Font = FONT_BLACK,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = PINK,
	Text = "❤️ ENERGÍA DEL PÚBLICO",
	Parent = Crowd.frame,
})
Crowd.count = text({
	Size = UDim2.fromScale(0.32, 0.3),
	Position = UDim2.fromScale(0.96, 0.11),
	AnchorPoint = Vector2.new(1, 0),
	Font = FONT_BOLD,
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "0 / 300",
	Parent = Crowd.frame,
})
Crowd.track = new("Frame", {
	Size = UDim2.fromScale(0.92, 0.36),
	Position = UDim2.fromScale(0.04, 0.52),
	BackgroundColor3 = Color3.fromRGB(45, 20, 40),
	BorderSizePixel = 0,
	Parent = Crowd.frame,
}, { corner() })
stroke(PINK, 2, 0.5).Parent = Crowd.track
Crowd.fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2, Parent = Crowd.track }, { corner() })
new("UIGradient", { Color = seq(Color3.fromRGB(255, 160, 210), PINK, Color3.fromRGB(200, 40, 120)), Rotation = 90, Parent = Crowd.fill })
shine(Crowd.fill, nil, 1, 3)
Crowd.hint = text({
	Size = UDim2.new(1, -20, 0.7, 0),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BLACK,
	TextStrokeTransparency = 0.2,
	Text = "¡DALE LIKE PARA EL GOLPE DEL PÚBLICO!",
	ZIndex = 5,
	Parent = Crowd.track,
})
Crowd.value = new("NumberValue", { Value = 0 })
Crowd.value.Changed:Connect(function(value)
	Crowd.fill.Size = UDim2.fromScale(math.clamp(value, 0, 1), 1)
end)

-- Corazones que suben desde la barra
function Crowd.hearts(amount)
	for _ = 1, math.clamp(math.floor((amount or 1) / 10) + 1, 1, 6) do
		local heart = text({
			Size = UDim2.fromScale(0.07, 0.34),
			Position = UDim2.fromScale(0.08 + math.random() * 0.84, 0.6),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Text = ({ "❤️", "💖", "💗" })[math.random(1, 3)],
			TextStrokeTransparency = 1,
			Rotation = math.random(-25, 25),
			ZIndex = 8,
			Parent = Crowd.frame,
		})
		tween(heart, 0.9 + math.random() * 0.4, { Position = heart.Position - UDim2.fromScale(0, 0.9 + math.random() * 0.4), TextTransparency = 1, Rotation = math.random(-40, 40) })
		Debris:AddItem(heart, 1.4)
	end
end

function Crowd.burst()
	Crowd.value.Value = 1
	pop(Crowd.scale, 1.12, 0.5)
	Crowd.hint.Text = "💥 ¡GOLPE DEL PÚBLICO! 💥"
	Crowd.hearts(60)
	task.delay(1.6, function()
		Crowd.hint.Text = "¡DALE LIKE PARA EL GOLPE DEL PÚBLICO!"
	end)
end

-- ===== MVP DE LA BATALLA =====
local Mvp = { slots = {}, last = {} }
Mvp.frame = panelFrame("BattleMvp", GOLD)
Mvp.frame.Visible = false
Mvp.frame.Parent = safe
text({
	Size = UDim2.fromScale(0.92, 0.28),
	Position = UDim2.fromScale(0.04, 0.05),
	Font = FONT_BLACK,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextColor3 = GOLD,
	Text = "🏅 MVP DE LA BATALLA",
	Parent = Mvp.frame,
})
Mvp.empty = text({
	Size = UDim2.fromScale(0.9, 0.36),
	Position = UDim2.fromScale(0.5, 0.62),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BOLD,
	TextColor3 = MUTED,
	Text = "¡Regala y aparece aquí!",
	Parent = Mvp.frame,
})
for i, medal in ipairs({ "🥇", "🥈", "🥉" }) do
	local slot = new("Frame", {
		Size = UDim2.new(1 / 3, -10, 0.58, 0),
		Position = UDim2.new((i - 1) / 3, 5 + (i == 1 and 5 or 0), 0.36, 0),
		BackgroundColor3 = if i == 1 then Color3.fromRGB(80, 60, 10) else Color3.fromRGB(36, 32, 50),
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Visible = false,
		Parent = Mvp.frame,
	}, { corner(12) })
	local scale = new("UIScale", { Parent = slot })
	text({ Size = UDim2.fromScale(0.26, 0.8), Position = UDim2.fromScale(0.02, 0.1), Text = medal, TextStrokeTransparency = 1, Parent = slot })
	local name = text({
		Size = UDim2.fromScale(0.7, 0.5),
		Position = UDim2.fromScale(0.29, 0.06),
		Font = FONT_BLACK,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = slot,
	})
	local coins = text({
		Size = UDim2.fromScale(0.7, 0.4),
		Position = UDim2.fromScale(0.29, 0.56),
		Font = FONT_BOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(150, 220, 255),
		Text = "",
		Parent = slot,
	})
	Mvp.slots[i] = { frame = slot, scale = scale, name = name, coins = coins }
end

function Mvp.render(list)
	list = type(list) == "table" and list or {}
	Mvp.empty.Visible = #list == 0
	for i, slot in ipairs(Mvp.slots) do
		local entry = list[i]
		slot.frame.Visible = entry ~= nil
		if entry then
			local key = tostring(entry.name) .. ":" .. tostring(entry.coins)
			slot.name.Text = tostring(entry.name)
			slot.coins.Text = "💎 " .. Shared.formatNumber(tonumber(entry.coins) or 0)
			if Mvp.last[i] ~= key then
				pop(slot.scale, 1.15, 0.4)
			end
			Mvp.last[i] = key
		else
			Mvp.last[i] = nil
		end
	end
end

-- ===== TARJETAS DE LO QUE PASA =====
local Cards = { counter = 0 }
Cards.frame = new("Frame", { Name = "BattleCards", BackgroundTransparency = 1, Visible = false, Parent = safe })
new("UIListLayout", {
	Padding = UDim.new(0, 8),
	SortOrder = Enum.SortOrder.LayoutOrder,
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	Parent = Cards.frame,
})

-- opts: { side, color, image, emoji, title, subtitle, big }
function Cards.push(opts)
	Cards.counter += 1
	local big = opts.big == true
	local color = opts.color or WHITE
	local fromRight = opts.side == "rival"
	local holder = new("Frame", {
		Size = UDim2.new(if big then 1 else 0.86, 0, 0, if big then 92 else 62),
		BackgroundTransparency = 1,
		LayoutOrder = Cards.counter,
		Parent = Cards.frame,
	})
	local card = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(if fromRight then 1.2 else -1.2, 0),
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Parent = holder,
	}, { corner(18) })
	new("UIGradient", { Color = seq(color:Lerp(BLACK, 0.35), Color3.fromRGB(16, 12, 24), color:Lerp(BLACK, 0.55)), Parent = card })
	stroke(color, if big then 3 else 2, 0.1).Parent = card
	local scale = new("UIScale", { Parent = card })
	local iconSize = if big then 0.84 else 0.8
	if opts.image and opts.image ~= "" then
		new("ImageLabel", {
			Size = UDim2.fromScale(iconSize, iconSize),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			Position = UDim2.new(0, 10, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			BackgroundTransparency = 1,
			Image = opts.image,
			ScaleType = Enum.ScaleType.Fit,
			Parent = card,
		})
	else
		text({
			Size = UDim2.fromScale(iconSize * 0.85, iconSize * 0.85),
			SizeConstraint = Enum.SizeConstraint.RelativeYY,
			Position = UDim2.new(0, 12, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5),
			Text = opts.emoji or "⚡",
			TextStrokeTransparency = 1,
			Parent = card,
		})
	end
	local textX = if big then 0.17 else 0.13
	text({
		Size = UDim2.fromScale(0.8, if opts.subtitle then 0.52 else 0.7),
		Position = UDim2.fromScale(textX, if opts.subtitle then 0.06 else 0.15),
		Font = FONT_BLACK,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color:Lerp(WHITE, 0.35),
		TextStrokeTransparency = 0.2,
		Text = opts.title or "",
		Parent = card,
	})
	if opts.subtitle then
		text({
			Size = UDim2.fromScale(0.8, 0.36),
			Position = UDim2.fromScale(textX, 0.58),
			Font = FONT_BOLD,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Color3.fromRGB(230, 225, 240),
			Text = opts.subtitle,
			Parent = card,
		})
	end
	if big then
		shine(card, 18, 0.8, 3)
	end
	tween(card, 0.35, { Position = UDim2.fromScale(0, 0) }, Enum.EasingStyle.Back)
	-- como mucho 4 a la vez: la más vieja se va
	local items = {}
	for _, child in ipairs(Cards.frame:GetChildren()) do
		if child:IsA("Frame") then
			table.insert(items, child)
		end
	end
	table.sort(items, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #items - 4 do
		items[i]:Destroy()
	end
	task.delay(if big then 3.6 else 2.8, function()
		if holder.Parent then
			tween(card, 0.3, { Position = UDim2.fromScale(if fromRight then -1.2 else 1.2, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			Debris:AddItem(holder, 0.32)
		end
	end)
	pop(scale, 1.05, 0.3)
end

-- ===== EFECTOS A PANTALLA COMPLETA =====
local Fx = {}

-- Aviso de últimos segundos (debajo de la barra)
Fx.last = new("Frame", {
	Name = "BattleLastCall",
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Visible = false,
	Parent = safe,
}, { corner() })
new("UIGradient", { Color = seq(Color3.fromRGB(255, 80, 60), Color3.fromRGB(170, 10, 40)), Rotation = 90, Parent = Fx.last })
stroke(WHITE, 2, 0.2).Parent = Fx.last
Fx.lastScale = new("UIScale", { Parent = Fx.last })
text({
	Size = UDim2.new(1, -24, 0.72, 0),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	Font = FONT_BLACK,
	TextStrokeTransparency = 0.2,
	Text = "⏳ ¡ÚLTIMOS SEGUNDOS! ¡MANDA TU REGALO!",
	Parent = Fx.last,
})
loop(Fx.lastScale, 0.35, { Scale = 1.06 })

-- Texto grande que cruza la pantalla ("¡REMONTADA!", "PODER 3"...)
function Fx.callout(message, color, side)
	local fromRight = side == "rival"
	local strip = new("Frame", {
		Size = UDim2.fromScale(1.2, 0.09),
		Position = UDim2.fromScale(if fromRight then 1.6 else -0.6, 0.34),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Rotation = -4,
		BackgroundColor3 = WHITE,
		BorderSizePixel = 0,
		ZIndex = 20,
		Parent = overlay,
	})
	new("UIGradient", {
		Color = seq(color:Lerp(BLACK, 0.6), color, color:Lerp(BLACK, 0.6)),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.1), NumberSequenceKeypoint.new(0.85, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Parent = strip,
	})
	text({
		Size = UDim2.fromScale(0.7, 0.8),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextStrokeTransparency = 0,
		Text = message,
		ZIndex = 21,
		Parent = strip,
	})
	tween(strip, 0.3, { Position = UDim2.fromScale(0.5, 0.34) }, Enum.EasingStyle.Back)
	task.delay(1.5, function()
		tween(strip, 0.3, { Position = UDim2.fromScale(if fromRight then -0.6 else 1.6, 0.34) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(strip, 0.35)
	end)
end

-- Número gigante de la cuenta atrás (5, 4, 3, 2, 1)
function Fx.countdown(n)
	local label = text({
		Size = UDim2.fromScale(0.3, 0.3),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextColor3 = Color3.fromRGB(255, 90, 80),
		TextStrokeTransparency = 0,
		TextTransparency = 0.1,
		Text = tostring(n),
		ZIndex = 25,
		Parent = overlay,
	})
	new("UIAspectRatioConstraint", { Parent = label })
	local scale = new("UIScale", { Scale = 2.2, Parent = label })
	tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(0.6, function()
		tween(label, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
		tween(scale, 0.3, { Scale = 0.6 })
	end)
	Debris:AddItem(label, 1)
end

-- Pantalla VS al empezar
function Fx.splash(meName, rivalName)
	local vertical = isVertical()
	local holder = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 30, Parent = overlay })
	local dim = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 30, Parent = holder })
	tween(dim, 0.25, { BackgroundTransparency = 0.45 })
	local function slab(team, name, fromRight)
		local info = TEAMS[team]
		local y = if fromRight then 0.58 else 0.4
		local size = if vertical then UDim2.fromScale(0.9, 0.12) else UDim2.fromScale(0.5, 0.17)
		local panel = new("Frame", {
			Size = size,
			Position = UDim2.fromScale(if fromRight then 1.6 else -0.6, y),
			AnchorPoint = Vector2.new(if fromRight then 0 else 1, 0.5),
			Rotation = -5,
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			ZIndex = 31,
			Parent = holder,
		}, { corner(18) })
		new("UIGradient", { Color = seq(info.color:Lerp(WHITE, 0.2), info.dark), Rotation = 90, Parent = panel })
		stroke(WHITE, 3, 0.2).Parent = panel
		text({
			Size = UDim2.fromScale(0.82, 0.62),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Font = FONT_BLACK,
			TextStrokeTransparency = 0,
			Text = if fromRight then (tostring(name) .. " " .. info.emoji) else (info.emoji .. " " .. tostring(name)),
			ZIndex = 32,
			Parent = panel,
		})
		local target = if vertical then UDim2.fromScale(if fromRight then 0.05 else 0.95, y) else UDim2.fromScale(if fromRight then 0.47 else 0.53, y)
		tween(panel, 0.45, { Position = target }, Enum.EasingStyle.Back)
		return panel
	end
	local left = slab("hero", meName, false)
	local right = slab("villain", rivalName, true)
	local vs = text({
		Size = UDim2.fromScale(0.2, 0.2),
		Position = UDim2.fromScale(0.5, 0.49),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextColor3 = WHITE,
		TextStrokeColor3 = RED,
		TextStrokeTransparency = 0,
		TextTransparency = 1,
		Text = "VS",
		ZIndex = 35,
		Parent = holder,
	})
	new("UIAspectRatioConstraint", { Parent = vs })
	new("UIGradient", { Color = seq(GOLD, WHITE, RED), Rotation = 90, Parent = vs })
	local vsScale = new("UIScale", { Scale = 4, Parent = vs })
	local go = text({
		Size = UDim2.fromScale(if vertical then 0.9 else 0.6, 0.07),
		Position = UDim2.fromScale(0.5, 0.78),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextColor3 = GOLD,
		TextStrokeTransparency = 0,
		TextTransparency = 1,
		Text = "¡QUE EMPIECE LA BATALLA!",
		ZIndex = 35,
		Parent = holder,
	})
	task.delay(0.4, function()
		tween(vs, 0.25, { TextTransparency = 0 })
		tween(vsScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		-- golpe: destello y temblor
		local flash = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 0.3, BorderSizePixel = 0, ZIndex = 34, Parent = holder })
		tween(flash, 0.4, { BackgroundTransparency = 1 })
		task.spawn(function()
			for _ = 1, 8 do
				holder.Position = UDim2.fromOffset(math.random(-14, 14), math.random(-10, 10))
				task.wait(0.03)
			end
			holder.Position = UDim2.fromOffset(0, 0)
		end)
	end)
	task.delay(0.8, function()
		go.Position = UDim2.fromScale(0.5, 0.84)
		tween(go, 0.3, { TextTransparency = 0, Position = UDim2.fromScale(0.5, 0.78) }, Enum.EasingStyle.Back)
	end)
	task.delay(2.4, function()
		tween(left, 0.35, { Position = UDim2.fromScale(-0.7, 0.4) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(right, 0.35, { Position = UDim2.fromScale(1.7, 0.58) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(vsScale, 0.35, { Scale = 0 })
		tween(go, 0.3, { TextTransparency = 1, TextStrokeTransparency = 1 })
		tween(dim, 0.4, { BackgroundTransparency = 1 })
		pop(Bar.scale, 1.06, 0.5)
	end)
	Debris:AddItem(holder, 3)
end

-- Pantalla de resultado (rayos girando, corona y el ganador)
function Fx.showResult()
	if Fx.result then
		return
	end
	local vertical = isVertical()
	local winner = data.winner
	local me = type(data.me) == "table" and data.me or {}
	local rival = type(data.rival) == "table" and data.rival or {}
	local winnerSide = if winner == "me" then me elseif winner == "rival" then rival else nil
	local color = if winner == "me" then TEAMS.hero.color elseif winner == "rival" then TEAMS.villain.color else Color3.fromRGB(210, 210, 230)
	local holder = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 40, Parent = overlay })
	Fx.result = holder
	local dim = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 40, Parent = holder })
	tween(dim, 0.4, { BackgroundTransparency = 0.5 })
	-- rayos
	local rays = new("Frame", {
		Size = UDim2.fromScale(if vertical then 1.4 else 0.9, if vertical then 1.4 else 0.9),
		SizeConstraint = if vertical then Enum.SizeConstraint.RelativeXX else Enum.SizeConstraint.RelativeYY,
		Position = UDim2.fromScale(0.5, 0.42),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 41,
		Parent = holder,
	})
	for i = 1, 16 do
		local ray = new("Frame", {
			Size = UDim2.fromScale(0.07, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 1),
			Rotation = i * 22.5,
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = 41,
			Parent = rays,
		})
		new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.75), NumberSequenceKeypoint.new(1, 0.55) }),
			Parent = ray,
		})
	end
	spinning[rays] = 18
	local raysScale = new("UIScale", { Scale = 0, Parent = rays })
	tween(raysScale, 0.6, { Scale = 1 }, Enum.EasingStyle.Back)
	local crown = text({
		Size = UDim2.fromScale(0.14, 0.14),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Position = UDim2.fromScale(0.5, -0.2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Text = if winnerSide then "👑" else "🤝",
		TextStrokeTransparency = 1,
		ZIndex = 44,
		Parent = holder,
	})
	tween(crown, 0.7, { Position = UDim2.fromScale(0.5, 0.27) }, Enum.EasingStyle.Bounce)
	local width = if vertical then 0.92 else 0.62
	local title = text({
		Size = UDim2.fromScale(width, 0.08),
		Position = UDim2.fromScale(0.5, 0.38),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextColor3 = WHITE,
		TextStrokeTransparency = 0,
		Text = if winner == "me" then "🏆 ¡VICTORIA!" elseif winner == "rival" then "💀 GANA EL RIVAL" else "¡EMPATE!",
		ZIndex = 44,
		Parent = holder,
	})
	new("UIGradient", { Color = seq(GOLD, WHITE, color), Rotation = 90, Parent = title })
	local name = text({
		Size = UDim2.fromScale(width, 0.1),
		Position = UDim2.fromScale(0.5, 0.48),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BLACK,
		TextColor3 = color,
		TextStrokeTransparency = 0,
		Text = if winnerSide then string.upper(tostring(winnerSide.name)) else (tostring(me.name) .. " 🤝 " .. tostring(rival.name)),
		ZIndex = 44,
		Parent = holder,
	})
	local nameScale = new("UIScale", { Scale = 0.3, Parent = name })
	tween(nameScale, 0.5, { Scale = 1 }, Enum.EasingStyle.Back)
	text({
		Size = UDim2.fromScale(width * 0.8, 0.05),
		Position = UDim2.fromScale(0.5, 0.56),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BOLD,
		TextStrokeTransparency = 0.2,
		Text = TEAMS.hero.emoji .. " " .. Shared.formatNumber(tonumber(me.points) or 0) .. "   vs   " .. Shared.formatNumber(tonumber(rival.points) or 0) .. " " .. TEAMS.villain.emoji,
		ZIndex = 44,
		Parent = holder,
	})
	local top = type(data.supporters) == "table" and data.supporters[1]
	text({
		Size = UDim2.fromScale(width * 0.8, 0.04),
		Position = UDim2.fromScale(0.5, 0.62),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Font = FONT_BOLD,
		TextColor3 = GOLD,
		TextStrokeTransparency = 0.2,
		Text = if top then ("🏅 MVP: " .. tostring(top.name) .. " · ¡gracias!") elseif winner == "rival" then "¡La próxima es nuestra!" else "¡Gracias a todos!",
		ZIndex = 44,
		Parent = holder,
	})
	-- confeti de cuadritos
	for _ = 1, 40 do
		local bit = new("Frame", {
			Size = UDim2.fromOffset(math.random(8, 16), math.random(8, 16)),
			Position = UDim2.fromScale(math.random(), -0.05),
			BackgroundColor3 = ({ GOLD, color, WHITE, RED, TEAMS.villain.color })[math.random(1, 5)],
			BorderSizePixel = 0,
			Rotation = math.random(0, 90),
			ZIndex = 43,
			Parent = holder,
		})
		tween(bit, 2 + math.random() * 2, { Position = UDim2.fromScale(math.random(), 1.05), Rotation = math.random(180, 720) }, Enum.EasingStyle.Linear)
		Debris:AddItem(bit, 4.2)
	end
end

function Fx.hideResult()
	local holder = Fx.result
	Fx.result = nil
	if holder then
		for _, item in ipairs(holder:GetDescendants()) do
			if item:IsA("TextLabel") then
				tween(item, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 })
			elseif item:IsA("Frame") then
				tween(item, 0.35, { BackgroundTransparency = 1 })
			end
		end
		Debris:AddItem(holder, 0.4)
	end
end

-- ===== DISEÑO (horizontal / vertical) =====
local function place(frame, anchor, position, size)
	frame.AnchorPoint = anchor
	frame.Position = position
	frame.Size = size
end

local function applyLayout()
	local viewport = camera.ViewportSize
	local vertical = isVertical()
	local base = if vertical then math.min(viewport.X / 1080, viewport.Y / 1920) else math.min(viewport.X / 1920, viewport.Y / 1080)
	local scale = math.clamp(base * setting("HudScale"), 0.2, 3)
	rootScale.Scale = scale
	root.Size = UDim2.fromOffset(viewport.X / scale, viewport.Y / scale)
	local side, top, bottom = setting("HudSafeSide"), setting("HudSafeTop"), setting("HudSafeBottom")
	safe.Position = UDim2.fromOffset(side, top)
	safe.Size = UDim2.new(1, -side * 2, 1, -(top + bottom))

	local headerH
	if vertical then
		place(Bar.frame, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 30), UDim2.fromOffset(1040, 270))
		Bar.layout(1040, 270)
		place(Lobby.frame, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 30), UDim2.fromOffset(1000, 250))
		place(Fx.last, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 318), UDim2.fromOffset(780, 52))
		place(Guide.frame, Vector2.new(0, 0), UDim2.fromOffset(10, 384), UDim2.fromOffset(345, 470))
		place(Attacks.frame, Vector2.new(1, 0), UDim2.new(1, -10, 0, 384), UDim2.fromOffset(355, 620))
		place(Cards.frame, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -290), UDim2.fromOffset(700, 330))
		place(Crowd.frame, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -146), UDim2.fromOffset(1000, 112))
		place(Mvp.frame, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -14), UDim2.fromOffset(1000, 122))
		headerH = 46
	else
		place(Bar.frame, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 26), UDim2.fromOffset(1300, 200))
		Bar.layout(1300, 200)
		place(Lobby.frame, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 26), UDim2.fromOffset(1100, 190))
		place(Fx.last, Vector2.new(0.5, 0), UDim2.new(0.5, 0, 0, 240), UDim2.fromOffset(760, 50))
		place(Guide.frame, Vector2.new(0, 0), UDim2.fromOffset(16, 250), UDim2.fromOffset(380, 560))
		place(Attacks.frame, Vector2.new(1, 0), UDim2.new(1, -16, 0, 250), UDim2.fromOffset(410, 610))
		place(Cards.frame, Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -16), UDim2.fromOffset(680, 320))
		place(Crowd.frame, Vector2.new(0, 1), UDim2.new(0, 16, 1, -16), UDim2.fromOffset(470, 120))
		place(Mvp.frame, Vector2.new(1, 1), UDim2.new(1, -16, 1, -16), UDim2.fromOffset(470, 140))
		headerH = 40
	end
	Guide.setCompact(vertical)
	Attacks.setCompact(vertical)
	-- cabeceras y cuerpos de las columnas
	for _, panel in ipairs({ Guide, Attacks }) do
		local header = panel.frame:FindFirstChild("Header")
		header.Position = UDim2.fromOffset(12, 10)
		header.Size = UDim2.new(1, -24, 0, headerH)
		local footer = panel.frame:FindFirstChild("Footer")
		local footerH = if footer then 30 else 0
		if footer then
			footer.Size = UDim2.new(1, -20, 0, footerH)
			footer.Position = UDim2.new(0, 10, 1, -footerH - 8)
		end
		panel.body.Position = UDim2.fromOffset(10, headerH + 18)
		panel.body.Size = UDim2.new(1, -20, 1, -(headerH + 26 + footerH + (if footer then 6 else 0)))
	end
end

-- ===== ACTUALIZAR CON LOS DATOS DEL SERVIDOR =====
local function refreshVisibility()
	local battleMode = setting("GameMode") == "Batalla"
	local cinematic = stateFolder:GetAttribute("CinematicActive") == true or stateFolder:GetAttribute("BattleFinisher") == true
	gui.Enabled = battleMode and not cinematic
	-- el editor del HUD normal (abajo a la derecha) no sirve en modo Batalla y taparía el MVP
	local editor = playerGui:FindFirstChild("ArenaHudEditor")
	if editor then
		editor.Enabled = not battleMode
	end
end

local function sideData(key)
	return type(data[key]) == "table" and data[key] or {}
end

local function updateSide(s, info, otherPoints, isNew)
	local points = tonumber(info.points) or 0
	local previous = s.shown or 0
	s.name.Text = tostring(info.name or "")
	if isNew then
		s.value.Value = points
	else
		tween(s.value, 0.6, { Value = points })
	end
	local total = points + otherPoints
	s.pct.Text = (if total > 0 then math.floor(points / total * 100 + 0.5) else 50) .. "%"
	-- subió: brillo en su escudo, "+N", combo y chispas en el choque
	if not isNew and points > previous then
		local now = os.clock()
		s.combo = if now - s.lastHitAt < 3 then s.combo + 1 else 1
		s.lastHitAt = now
		pop(s.crestScale, 1.18, 0.35)
		pop(s.pointsScale, 1.25, 0.35)
		Bar.floater(s, points - previous)
		Bar.sparks(s.info.color, if points - previous >= 100 then 16 else 8)
		if s.combo >= 3 then
			s.comboLabel.Visible = true
			s.comboLabel.Text = "🔥 COMBO x" .. s.combo
			pop(s.comboScale, 1.4, 0.3)
		end
	end
	s.shown = points
	-- poder
	local level = math.clamp(tonumber(info.power) or 0, 0, 4)
	s.powerText.Text = "🔥 PODER " .. level
	for i, pip in ipairs(s.pips) do
		local lit = level >= i
		pip.frame.BackgroundColor3 = if lit then Color3.fromRGB(255, 150, 40) else Color3.fromRGB(60, 50, 70)
		if lit and not pip.lit and not isNew then
			pop(pip.scale, 1.8, 0.5)
		end
		pip.lit = lit
	end
	local nextStep = BATTLE.POWER_STEPS[level + 1]
	s.nextText.Text = if nextStep then ("→ " .. Shared.formatNumber(nextStep)) else "MÁX"
end

local function render(payload)
	local previous = data
	data = type(payload) == "table" and payload or { active = false }
	local active = data.active == true
	local isNew = active and previous.active ~= true
	Bar.frame.Visible = active
	Lobby.frame.Visible = not active
	Guide.frame.Visible = true
	Attacks.frame.Visible = true
	Cards.frame.Visible = true
	Crowd.frame.Visible = active
	Mvp.frame.Visible = active

	local wins = type(data.wins) == "table" and data.wins or {}
	local won, lost = tonumber(wins.me) or 0, tonumber(wins.rival) or 0
	Lobby.record.Text = if won + lost > 0 then ("🏆 Ganadas " .. won .. "  ·  Perdidas " .. lost) else "¡Dale like, sigue o regala mientras tanto!"

	if not active then
		Fx.hideResult()
		Fx.last.Visible = false
		view.leader = nil
		view.lastSecond = nil
		refreshVisibility()
		return
	end

	local me, rival = sideData("me"), sideData("rival")
	local mp, rp = tonumber(me.points) or 0, tonumber(rival.points) or 0
	if isNew then
		Bar.me.combo, Bar.rival.combo = 0, 0
		view.lastSecond = nil
		view.leader = nil
		Bar.me.shown, Bar.rival.shown = mp, rp
		Bar.ratio.Value = 0.5
		Crowd.value.Value = 0
		pop(Bar.scale, 0.6, 0.5)
	end
	updateSide(Bar.me, me, rp, isNew)
	updateSide(Bar.rival, rival, mp, isNew)
	local total = mp + rp
	tween(Bar.ratio, 0.5, { Value = if total > 0 then math.clamp(mp / total, 0.04, 0.96) else 0.5 }, Enum.EasingStyle.Back)

	-- quién va ganando (corona) y remontadas
	local leader = if mp > rp then "me" elseif rp > mp then "rival" else nil
	Bar.me.crown.Visible = leader == "me"
	Bar.rival.crown.Visible = leader == "rival"
	if leader and view.leader and leader ~= view.leader and data.phase == "fight" then
		local s = if leader == "me" then me else rival
		Fx.callout("🔄 ¡REMONTADA DE " .. string.upper(tostring(s.name)) .. "!", TEAMS[if leader == "me" then "hero" else "villain"].color, leader)
	end
	if leader then
		view.leader = leader
	end

	-- etiqueta de arriba
	local phase = data.phase
	Bar.tagText.Text = if phase == "intro" then "⚔️ PREPARANDO EL RING…"
		elseif phase == "finisher" then "💥 ¡ATAQUE FINAL!"
		elseif phase == "over" then "🏁 FINAL"
		else "🔴 BATALLA EN VIVO"

	-- energía del público
	local goal = math.max(1, tonumber(data.likeGoal) or setting("BattleLikeGoal"))
	local crowd = tonumber(data.crowd) or 0
	Crowd.count.Text = Shared.formatNumber(crowd) .. " / " .. Shared.formatNumber(goal) .. " ❤"
	tween(Crowd.value, 0.4, { Value = crowd / goal })

	Mvp.render(data.supporters)

	if phase == "over" then
		Fx.last.Visible = false
		Fx.showResult()
	else
		Fx.hideResult()
	end
	refreshVisibility()
end

-- Reloj: cuenta atrás si TikTok dijo cuánto dura; si no, tiempo transcurrido
task.spawn(function()
	while true do
		task.wait(0.1)
		if data.active and gui.Enabled then
			local now = Workspace:GetServerTimeNow()
			local endsAt = tonumber(data.endsAt)
			local startedAt = tonumber(data.startedAt) or now
			local dots = Bar.dots
			if endsAt and data.phase ~= "over" then
				local left = math.max(0, endsAt - now)
				local urgent = left <= 30
				Bar.time.Text = formatTime(math.ceil(left))
				Bar.timeCaption.Text = if urgent then "¡RÁPIDO!" else "QUEDAN"
				Bar.time.TextColor3 = if left <= 10 then Color3.fromRGB(255, 110, 100) else WHITE
				local lit = math.ceil(left / math.max(1, endsAt - startedAt) * #dots)
				for i, dot in ipairs(dots) do
					dot.BackgroundTransparency = if i <= lit then 0 else 0.85
					dot.BackgroundColor3 = if urgent then RED else WHITE
				end
				Bar.timerScale.Scale = if urgent then 1 + 0.06 * math.abs(math.sin(os.clock() * 6)) else 1
				Bar.timerStroke.Color = if urgent then RED else Color3.fromRGB(255, 120, 120)
				Fx.last.Visible = left <= 15 and left > 0 and data.phase == "fight"
				local second = math.ceil(left)
				if second >= 1 and second <= 5 and second ~= view.lastSecond and data.phase == "fight" then
					view.lastSecond = second
					Fx.countdown(second)
				end
			else
				Bar.time.Text = formatTime(now - startedAt)
				Bar.timeCaption.Text = if data.phase == "over" then "DURÓ" else "EN CURSO"
				Bar.time.TextColor3 = WHITE
				Bar.timerScale.Scale = 1
				Fx.last.Visible = false
				-- un cometa de luz que da vueltas
				local head = math.floor(os.clock() * 14) % #dots + 1
				for i, dot in ipairs(dots) do
					local distance = (head - i) % #dots
					dot.BackgroundTransparency = if distance < 10 then distance / 10 else 0.85
					dot.BackgroundColor3 = WHITE
				end
			end
			-- los combos se apagan solos
			for _, s in ipairs({ Bar.me, Bar.rival }) do
				if s.comboLabel.Visible and os.clock() - s.lastHitAt > 3 then
					s.comboLabel.Visible = false
					s.combo = 0
				end
			end
		end
	end
end)

-- Ondas de radar en la sala de espera
task.spawn(function()
	while true do
		task.wait(1.4)
		if gui.Enabled and Lobby.frame.Visible then
			for _, crest in ipairs(Lobby.crests) do
				local ring = new("Frame", {
					Size = UDim2.fromScale(1, 1),
					Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundTransparency = 1,
					ZIndex = 2,
					Parent = crest.frame,
				}, { corner() })
				local ringStroke = stroke(crest.color, 3, 0.1)
				ringStroke.Parent = ring
				tween(ring, 1.3, { Size = UDim2.fromScale(2.1, 2.1) })
				tween(ringStroke, 1.3, { Transparency = 1 })
				Debris:AddItem(ring, 1.35)
			end
			-- puntos suspensivos que se mueven
			Lobby.dots = ((Lobby.dots or 0) % 3) + 1
			Lobby.sub.Text = "Esperando una batalla en TikTok" .. string.rep(".", Lobby.dots)
		end
	end
end)

-- ===== EVENTOS DE LA BATALLA =====
local function onBattleEvent(event)
	if type(event) ~= "table" then
		return
	end
	local kind = event.kind
	if kind == "intro" then
		Fx.splash(event.me or sideData("me").name or "Yo", event.rival or sideData("rival").name or "Rival")
	elseif kind == "special" then
		local attack = BATTLE.ATTACKS[event.level] or {}
		local color = LEVEL_COLORS[event.level] or WHITE
		Guide.flash("special", true)
		Attacks.flash(event.level, event.user)
		Cards.push({
			side = event.side,
			color = color,
			image = event.image,
			emoji = attack.emoji,
			title = tostring(attack.emoji or "") .. " " .. tostring(event.attack or attack.name or ""),
			subtitle = tostring(event.user) .. " envió " .. tostring(event.gift) .. (if (tonumber(event.count) or 1) > 1 then (" x" .. event.count) else ""),
			big = true,
		})
		if event.level == 4 or event.level == 5 or event.level == "rain" then
			Fx.callout(tostring(attack.emoji or "") .. " " .. tostring(event.attack or ""), color, event.side)
		end
		Bar.sparks(color, 14)
	elseif kind == "gift" then
		Guide.flash("gift")
		Cards.push({
			side = event.side,
			color = GOLD,
			image = event.image,
			emoji = "🎁",
			title = tostring(event.user),
			subtitle = "envió " .. tostring(event.gift) .. " · +" .. Shared.formatNumber(tonumber(event.coins) or 0) .. " 💎",
		})
	elseif kind == "power" then
		Guide.flash("power", true)
		local team = if event.side == "rival" then "villain" else "hero"
		Fx.callout("🔥 " .. string.upper(tostring(event.name)) .. " · PODER " .. tostring(event.level), TEAMS[team].color, event.side)
		local s = if event.side == "rival" then Bar.rival else Bar.me
		pop(s.crestScale, 1.35, 0.5)
	elseif kind == "likes" then
		Guide.flash("likes")
		Crowd.hearts(tonumber(event.count) or 1)
	elseif kind == "crowd" then
		Guide.flash("likes", true)
		Crowd.burst()
		Attacks.flash("crowd", "el público")
		Fx.callout("❤️ ¡GOLPE DEL PÚBLICO!", PINK, "me")
		Cards.push({ side = "me", color = PINK, emoji = "❤️", title = "¡GOLPE DEL PÚBLICO!", subtitle = "Los likes le dan un combo a " .. tostring(event.name or sideData("me").name), big = true })
	elseif kind == "follow" then
		Guide.flash("follow", true)
		Cards.push({
			side = "me",
			color = GREEN,
			emoji = "➕",
			title = tostring(event.user) .. " te sigue",
			subtitle = "Cura +" .. math.floor((tonumber(event.heal) or 0) + 0.5) .. " ❤ a " .. tostring(sideData("me").name or "tu campeón"),
		})
	end
end

hudEvent.OnClientEvent:Connect(function(kind, payload)
	if kind == "battle" then
		render(payload)
	elseif kind == "battleEvent" then
		local ok, err = pcall(onBattleEvent, payload)
		if not ok then
			warn("⚠️ BattleHUD: " .. tostring(err))
		end
	elseif kind == "snapshot" and type(payload) == "table" and payload.battle then
		render(payload.battle)
	end
end)

settingsFolder.AttributeChanged:Connect(function(key)
	if string.sub(key, 1, 3) == "Hud" then
		applyLayout()
	elseif key == "GameMode" then
		refreshVisibility()
	elseif key == "BattleLikeGoal" then
		Attacks.build()
	end
end)
stateFolder:GetAttributeChangedSignal("CinematicActive"):Connect(refreshVisibility)
stateFolder:GetAttributeChangedSignal("BattleFinisher"):Connect(refreshVisibility)
playerGui.ChildAdded:Connect(function(child)
	if child.Name == "ArenaHudEditor" then
		task.defer(refreshVisibility)
	end
end)

local function watchCamera()
	camera = Workspace.CurrentCamera
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
end
watchCamera()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	watchCamera()
	applyLayout()
end)

applyLayout()
render(data)
devCommand:FireServer("hello") -- (pide el estado actual: llega en el "snapshot")
