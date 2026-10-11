-- EntranceCinematics (LocalScript en StarterPlayerScripts)
-- Entradas de cine cuando un peleador ÉLITE o DEFINITIVO entra al ring.
--   ⚡ ÉLITE: sale de una nube de humo, avanza amenazante lanzando golpes
--      (jab, directo, gancho, uppercut), se agacha, salta dejando una estela de
--      humo y cae con una onda de choque; termina posando con los bíceps.
--   👑 DEFINITIVO: aparece FUERA del ring con un rayo que cae del cielo, carga
--      poder, da un salto gigante con mortal hacia el ring y cae en aterrizaje
--      de superhéroe (rodilla y puño al piso, el piso se agrieta); se queda
--      agachado, se levanta despacio y ruge.
-- Mientras dura, el juego está en pausa (el servidor no deja pelear ni entrar
-- a nadie y FighterAnimator congela a los demás). Aquí se mueve al peleador
-- (su raíz está anclada en el servidor, así que la movemos solo en este cliente,
-- a 60 FPS) y se disparan sus poses (LocalAnim) y efectos (LocalVfx) con el mismo
-- reloj. La cámara la maneja ArenaCamera con el mismo aviso.
-- El servidor manda FxEvent("cinematic", { kind, target, team, name, from, mid, to,
-- facing, rootHeight, duration }). Los tiempos deben coincidir con ArenaManager
-- (sonidos) y ArenaCamera (planos).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local fxEvent = arena:WaitForChild("Remotes"):WaitForChild("FxEvent")
local localAnim = arena:WaitForChild("LocalAnim", 30)
local localVfx = arena:WaitForChild("LocalVfx", 30)

local UP = Vector3.yAxis

local function anim(npc, move, data)
	if localAnim then
		localAnim:Fire(npc, move, data or {})
	end
end

local function vfx(name, ...)
	if localVfx then
		localVfx:Fire(name, ...)
	end
end

local function tween(inst, seconds, goal, style, direction)
	local t = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

-- ===== FRANJAS DE CINE Y CARTEL =====
local gui = Instance.new("ScreenGui")
gui.Name = "ArenaCinematic"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 45 -- encima del HUD, debajo de los paneles dev
gui.Parent = playerGui

local function bar(anchorY)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0, anchorY)
	frame.Position = UDim2.fromScale(0, anchorY)
	frame.Size = UDim2.fromScale(1, 0)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BorderSizePixel = 0
	frame.Parent = gui
	return frame
end
local topBar = bar(0)
local bottomBar = bar(1)

local banner = Instance.new("Frame")
banner.AnchorPoint = Vector2.new(0.5, 1)
banner.Position = UDim2.new(0.5, 0, 0.88, -6)
banner.Size = UDim2.fromScale(0.84, 0.15)
banner.BackgroundTransparency = 1
banner.Parent = gui
local bannerScale = Instance.new("UIScale")
bannerScale.Parent = banner

local function bannerLabel(y, height)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0, y)
	label.Size = UDim2.fromScale(1, height)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.25
	label.TextTransparency = 1
	label.Text = ""
	label.Parent = banner
	return label
end
local tierLabel = bannerLabel(0, 0.36)
local nameLabel = bannerLabel(0.38, 0.62)

local correction = Instance.new("ColorCorrectionEffect")
correction.Name = "ArenaCinematicLook"
correction.Parent = Lighting

local function showTier(text, color)
	tierLabel.Text = text
	tierLabel.TextColor3 = color
	tierLabel.TextTransparency = 1
	tween(tierLabel, 0.35, { TextTransparency = 0, TextStrokeTransparency = 0.25 })
end

local function showName(name, color)
	nameLabel.Text = string.upper(tostring(name))
	nameLabel.TextColor3 = color
	nameLabel.TextTransparency = 0
	nameLabel.TextStrokeTransparency = 0.25
	bannerScale.Scale = 0.4
	tween(bannerScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function hideBanner()
	tween(tierLabel, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 })
	tween(nameLabel, 0.35, { TextTransparency = 1, TextStrokeTransparency = 1 })
end

local hudWasEnabled = nil
local function setCinemaLook(on)
	tween(topBar, 0.5, { Size = UDim2.fromScale(1, if on then 0.1 else 0) })
	tween(bottomBar, 0.5, { Size = UDim2.fromScale(1, if on then 0.1 else 0) })
	tween(correction, 0.6, { Saturation = if on then -0.2 else 0, Contrast = if on then 0.12 else 0 })
	-- el HUD se esconde: toda la atención en la entrada
	local hud = playerGui:FindFirstChild("ArenaHUD")
	if hud then
		if on then
			hudWasEnabled = hud.Enabled
			hud.Enabled = false
		elseif hudWasEnabled ~= nil then
			hud.Enabled = hudWasEnabled
			hudWasEnabled = nil
		end
	end
end

-- Esconde o muestra al peleador solo en este cliente
local function setHidden(npc, amount)
	for _, item in ipairs(npc:GetDescendants()) do
		if item:IsA("BasePart") or item:IsA("Decal") then
			item.LocalTransparencyModifier = amount
		end
	end
end

local function fadeIn(npc, seconds)
	local started = os.clock()
	task.spawn(function()
		while npc.Parent do
			local u = math.clamp((os.clock() - started) / seconds, 0, 1)
			setHidden(npc, 1 - u)
			if u >= 1 then
				break
			end
			task.wait()
		end
	end)
end

-- ===== RECORRIDOS (posición del piso bajo el peleador en el segundo t) =====
local function arc(a, b, u, extraHeight)
	local position = a:Lerp(b, u)
	return position + Vector3.new(0, 4 * extraHeight * u * (1 - u), 0)
end

local PATHS = {}

PATHS.elite = function(d, t)
	if t < 0.5 then
		return d.from
	elseif t < 2.6 then
		return d.from:Lerp(d.mid, (t - 0.5) / 2.1)
	elseif t < 2.85 then
		return d.mid
	elseif t < 3.45 then
		return arc(d.mid, d.to, (t - 2.85) / 0.6, 7)
	end
	return d.to
end

PATHS.definitive = function(d, t)
	if t < 1.9 then
		return d.from
	elseif t < 3.7 then
		local apex = math.max(d.from.Y, d.to.Y) + 26
		return arc(d.from, d.to, (t - 1.9) / 1.8, apex - (d.from.Y + d.to.Y) / 2)
	end
	return d.to
end

-- ===== COREOGRAFÍAS (qué pasa en cada segundo) =====
local function eliteEvents(d, npc, root, color, dark)
	local events = {}
	local function at(t, fn)
		table.insert(events, { t = t, fn = fn })
	end
	local function feet()
		return root.Position - UP * (d.rootHeight - 0.3)
	end

	at(0, function()
		setHidden(npc, 1)
	end)
	at(0.15, function()
		vfx("smokeBurst", d.from + UP * 2.5, dark, 1.3)
	end)
	at(0.3, function()
		showTier("⚡ ENTRADA ÉLITE ⚡", color)
	end)
	at(0.35, function()
		fadeIn(npc, 0.45)
	end)
	at(0.5, function()
		anim(npc, "cineStalk", { duration = 2.1 })
	end)
	for _, punch in ipairs({ { 0.75, "jab" }, { 1.2, "cross" }, { 1.7, "hook" }, { 2.15, "uppercut" } }) do
		at(punch[1], function()
			anim(npc, punch[2], { speed = 1.1 })
		end)
		local impact = (Shared.MOVES[punch[2]].impact or 0.2) / 1.1
		at(punch[1] + impact, function()
			vfx("airPunch", root.Position + d.facing * 5.5 + UP * 1.8, d.facing, color)
		end)
	end
	for t = 0.62, 2.5, 0.42 do
		at(t, function()
			vfx("smokePuff", feet(), dark, 1)
		end)
	end
	at(2.6, function()
		anim(npc, "cineCrouch", { duration = 0.25 })
		vfx("dust", d.mid, 8)
	end)
	at(2.85, function()
		anim(npc, "cineLeap", { duration = 0.6 })
		vfx("groundRing", d.mid + UP * 0.2, color, 10, 0.4)
	end)
	for t = 2.9, 3.4, 0.06 do
		at(t, function()
			vfx("smokePuff", root.Position, dark, 0.8)
		end)
	end
	at(3.45, function()
		anim(npc, "cineLand", { duration = 0.5 })
		vfx("landingBlast", d.to, color, 1)
	end)
	at(3.5, function()
		showName(d.name, color)
	end)
	at(3.95, function()
		anim(npc, "victory", { duration = 1.9, variant = 2 })
	end)
	at(5.6, hideBanner)
	return events
end

local function definitiveEvents(d, npc, root, color)
	local events = {}
	local function at(t, fn)
		table.insert(events, { t = t, fn = fn })
	end

	at(0, function()
		setHidden(npc, 1)
	end)
	at(0.12, function()
		vfx("lightningStrike", d.from, color)
		setHidden(npc, 0)
	end)
	at(0.2, function()
		vfx("groundCrack", d.from, color, 8)
	end)
	at(0.25, function()
		showTier("👑 ENTRADA DEFINITIVA 👑", color)
	end)
	at(0.3, function()
		anim(npc, "powerUp", { duration = 1.3 })
	end)
	at(0.5, function()
		vfx("teamBurst", root.Position, d.team, 1.2)
	end)
	for _, t in ipairs({ 0.45, 0.85, 1.25 }) do
		at(t, function()
			vfx("healBurst", root.Position, color, 14)
		end)
	end
	at(1.6, function()
		anim(npc, "cineCrouch", { duration = 0.3, deep = true })
	end)
	at(1.9, function()
		anim(npc, "cineLeap", { duration = 1.8, flip = true, super = true })
		vfx("dust", d.from, 14)
		vfx("groundRing", d.from + UP * 0.2, color, 16, 0.5)
	end)
	for t = 1.95, 3.65, 0.07 do
		at(t, function()
			vfx("smokePuff", root.Position, color, 0.9, true)
		end)
	end
	at(3.7, function()
		anim(npc, "superLand", { hold = 1.6, rise = 1, duration = 2.7 })
		vfx("landingBlast", d.to, color, 1.8)
		vfx("groundCrack", d.to, color, 13)
	end)
	at(4, function()
		showName(d.name, color)
	end)
	at(5.3, function()
		vfx("dust", d.to, 6)
	end)
	at(6.3, function()
		anim(npc, "cineRoar", { duration = 1.45 })
		vfx("teamBurst", root.Position + UP * 1.5, d.team, 1.6)
		vfx("shockSprite", root.Position + UP * 2, color, 22, 0.5)
	end)
	at(7.4, hideBanner)
	return events
end

-- ===== REPRODUCIR =====
local playing = false

local function play(data)
	local npc = data.target
	if typeof(npc) ~= "Instance" or playing then
		return
	end
	local root = npc:WaitForChild("HumanoidRootPart", 3)
	local path = PATHS[data.kind]
	if not root or not path or typeof(data.from) ~= "Vector3" or typeof(data.to) ~= "Vector3" then
		return
	end
	playing = true
	data.mid = if typeof(data.mid) == "Vector3" then data.mid else data.from
	local facing = if typeof(data.facing) == "Vector3" then Vector3.new(data.facing.X, 0, data.facing.Z) else Vector3.new(0, 0, -1)
	data.facing = if facing.Magnitude > 0.01 then facing.Unit else Vector3.new(0, 0, -1)
	data.rootHeight = tonumber(data.rootHeight) or 4.5
	local duration = tonumber(data.duration) or 6
	local color = Shared.teamColor(data.team)
	local dark = color:Lerp(Color3.fromRGB(20, 20, 25), 0.6)

	local events = if data.kind == "elite"
		then eliteEvents(data, npc, root, color, dark)
		else definitiveEvents(data, npc, root, color)
	table.sort(events, function(a, b)
		return a.t < b.t
	end)

	setCinemaLook(true)
	local started = os.clock()
	local nextEvent = 1
	local lift = UP * data.rootHeight
	RunService:BindToRenderStep("ArenaCinematic", Enum.RenderPriority.Camera.Value - 10, function()
		local t = os.clock() - started
		if root.Parent then
			local position = path(data, math.min(t, duration)) + lift
			root.CFrame = CFrame.lookAt(position, position + data.facing)
		end
		while nextEvent <= #events and events[nextEvent].t <= t do
			local fn = events[nextEvent].fn
			nextEvent += 1
			local ok, err = pcall(fn)
			if not ok then
				warn("⚠️ EntranceCinematics: " .. tostring(err))
			end
		end
	end)

	task.wait(duration)
	RunService:UnbindFromRenderStep("ArenaCinematic")
	if npc.Parent then
		setHidden(npc, 0)
	end
	hideBanner()
	setCinemaLook(false)
	playing = false
end

-- ===== ATAQUE FINAL DE LA BATALLA DE TIKTOK =====
-- FxEvent("finisher", { winner, loser, team, winnerName, loserName, from, to,
-- loserAt, facing, rootHeight, duration, impact }). Aquí van las franjas, el
-- cartel y el lanzamiento del ganador (su raíz está anclada en el servidor y la
-- movemos en este cliente a 60 FPS, como en las entradas). Animaciones, efectos
-- y sonidos los pone el servidor (ArenaManager → Battle.runFinish); la cámara,
-- ArenaCamera. Los tiempos deben coincidir con Battle.FINISHER_*.
local function playFinisher(data)
	local npc = data.winner
	if typeof(npc) ~= "Instance" or playing then
		return
	end
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root or typeof(data.from) ~= "Vector3" or typeof(data.to) ~= "Vector3" then
		return
	end
	playing = true
	local facing = if typeof(data.facing) == "Vector3" then Vector3.new(data.facing.X, 0, data.facing.Z) else Vector3.new(0, 0, -1)
	facing = if facing.Magnitude > 0.01 then facing.Unit else Vector3.new(0, 0, -1)
	local lift = UP * (tonumber(data.rootHeight) or 4.5)
	local duration = tonumber(data.duration) or 7
	local impact = tonumber(data.impact) or 2.45
	local dashStart = impact - 0.5
	local color = Shared.teamColor(data.team)
	setCinemaLook(true)
	task.delay(0.25, function()
		showTier("💥 ATAQUE FINAL 💥", color)
	end)
	task.delay(impact + 0.1, function()
		showName(tostring(data.winnerName or "") .. " GANA", color)
	end)
	task.delay(duration - 0.7, hideBanner)
	local started = os.clock()
	RunService:BindToRenderStep("ArenaFinisher", Enum.RenderPriority.Camera.Value - 10, function()
		if not root.Parent then
			return
		end
		local t = os.clock() - started
		local position = data.from
		if t >= impact then
			position = data.to
		elseif t >= dashStart then
			-- se lanza acelerando, con un pequeño salto
			local u = (t - dashStart) / (impact - dashStart)
			position = data.from:Lerp(data.to, u * u) + UP * math.sin(u * math.pi) * 1.2
		end
		root.CFrame = CFrame.lookAt(position + lift, position + lift + facing)
	end)
	task.wait(duration)
	RunService:UnbindFromRenderStep("ArenaFinisher")
	setCinemaLook(false)
	playing = false
end

fxEvent.OnClientEvent:Connect(function(kind, data)
	if kind == "finisher" and type(data) == "table" then
		task.spawn(function()
			local ok, err = pcall(playFinisher, data)
			if not ok then
				warn("⚠️ Ataque final: " .. tostring(err))
				pcall(function()
					RunService:UnbindFromRenderStep("ArenaFinisher")
				end)
				hideBanner()
				setCinemaLook(false)
				playing = false
			end
		end)
	end
end)

fxEvent.OnClientEvent:Connect(function(kind, data)
	if kind == "cinematic" and type(data) == "table" then
		task.spawn(function()
			local ok, err = pcall(play, data)
			if not ok then
				warn("⚠️ EntranceCinematics: " .. tostring(err))
				pcall(function()
					RunService:UnbindFromRenderStep("ArenaCinematic")
				end)
				setCinemaLook(false)
				playing = false
			end
		end)
	end
end)
