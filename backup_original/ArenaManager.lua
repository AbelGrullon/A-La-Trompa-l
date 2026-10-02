-- ArenaManager (Script dentro de ServerScriptService)

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local donationNoticeEvent = ReplicatedStorage:WaitForChild("DonationNotice")
local queueUpdateEvent = ReplicatedStorage:WaitForChild("QueueUpdate")
local victoryPunchEvent = ReplicatedStorage:WaitForChild("VictoryPunch")
local messageUpdateEvent = ReplicatedStorage:WaitForChild("MessageUpdate")
local teamScoreEvent = ReplicatedStorage:WaitForChild("TeamScoreUpdate")

local ring = Workspace:WaitForChild("Ring")
local dummyTemplate = ServerStorage:WaitForChild("NPCDummy")
local particulaAmarillaTemplates = { -- héroes: LVL1 (Profesional) a LVL4 (Definitivo)
	ServerStorage:WaitForChild("ParticulaAmarillaLVL1"),
	ServerStorage:WaitForChild("ParticulaAmarillaLVL2"),
	ServerStorage:WaitForChild("ParticulaAmarillaLVL3"),
	ServerStorage:WaitForChild("ParticulaAmarillaLVL4"),
}
local particulaMoradaTemplates = { -- villanos: LVL1 (Profesional) a LVL4 (Definitivo)
	ServerStorage:WaitForChild("ParticulaMoradaLVL1"),
	ServerStorage:WaitForChild("ParticulaMoradaLVL2"),
	ServerStorage:WaitForChild("ParticulaMoradaLVL3"),
	ServerStorage:WaitForChild("ParticulaMoradaLVL4"),
}
local spectatorsFolder = Workspace:WaitForChild("Espectadores")
local spectatorBlocks = spectatorsFolder:GetChildren() -- tus 18 Parts "Espectador"
local MAX_SPECTATORS = #spectatorBlocks
local SPECTATOR_ANIM_ID = "rbxassetid://99263851255941"

local activeFighters = Instance.new("Folder")
activeFighters.Name = "ActiveFighters"
activeFighters.Parent = Workspace

-- Los 4 pares de puntos de spawn (8 en total) que ya creaste en el Ring.
local SPAWN_PAIRS = {
	{ a = ring:WaitForChild("SpawnA1"), b = ring:WaitForChild("SpawnB1") },
	{ a = ring:WaitForChild("SpawnA2"), b = ring:WaitForChild("SpawnB2") },
	{ a = ring:WaitForChild("SpawnA3"), b = ring:WaitForChild("SpawnB3") },
	{ a = ring:WaitForChild("SpawnA4"), b = ring:WaitForChild("SpawnB4") },
}

-- Los mismos 8 puntos, pero como lista plana: ya no representan "parejas fijas",
-- solo son lugares donde puede aparecer un peleador nuevo.
local SPAWN_POINTS = {}
for _, pair in ipairs(SPAWN_PAIRS) do
	table.insert(SPAWN_POINTS, pair.a)
	table.insert(SPAWN_POINTS, pair.b)
end

local MAX_ACTIVE_FIGHTERS = 8

-- Cuentas de Roblox de respaldo: si alguien manda un regalo válido pero
-- NUNCA escribió un username de Roblox antes, se elige una de estas al azar
-- para el avatar (mostrando igual su nombre real de TikTok en el juego).
local FALLBACK_AVATAR_POOL = {
	"Eltoyverificado", "Elmmmssi8", "alexpigyyYT", "pinoquinhow828", "gbfieell57",
	"sub_zero02011", "edgarc595", "matesu513", "eu_joseph004", "pipoieto2444",
	"Dark_r170", "davizinho777733", "pietroooo348", "Bernardox_x244", "kkss_42",
	"yuriyuri897", "davilu_1241", "Gojovegita", "kauanagro",
}

-- ===== CONFIGURACIÓN DEL COMBATE =====
local CONFIG = {
	FIGHT_RANGE = 11, -- ajustado para el tamaño de personaje al 175% (antes: 6)
	MIN_FIGHT_DISTANCE = 7, -- ajustado para el tamaño de personaje al 175% (antes: 4)
	ATTACK_COOLDOWN_MIN = 1.2,
	ATTACK_COOLDOWN_MAX = 2.0,
	PUNCH_IMPACT_DELAY = 0.3,
	DAMAGE_PER_HIT = 8,
	HEALTH_MAX = 100,
	REGEN_ON_WIN = 75, -- al ganar, se cura HASTA +75 puntos de vida (no al máximo total)
	-- Lluvia de guantes (regalos "Sombrero y bigote" / "Cisne de papel")
	GLOVE_RAIN_COUNT = 45,
	GLOVE_RAIN_HEIGHT = 60,
	GLOVE_RAIN_SPAWN_RADIUS = 16,
	GLOVE_RAIN_STAGGER_MAX = 4.5, -- los 45 no caen todos a la vez, se reparten en esta ventana
	GLOVE_RAIN_EXPLOSION_RADIUS = 12,
	GLOVE_RAIN_DAMAGE = 40,
	GLOVE_RAIN_LIFETIME = 8, -- por si algún guante nunca toca nada (se pierde, queda trabado, etc.)
	FALL_MARGIN = 5,
	WALK_ANIM_ID = "rbxassetid://913402848",
	IDLE_ANIM_ID = "rbxassetid://107589616310404",
	PUNCH_ANIM_IDS = {
		"rbxassetid://104387521934805",
		"rbxassetid://84238644583375",
		"rbxassetid://106628468470867",
	},
	BLOCK_ANIM_ID = "rbxassetid://103278281479227",
	BLOCK_CHANCE = 0.25,
	BOOM_IMAGE_ID = "rbxassetid://110449530369400",
	BLOCKED_IMAGE_ID = "rbxassetid://90642108973827",
	POPUP_DURATION = 0.6,
	STUN_ICON_ID = "rbxassetid://90676545548082",
	STUN_DURATION = 2,
	STUN_CHECK_MIN_INTERVAL = 3,
	STUN_CHECK_MAX_INTERVAL = 6,
	STUN_CHANCE = 0.35,
	DEATH_FADE_DURATION = 0.4,
	WIN_CELEBRATION_DURATION = 2,
	PREFIGHT_COUNTDOWN_SECONDS = 3,
	BRIDGE_URL = "http://localhost:3000",
	BRIDGE_ACCESS_TOKEN = "Elmejorenesto07",
	BRIDGE_POLL_INTERVAL = 3,
	BACKGROUND_MUSIC_ID = "rbxassetid://93616367708595",
	BACKGROUND_MUSIC_VOLUME = 0.5,
	BELL_SOUND_ID = "rbxassetid://77267160233967",
	HIT_SOUND_IDS = {
		"rbxassetid://107880347380356",
		"rbxassetid://105646646799559",
		"rbxassetid://110161496671275",
		"rbxassetid://125432357024120",
		"rbxassetid://131678220004053",
		"rbxassetid://106274302977627",
	},
	STUN_SOUND_ID = "rbxassetid://135182670866586",
}

local COUNTDOWN_COLORS = {
	Color3.fromRGB(255, 60, 60),
	Color3.fromRGB(255, 170, 40),
	Color3.fromRGB(255, 230, 40),
	Color3.fromRGB(80, 220, 255),
}

-- ===== COLA DE ESPERA (usernames de Roblox escritos en el chat de TikTok) =====
-- Lista simple de texto en el orden en que llegaron. La VALIDACIÓN real (¿existe esa
-- cuenta de Roblox?) ocurre más abajo, justo antes de spawnear a alguien — así un
-- mensaje de chat cualquiera que por casualidad tenga forma de username nunca llega
-- a ocupar un lugar real en la arena si la cuenta no existe de verdad.
local waitingQueue = {}

-- Espectadores: candidatos YA validados (cuentas reales de Roblox), parados en uno
-- de los 18 bloques mientras esperan su turno de entrar al ring. Es una cola FIFO
-- igual que waitingQueue, pero cada entrada además trae el NPC visible y su bloque.
local spectatorQueue = {}

local function popNextCandidate()
	return table.remove(waitingQueue, 1)
end

local function broadcastQueuePreview()
	local preview = {}
	for i = 1, math.min(5, #spectatorQueue) do
		local entry = spectatorQueue[i]
		table.insert(preview, { username = entry.username, team = entry.team })
	end
	queueUpdateEvent:FireAllClients(preview)
end

-- Saca candidatos de la cola hasta encontrar uno que sea una cuenta REAL de Roblox
-- (o hasta vaciar la cola). Devuelve el username y su HumanoidDescription ya lista
-- para aplicar, o nil si no hay nadie válido esperando en este momento.
-- ¿Ya está peleando en el ring, o ya está esperando como espectador? Evita
-- que la misma persona entre dos veces a la cola mientras su personaje
-- todavía existe.
local function isAlreadyActiveOrWaiting(username)
	if activeFighters:FindFirstChild(username) then
		return true
	end
	for _, entry in ipairs(spectatorQueue) do
		if entry.username == username then
			return true
		end
	end
	return false
end

local function getNextValidFighter()
	while true do
		local entry = popNextCandidate()
		if not entry then
			return nil
		end

		local username = entry.username
		local team = entry.team
		local healthPercent = entry.healthPercent or 0
		local damagePercent = entry.damagePercent or 0
		local speedPercent = entry.speedPercent or 0
		-- avatarUsername: para el caso de "regalo sin username" — la cuenta
		-- de Roblox de respaldo de la que sacamos el avatar, distinta de
		-- "username" (que en ese caso es el nombre real de TikTok, para mostrar).
		local avatarUsername = entry.avatarUsername or username

		if isAlreadyActiveOrWaiting(username) then
			warn("⚠️ '" .. tostring(username) .. "' ya está peleando o esperando, se descarta el duplicado")
		else
			local idSuccess, userId = pcall(function()
				return Players:GetUserIdFromNameAsync(avatarUsername)
			end)

			if idSuccess and userId then
				local descSuccess, description = pcall(function()
					return Players:GetHumanoidDescriptionFromUserId(userId)
				end)
				if descSuccess and description then
					return username, description, team, healthPercent, damagePercent, speedPercent
				end
			end

			warn("⚠️ '" .. tostring(avatarUsername) .. "' no es una cuenta válida de Roblox, descartado")
		end
	end
end

-- ===== ESPECTADORES: candidatos validados, visibles y esperando su turno =====

local occupiedBlocks = {}

local function getFreeBlock()
	local free = {}
	for _, block in ipairs(spectatorBlocks) do
		if not occupiedBlocks[block] then
			table.insert(free, block)
		end
	end
	if #free == 0 then
		return nil
	end
	return free[math.random(1, #free)] -- al azar entre los libres, no siempre el mismo orden
end

-- ===== EQUIPOS: VILLANO (morado, pulso oscuro) y HEROE (dorado, pulso blanco) =====

local TEAM_COLORS = {
	villain = { base = Color3.fromRGB(150, 60, 200), pulse = Color3.fromRGB(35, 10, 45) },
	hero = { base = Color3.fromRGB(255, 215, 0), pulse = Color3.fromRGB(255, 255, 255) },
}
local NAME_PULSE_PERIOD = 1.3 -- segundos por ciclo completo (ida y vuelta)

local function lerpColor3(colorA, colorB, alpha)
	return Color3.new(
		colorA.R + (colorB.R - colorA.R) * alpha,
		colorA.G + (colorB.G - colorA.G) * alpha,
		colorA.B + (colorB.B - colorA.B) * alpha
	)
end

-- Hace que el TextLabel del nombre oscile para siempre entre dos colores, mientras
-- el propio label siga existiendo (se detiene solo cuando lo destruimos junto al NPC).
local function startNamePulse(label, colorA, colorB)
	local myToken = (label:GetAttribute("PulseToken") or 0) + 1
	label:SetAttribute("PulseToken", myToken)
	task.spawn(function()
		local t = 0
		while label.Parent and label:GetAttribute("PulseToken") == myToken do
			t = t + 0.05
			local alpha = (math.sin(t * (2 * math.pi / NAME_PULSE_PERIOD)) + 1) / 2
			label.TextColor3 = lerpColor3(colorA, colorB, alpha)
			task.wait(0.05)
		end
	end)
end

local function applyTeamNameStyle(label, team)
	local colors = TEAM_COLORS[team]
	if not colors then
		-- sin equipo: invalida cualquier pulso viejo (por si venía de un equipo
		-- anterior) y deja el color blanco normal
		label:SetAttribute("PulseToken", (label:GetAttribute("PulseToken") or 0) + 1)
		label.TextColor3 = Color3.new(1, 1, 1)
		return
	end
	startNamePulse(label, colors.base, colors.pulse)
end

-- Aura de color alrededor del personaje (no el nombre, el cuerpo): un
-- Highlight nativo de Roblox, con un pulso sutil de transparencia para que
-- se sienta "viva" en vez de un contorno fijo.
local function applyTeamAura(npc, team)
	local colors = TEAM_COLORS[team]
	if not colors then
		return -- sin equipo: sin aura
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "TeamAura"
	highlight.FillColor = colors.base
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = colors.base
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = npc

	task.spawn(function()
		local t = 0
		while highlight.Parent do
			t = t + 0.05
			local pulse = (math.sin(t * (2 * math.pi / 1.5)) + 1) / 2
			highlight.FillTransparency = 0.55 + pulse * 0.3
			task.wait(0.05)
		end
	end)
end

-- Partículas en cada mano para peleadores con mucho daño acumulado (nivel
-- "Peleador Profesional" o mayor): amarillas para héroes, moradas para
-- villanos. Clona la plantilla (Part + Attachment + ParticleEmitter que ya
-- armaste en ServerStorage) y la suelda a cada mano con WeldConstraint.
-- Nivel de partícula de mano según el % de daño acumulado: 0 = ninguna,
-- 1 = Profesional, 2 = Elite, 3 = Legendario, 4 = Definitivo.
local HAND_PARTICLE_LEVEL_THRESHOLDS = { 0.25, 0.35, 0.45, 0.55 }

local function getHandParticleLevel(damageMultiplier)
	local percent = (damageMultiplier or 1) - 1
	local level = 0
	for i, threshold in ipairs(HAND_PARTICLE_LEVEL_THRESHOLDS) do
		if percent >= threshold - 0.001 then -- pequeño margen por errores de coma flotante
			level = i
		end
	end
	return level
end

local HAND_PARTICLE_NAMES = {
	"ParticulaAmarillaLVL1", "ParticulaAmarillaLVL2", "ParticulaAmarillaLVL3", "ParticulaAmarillaLVL4",
	"ParticulaMoradaLVL1", "ParticulaMoradaLVL2", "ParticulaMoradaLVL3", "ParticulaMoradaLVL4",
}

local function clearHandParticles(npc)
	for _, child in ipairs(npc:GetChildren()) do
		for _, particleName in ipairs(HAND_PARTICLE_NAMES) do
			if child.Name == particleName then
				child:Destroy()
				break
			end
		end
	end
end

local function attachHandParticles(npc, team, damageMultiplier)
	local level = getHandParticleLevel(damageMultiplier)
	if level == (npc:GetAttribute("HandParticleLevel") or 0) then
		return -- ya tiene puesto el nivel correcto, no repetir
	end
	npc:SetAttribute("HandParticleLevel", level)

	clearHandParticles(npc)
	if level == 0 then
		return
	end

	local template
	if team == "hero" then
		template = particulaAmarillaTemplates[level]
	elseif team == "villain" then
		template = particulaMoradaTemplates[level]
	end
	if not template then
		return
	end

	local leftHand = npc:FindFirstChild("LeftHand")
	local rightHand = npc:FindFirstChild("RightHand")

	for _, hand in ipairs({ leftHand, rightHand }) do
		if hand then
			local particlePart = template:Clone()
			particlePart.Anchored = false
			particlePart.CanCollide = false
			particlePart.Massless = true
			particlePart.Transparency = 1 -- solo se ve el efecto de partículas, no la caja
			particlePart.CFrame = hand.CFrame
			particlePart.Parent = npc

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = particlePart
			weld.Parent = particlePart
		end
	end
end

-- Los jugadores se ven un 75% más grandes que su tamaño real de Roblox.
-- Aplicamos el multiplicador DESPUÉS de ApplyDescription, sobre las escalas
-- reales de ese avatar — así cada uno mantiene sus propias proporciones
-- (alguien con cabeza grande sigue teniendo cabeza grande, solo que todo
-- junto queda más grande), en vez de forzar un tamaño idéntico para todos.
local SIZE_MULTIPLIER = 1.75

local function applySizeBoost(humanoid)
	-- En R15, estas escalas NO son propiedades numéricas directas del
	-- Humanoid: son objetos NumberValue hijos suyos. Hay que leer/escribir
	-- su .Value, no la Instance en sí.
	local scaleNames = { "HeadScale", "BodyDepthScale", "BodyHeightScale", "BodyWidthScale" }
	for _, scaleName in ipairs(scaleNames) do
		local scaleValue = humanoid:FindFirstChild(scaleName)
		if scaleValue then
			scaleValue.Value = scaleValue.Value * SIZE_MULTIPLIER
		end
	end
end

local function spawnSpectator(username, description, block, team, maxHealth)
	maxHealth = maxHealth or CONFIG.HEALTH_MAX

	local npc = dummyTemplate:Clone()
	npc.Name = username
	npc:PivotTo(block.CFrame + Vector3.new(0, 3, 0))
	npc.Parent = spectatorsFolder

	local humanoid = npc:WaitForChild("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	local applySuccess = pcall(function()
		humanoid:ApplyDescription(description)
	end)
	if not applySuccess then
		warn("No se pudo aplicar el avatar de " .. username .. " en la fila de espera")
	end
	applySizeBoost(humanoid)

	local head = npc:WaitForChild("Head")
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.new(0, 75, 0, 18)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Text = username
	label.Parent = billboard

	npc:SetAttribute("Team", team or "")
	npc:SetAttribute("MaxHealth", maxHealth)
	npc:SetAttribute("Health", maxHealth) -- en espera, siempre se muestra "a full"
	applyTeamNameStyle(label, team)
	if maxHealth > CONFIG.HEALTH_MAX then
		applyTeamAura(npc, team) -- el aura solo aparece si YA nació boosteado
	end

	local animator = humanoid:WaitForChild("Animator")
	local animation = Instance.new("Animation")
	animation.AnimationId = SPECTATOR_ANIM_ID
	local track = animator:LoadAnimation(animation)
	track.Looped = true
	track:Play()

	return npc
end

-- Va llenando los bloques libres con candidatos ya validados, hasta 18 a la vez
-- (o hasta que ya no haya más candidatos válidos esperando en la cola cruda).
local function fillSpectatorPool()
	while #spectatorQueue < MAX_SPECTATORS do
		local block = getFreeBlock()
		if not block then
			break
		end

		local username, description, team, healthPercent, damagePercent, speedPercent = getNextValidFighter()
		if not username then
			break
		end

		local startingMaxHealth = CONFIG.HEALTH_MAX * (1 + healthPercent)
		local startingDamageMultiplier = 1 + damagePercent
		local startingSpeedMultiplier = 1 + speedPercent

		local npc = spawnSpectator(username, description, block, team, startingMaxHealth)
		occupiedBlocks[block] = true
		table.insert(spectatorQueue, {
			npc = npc,
			username = username,
			description = description,
			block = block,
			team = team,
			maxHealth = startingMaxHealth,
			damageMultiplier = startingDamageMultiplier,
			speedMultiplier = startingSpeedMultiplier,
		})
	end
end

-- Saca al primero de la fila de espectadores (el que lleva más tiempo esperando),
-- borra su versión "de espectador" del bloque, y devuelve sus datos listos para
-- que spawnFighter lo cree de verdad dentro del ring.
local function pullNextRingFighter()
	if #spectatorQueue == 0 then
		return nil
	end

	local entry = table.remove(spectatorQueue, 1)
	occupiedBlocks[entry.block] = nil
	if entry.npc and entry.npc.Parent then
		entry.npc:Destroy()
	end

	return entry.username, entry.description, entry.team, entry.maxHealth, entry.damageMultiplier, entry.speedMultiplier
end

-- ===== EFECTOS DE ENTRADA Y MUERTE =====

-- Destello de luz breve en el pecho del NPC, que aparece brillante y se apaga solo.
-- Se reutiliza para los dos efectos, solo cambia el color/intensidad.
local function flashLight(npc, color, brightness, duration)
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = 14
	light.Parent = root

	TweenService:Create(
		light,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Brightness = 0 }
	):Play()

	task.delay(duration, function()
		light:Destroy()
	end)
end

-- ===== EXPLOSIONES DE EQUIPO (entrada y muerte) =====
-- Héroe: siempre acompañado de una explosión de luz. Villano: siempre de
-- humo morado. Se usan tanto al aparecer como al caer — mismo lenguaje
-- visual en los dos momentos, para que la identidad de equipo se sienta
-- consistente de principio a fin.

local function spawnPointLightBurst(anchorPart, color, brightness, duration)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = 16
	light.Parent = anchorPart

	TweenService:Create(
		light,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Brightness = 0 }
	):Play()
end

local function spawnLightExplosion(position)
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	spawnPointLightBurst(anchor, Color3.fromRGB(255, 250, 200), 10, 0.6)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 245, 180))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Speed = NumberRange.new(10, 18)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.LightEmission = 1 -- se ve "encendido", no una partícula opaca
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(28)

	-- Un anillo de energía dorado/blanco que se expande y desaparece
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Anchored = true
	ring.CanCollide = false
	ring.CastShadow = false
	ring.Color = Color3.fromRGB(255, 245, 190)
	ring.Transparency = 0.1
	ring.Size = Vector3.new(0.2, 0.6, 0.6)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace
	TweenService:Create(
		ring,
		TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.2, 11, 11), Transparency = 1 }
	):Play()
	task.delay(0.5, function()
		ring:Destroy()
	end)

	task.delay(1, function()
		anchor:Destroy()
	end)
end

local function spawnPurpleSmokeExplosion(position)
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	spawnPointLightBurst(anchor, Color3.fromRGB(150, 50, 200), 7, 0.5)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(110, 30, 150))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 3.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.9, 1.4)
	emitter.Speed = NumberRange.new(3, 7)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 5, 0) -- sube despacio, como humo de verdad
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(26)

	task.delay(1.6, function()
		anchor:Destroy()
	end)
end

-- El personaje "se materializa": arranca invisible y se desvanece hacia adentro.
-- Si tiene equipo, además dispara su explosión correspondiente (luz o humo);
-- si es neutral, se queda con el destello celeste genérico de siempre.
local function playEntranceEffect(npc)
	for _, part in ipairs(npc:GetDescendants()) do
		if part:IsA("BasePart") then
			local targetTransparency = part.Transparency
			part.Transparency = 1
			TweenService:Create(
				part,
				TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Transparency = targetTransparency }
			):Play()
		end
	end

	local root = npc:FindFirstChild("HumanoidRootPart")
	local position = root and root.Position or npc:GetPivot().Position
	local team = npc:GetAttribute("Team")

	if team == "hero" then
		spawnLightExplosion(position)
	elseif team == "villain" then
		spawnPurpleSmokeExplosion(position)
	else
		flashLight(npc, Color3.fromRGB(150, 220, 255), 6, 0.5)
	end
end

-- ===== SPAWN Y ANIMACIONES =====
local function loadAnimationTrack(npc, animId, looped)
	local humanoid = npc:WaitForChild("Humanoid")
	local animator = humanoid:WaitForChild("Animator")

	local animation = Instance.new("Animation")
	animation.AnimationId = animId

	local track = animator:LoadAnimation(animation)
	track.Looped = looped
	return track
end

-- Guardamos las animaciones ya cargadas de cada peleador (por instancia de NPC), para
-- no tener que volver a cargarlas en cada ronda. Esto importa ahora que un ganador
-- puede quedarse peleando muchas rondas seguidas: sin esto, se irían acumulando
-- AnimationTracks nuevos cada vez, uno encima del otro, sin necesidad.
local fighterTracks = {}

local function loadFighterTracks(npc)
	local tracks = {
		walk = loadAnimationTrack(npc, CONFIG.WALK_ANIM_ID, true),
		idle = loadAnimationTrack(npc, CONFIG.IDLE_ANIM_ID, true),
		block = loadAnimationTrack(npc, CONFIG.BLOCK_ANIM_ID, false),
		punches = {},
	}
	tracks.idle.Priority = Enum.AnimationPriority.Idle
	for _, animId in ipairs(CONFIG.PUNCH_ANIM_IDS) do
		local punchTrack = loadAnimationTrack(npc, animId, false)
		punchTrack.Priority = Enum.AnimationPriority.Action -- para que gane siempre sobre el idle al superponerse
		table.insert(tracks.punches, punchTrack)
	end
	fighterTracks[npc] = tracks
	return tracks
end



local function spawnFighter(spawnPart, username, description, team, maxHealth, damageMultiplier, speedMultiplier)
	maxHealth = maxHealth or CONFIG.HEALTH_MAX
	damageMultiplier = damageMultiplier or 1
	speedMultiplier = speedMultiplier or 1

	local npc = dummyTemplate:Clone()
	npc.Name = username
	npc:PivotTo(spawnPart.CFrame + Vector3.new(0, 3, 0))
	npc.Parent = activeFighters

	local humanoid = npc:WaitForChild("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None -- apaga el nombre automático de Roblox; usamos el nuestro
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false) -- evita que un personaje "trepe" encima del otro al chocar
	local applySuccess = pcall(function()
		humanoid:ApplyDescription(description)
	end)
	if not applySuccess then
		warn("No se pudo aplicar el avatar de " .. username .. ", se deja el dummy por defecto")
	end
	applySizeBoost(humanoid)

	local tracks = loadFighterTracks(npc)
	if speedMultiplier ~= 1 then
		for _, punchTrack in ipairs(tracks.punches) do
			punchTrack:AdjustSpeed(speedMultiplier)
		end
	end

	local head = npc:WaitForChild("Head")
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.new(0, 85, 0, 20)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Text = username
	label.Parent = billboard

	npc:SetAttribute("Health", maxHealth)
	npc:SetAttribute("MaxHealth", maxHealth)
	npc:SetAttribute("DamageMultiplier", damageMultiplier)
	npc:SetAttribute("SpeedMultiplier", speedMultiplier)
	npc:SetAttribute("SpawnY", spawnPart.Position.Y)
	npc:SetAttribute("FallStreak", 0)
	npc:SetAttribute("Team", team or "")
	applyTeamNameStyle(label, team)
	if maxHealth > CONFIG.HEALTH_MAX then
		applyTeamAura(npc, team) -- el aura solo aparece si YA nació boosteado
	end
	attachHandParticles(npc, team, damageMultiplier)

	npc.AncestryChanged:Connect(function(_, parent)
		if not parent then
			print("⚠️ " .. npc.Name .. " fue eliminado de la jerarquía por completo")
		end
	end)

	humanoid.Died:Connect(function()
		print("⚠️ " .. npc.Name .. " murió (Humanoid.Died) con Health: " .. humanoid.Health)
	end)

	playEntranceEffect(npc)
	donationNoticeEvent:FireAllClients(username)

	return npc
end

-- ===== POPUPS DE ESTADO (impacto, bloqueo, aturdido, texto) =====

local function showImpactPopup(npc, imageId, duration, spin)
	duration = duration or CONFIG.POPUP_DURATION

	local head = npc:FindFirstChild("Head")
	if not head then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ImpactPopup"
	billboard.Size = UDim2.new(0, 40, 0, 40)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local image = Instance.new("ImageLabel")
	image.Size = UDim2.new(1, 0, 1, 0)
	image.BackgroundTransparency = 1
	image.Image = imageId
	image.Parent = billboard

	local growTween = TweenService:Create(
		billboard,
		TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, 45, 0, 45) }
	)
	growTween:Play()

	if spin then
		local spinTween = TweenService:Create(
			image,
			TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false),
			{ Rotation = 360 }
		)
		spinTween:Play()
	end

	local fadeTween = TweenService:Create(
		image,
		TweenInfo.new(0.25, Enum.EasingStyle.Linear),
		{ ImageTransparency = 1 }
	)
	task.delay(math.max(duration - 0.25, 0), function()
		fadeTween:Play()
	end)

	task.delay(duration, function()
		billboard:Destroy()
	end)
end

local function showTextPopup(npc, text, color, duration)
	duration = duration or CONFIG.POPUP_DURATION

	local head = npc:FindFirstChild("Head")
	if not head then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TextPopup"
	billboard.Size = UDim2.new(0, 40, 0, 40)
	billboard.StudsOffset = Vector3.new(0, 4.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0
	label.Text = text
	label.Parent = billboard

	local growTween = TweenService:Create(
		billboard,
		TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, 70, 0, 32) }
	)
	growTween:Play()

	local riseTween = TweenService:Create(
		billboard,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{ StudsOffset = Vector3.new(0, 7, 0) }
	)
	riseTween:Play()

	local fadeTween = TweenService:Create(label, TweenInfo.new(0.3, Enum.EasingStyle.Linear), { TextTransparency = 1 })
	task.delay(math.max(duration - 0.3, 0), function()
		fadeTween:Play()
	end)

	task.delay(duration, function()
		billboard:Destroy()
	end)
end

-- ===== COMBATE (igual que antes: sin empujones, con aturdimiento y distancia mínima) =====

local function getStopPosition(fromPosition, towardPosition, keepDistance)
	local offset = towardPosition - fromPosition
	if offset.Magnitude <= keepDistance then
		return fromPosition
	end
	return towardPosition - offset.Unit * keepDistance
end

local function faceTarget(root, targetPosition)
	local lookAt = Vector3.new(targetPosition.X, root.Position.Y, targetPosition.Z)
	root.CFrame = CFrame.new(root.Position, lookAt)
end

local function playRandomSound(soundIds)
	if #soundIds == 0 then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = soundIds[math.random(1, #soundIds)]
	sound.Parent = SoundService
	sound:Play()

	local function cleanup()
		sound:Destroy()
	end

	sound.Ended:Connect(cleanup)
	task.delay(5, cleanup)
end

-- ===== EFECTOS DE IMPACTO (onda de choque / viento / chispas) =====
-- Tres tipos distintos, elegidos al azar en cada golpe para que nunca se
-- sienta repetitivo. Todos son geometría pura (Parts/ParticleEmitter), sin
-- necesitar ninguna imagen o textura externa.

local function spawnShockwaveRing(position, overrideColor)
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Anchored = true
	ring.CanCollide = false
	ring.CastShadow = false
	ring.Color = overrideColor or Color3.fromHSV(math.random(), 0.85, 1) -- color de equipo, o al azar si es neutral
	ring.Transparency = 0.15
	ring.Size = Vector3.new(0.2, 0.6, 0.6)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = Workspace

	TweenService:Create(
		ring,
		TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.2, 9, 9), Transparency = 1 }
	):Play()

	task.delay(0.35, function()
		ring:Destroy()
	end)
end

local function spawnWindBurst(position, overrideColor)
	local lineCount = 6
	for i = 1, lineCount do
		local angle = (i / lineCount) * math.pi * 2 + math.random() * 0.3
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))

		local line = Instance.new("Part")
		line.Size = Vector3.new(0.15, 0.15, 2.5)
		line.Material = Enum.Material.Neon
		line.Color = overrideColor or Color3.fromRGB(220, 240, 255) -- color de equipo, o blanco azulado si es neutral
		line.Anchored = true
		line.CanCollide = false
		line.CastShadow = false
		line.Transparency = 0.25
		line.CFrame = CFrame.new(position, position + direction)
		line.Parent = Workspace

		local targetPosition = position + direction * 6
		TweenService:Create(
			line,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.new(targetPosition, targetPosition + direction), Transparency = 1 }
		):Play()

		task.delay(0.3, function()
			line:Destroy()
		end)
	end
end

local function spawnParticleBurst(position, overrideColor)
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(overrideColor or Color3.fromHSV(math.random(), 0.9, 1))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Lifetime = NumberRange.new(0.3, 0.5)
	emitter.Speed = NumberRange.new(8, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0 -- no emite solo; lo disparamos manualmente con :Emit()
	emitter.Parent = anchor

	emitter:Emit(18)

	task.delay(0.6, function()
		anchor:Destroy()
	end)
end

local HIT_EFFECT_TYPES = { "ring", "wind", "particles" }

-- Si quien golpea tiene equipo, el efecto se pinta de su color (dorado para
-- héroe, morado para villano) en vez de un color al azar — así los golpes
-- también cargan identidad de equipo, igual que la entrada y la muerte.
local HIT_TEAM_COLORS = {
	hero = Color3.fromRGB(255, 235, 150),
	villain = Color3.fromRGB(150, 60, 200),
}

local function spawnHitEffect(position, team)
	local overrideColor = HIT_TEAM_COLORS[team]

	local choice = HIT_EFFECT_TYPES[math.random(1, #HIT_EFFECT_TYPES)]
	if choice == "ring" then
		spawnShockwaveRing(position, overrideColor)
	elseif choice == "wind" then
		spawnWindBurst(position, overrideColor)
	else
		spawnParticleBurst(position, overrideColor)
	end
end

local function applyHit(attacker, defender)
	local defenderHumanoid = defender:FindFirstChild("Humanoid")
	if not defenderHumanoid then
		return
	end

	local currentHealth = defender:GetAttribute("Health")
	local damageMultiplier = attacker:GetAttribute("DamageMultiplier") or 1
	local damage = math.floor(CONFIG.DAMAGE_PER_HIT * damageMultiplier + 0.5)
	local newHealth = math.max(0, currentHealth - damage)
	defender:SetAttribute("Health", newHealth)

	showImpactPopup(defender, CONFIG.BOOM_IMAGE_ID)
	playRandomSound(CONFIG.HIT_SOUND_IDS)

	local attackerRoot = attacker:FindFirstChild("HumanoidRootPart")
	local defenderRoot = defender:FindFirstChild("HumanoidRootPart")
	if attackerRoot and defenderRoot then
		-- El punto de impacto queda un poco más cerca del atacante que del
		-- defensor (30% del camino), a la altura del pecho, para que se sienta
		-- como si el golpe conectara ahí en vez de aparecer flotando al azar.
		local impactPosition = defenderRoot.Position:Lerp(attackerRoot.Position, 0.3) + Vector3.new(0, 2.5, 0)
		spawnHitEffect(impactPosition, attacker:GetAttribute("Team"))
	end
end

local function applyStun(key, npc, humanoid, originalWalkSpeed, stunState)
	if stunState[key] then
		return
	end
	stunState[key] = true
	humanoid.WalkSpeed = 0
	showImpactPopup(npc, CONFIG.STUN_ICON_ID, CONFIG.STUN_DURATION, true)
	playRandomSound({ CONFIG.STUN_SOUND_ID })

	task.delay(CONFIG.STUN_DURATION, function()
		stunState[key] = false
		if humanoid and humanoid.Parent then
			humanoid.WalkSpeed = originalWalkSpeed
		end
	end)
end

local FALL_TICKS_REQUIRED = 5

local function hasFallen(npc)
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root then
		return true
	end

	local spawnY = npc:GetAttribute("SpawnY")
	local isBelow = root.Position.Y < (spawnY - CONFIG.FALL_MARGIN)

	if isBelow then
		local streak = npc:GetAttribute("FallStreak") + 1
		npc:SetAttribute("FallStreak", streak)
		return streak >= FALL_TICKS_REQUIRED
	else
		npc:SetAttribute("FallStreak", 0)
		return false
	end
end

local function hasDied(npc)
	return npc:GetAttribute("Health") <= 0
end

local function performAttack(attacker, defender, attackTracks, defenderBlockTrack)
	local randomPunch = attackTracks[math.random(1, #attackTracks)]
	randomPunch:Play()

	task.delay(CONFIG.PUNCH_IMPACT_DELAY, function()
		if not attacker.Parent or not defender.Parent then
			return
		end

		if math.random() < CONFIG.BLOCK_CHANCE then
			defenderBlockTrack:Play()
			showImpactPopup(defender, CONFIG.BLOCKED_IMAGE_ID)
		else
			applyHit(attacker, defender)
		end
	end)
end

local function runCombat(npcA, npcB)
	local tracksA = fighterTracks[npcA]
	local tracksB = fighterTracks[npcB]

	local walkTrackA = tracksA.walk
	local walkTrackB = tracksB.walk
	local idleTrackA = tracksA.idle
	local idleTrackB = tracksB.idle
	local blockTrackA = tracksA.block
	local blockTrackB = tracksB.block
	local attackTracksA = tracksA.punches
	local attackTracksB = tracksB.punches

	local humanoidA = npcA:WaitForChild("Humanoid")
	local humanoidB = npcB:WaitForChild("Humanoid")

	local originalWalkSpeedA = humanoidA.WalkSpeed
	local originalWalkSpeedB = humanoidB.WalkSpeed

	local speedMultiplierA = npcA:GetAttribute("SpeedMultiplier") or 1
	local speedMultiplierB = npcB:GetAttribute("SpeedMultiplier") or 1

	local function rollCooldown(speedMultiplier)
		local base = CONFIG.ATTACK_COOLDOWN_MIN + math.random() * (CONFIG.ATTACK_COOLDOWN_MAX - CONFIG.ATTACK_COOLDOWN_MIN)
		return base / speedMultiplier -- más velocidad = menos espera entre golpes
	end

	local stunState = { A = false, B = false }

	local lastAttackA = os.clock() - math.random() * CONFIG.ATTACK_COOLDOWN_MIN
	local lastAttackB = os.clock() - math.random() * CONFIG.ATTACK_COOLDOWN_MIN
	local nextCooldownA = rollCooldown(speedMultiplierA)
	local nextCooldownB = rollCooldown(speedMultiplierB)

	local lastStunCheckA = os.clock()
	local lastStunCheckB = os.clock()
	local nextStunIntervalA = CONFIG.STUN_CHECK_MIN_INTERVAL + math.random() * (CONFIG.STUN_CHECK_MAX_INTERVAL - CONFIG.STUN_CHECK_MIN_INTERVAL)
	local nextStunIntervalB = CONFIG.STUN_CHECK_MIN_INTERVAL + math.random() * (CONFIG.STUN_CHECK_MAX_INTERVAL - CONFIG.STUN_CHECK_MIN_INTERVAL)

	while true do
		task.wait(0.1)

		if hasDied(npcA) or hasFallen(npcA) then
			return npcB, npcA
		end
		if hasDied(npcB) or hasFallen(npcB) then
			return npcA, npcB
		end

		local rootA = npcA:FindFirstChild("HumanoidRootPart")
		local rootB = npcB:FindFirstChild("HumanoidRootPart")
		if not rootA or not rootB then
			return npcA, npcB
		end

		local distance = (rootA.Position - rootB.Position).Magnitude
		local inFightRange = distance <= CONFIG.FIGHT_RANGE

		if inFightRange then
			faceTarget(rootA, rootB.Position)
			faceTarget(rootB, rootA.Position)
		end

		if stunState.A then
			walkTrackA:Stop()
			idleTrackA:Stop()
		elseif inFightRange then
			humanoidA:MoveTo(rootA.Position)
			walkTrackA:Stop()
			if not idleTrackA.IsPlaying then
				idleTrackA:Play()
			end
		else
			humanoidA:MoveTo(getStopPosition(rootA.Position, rootB.Position, CONFIG.MIN_FIGHT_DISTANCE))
			idleTrackA:Stop()
			if not walkTrackA.IsPlaying then
				walkTrackA:Play()
			end
		end

		if stunState.B then
			walkTrackB:Stop()
			idleTrackB:Stop()
		elseif inFightRange then
			humanoidB:MoveTo(rootB.Position)
			walkTrackB:Stop()
			if not idleTrackB.IsPlaying then
				idleTrackB:Play()
			end
		else
			humanoidB:MoveTo(getStopPosition(rootB.Position, rootA.Position, CONFIG.MIN_FIGHT_DISTANCE))
			idleTrackB:Stop()
			if not walkTrackB.IsPlaying then
				walkTrackB:Play()
			end
		end

		local now = os.clock()

		if inFightRange then
			if not stunState.A and now - lastAttackA >= nextCooldownA then
				performAttack(npcA, npcB, attackTracksA, blockTrackB)
				lastAttackA = now
				nextCooldownA = rollCooldown(speedMultiplierA)
			end
			if not stunState.B and now - lastAttackB >= nextCooldownB then
				performAttack(npcB, npcA, attackTracksB, blockTrackA)
				lastAttackB = now
				nextCooldownB = rollCooldown(speedMultiplierB)
			end
		end

		if not stunState.A and now - lastStunCheckA >= nextStunIntervalA then
			lastStunCheckA = now
			nextStunIntervalA = CONFIG.STUN_CHECK_MIN_INTERVAL + math.random() * (CONFIG.STUN_CHECK_MAX_INTERVAL - CONFIG.STUN_CHECK_MIN_INTERVAL)
			if math.random() < CONFIG.STUN_CHANCE then
				applyStun("A", npcA, humanoidA, originalWalkSpeedA, stunState)
			end
		end
		if not stunState.B and now - lastStunCheckB >= nextStunIntervalB then
			lastStunCheckB = now
			nextStunIntervalB = CONFIG.STUN_CHECK_MIN_INTERVAL + math.random() * (CONFIG.STUN_CHECK_MAX_INTERVAL - CONFIG.STUN_CHECK_MIN_INTERVAL)
			if math.random() < CONFIG.STUN_CHANCE then
				applyStun("B", npcB, humanoidB, originalWalkSpeedB, stunState)
			end
		end
	end
end

-- ===== MUERTE DEL PERDEDOR Y CELEBRACIÓN DEL GANADOR =====

local function playDeathEffect(npc)
	local humanoid = npc:FindFirstChild("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true
	end

	local root = npc:FindFirstChild("HumanoidRootPart")
	local position = root and root.Position or npc:GetPivot().Position
	local team = npc:GetAttribute("Team")

	if team == "hero" then
		spawnLightExplosion(position)
	elseif team == "villain" then
		spawnPurpleSmokeExplosion(position)
	else
		flashLight(npc, Color3.fromRGB(255, 50, 50), 8, 0.35)
	end

	for _, part in ipairs(npc:GetDescendants()) do
		if part:IsA("BasePart") then
			local tween = TweenService:Create(
				part,
				TweenInfo.new(CONFIG.DEATH_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			tween:Play()
		end
	end

	fighterTracks[npc] = nil -- ya no lo necesitamos, se va a destruir

	task.delay(CONFIG.DEATH_FADE_DURATION + 0.05, function()
		if npc and npc.Parent then
			npc:Destroy()
		end
	end)
end

-- Texto "VICTORIA" dorado con pulso y brillo, distinto del popup rápido de golpe/bloqueo:
-- este se queda sobre la cabeza todo el tiempo que dure la celebración, no solo un instante.
local function showVictoryText(npc, duration)
	local head = npc:FindFirstChild("Head")
	if not head then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "VictoryText"
	billboard.Size = UDim2.new(0, 10, 0, 5)
	billboard.StudsOffset = Vector3.new(0, 4.8, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 215, 0)
	label.TextStrokeTransparency = 0
	label.Text = "VICTORIA"
	label.Parent = billboard

	local entrance = TweenService:Create(
		billboard,
		TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.new(0, 90, 0, 32) }
	)
	entrance:Play()

	-- El "pulso": el texto crece y encoge sin parar mientras dure la celebración
	local pulseTween = TweenService:Create(
		billboard,
		TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Size = UDim2.new(0, 98, 0, 35) }
	)
	pulseTween:Play()

	-- El "brillo": el color oscila suavemente entre tonos dorados/ámbar, no un solo dorado fijo
	local glowRunning = true
	task.spawn(function()
		local t = 0
		while glowRunning do
			t = t + 0.05
			local hue = 0.12 + math.sin(t) * 0.02
			label.TextColor3 = Color3.fromHSV(hue, 0.85, 1)
			task.wait(0.05)
		end
	end)

	task.delay(math.max(duration - 0.3, 0), function()
		glowRunning = false
		pulseTween:Cancel()
		local exitTween = TweenService:Create(
			billboard,
			TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In),
			{ Size = UDim2.new(0, 10, 0, 5) }
		)
		exitTween:Play()
	end)

	task.delay(duration, function()
		billboard:Destroy()
	end)
end

-- El ganador YA NO sale de la pelea: se le restaura la vida y se queda como campeón
-- de ese cupo, esperando al siguiente retador.
local function celebrateWinner(npc)
	if not npc or not npc.Parent then
		return
	end
	local maxHealth = npc:GetAttribute("MaxHealth") or CONFIG.HEALTH_MAX
	local currentHealth = npc:GetAttribute("Health") or maxHealth
	local newHealth = math.min(maxHealth, currentHealth + CONFIG.REGEN_ON_WIN)
	npc:SetAttribute("Health", newHealth)
	showVictoryText(npc, CONFIG.WIN_CELEBRATION_DURATION)
	playRandomSound(CONFIG.HIT_SOUND_IDS)
	victoryPunchEvent:FireAllClients(npc.Name) -- avisa a las cámaras que hagan el enfoque rápido
	task.wait(CONFIG.WIN_CELEBRATION_DURATION)
end

-- ===== CUENTA REGRESIVA CORTA POR PAREJA =====

local function createPairSignAnchor(spawnA, spawnB)
	local anchor = Instance.new("Part")
	anchor.Name = "PairSignAnchor"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.Anchored = true

	local midPoint = (spawnA.Position + spawnB.Position) / 2
	anchor.Position = midPoint + Vector3.new(0, 8, 0)
	anchor.Parent = ring

	return anchor
end

local function runShortCountdown(anchor, seconds)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CountdownGui"
	billboard.Size = UDim2.new(0, 120, 0, 120)
	billboard.AlwaysOnTop = true
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = billboard

	for i = seconds, 1, -1 do
		label.Text = tostring(i)
		label.TextColor3 = COUNTDOWN_COLORS[((seconds - i) % #COUNTDOWN_COLORS) + 1]
		label.Size = UDim2.new(0, 20, 0, 20)

		local popTween = TweenService:Create(
			label,
			TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Size = UDim2.new(1, 0, 1, 0) }
		)
		popTween:Play()

		task.wait(1)
	end

	billboard:Destroy()
end

-- ===== SONIDO =====

local function playBackgroundMusic()
	local music = Instance.new("Sound")
	music.Name = "BackgroundMusic"
	music.SoundId = CONFIG.BACKGROUND_MUSIC_ID
	music.Looped = true
	music.Volume = CONFIG.BACKGROUND_MUSIC_VOLUME
	music.Parent = SoundService
	music:Play()
	return music
end

local bellSound = Instance.new("Sound")
bellSound.Name = "BellSound"
bellSound.SoundId = CONFIG.BELL_SOUND_ID
bellSound.Volume = 0.6
bellSound.Parent = SoundService

local function ringBell()
	-- A diferencia de un solo duelo, aquí puede haber varios duelos arrancando o
	-- terminando casi al mismo tiempo. Reutilizar un solo Sound cortaría la campana
	-- de un duelo con la del otro, así que creamos uno nuevo y desechable cada vez.
	local sound = bellSound:Clone()
	sound.Parent = SoundService
	sound:Play()
	task.delay(3, function()
		sound:Destroy()
	end)
end

-- ===== BRIDGE (TIKTOK/TIKFINITY) =====

local function pollBridgeForJoinRequests()
	local url = CONFIG.BRIDGE_URL .. "/queue/pull?token=" .. CONFIG.BRIDGE_ACCESS_TOKEN

	local requestSuccess, response = pcall(function()
		return HttpService:GetAsync(url)
	end)
	if not requestSuccess then
		warn("No se pudo consultar el bridge: " .. tostring(response))
		return
	end

	local decodeSuccess, data = pcall(function()
		return HttpService:JSONDecode(response)
	end)
	if not decodeSuccess or not data.names then
		return
	end

	for _, entry in ipairs(data.names) do
		table.insert(waitingQueue, entry)
	end

	if #data.names > 0 then
		broadcastQueuePreview()
	end
end

task.spawn(function()
	while true do
		task.wait(CONFIG.BRIDGE_POLL_INTERVAL)
		pollBridgeForJoinRequests()
	end
end)

-- ===== BOOST DE VIDA POR ROSA =====
-- Si alguien manda una rosa mientras su personaje está en el ring O esperando
-- como espectador, le suma CONFIG.ROSE_HEALTH_BOOST a su vida MÁXIMA (no solo
-- a la actual) — así el boost se queda con él incluso si ya se curó del todo
-- después. Si en ese momento tenía menos que el máximo, también se le suma a
-- la vida actual (sin pasarse del nuevo máximo).

-- Si alguien manda uno de los 5 regalos válidos mientras su personaje está
-- en el ring O esperando como espectador, se le suman los porcentajes de ese
-- regalo a sus estadísticas (se APILAN sobre lo que ya tenía, no lo reemplazan).
-- Si en ese momento tenía menos que el máximo de vida, también se le suma a
-- la vida actual (sin pasarse del nuevo máximo).

-- Cuando un regalo trae equipo, y ese equipo es DISTINTO al que ya tenía
-- este peleador, hay que "recolorear" todo lo que depende del equipo — no
-- solo cambiar el atributo Team en silencio, si no el nombre pulsando, el
-- aura y las partículas de mano se quedarían con los colores viejos.
local function reassignTeam(npc, newTeam)
	local currentTeam = npc:GetAttribute("Team") or ""
	if newTeam == currentTeam then
		return -- ya está en ese equipo, no hay nada que recolorear
	end

	npc:SetAttribute("Team", newTeam or "")

	local head = npc:FindFirstChild("Head")
	local nameTag = head and head:FindFirstChild("NameTag")
	local label = nameTag and nameTag:FindFirstChildOfClass("TextLabel")
	if label then
		applyTeamNameStyle(label, newTeam)
	end

	local existingAura = npc:FindFirstChild("TeamAura")
	if existingAura then
		existingAura:Destroy()
	end
	local maxHealth = npc:GetAttribute("MaxHealth") or CONFIG.HEALTH_MAX
	if maxHealth > CONFIG.HEALTH_MAX then
		applyTeamAura(npc, newTeam)
	end

	-- Fuerza a que las partículas de mano se vuelvan a evaluar con el color
	-- del equipo nuevo, aunque el nivel de daño acumulado no haya cambiado.
	npc:SetAttribute("HandParticleLevel", nil)
	local damageMultiplier = npc:GetAttribute("DamageMultiplier") or 1
	attachHandParticles(npc, newTeam, damageMultiplier)
end

local function applyGiftBoost(username, team, healthPercent, damagePercent, speedPercent)
	-- ============================================================
	-- 1. ¿EL JUGADOR ESTÁ ACTUALMENTE EN EL RING?
	-- ============================================================
	local ringNpc = activeFighters:FindFirstChild(username)

	if ringNpc then
		-- Si el regalo pertenece a Héroe/Villano, actualizamos su equipo.
		if team then
			reassignTeam(ringNpc, team)
		end

		local currentMax = ringNpc:GetAttribute("MaxHealth") or CONFIG.HEALTH_MAX
		local currentHealth = ringNpc:GetAttribute("Health") or currentMax
		local currentDamageMultiplier = ringNpc:GetAttribute("DamageMultiplier") or 1
		local currentSpeedMultiplier = ringNpc:GetAttribute("SpeedMultiplier") or 1

		-- Calculamos cuánto agrega ESTE regalo.
		local healthGain = CONFIG.HEALTH_MAX * healthPercent

		local newMax = currentMax + healthGain
		local newHealth = math.min(newMax, currentHealth + healthGain)

		local newDamageMultiplier =
			currentDamageMultiplier + damagePercent

		local newSpeedMultiplier =
			currentSpeedMultiplier + speedPercent

		-- Guardamos las nuevas estadísticas.
		ringNpc:SetAttribute("MaxHealth", newMax)
		ringNpc:SetAttribute("Health", newHealth)
		ringNpc:SetAttribute("DamageMultiplier", newDamageMultiplier)
		ringNpc:SetAttribute("SpeedMultiplier", newSpeedMultiplier)

		-- Si el regalo aumenta velocidad, actualizamos las animaciones
		-- que ya están cargadas.
		if speedPercent > 0 then
			local tracks = fighterTracks[ringNpc]

			if tracks then
				for _, punchTrack in ipairs(tracks.punches) do
					punchTrack:AdjustSpeed(newSpeedMultiplier)
				end
			end
		end

		-- Mensaje visual sobre el peleador.
		showTextPopup(
			ringNpc,
			"+" .. math.floor(healthGain + 0.5) .. " VIDA 🎁",
			Color3.fromRGB(255, 105, 180),
			1.2
		)

		-- Si todavía no tiene aura, se la ponemos.
		if not ringNpc:FindFirstChild("TeamAura") then
			applyTeamAura(
				ringNpc,
				ringNpc:GetAttribute("Team")
			)
		end

		-- Actualizamos las partículas de las manos según el nuevo daño.
		attachHandParticles(
			ringNpc,
			ringNpc:GetAttribute("Team"),
			newDamageMultiplier
		)

		print(
			"🎁 " ..
				tostring(username) ..
				" recibió boost MIENTRAS PELEABA"
		)

		return true
	end


	-- ============================================================
	-- 2. ¿EL JUGADOR ESTÁ ESPERANDO COMO ESPECTADOR?
	-- ============================================================
	for _, entry in ipairs(spectatorQueue) do

		if entry.username == username then

			-- Actualizamos el equipo.
			if team and entry.npc and entry.npc.Parent then
				reassignTeam(entry.npc, team)
			end

			entry.team = team or entry.team

			-- Calculamos el boost.
			local healthGain =
				CONFIG.HEALTH_MAX * healthPercent

			entry.maxHealth =
				(entry.maxHealth or CONFIG.HEALTH_MAX) + healthGain

			entry.damageMultiplier =
				(entry.damageMultiplier or 1) + damagePercent

			entry.speedMultiplier =
				(entry.speedMultiplier or 1) + speedPercent

			-- Actualizamos visualmente al espectador.
			if entry.npc and entry.npc.Parent then

				entry.npc:SetAttribute(
					"MaxHealth",
					entry.maxHealth
				)

				entry.npc:SetAttribute(
					"Health",
					entry.maxHealth
				)

				showTextPopup(
					entry.npc,
					"+" .. math.floor(healthGain + 0.5) .. " VIDA 🎁",
					Color3.fromRGB(255, 105, 180),
					1.2
				)

				if not entry.npc:FindFirstChild("TeamAura") then
					applyTeamAura(
						entry.npc,
						entry.team
					)
				end
			end

			print(
				"🎁 " ..
					tostring(username) ..
					" recibió boost MIENTRAS ESPERABA"
			)

			return true
		end
	end


	-- ============================================================
	-- 3. NO ESTÁ EN EL RING Y TAMPOCO ESTÁ ESPERANDO
	--
	-- ESTE ES EL CASO QUE ESTABA FALLANDO.
	--
	-- Significa que su peleador anterior murió.
	-- Ahora el regalo DEBE CREARLE UN NUEVO PELEADOR.
	-- ============================================================

	-- Elegimos una cuenta de Roblox de respaldo para utilizar
	-- únicamente como avatar.
	local avatarUsername =
		FALLBACK_AVATAR_POOL[
	math.random(1, #FALLBACK_AVATAR_POOL)
	]

	-- Agregamos directamente el nuevo peleador a la cola.
	table.insert(waitingQueue, {
		username = username,

		-- El equipo viene determinado por el regalo.
		team = team,

		-- El nuevo peleador NACE con las estadísticas del regalo.
		healthPercent = healthPercent,
		damagePercent = damagePercent,
		speedPercent = speedPercent,

		-- Avatar de Roblox que usaremos para representar
		-- visualmente al usuario de TikTok.
		avatarUsername = avatarUsername,
	})

	print(
		"🎁 " ..
			tostring(username) ..
			" NO estaba en el ring ni esperando."
	)

	print(
		"🥊 NUEVO PELEADOR AGREGADO POR REGALO → " ..
			tostring(username) ..
			" | Avatar: " ..
			tostring(avatarUsername)
	)

	print(
		"📊 Estadísticas iniciales → Vida +" ..
			tostring(math.floor(healthPercent * 100)) ..
			"% | Daño +" ..
			tostring(math.floor(damagePercent * 100)) ..
			"% | Velocidad +" ..
			tostring(math.floor(speedPercent * 100)) ..
			"%"
	)

	-- MUY IMPORTANTE:
	-- devolvemos true porque el regalo YA FUE PROCESADO.
	return true
end

local function pollBridgeForGiftBoosts()
	local url = CONFIG.BRIDGE_URL .. "/boost/pull?token=" .. CONFIG.BRIDGE_ACCESS_TOKEN

	local requestSuccess, response = pcall(function()
		return HttpService:GetAsync(url)
	end)
	if not requestSuccess then
		return
	end

	local decodeSuccess, data = pcall(function()
		return HttpService:JSONDecode(response)
	end)
	if not decodeSuccess or not data.boosts then
		return
	end

	for _, boost in ipairs(data.boosts) do

		local applied = applyGiftBoost(
			boost.username,
			boost.team,
			boost.healthPercent or 0,
			boost.damagePercent or 0,
			boost.speedPercent or 0
		)

		if applied then

			print(
				"🎁 Regalo procesado correctamente para " ..
					tostring(boost.username)
			)

		else

			warn(
				"⚠️ No se pudo procesar el regalo de " ..
					tostring(boost.username)
			)

		end
	end
end

-- Regalos de gente que nunca escribió un username: se les asigna una cuenta
-- de Roblox de respaldo al azar (para el avatar), pero se identifican y se
-- muestran con su nombre real de TikTok.
local function pollBridgeForGiftSpawns()
	local url = CONFIG.BRIDGE_URL .. "/giftspawn/pull?token=" .. CONFIG.BRIDGE_ACCESS_TOKEN

	local requestSuccess, response = pcall(function()
		return HttpService:GetAsync(url)
	end)
	if not requestSuccess then
		return
	end

	local decodeSuccess, data = pcall(function()
		return HttpService:JSONDecode(response)
	end)
	if not decodeSuccess or not data.spawns then
		return
	end

	for _, spawnData in ipairs(data.spawns) do
		local avatarUsername = FALLBACK_AVATAR_POOL[math.random(1, #FALLBACK_AVATAR_POOL)]
		local alreadyExists = isAlreadyActiveOrWaiting(spawnData.tiktokUsername)
		if not alreadyExists then
			table.insert(waitingQueue, {
				username = spawnData.tiktokUsername,
				team = spawnData.team,
				healthPercent = spawnData.healthPercent or 0,
				damagePercent = spawnData.damagePercent or 0,
				speedPercent = spawnData.speedPercent or 0,
				avatarUsername = avatarUsername,
			})
			print("🎁 " .. tostring(spawnData.tiktokUsername) .. " aparecerá con la cuenta de respaldo " .. avatarUsername .. (spawnData.team and (" (equipo: " .. spawnData.team .. ")") or ""))
		end
	end
end

task.spawn(function()
	while true do
		task.wait(CONFIG.BRIDGE_POLL_INTERVAL)
		pollBridgeForGiftBoosts()
	end
end)

task.spawn(function()
	while true do
		task.wait(CONFIG.BRIDGE_POLL_INTERVAL)
		pollBridgeForGiftSpawns()
	end
end)

-- ===== EMPAREJAMIENTO LIBRE: cada peleador sin rival busca al más cercano
-- que tampoco tenga rival. No hay "cupos" fijos: quien gana se cura y busca
-- rival nuevo de inmediato, sin teletransportarse ni reiniciarse. =====

playBackgroundMusic()

-- true mientras ese NPC está activamente peleando con alguien.
local inCombat = {}

-- ===== LLUVIA DE GUANTES (regalos "Sombrero y bigote" / "Cisne de papel") =====
-- Sistema físico de verdad: los guantes caen con gravedad real y se
-- detectan por colisión (.Touched), no por animación controlada — se sienten
-- como un impacto de verdad, no como un efecto de cámara.

-- Promedia la posición de todos los peleadores activos, para saber dónde
-- centrar la lluvia (si el ring está vacío, cae en el centro del Ring).
local function obtenerCentroJugadores()
	local sumaPos = Vector3.new(0, 0, 0)
	local cantidad = 0

	for _, npc in ipairs(activeFighters:GetChildren()) do
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			sumaPos = sumaPos + root.Position
			cantidad = cantidad + 1
		end
	end

	if cantidad > 0 then
		return sumaPos / cantidad
	else
		return ring and ring.Position or Vector3.new(0, 0, 0)
	end
end

-- Esfera que se expande + rayo vertical + ráfaga de chispas, en el color del
-- guante que acaba de caer.
local function crearExplosionVisualAvanzada(posicion, esDorado)
	local colorPrincipal = esDorado and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(110, 30, 160)
	local colorRayo = esDorado and Color3.fromRGB(255, 255, 180) or Color3.fromRGB(200, 100, 255)

	local explosion = Instance.new("Part")
	explosion.Shape = Enum.PartType.Ball
	explosion.Material = Enum.Material.Neon
	explosion.Color = colorPrincipal
	explosion.Size = Vector3.new(2, 2, 2)
	explosion.Position = posicion
	explosion.Anchored = true
	explosion.CanCollide = false
	explosion.Parent = Workspace

	TweenService:Create(
		explosion,
		TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{
			Size = Vector3.new(
				CONFIG.GLOVE_RAIN_EXPLOSION_RADIUS * 2,
				CONFIG.GLOVE_RAIN_EXPLOSION_RADIUS * 2,
				CONFIG.GLOVE_RAIN_EXPLOSION_RADIUS * 2
			),
			Transparency = 1,
		}
	):Play()
	Debris:AddItem(explosion, 0.45)

	local rayo = Instance.new("Part")
	rayo.Shape = Enum.PartType.Cylinder
	rayo.Material = Enum.Material.Neon
	rayo.Color = colorRayo
	rayo.Size = Vector3.new(45, 1.8, 1.8)
	rayo.CFrame = CFrame.new(posicion + Vector3.new(0, 20, 0)) * CFrame.Angles(0, 0, math.rad(90))
	rayo.Anchored = true
	rayo.CanCollide = false
	rayo.Parent = Workspace

	TweenService:Create(
		rayo,
		TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(50, 0, 0), Transparency = 1 }
	):Play()
	Debris:AddItem(rayo, 0.35)

	local anchorChispas = Instance.new("Part")
	anchorChispas.Size = Vector3.new(0.2, 0.2, 0.2)
	anchorChispas.Transparency = 1
	anchorChispas.Anchored = true
	anchorChispas.CanCollide = false
	anchorChispas.CFrame = CFrame.new(posicion)
	anchorChispas.Parent = Workspace

	local chispas = Instance.new("ParticleEmitter")
	chispas.Color = ColorSequence.new(colorRayo)
	chispas.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	chispas.Lifetime = NumberRange.new(0.2, 0.5)
	chispas.Speed = NumberRange.new(18, 35)
	chispas.SpreadAngle = Vector2.new(180, 180)
	chispas.LightEmission = 1
	chispas.Rate = 0
	chispas.Parent = anchorChispas

	chispas:Emit(30)
	Debris:AddItem(anchorChispas, 0.6)
end

-- Aviso de pantalla completa (temblando) para todos los espectadores del
-- live, avisando qué lluvia está a punto de caer.
local function mostrarImagenTemblando(esDorado)
	local imageId = esDorado and "rbxassetid://71981344068380" or "rbxassetid://88522051020137"

	for _, player in ipairs(Players:GetPlayers()) do
		local playerGui = player:FindFirstChild("PlayerGui")
		if playerGui then
			local screenGui = Instance.new("ScreenGui")
			screenGui.Name = "AlertaLluvia"
			screenGui.Parent = playerGui

			local imageLabel = Instance.new("ImageLabel")
			imageLabel.Size = UDim2.new(0, 250, 0, 250)
			imageLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
			imageLabel.AnchorPoint = Vector2.new(0.5, 0.5)
			imageLabel.BackgroundTransparency = 1
			imageLabel.Image = imageId
			imageLabel.ImageTransparency = 0
			imageLabel.Parent = screenGui

			task.spawn(function()
				local tiempoTemblor = 2.5
				local tiempoInicio = tick()
				local posOriginal = UDim2.new(0.5, 0, 0.5, 0)

				while tick() - tiempoInicio < tiempoTemblor do
					local offsetX = math.random(-20, 20)
					local offsetY = math.random(-20, 20)
					local rot = math.random(-8, 8)

					imageLabel.Position = posOriginal + UDim2.new(0, offsetX, 0, offsetY)
					imageLabel.Rotation = rot

					task.wait(0.04)
				end

				local tween = TweenService:Create(imageLabel, TweenInfo.new(0.5), { ImageTransparency = 1 })
				tween:Play()
				tween.Completed:Wait()

				screenGui:Destroy()
			end)
		end
	end
end

-- Deja caer CONFIG.GLOVE_RAIN_COUNT guantes con gravedad real, repartidos en
-- el tiempo. Al tocar a alguien o al piso, explota y daña en área — solo al
-- equipo contrario al color del guante (dorado daña villanos, oscuro daña héroes).
local function iniciarLluviaGuantes(tipoGuante)
	local modeloTemplate = ServerStorage:FindFirstChild(tipoGuante)
	if not modeloTemplate then
		warn("⚠️ No se encontró el modelo '" .. tostring(tipoGuante) .. "' en ServerStorage")
		return
	end

	local esDorado = (tipoGuante == "PuñoDorado")
	mostrarImagenTemblando(esDorado)

	for i = 1, CONFIG.GLOVE_RAIN_COUNT do
		task.delay(math.random() * CONFIG.GLOVE_RAIN_STAGGER_MAX, function()
			local guante = modeloTemplate:Clone()
			local hitbox = guante.PrimaryPart or guante:FindFirstChildWhichIsA("BasePart")
			if not hitbox then
				return
			end

			local centroCombate = obtenerCentroJugadores()
			local offsetX = math.random(-CONFIG.GLOVE_RAIN_SPAWN_RADIUS, CONFIG.GLOVE_RAIN_SPAWN_RADIUS)
			local offsetZ = math.random(-CONFIG.GLOVE_RAIN_SPAWN_RADIUS, CONFIG.GLOVE_RAIN_SPAWN_RADIUS)
			local spawnPos = Vector3.new(
				centroCombate.X + offsetX,
				centroCombate.Y + CONFIG.GLOVE_RAIN_HEIGHT,
				centroCombate.Z + offsetZ
			)

			guante:PivotTo(CFrame.new(spawnPos))
			guante.Parent = Workspace

			for _, part in ipairs(guante:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = false
					part.CanCollide = false
				end
			end

			local haExplotado = false

			hitbox.Touched:Connect(function(hit)
				if haExplotado then
					return
				end

				local character = hit.Parent
				local esPiso = hit.Name == "Baseplate" or hit.Name == "Floor" or hit.Name == "Ring" or hit:IsDescendantOf(ring)

				if (character and character:FindFirstChild("Humanoid")) or esPiso then
					haExplotado = true
					crearExplosionVisualAvanzada(hitbox.Position, esDorado)

					for _, model in ipairs(activeFighters:GetChildren()) do
						local currentHealth = model:GetAttribute("Health")
						if currentHealth and currentHealth > 0 then
							local rootPart = model:FindFirstChild("HumanoidRootPart")
							if rootPart and (rootPart.Position - hitbox.Position).Magnitude <= CONFIG.GLOVE_RAIN_EXPLOSION_RADIUS then
								local equipo = model:GetAttribute("Team")
								local leToca = (esDorado and equipo == "villain") or (not esDorado and equipo == "hero")

								if leToca then
									local nuevaVida = math.max(0, currentHealth - CONFIG.GLOVE_RAIN_DAMAGE)
									print(string.format(
										"💥 [Lluvia de Guantes] Impacto a: %s | Team: %s | Daño: %d | Vida restante: %d",
										model.Name, tostring(equipo), CONFIG.GLOVE_RAIN_DAMAGE, nuevaVida
										))
									model:SetAttribute("Health", nuevaVida)

									if nuevaVida <= 0 and not inCombat[model] then
										-- No está en medio de un runCombat activo que lo vaya a
										-- detectar solo (por ejemplo, un campeón esperando a su
										-- próximo rival) — hay que cerrarle el círculo acá mismo.
										-- Si SÍ está en combate activo, el propio runCombat lo
										-- detecta en su próximo tick (cada 0.1s) y maneja todo
										-- lo demás (ganador, puntaje de equipo, etc.) normal.
										print("☠️ [Lluvia de Guantes] " .. model.Name .. " fue eliminado por la lluvia de guantes.")
										playDeathEffect(model)
									end
								end
							end
						end
					end

					guante:Destroy()
				end
			end)

			Debris:AddItem(guante, CONFIG.GLOVE_RAIN_LIFETIME)
		end)
	end
end

local function pollBridgeForSpecialGifts()
	local url = CONFIG.BRIDGE_URL .. "/gifts/pull?token=" .. CONFIG.BRIDGE_ACCESS_TOKEN

	local requestSuccess, response = pcall(function()
		return HttpService:GetAsync(url)
	end)
	if not requestSuccess then
		return
	end

	local decodeSuccess, data = pcall(function()
		return HttpService:JSONDecode(response)
	end)
	if not decodeSuccess or not data.gifts then
		return
	end

	for _, giftData in ipairs(data.gifts) do
		local giftId = tonumber(giftData.giftId)
		if giftId == 6427 then
			iniciarLluviaGuantes("PuñoOscuro")
		elseif giftId == 5659 then
			iniciarLluviaGuantes("PuñoDorado")
		end
	end
end

task.spawn(function()
	while true do
		task.wait(CONFIG.BRIDGE_POLL_INTERVAL)
		pollBridgeForSpecialGifts()
	end
end)

-- ===== PANEL DE ADMINISTRACIÓN (reseteos desde el panel web) =====

local function resetActiveFighters()
	for _, npc in ipairs(activeFighters:GetChildren()) do
		fighterTracks[npc] = nil
		inCombat[npc] = nil
		npc:Destroy()
	end
end

local function resetWaitingQueue()
	waitingQueue = {}

	for _, entry in ipairs(spectatorQueue) do
		occupiedBlocks[entry.block] = nil
		if entry.npc and entry.npc.Parent then
			entry.npc:Destroy()
		end
	end
	spectatorQueue = {}

	broadcastQueuePreview()
end

local function pollBridgeForAdminCommands()
	local url = CONFIG.BRIDGE_URL .. "/admin/pull-commands?token=" .. CONFIG.BRIDGE_ACCESS_TOKEN

	local requestSuccess, response = pcall(function()
		return HttpService:GetAsync(url)
	end)
	if not requestSuccess then
		return
	end

	local decodeSuccess, data = pcall(function()
		return HttpService:JSONDecode(response)
	end)
	if not decodeSuccess or not data.commands then
		return
	end

	for _, command in ipairs(data.commands) do
		if command.action == "reset_fighters" then
			resetActiveFighters()
			print("🧹 Peleadores activos reseteados desde el panel")
		elseif command.action == "reset_queue" then
			resetWaitingQueue()
			print("🧹 Cola de espera reseteada desde el panel")
		elseif command.action == "set_message" then
			messageUpdateEvent:FireAllClients(command.message)
			print("📝 Mensaje del HUD actualizado desde el panel: " .. tostring(command.message))
		end
	end
end

task.spawn(function()
	while true do
		task.wait(CONFIG.BRIDGE_POLL_INTERVAL)
		pollBridgeForAdminCommands()
	end
end)

local function getFreeFighters()
	local free = {}
	for _, npc in ipairs(activeFighters:GetChildren()) do
		if not inCombat[npc] then
			table.insert(free, npc)
		end
	end
	return free
end

-- Dos equipos reales (VILLANO/HEROE) nunca pueden pelear contra su propio equipo.
-- Un neutral (sin equipo) puede pelear contra cualquiera, ya que técnicamente no
-- pertenece a ningún bando.
local function canFight(npcA, npcB)
	local teamA = npcA:GetAttribute("Team")
	local teamB = npcB:GetAttribute("Team")
	if teamA ~= "" and teamB ~= "" and teamA == teamB then
		return false
	end
	return true
end

local function findNearestFreeOpponent(npc, candidates)
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local nearest, nearestDistance = nil, math.huge
	for _, other in ipairs(candidates) do
		if other ~= npc and canFight(npc, other) then
			local otherRoot = other:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local distance = (root.Position - otherRoot.Position).Magnitude
				if distance < nearestDistance then
					nearest = other
					nearestDistance = distance
				end
			end
		end
	end
	return nearest
end

-- Trae UN peleador válido de la cola y lo spawnea en el punto indicado.
-- Devuelve el NPC, o nil si no había nadie válido esperando ahora mismo.
local function spawnOneFromQueue(spawnPoint)
	local name, desc, team, maxHealth, damageMultiplier, speedMultiplier = pullNextRingFighter()
	if not name then
		return nil
	end
	return spawnFighter(spawnPoint, name, desc, team, maxHealth, damageMultiplier, speedMultiplier)
end

-- Si el ring quedó lleno (8) con un solo equipo, nadie puede pelear entre ellos
-- (la regla de equipos lo prohíbe) y la arena se traba. Esta función detecta
-- justo ese caso y reemplaza a UNO de los "sobrantes" por alguien del equipo
-- contrario que ya esté esperando (en los bloques de espectador). El reemplazado
-- no se destruye del todo: vuelve a la cola cruda para intentarlo de nuevo.
local function breakSameTeamDeadlock()
	if #activeFighters:GetChildren() < MAX_ACTIVE_FIGHTERS then
		return -- todavía hay lugar libre, no hace falta forzar nada
	end

	local freeList = getFreeFighters()
	if #freeList == 0 then
		return -- todos están peleando ya, no hay ningún atasco
	end

	local firstTeam = freeList[1]:GetAttribute("Team")
	if firstTeam == "" then
		return -- si hay neutrales sueltos, esos ya pueden pelear con cualquiera
	end

	for _, npc in ipairs(freeList) do
		if npc:GetAttribute("Team") ~= firstTeam then
			return -- hay variedad de equipos entre los libres, no es un atasco real
		end
	end

	local opponentTeam = (firstTeam == "villain") and "hero" or "villain"
	local replacementIndex = nil
	for i, entry in ipairs(spectatorQueue) do
		if entry.team == opponentTeam then
			replacementIndex = i
			break
		end
	end
	if not replacementIndex then
		return -- todavía no hay nadie del equipo contrario esperando
	end

	local newEntry = table.remove(spectatorQueue, replacementIndex)
	occupiedBlocks[newEntry.block] = nil
	if newEntry.npc and newEntry.npc.Parent then
		newEntry.npc:Destroy()
	end

	local displaced = freeList[1]
	table.insert(waitingQueue, { username = displaced.Name, team = displaced:GetAttribute("Team") })
	fighterTracks[displaced] = nil
	displaced:Destroy()

	local spawnPoint = SPAWN_POINTS[math.random(1, #SPAWN_POINTS)]
	spawnFighter(spawnPoint, newEntry.username, newEntry.description, newEntry.team, newEntry.maxHealth, newEntry.damageMultiplier, newEntry.speedMultiplier)

	broadcastQueuePreview()
end

-- Corre un duelo completo entre dos peleadores ya emparejados, y al terminar
-- los libera (el ganador queda disponible para un rival nuevo de inmediato;
-- el perdedor se destruye).
local teamWins = { villain = 0, hero = 0 }

local function runMatch(npcA, npcB)
	ringBell()

	local winner, loser = runCombat(npcA, npcB)

	if loser and loser.Parent then
		playDeathEffect(loser)
	end

	celebrateWinner(winner) -- restaura la vida y muestra "VICTORIA"; NO teletransporta ni reinicia nada

	if winner and winner.Parent then
		winner:SetAttribute("OpponentName", "")

		local winnerTeam = winner:GetAttribute("Team")
		if winnerTeam == "villain" or winnerTeam == "hero" then
			teamWins[winnerTeam] = teamWins[winnerTeam] + 1
			teamScoreEvent:FireAllClients(teamWins.villain, teamWins.hero)
		end
	end

	inCombat[npcA] = nil
	inCombat[npcB] = nil
end

-- Se ejecuta constantemente: (1) llena la arena hasta 8 con gente de la cola,
-- (2) empareja a todo el que esté libre con su rival libre más cercano.
local function matchmakerTick()
	breakSameTeamDeadlock()

	while #activeFighters:GetChildren() < MAX_ACTIVE_FIGHTERS do
		local activeCount = #activeFighters:GetChildren()
		local spawnPoint = SPAWN_POINTS[(activeCount % #SPAWN_POINTS) + 1]
		local newFighter = spawnOneFromQueue(spawnPoint)
		if not newFighter then
			break -- no había más candidatos válidos esperando, no seguimos insistiendo
		end
	end

	local free = getFreeFighters()
	while #free >= 2 do
		local npc = table.remove(free, 1)
		local opponent = findNearestFreeOpponent(npc, free)
		if not opponent then
			break
		end

		for i, candidate in ipairs(free) do
			if candidate == opponent then
				table.remove(free, i)
				break
			end
		end

		inCombat[npc] = true
		inCombat[opponent] = true
		npc:SetAttribute("OpponentName", opponent.Name)
		opponent:SetAttribute("OpponentName", npc.Name)

		task.spawn(function()
			runMatch(npc, opponent)
		end)
	end

	broadcastQueuePreview()
end

task.spawn(function()
	while true do
		fillSpectatorPool()
		matchmakerTick()
		task.wait(1)
	end
end)
