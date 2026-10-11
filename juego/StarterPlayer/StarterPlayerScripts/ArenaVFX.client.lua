-- ArenaVFX (LocalScript en StarterPlayerScripts)
-- Efectos visuales 3D dibujados en el cliente (60 FPS, sin tirones de red):
--   💥 impactos de los golpes (estrella de impacto, ondas de choque, chispas,
--      destellos, polvo) con 3 niveles: normal, crítico y SÚPER
--   🛡️ bloqueo (escudo azul) y esquiva (ráfaga de viento)
--   ⚡ carga de energía en el puño antes del SÚPER y explosión del K.O.
--   🌟 entradas al ring, columnas de poder, curaciones, confeti, lluvias...
--   🔥 AURAS de los peleadores del ring, según lo potenciados que estén:
--        todos: disco de su equipo en el piso
--        nivel 1: contorno brillante + partículas que suben (luz dorada / humo morado)
--        nivel 2: + llamas del color del equipo, anillo de runas que gira y luz
--        nivel 3: + aura gigante de fuego, esferas orbitando y rayos
--        SÚPER cargado: puños brillando con chispas eléctricas
--        racha de 3+: corona de luz dorada girando sobre la cabeza
-- El servidor manda FxEvent("vfx", { name, args }) desde el módulo Effects.
-- Las auras salen solas de los atributos del NPC (Aura, MaxHealth,
-- DamageMultiplier, SpeedMultiplier, Energy, Streak, Team).

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local fxEvent = arena:WaitForChild("Remotes"):WaitForChild("FxEvent")
local settingsFolder = arena:WaitForChild("Settings")
local activeFighters = Workspace:WaitForChild("ActiveFighters")

local folder = Instance.new("Folder")
folder.Name = "ArenaVFXLocal" -- solo existe en este cliente
folder.Parent = Workspace

-- Texturas que trae Roblox (no hay que subir nada). Probadas en el ring:
-- fire_sparks y forcefield_glow NO se ven como partículas, por eso no se usan.
local TEX = {
	spark = "rbxasset://textures/particles/sparkles_main.dds", -- estrellita
	flame = "rbxasset://textures/particles/explosion01_core_main.dds", -- fuego naranja
	wisp = "rbxasset://textures/particles/fire_main.dds", -- humo en hilos
	soft = "rbxasset://textures/particles/smoke_main.dds", -- brillo suave (se tiñe bien)
	shock = "rbxasset://textures/particles/explosion01_shockwave_main.dds", -- destello redondo
}

local HIT_COLORS = {
	hero = Color3.fromRGB(255, 235, 150),
	villain = Color3.fromRGB(190, 100, 255),
}
local WHITE = Color3.new(1, 1, 1)
local NIL = "__nil" -- así llegan los argumentos nil desde el servidor

-- ===== AYUDANTES =====

local function tween(inst, duration, props, style, direction)
	local t = TweenService:Create(
		inst,
		TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

local function basePart(shape)
	local part = Instance.new("Part")
	if shape then
		part.Shape = shape
	end
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function anchorAt(position, lifetime)
	local anchor = basePart()
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = folder
	Debris:AddItem(anchor, lifetime or 2)
	return anchor
end

local function pointLight(parent, color, brightness, range, duration)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
	tween(light, duration, { Brightness = 0 })
	Debris:AddItem(light, duration + 0.1)
	return light
end

local function numberSeq(a, b)
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b) })
end

-- Emisor que suelta 'count' partículas de una vez en 'position'
local function burst(position, lifetime, count, props)
	local anchor = anchorAt(position, lifetime)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.LightEmission = 1
	for key, value in pairs(props) do
		emitter[key] = value
	end
	emitter.Parent = anchor
	emitter:Emit(count)
	return anchor, emitter
end

local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude

-- Punto del piso debajo de una posición
local function floorBelow(position)
	local ignore = { folder, activeFighters }
	for _, name in ipairs({ "ArenaFX", "WaitingFighters" }) do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(ignore, f)
		end
	end
	floorParams.FilterDescendantsInstances = ignore
	local hit = Workspace:Raycast(position, Vector3.new(0, -25, 0), floorParams)
	return if hit then hit.Position else position - Vector3.new(0, 4.5, 0)
end

-- ===== EFECTOS =====
local FX = {}

function FX.sparks(position, color, count, speedMin, speedMax, size, lifetime)
	lifetime = lifetime or 0.3
	burst(position, 1.5, count or 16, {
		Texture = TEX.spark,
		Color = ColorSequence.new(color or WHITE),
		Size = numberSeq((size or 0.45) * 1.6, 0),
		Transparency = numberSeq(0, 1),
		Lifetime = NumberRange.new(lifetime, lifetime + 0.25),
		Speed = NumberRange.new(speedMin or 8, speedMax or 16),
		Drag = 3,
		Rotation = NumberRange.new(0, 360),
	})
end

-- Brasas que saltan y caen
function FX.embers(position, color, count)
	burst(position, 2, count or 20, {
		Texture = TEX.spark,
		Color = ColorSequence.new(WHITE, color or Color3.fromRGB(255, 160, 60)),
		Size = numberSeq(0.8, 0.1),
		Transparency = numberSeq(0, 1),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(14, 26),
		Acceleration = Vector3.new(0, -30, 0),
		Drag = 2,
	})
end

-- Nubecita de polvo en el piso
function FX.dust(position, amount)
	burst(position + Vector3.new(0, 0.4, 0), 2, amount or 10, {
		Texture = TEX.soft,
		Color = ColorSequence.new(Color3.fromRGB(200, 190, 175)),
		Size = numberSeq(1.2, 3.2),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(0.6, 1),
		Speed = NumberRange.new(6, 11),
		SpreadAngle = Vector2.new(180, 8),
		EmissionDirection = Enum.NormalId.Top,
		Drag = 4,
		LightEmission = 0,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
	})
end

-- Onda de choque (sprite redondo que se expande mirando a la cámara)
function FX.shockSprite(position, color, size, duration)
	burst(position, (duration or 0.3) + 0.2, 1, {
		Texture = TEX.shock,
		Color = ColorSequence.new(color or WHITE),
		Size = numberSeq((size or 8) * 0.2, size or 8),
		Transparency = numberSeq(0, 1),
		Lifetime = NumberRange.new(duration or 0.3),
		Speed = NumberRange.new(0),
		Rotation = NumberRange.new(0, 360),
		ZOffset = 2,
	})
end

-- Anillo plano (horizontal) que se expande en el piso / a la altura dada
function FX.groundRing(position, color, maxDiameter, duration, startTransparency)
	local ring = basePart(Enum.PartType.Cylinder)
	ring.Color = color
	ring.Transparency = startTransparency or 0.1
	ring.Size = Vector3.new(0.25, 1, 1)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = folder
	tween(ring, duration, { Size = Vector3.new(0.12, maxDiameter, maxDiameter), Transparency = 1 })
	Debris:AddItem(ring, duration + 0.05)
end

-- Anillo vertical mirando en la dirección del golpe
function FX.facingRing(position, direction, color, maxDiameter, duration)
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.01 then
		direction = Vector3.new(0, 0, -1)
	end
	local ring = basePart(Enum.PartType.Cylinder)
	ring.Color = color
	ring.Transparency = 0.15
	ring.Size = Vector3.new(0.2, 0.8, 0.8)
	ring.CFrame = CFrame.lookAt(position, position + direction) * CFrame.Angles(0, math.rad(90), 0)
	ring.Parent = folder
	tween(ring, duration, { Size = Vector3.new(0.08, maxDiameter, maxDiameter), Transparency = 1 })
	Debris:AddItem(ring, duration + 0.05)
end

-- Líneas de viento que salen disparadas
function FX.windBurst(position, color, lines, reach)
	lines = lines or 6
	reach = reach or 6
	for i = 1, lines do
		local angle = (i / lines) * math.pi * 2 + math.random() * 0.4
		local direction = Vector3.new(math.cos(angle), (math.random() - 0.5) * 0.5, math.sin(angle)).Unit
		local line = basePart()
		line.Size = Vector3.new(0.15, 0.15, 2.8)
		line.Color = color
		line.Transparency = 0.2
		line.CFrame = CFrame.lookAt(position, position + direction)
		line.Parent = folder
		local target = position + direction * reach
		tween(line, 0.3, { CFrame = CFrame.lookAt(target, target + direction), Transparency = 1, Size = Vector3.new(0.05, 0.05, 4) })
		Debris:AddItem(line, 0.35)
	end
end

-- Estrella de impacto: puntas de luz que salen del punto del golpe
function FX.impactStar(position, direction, color, spikes, length, duration)
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.01 then
		direction = Vector3.new(0, 0, -1)
	end
	local forward = direction.Unit
	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude < 0.01 then
		right = Vector3.xAxis
	end
	right = right.Unit
	local up = right:Cross(forward)
	local offset = math.random() * math.pi
	for i = 1, spikes do
		local angle = offset + (i / spikes) * math.pi * 2
		local long = if i % 2 == 0 then 1 else 0.6
		local spikeDir = (right * math.cos(angle) + up * math.sin(angle) - forward * 0.35).Unit
		local spike = basePart()
		spike.Color = if i % 3 == 0 then WHITE else color
		spike.Transparency = 0
		spike.Size = Vector3.new(0.22, 0.22, 0.6)
		spike.CFrame = CFrame.lookAt(position, position + spikeDir) * CFrame.new(0, 0, -0.3)
		spike.Parent = folder
		local reach = length * long
		tween(spike, duration, {
			Size = Vector3.new(0.05, 0.05, reach),
			CFrame = CFrame.lookAt(position, position + spikeDir) * CFrame.new(0, 0, -reach * 0.75),
			Transparency = 1,
		}, Enum.EasingStyle.Quart)
		Debris:AddItem(spike, duration + 0.05)
	end
end

function FX.flashBall(position, color, maxDiameter, duration)
	local ball = basePart(Enum.PartType.Ball)
	ball.Color = color
	ball.Transparency = 0.05
	ball.Size = Vector3.new(1, 1, 1)
	ball.CFrame = CFrame.new(position)
	ball.Parent = folder
	tween(ball, duration, { Size = Vector3.new(maxDiameter, maxDiameter, maxDiameter), Transparency = 1 })
	Debris:AddItem(ball, duration + 0.05)
end

function FX.lightBurst(position, color, brightness, range, duration)
	local anchor = anchorAt(position, duration + 0.2)
	pointLight(anchor, color, brightness, range, duration)
end

-- Escudo azul del bloqueo
function FX.shieldFlash(position, direction)
	if typeof(direction) ~= "Vector3" or direction.Magnitude < 0.01 then
		direction = Vector3.new(0, 0, -1)
	end
	local disc = basePart(Enum.PartType.Cylinder)
	disc.Material = Enum.Material.ForceField
	disc.Color = Color3.fromRGB(120, 200, 255)
	disc.Transparency = 0
	disc.Size = Vector3.new(0.1, 3, 3)
	disc.CFrame = CFrame.lookAt(position, position + direction) * CFrame.Angles(0, math.rad(90), 0)
	disc.Parent = folder
	tween(disc, 0.35, { Size = Vector3.new(0.1, 6, 6), Transparency = 1 })
	Debris:AddItem(disc, 0.4)
end

-- ===== GOLPES =====
-- kind: "normal" | "crit" | "special" | "block" | "dodge"
function FX.hit(position, direction, team, kind)
	local color = HIT_COLORS[team] or Color3.fromHSV(math.random(), 0.8, 1)

	if kind == "block" then
		FX.shieldFlash(position, direction)
		FX.facingRing(position, direction, Color3.fromRGB(150, 210, 255), 6, 0.25)
		FX.sparks(position, Color3.fromRGB(170, 220, 255), 14, 10, 20, 0.3, 0.2)
		return
	elseif kind == "dodge" then
		FX.windBurst(position, Color3.fromRGB(230, 240, 255), 6, 5)
		return
	end

	if kind == "special" then
		local floor = floorBelow(position)
		FX.flashBall(position, WHITE, 9, 0.22)
		FX.impactStar(position, direction, color, 14, 10, 0.32)
		FX.facingRing(position, direction, color, 22, 0.45)
		task.delay(0.08, function()
			FX.facingRing(position, direction, WHITE, 14, 0.35)
		end)
		FX.shockSprite(position, color, 28, 0.5)
		FX.groundRing(floor + Vector3.new(0, 0.15, 0), color, 30, 0.6)
		FX.windBurst(position, color, 12, 12)
		FX.sparks(position, color, 50, 22, 40, 0.6, 0.45)
		FX.embers(position, color, 30)
		FX.dust(floor, 16)
		FX.lightBurst(position, color, 14, 30, 0.6)
		return
	end

	if kind == "crit" then
		FX.flashBall(position, Color3.fromRGB(255, 250, 230), 5, 0.16)
		FX.impactStar(position, direction, color, 10, 6.5, 0.24)
		FX.facingRing(position, direction, color, 12, 0.35)
		FX.shockSprite(position, color, 14, 0.35)
		FX.sparks(position, color, 30, 14, 30, 0.5, 0.3)
		FX.sparks(position, WHITE, 12, 18, 32, 0.3, 0.2)
		FX.windBurst(position, color, 8, 8)
		FX.lightBurst(position, color, 9, 18, 0.35)
		return
	end

	-- Golpe normal
	FX.impactStar(position, direction, color, 7, 4, 0.16)
	FX.flashBall(position, WHITE, 2.4, 0.12)
	if math.random() < 0.5 then
		FX.facingRing(position, direction, color, 8, 0.28)
	else
		FX.shockSprite(position, color, 9, 0.25)
	end
	FX.sparks(position, color, 16, 9, 18, 0.4, 0.28)
	FX.lightBurst(position, color, 5, 12, 0.2)
end

-- Destello del cuerpo al recibir un golpe
function FX.hitFlash(npc, color)
	if typeof(npc) ~= "Instance" or not npc.Parent then
		return
	end
	local flash = npc:FindFirstChild("HitFlashLocal")
	if not flash then
		flash = Instance.new("Highlight")
		flash.Name = "HitFlashLocal"
		flash.OutlineTransparency = 1
		flash.DepthMode = Enum.HighlightDepthMode.Occluded
		flash.Parent = npc
	end
	flash.FillColor = color or WHITE
	flash.FillTransparency = 0.2
	flash.Enabled = true
	tween(flash, 0.2, { FillTransparency = 1 })
	task.delay(0.22, function()
		if flash.Parent and flash.FillTransparency >= 0.99 then
			flash.Enabled = false
		end
	end)
end

-- Energía que se junta en el puño derecho antes del SÚPER
function FX.superCharge(npc, team, duration)
	if typeof(npc) ~= "Instance" then
		return
	end
	local hand = npc:FindFirstChild("RightHand")
	if not hand then
		return
	end
	duration = math.clamp(tonumber(duration) or 0.6, 0.2, 1.6)
	local color = Shared.teamColor(team)

	local ball = basePart(Enum.PartType.Ball)
	ball.Color = color
	ball.Transparency = 0.15
	ball.Size = Vector3.one * 0.4
	ball.Parent = folder
	local core = basePart(Enum.PartType.Ball)
	core.Color = WHITE
	core.Transparency = 0
	core.Size = Vector3.one * 0.2
	core.Parent = folder
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 0
	light.Parent = ball

	-- partículas que vienen desde una esfera grande hacia el puño
	local catcher = basePart(Enum.PartType.Ball)
	catcher.Transparency = 1
	catcher.Size = Vector3.one * 7
	catcher.Parent = folder
	local suck = Instance.new("ParticleEmitter")
	suck.Texture = TEX.spark
	suck.Color = ColorSequence.new(WHITE, color)
	suck.LightEmission = 1
	suck.Size = numberSeq(0.7, 0.1)
	suck.Transparency = numberSeq(0.2, 0)
	suck.Lifetime = NumberRange.new(0.3, 0.35)
	suck.Speed = NumberRange.new(10, 11)
	suck.Shape = Enum.ParticleEmitterShape.Sphere
	suck.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	suck.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	suck.Rate = 70
	suck.Parent = catcher

	local started = os.clock()
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local u = (os.clock() - started) / duration
		if u >= 1 or not hand.Parent then
			connection:Disconnect()
			suck.Enabled = false
			Debris:AddItem(catcher, 0.4)
			light.Brightness = 6
			tween(light, 0.3, { Brightness = 0 })
			tween(ball, 0.25, { Size = Vector3.one * 6, Transparency = 1 })
			tween(core, 0.2, { Size = Vector3.one * 3, Transparency = 1 })
			Debris:AddItem(ball, 0.35)
			Debris:AddItem(core, 0.3)
			return
		end
		local position = hand.Position
		local flicker = 1 + math.sin(os.clock() * 45) * 0.12
		local size = (0.4 + 1.6 * u) * flicker
		ball.Size = Vector3.one * size
		core.Size = Vector3.one * size * 0.5
		ball.CFrame = CFrame.new(position)
		core.CFrame = CFrame.new(position)
		catcher.CFrame = CFrame.new(position)
		light.Brightness = 1 + 4 * u
	end)
end

-- Explosión del K.O.: columna de luz, onda, estrellas y humo
function FX.koBlast(position, color)
	color = color or WHITE
	local floor = floorBelow(position)
	local pillar = basePart(Enum.PartType.Cylinder)
	pillar.Color = color
	pillar.Transparency = 0.1
	pillar.Size = Vector3.new(60, 6, 6)
	pillar.CFrame = CFrame.new(floor + Vector3.new(0, 30, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pillar.Parent = folder
	tween(pillar, 0.6, { Size = Vector3.new(70, 0.3, 0.3), Transparency = 1 }, Enum.EasingStyle.Quint)
	Debris:AddItem(pillar, 0.65)
	FX.shockSprite(position, color, 30, 0.55)
	FX.groundRing(floor + Vector3.new(0, 0.15, 0), color, 34, 0.7)
	task.delay(0.1, function()
		FX.groundRing(floor + Vector3.new(0, 0.2, 0), WHITE, 22, 0.5)
	end)
	FX.dust(floor, 20)
	burst(position + Vector3.new(0, 3, 0), 2.5, 24, {
		Texture = TEX.spark,
		Color = ColorSequence.new(Color3.fromRGB(255, 240, 120)),
		Size = numberSeq(1.4, 0),
		Transparency = numberSeq(0, 1),
		Lifetime = NumberRange.new(0.8, 1.4),
		Speed = NumberRange.new(10, 22),
		Acceleration = Vector3.new(0, -12, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-200, 200),
	})
end

-- ===== EXPLOSIONES DE EQUIPO (entrada y muerte) =====
function FX.teamBurst(position, team, scale)
	scale = scale or 1
	if team == "hero" then
		local anchor = anchorAt(position, 1.4)
		pointLight(anchor, Color3.fromRGB(255, 250, 200), 10 * scale, 18 * scale, 0.6)
		burst(position, 1.4, math.floor(32 * scale), {
			Texture = TEX.spark,
			Color = ColorSequence.new(Color3.fromRGB(255, 245, 180)),
			Size = numberSeq(1 * scale, 0),
			Transparency = numberSeq(0.1, 1),
			Lifetime = NumberRange.new(0.4, 0.8),
			Speed = NumberRange.new(10 * scale, 20 * scale),
			Rotation = NumberRange.new(0, 360),
		})
		FX.groundRing(position - Vector3.new(0, 2.5, 0), Color3.fromRGB(255, 245, 190), 12 * scale, 0.5)
	elseif team == "villain" then
		local anchor = anchorAt(position, 2.2)
		pointLight(anchor, Color3.fromRGB(150, 50, 200), 7 * scale, 16 * scale, 0.5)
		burst(position, 2.2, math.floor(28 * scale), {
			Texture = TEX.wisp,
			Color = ColorSequence.new(Color3.fromRGB(150, 50, 200), Color3.fromRGB(40, 5, 60)),
			Size = numberSeq(1.5 * scale, 4 * scale),
			Transparency = numberSeq(0.25, 1),
			Lifetime = NumberRange.new(0.9, 1.5),
			Speed = NumberRange.new(3 * scale, 8 * scale),
			Acceleration = Vector3.new(0, 5, 0),
			RotSpeed = NumberRange.new(-60, 60),
			LightEmission = 0.2,
		})
		FX.sparks(position, Color3.fromRGB(200, 110, 255), 20, 8, 16, 0.4, 0.4)
		FX.groundRing(position - Vector3.new(0, 2.5, 0), Color3.fromRGB(140, 50, 200), 12 * scale, 0.6, 0.3)
	else
		FX.lightBurst(position, Color3.fromRGB(150, 220, 255), 6, 14, 0.5)
	end
end

-- Rayo de luz que cae del cielo cuando alguien entra al ring
function FX.entranceBeam(position, team)
	local color = Shared.teamColor(team)
	local beam = basePart(Enum.PartType.Cylinder)
	beam.Color = color
	beam.Transparency = 0.15
	beam.Size = Vector3.new(120, 4, 4)
	beam.CFrame = CFrame.new(position + Vector3.new(0, 60, 0)) * CFrame.Angles(0, 0, math.rad(90))
	beam.Parent = folder
	tween(beam, 0.55, { Size = Vector3.new(120, 0.2, 0.2), Transparency = 1 }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	Debris:AddItem(beam, 0.6)
	FX.groundRing(position - Vector3.new(0, 2.8, 0), color, 16, 0.6)
	FX.dust(floorBelow(position), 10)
	FX.teamBurst(position, team, 1)
end

-- Columna de poder cuando un regalo potencia a alguien
function FX.boostPillar(position, team, level)
	level = level or 1
	local color = Shared.teamColor(team)
	local pillar = basePart(Enum.PartType.Cylinder)
	pillar.Color = color
	pillar.Transparency = 0.25
	pillar.Size = Vector3.new(40, 3 + level, 3 + level)
	pillar.CFrame = CFrame.new(position + Vector3.new(0, 18, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pillar.Parent = folder
	tween(pillar, 0.9, { Size = Vector3.new(40, 0.3, 0.3), Transparency = 1 })
	Debris:AddItem(pillar, 1)
	FX.groundRing(position - Vector3.new(0, 2.8, 0), color, 10 + level * 3, 0.7)
	FX.sparks(position, color, 20 + level * 8, 10, 22, 0.5, 0.6)
	burst(position, 2, 12 + level * 6, {
		Texture = if team == "villain" then TEX.soft else TEX.flame,
		Color = ColorSequence.new(WHITE, color),
		Size = numberSeq(2.5, 0.5),
		Transparency = numberSeq(0.2, 1),
		Lifetime = NumberRange.new(0.6, 1),
		Speed = NumberRange.new(8, 16),
		SpreadAngle = Vector2.new(25, 25),
		EmissionDirection = Enum.NormalId.Top,
	})
	FX.lightBurst(position, color, 6 + level * 2, 20, 0.9)
end

-- Partículas que suben (curación por likes, lluvia de corazones, seguidor)
function FX.healBurst(position, color, amount)
	burst(position, 2, amount or 14, {
		Texture = TEX.spark,
		Color = ColorSequence.new(color or Color3.fromRGB(255, 110, 180)),
		Size = numberSeq(0.8, 0),
		Transparency = numberSeq(0, 1),
		Lifetime = NumberRange.new(0.8, 1.3),
		Speed = NumberRange.new(3, 7),
		SpreadAngle = Vector2.new(35, 35),
		Acceleration = Vector3.new(0, 6, 0),
		LightEmission = 0.8,
	})
end

-- Confeti multicolor (victorias, rachas, metas)
function FX.confetti(position, count)
	count = count or 60
	local colors = {
		Color3.fromRGB(255, 80, 120),
		Color3.fromRGB(255, 220, 60),
		Color3.fromRGB(80, 200, 255),
		Color3.fromRGB(120, 255, 140),
		Color3.fromRGB(200, 120, 255),
	}
	local anchor = anchorAt(position, 4)
	for _, color in ipairs(colors) do
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new(0.35)
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(1.8, 2.8)
		emitter.Speed = NumberRange.new(22, 38)
		emitter.SpreadAngle = Vector2.new(40, 40)
		emitter.Acceleration = Vector3.new(0, -28, 0)
		emitter.Drag = 1.5
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-300, 300)
		emitter.Rate = 0
		emitter.Parent = anchor
		emitter:Emit(math.floor(count / #colors))
	end
end

-- Explosión del guante de la lluvia
function FX.gloveImpact(position, isGold, radius)
	local main = isGold and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(110, 30, 160)
	local ray = isGold and Color3.fromRGB(255, 255, 180) or Color3.fromRGB(200, 100, 255)
	FX.flashBall(position, main, radius * 2, 0.4)
	local column = basePart(Enum.PartType.Cylinder)
	column.Color = ray
	column.Size = Vector3.new(45, 1.8, 1.8)
	column.CFrame = CFrame.new(position + Vector3.new(0, 20, 0)) * CFrame.Angles(0, 0, math.rad(90))
	column.Parent = folder
	tween(column, 0.3, { Size = Vector3.new(50, 0, 0), Transparency = 1 })
	Debris:AddItem(column, 0.35)
	FX.groundRing(position, main, radius * 2.2, 0.45)
	FX.shockSprite(position, ray, radius * 2, 0.4)
	FX.sparks(position, ray, 30, 18, 35, 0.5, 0.3)
	FX.dust(position, 8)
	FX.lightBurst(position, main, 8, radius * 2, 0.4)
end

-- Marca pulsante en el piso donde va a caer algo
function FX.groundMarker(position, color, lifetime)
	local marker = basePart(Enum.PartType.Cylinder)
	marker.Color = color
	marker.Transparency = 0.55
	marker.Size = Vector3.new(0.15, 2, 2)
	marker.CFrame = CFrame.new(position + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90))
	marker.Parent = folder
	tween(marker, lifetime, { Size = Vector3.new(0.15, 9, 9) }, Enum.EasingStyle.Linear)
	TweenService:Create(
		marker,
		TweenInfo.new(0.25, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.15 }
	):Play()
	Debris:AddItem(marker, lifetime + 0.1)
end

-- Lluvia de partículas rosas sobre todo el ring (meta de likes)
function FX.heartRain(center, radius, duration)
	local cloud = basePart()
	cloud.Size = Vector3.new(radius * 2, 1, radius * 2)
	cloud.Transparency = 1
	cloud.CFrame = CFrame.new(center + Vector3.new(0, 32, 0))
	cloud.Parent = folder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 90, 160), Color3.fromRGB(255, 190, 220))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 0.4) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.85, 0.2), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(2.5, 3.2)
	emitter.Speed = NumberRange.new(6, 10)
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Acceleration = Vector3.new(0, -4, 0)
	emitter.LightEmission = 0.7
	emitter.Rate = 70
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.Parent = cloud
	task.delay(duration, function()
		emitter.Enabled = false
	end)
	Debris:AddItem(cloud, duration + 3.5)
end

-- Rayo eléctrico entre dos puntos (auras de nivel 3 y la entrada Definitiva)
function FX.bolt(from, to, color, width, duration)
	duration = duration or 0.16
	local length = (to - from).Magnitude
	local segments = math.clamp(math.floor(length / 3), 4, 16)
	local jitterSize = math.min(length * 0.06 + 0.8, 3)
	local points = { from }
	for i = 1, segments - 1 do
		local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * jitterSize
		table.insert(points, from:Lerp(to, i / segments) + jitter)
	end
	table.insert(points, to)
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local segment = basePart()
		segment.Color = color
		segment.Size = Vector3.new(width, width, (b - a).Magnitude + width)
		segment.CFrame = CFrame.lookAt((a + b) / 2, b)
		segment.Parent = folder
		tween(segment, duration, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		Debris:AddItem(segment, duration + 0.05)
	end
end

-- ===== ENTRADAS DE CINE =====

-- Nube de humo grande de la que sale el peleador Élite
function FX.smokeBurst(position, color, scale)
	scale = scale or 1
	color = color or Color3.fromRGB(60, 60, 70)
	burst(position, 3.5, math.floor(26 * scale), {
		Texture = TEX.soft,
		Color = ColorSequence.new(color, Color3.fromRGB(25, 25, 30)),
		Size = numberSeq(3 * scale, 8 * scale),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(0.6, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(1.6, 2.6),
		Speed = NumberRange.new(5 * scale, 13 * scale),
		Drag = 3,
		Acceleration = Vector3.new(0, 2.5, 0),
		LightEmission = 0,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-50, 50),
	})
	burst(position, 3, math.floor(14 * scale), {
		Texture = TEX.wisp,
		Color = ColorSequence.new(color, Color3.new(0, 0, 0)),
		Size = numberSeq(2 * scale, 5 * scale),
		Transparency = numberSeq(0.25, 1),
		Lifetime = NumberRange.new(1, 1.6),
		Speed = NumberRange.new(4, 9),
		Acceleration = Vector3.new(0, 6, 0),
		LightEmission = 0.2,
		Rotation = NumberRange.new(0, 360),
	})
	FX.sparks(position, color:Lerp(WHITE, 0.5), 16, 10, 20, 0.5, 0.4)
end

-- Bocanada de humo (pasos, estela del salto). glow = brilla con el color del equipo
function FX.smokePuff(position, color, scale, glow)
	scale = scale or 1
	burst(position, 1.6, 3, {
		Texture = TEX.soft,
		Color = ColorSequence.new(color or Color3.fromRGB(90, 90, 100)),
		Size = numberSeq(1.4 * scale, 3.2 * scale),
		Transparency = numberSeq(if glow then 0.45 else 0.35, 1),
		Lifetime = NumberRange.new(0.6, 1),
		Speed = NumberRange.new(1.5, 4),
		Drag = 2,
		LightEmission = if glow then 0.8 else 0,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
	})
end

-- Golpe al aire: anillo de viento delante del puño
function FX.airPunch(position, direction, color)
	FX.facingRing(position, direction, color or WHITE, 5, 0.22)
	FX.sparks(position, color or WHITE, 6, 6, 12, 0.3, 0.2)
end

-- Rayo que cae del cielo (aparición del Definitivo)
function FX.lightningStrike(position, color)
	color = color or WHITE
	local top = position + Vector3.new(math.random(-6, 6), 75, math.random(-6, 6))
	FX.bolt(top, position, WHITE, 1, 0.45)
	for _ = 1, 2 do
		FX.bolt(top + Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 6, position, color, 0.5, 0.35)
	end
	task.delay(0.12, function()
		FX.bolt(top, position, color, 0.7, 0.3) -- segundo destello
	end)
	FX.flashBall(position + Vector3.new(0, 2, 0), WHITE, 14, 0.3)
	FX.groundRing(position + Vector3.new(0, 0.2, 0), color, 26, 0.6)
	FX.shockSprite(position + Vector3.new(0, 3, 0), color, 24, 0.5)
	FX.lightBurst(position + Vector3.new(0, 4, 0), color, 16, 50, 0.8)
	FX.dust(position, 16)
	FX.sparks(position + Vector3.new(0, 1, 0), WHITE, 30, 14, 30, 0.6, 0.4)
end

-- Grietas brillantes que se abren en el piso
function FX.groundCrack(position, color, radius)
	radius = radius or 8
	color = color or WHITE
	local pieces = {}
	local count = 9
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + math.random() * 0.5
		local length = radius * (0.6 + math.random() * 0.5)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local bend = Vector3.new(-dir.Z, 0, dir.X) * (math.random() - 0.5) * 1.6
		local mid = position + dir * length * 0.5 + bend
		local tip = position + dir * length
		for _, segment in ipairs({ { position, mid }, { mid, tip } }) do
			local a, b = segment[1] + Vector3.new(0, 0.1, 0), segment[2] + Vector3.new(0, 0.1, 0)
			local glow = basePart()
			glow.Color = color
			glow.Size = Vector3.new(0.3, 0.06, (b - a).Magnitude)
			glow.CFrame = CFrame.lookAt((a + b) / 2, b)
			glow.Parent = folder
			local dark = basePart()
			dark.Material = Enum.Material.SmoothPlastic
			dark.Color = Color3.fromRGB(25, 20, 20)
			dark.Size = Vector3.new(0.9, 0.04, (b - a).Magnitude + 0.3)
			dark.CFrame = CFrame.lookAt((a + b) / 2 - Vector3.new(0, 0.02, 0), b - Vector3.new(0, 0.02, 0))
			dark.Parent = folder
			table.insert(pieces, glow)
			table.insert(pieces, dark)
		end
	end
	task.delay(2.4, function()
		for _, piece in ipairs(pieces) do
			if piece.Parent then
				tween(piece, 1, { Transparency = 1 })
			end
		end
	end)
	for _, piece in ipairs(pieces) do
		Debris:AddItem(piece, 3.6)
	end
end

-- Pedazos de piso que salen volando
function FX.debris(position, count)
	for _ = 1, count or 8 do
		local rock = Instance.new("Part")
		rock.Size = Vector3.one * (0.4 + math.random() * 0.7)
		rock.Material = Enum.Material.Slate
		rock.Color = Color3.fromRGB(125, 118, 110)
		rock.CanCollide = false
		rock.CanQuery = false
		rock.CanTouch = false
		rock.CastShadow = false
		rock.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
			* CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		rock.Parent = folder
		local angle = math.random() * math.pi * 2
		local spread = 10 + math.random() * 16
		rock.AssemblyLinearVelocity = Vector3.new(math.cos(angle) * spread, 22 + math.random() * 22, math.sin(angle) * spread)
		rock.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 20
		Debris:AddItem(rock, 1.6)
	end
end

-- Aterrizaje imponente: destello, ondas, polvo, escombros y luz
function FX.landingBlast(position, color, scale)
	scale = scale or 1
	color = color or WHITE
	FX.flashBall(position + Vector3.new(0, 1.5, 0), WHITE, 10 * scale, 0.25)
	FX.shockSprite(position + Vector3.new(0, 2, 0), color, 26 * scale, 0.5)
	FX.groundRing(position + Vector3.new(0, 0.15, 0), color, 30 * scale, 0.6)
	task.delay(0.08, function()
		FX.groundRing(position + Vector3.new(0, 0.2, 0), WHITE, 20 * scale, 0.45)
	end)
	task.delay(0.16, function()
		FX.groundRing(position + Vector3.new(0, 0.25, 0), color, 40 * scale, 0.8, 0.4)
	end)
	FX.dust(position, math.floor(18 * scale))
	FX.debris(position, math.floor(10 * scale))
	FX.sparks(position + Vector3.new(0, 1, 0), color, math.floor(30 * scale), 14, 30, 0.6, 0.4)
	FX.lightBurst(position + Vector3.new(0, 3, 0), color, 10 * scale, 30 * scale, 0.6)
end

-- ===== AURAS DE LOS PELEADORES =====
local auras = {} -- npc -> estado

local function auraTier(npc)
	if not npc:GetAttribute("Aura") then
		return 0
	end
	local health = (npc:GetAttribute("MaxHealth") or 100) / 100 - 1
	local damage = (npc:GetAttribute("DamageMultiplier") or 1) - 1
	local speed = (npc:GetAttribute("SpeedMultiplier") or 1) - 1
	local power = health + damage * 1.5 + speed
	if power >= 3 then
		return 3
	elseif power >= 1.2 then
		return 2
	end
	return 1
end

local function clearAura(state)
	for _, inst in ipairs(state.instances) do
		inst:Destroy()
	end
	table.clear(state.instances)
	state.disc, state.highlight = nil, nil
	state.runes, state.orbs, state.halo, state.fists = {}, {}, {}, {}
end

local function keep(state, inst)
	table.insert(state.instances, inst)
	return inst
end

local function emitterOn(state, parent, props)
	if not parent then
		return nil
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "AuraFX"
	for key, value in pairs(props) do
		emitter[key] = value
	end
	emitter.Parent = parent
	return keep(state, emitter)
end

local function buildAura(npc, state, tier, team, charged, streak)
	clearAura(state)
	if settingsFolder:GetAttribute("FighterAuras") == false then
		return
	end
	local color = Shared.teamColor(team)
	local info = Shared.TEAMS[team] or Shared.TEAMS.hero
	local isHero = team ~= "villain"
	local upper = npc:FindFirstChild("UpperTorso")
	local lower = npc:FindFirstChild("LowerTorso")

	-- Todos: disco de su equipo en el piso
	local disc = keep(state, basePart(Enum.PartType.Cylinder))
	disc.Color = color
	disc.Transparency = 0.6
	disc.Size = Vector3.new(0.1, 6.5, 6.5)
	disc.Parent = folder
	state.disc = disc

	if tier >= 1 then
		local highlight = keep(state, Instance.new("Highlight"))
		highlight.Name = "AuraLocal"
		highlight.FillColor = color
		highlight.OutlineColor = info.light
		highlight.FillTransparency = 0.85
		highlight.OutlineTransparency = 0.1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = npc
		state.highlight = highlight
		if isHero then
			emitterOn(state, upper, {
				Texture = TEX.spark,
				Color = ColorSequence.new(Color3.fromRGB(255, 250, 210), color),
				Size = numberSeq(0.9, 0),
				Transparency = numberSeq(0, 1),
				Lifetime = NumberRange.new(0.8, 1.3),
				Speed = NumberRange.new(2, 4),
				SpreadAngle = Vector2.new(180, 180),
				Acceleration = Vector3.new(0, 7, 0),
				LightEmission = 1,
				Rate = 10 + tier * 6,
				Rotation = NumberRange.new(0, 360),
			})
		else
			emitterOn(state, upper, {
				Texture = TEX.wisp,
				Color = ColorSequence.new(Color3.fromRGB(170, 70, 230), Color3.fromRGB(40, 0, 60)),
				Size = numberSeq(1.6, 3.4),
				Transparency = numberSeq(0.3, 1),
				Lifetime = NumberRange.new(0.9, 1.4),
				Speed = NumberRange.new(1, 2.5),
				SpreadAngle = Vector2.new(180, 180),
				Acceleration = Vector3.new(0, 4, 0),
				LightEmission = 0.25,
				Rate = 8 + tier * 4,
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-40, 40),
			})
		end
	end

	if tier >= 2 then
		emitterOn(state, lower, {
			Texture = if isHero then TEX.flame else TEX.soft,
			Color = ColorSequence.new(if isHero then Color3.fromRGB(255, 255, 220) else Color3.fromRGB(230, 120, 255), color),
			Size = numberSeq(2.6, 0.6),
			Transparency = numberSeq(if isHero then 0.15 else 0.35, 1),
			Lifetime = NumberRange.new(0.5, 0.8),
			Speed = NumberRange.new(4, 7),
			SpreadAngle = Vector2.new(30, 30),
			EmissionDirection = Enum.NormalId.Top,
			LightEmission = if isHero then 1 else 0.8,
			Rate = 22,
			Rotation = NumberRange.new(0, 360),
		})
		if upper then
			local light = keep(state, Instance.new("PointLight"))
			light.Color = color
			light.Brightness = 1.6
			light.Range = 14
			light.Shadows = false
			light.Parent = upper
		end
		for i = 1, 10 do
			local rune = keep(state, basePart())
			rune.Color = info.light
			rune.Transparency = 0.15
			rune.Size = Vector3.new(0.3, 0.12, 1.3)
			rune.Parent = folder
			state.runes[i] = rune
		end
	end

	if tier >= 3 then
		emitterOn(state, upper, {
			Texture = if isHero then TEX.flame else TEX.soft,
			Color = ColorSequence.new(if isHero then WHITE else Color3.fromRGB(220, 110, 255), if isHero then Color3.fromRGB(255, 140, 20) else Color3.fromRGB(90, 0, 150)),
			Size = numberSeq(5, 1.5),
			Transparency = numberSeq(if isHero then 0.25 else 0.4, 1),
			Lifetime = NumberRange.new(0.6, 0.9),
			Speed = NumberRange.new(4, 7),
			SpreadAngle = Vector2.new(20, 20),
			EmissionDirection = Enum.NormalId.Top,
			Acceleration = Vector3.new(0, 8, 0),
			LightEmission = if isHero then 1 else 0.85,
			Rate = 32,
			ZOffset = -1,
			Rotation = NumberRange.new(0, 360),
		})
		for i = 1, 3 do
			local orb = keep(state, basePart(Enum.PartType.Ball))
			orb.Color = info.light
			orb.Size = Vector3.one * 0.7
			orb.Parent = folder
			local trailA = Instance.new("Attachment")
			trailA.Position = Vector3.new(0, 0.3, 0)
			trailA.Parent = orb
			local trailB = Instance.new("Attachment")
			trailB.Position = Vector3.new(0, -0.3, 0)
			trailB.Parent = orb
			local trail = Instance.new("Trail")
			trail.Attachment0 = trailA
			trail.Attachment1 = trailB
			trail.Color = ColorSequence.new(info.light, color)
			trail.LightEmission = 1
			trail.Lifetime = 0.35
			trail.Transparency = numberSeq(0.2, 1)
			trail.FaceCamera = true
			trail.Parent = orb
			state.orbs[i] = orb
		end
		state.nextBolt = os.clock() + math.random()
	end

	if charged then
		for _, handName in ipairs({ "LeftHand", "RightHand" }) do
			local hand = npc:FindFirstChild(handName)
			if hand then
				emitterOn(state, hand, {
					Texture = TEX.spark,
					Color = ColorSequence.new(Color3.fromRGB(150, 240, 255), Color3.fromRGB(60, 160, 255)),
					Size = numberSeq(0.8, 0),
					Transparency = numberSeq(0, 1),
					Lifetime = NumberRange.new(0.2, 0.35),
					Speed = NumberRange.new(4, 9),
					SpreadAngle = Vector2.new(180, 180),
					LightEmission = 1,
					Rate = 30,
				})
				local glow = keep(state, basePart(Enum.PartType.Ball))
				glow.Color = Color3.fromRGB(130, 225, 255)
				glow.Transparency = 0.35
				glow.Size = Vector3.one * 1.2
				glow.Parent = folder
				state.fists[hand] = glow
			end
		end
	end

	if streak then
		for i = 1, 8 do
			local gem = keep(state, basePart(Enum.PartType.Ball))
			gem.Color = Color3.fromRGB(255, 215, 60)
			gem.Size = Vector3.one * 0.45
			gem.Parent = folder
			state.halo[i] = gem
		end
	end
end

local function trackAura(npc)
	if auras[npc] or not npc:IsA("Model") then
		return
	end
	auras[npc] = { instances = {}, runes = {}, orbs = {}, halo = {}, fists = {}, key = nil }
end

local function untrackAura(npc)
	local state = auras[npc]
	if state then
		auras[npc] = nil
		clearAura(state)
	end
end

activeFighters.ChildAdded:Connect(trackAura)
activeFighters.ChildRemoved:Connect(untrackAura)
for _, npc in ipairs(activeFighters:GetChildren()) do
	trackAura(npc)
end

-- Número fijo para cada pieza (si ApplyDescription cambia el torso, se rehace el aura)
local partIds = setmetatable({}, { __mode = "k" })
local nextPartId = 0
local function idOf(inst)
	if not inst then
		return "-"
	end
	if not partIds[inst] then
		nextPartId += 1
		partIds[inst] = nextPartId
	end
	return tostring(partIds[inst])
end

-- Revisa 4 veces por segundo si cambió algo (equipo, nivel, súper, racha, cuerpo nuevo)
task.spawn(function()
	while true do
		task.wait(0.25)
		local enabled = settingsFolder:GetAttribute("FighterAuras") ~= false
		for npc, state in pairs(auras) do
			local ok, err = pcall(function()
				local team = npc:GetAttribute("Team") or "hero"
				local tier = auraTier(npc)
				local charged = (npc:GetAttribute("Energy") or 0) >= 100
				local streak = (npc:GetAttribute("Streak") or 0) >= 3
				local upper = npc:FindFirstChild("UpperTorso")
				local key = table.concat({
					tostring(enabled), team, tostring(tier), tostring(charged), tostring(streak), idOf(upper),
				}, "|")
				if key ~= state.key then
					state.key = key
					buildAura(npc, state, tier, team, charged, streak)
				end
			end)
			if not ok then
				warn("⚠️ ArenaVFX aura: " .. tostring(err))
			end
		end
	end
end)

-- Cada fotograma: mueve los adornos de las auras con su peleador
RunService.RenderStepped:Connect(function()
	local now = os.clock()
	for npc, state in pairs(auras) do
		local root = npc:FindFirstChild("HumanoidRootPart")
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		if root and humanoid and state.disc then
			local floorY = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
			local base = Vector3.new(root.Position.X, floorY, root.Position.Z)
			state.disc.CFrame = CFrame.new(base + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90))
			state.disc.Transparency = 0.62 + 0.1 * math.sin(now * 3)

			local runeCount = #state.runes
			for i, rune in ipairs(state.runes) do
				local angle = now * 1.3 + (i / runeCount) * math.pi * 2
				local offset = Vector3.new(math.cos(angle) * 4.3, 0.2 + 0.08 * math.sin(now * 4 + i), math.sin(angle) * 4.3)
				rune.CFrame = CFrame.lookAt(base + offset, base + offset + Vector3.new(-math.sin(angle), 0, math.cos(angle)))
			end

			local torso = root.Position + Vector3.new(0, 1.2, 0)
			for i, orb in ipairs(state.orbs) do
				local angle = now * 2.6 + i * (math.pi * 2 / 3)
				orb.CFrame = CFrame.new(torso + Vector3.new(math.cos(angle) * 3.6, math.sin(now * 3 + i * 2) * 1.6, math.sin(angle) * 3.6))
			end

			if #state.halo > 0 then
				local head = npc:FindFirstChild("Head")
				if head then
					local top = head.Position + Vector3.new(0, head.Size.Y / 2 + 0.9, 0)
					for i, gem in ipairs(state.halo) do
						local angle = now * 2 + (i / #state.halo) * math.pi * 2
						gem.CFrame = CFrame.new(top + Vector3.new(math.cos(angle) * 1.5, 0.12 * math.sin(now * 5 + i), math.sin(angle) * 1.5))
					end
				end
			end

			for hand, glow in pairs(state.fists) do
				if hand.Parent then
					glow.CFrame = CFrame.new(hand.Position)
					glow.Size = Vector3.one * (1.1 + 0.25 * math.sin(now * 20))
				end
			end

			if state.highlight then
				state.highlight.FillTransparency = 0.82 + 0.08 * math.sin(now * 4)
				if next(state.fists) then
					state.highlight.OutlineColor = if math.sin(now * 18) > 0 then Color3.fromRGB(140, 235, 255) else WHITE
				end
			end

			if state.nextBolt and now >= state.nextBolt and #state.orbs > 0 then
				state.nextBolt = now + 0.25 + math.random() * 0.6
				local from = torso + Vector3.new(math.random() - 0.5, math.random() * 2 - 1, math.random() - 0.5) * 2
				local angle = math.random() * math.pi * 2
				local to = torso + Vector3.new(math.cos(angle) * 3.5, math.random() * 4 - 2, math.sin(angle) * 3.5)
				FX.bolt(from, to, Shared.TEAMS[npc:GetAttribute("Team") or "hero"].light, 0.12)
			end
		end
	end
end)

-- Evento solo de este cliente: EntranceCinematics pide aquí sus efectos con el
-- mismo reloj que mueve al peleador.
local localVfx = Instance.new("BindableEvent")
localVfx.Name = "LocalVfx"
localVfx.Parent = arena
localVfx.Event:Connect(function(name, ...)
	local fn = FX[name]
	if fn then
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("⚠️ ArenaVFX " .. tostring(name) .. ": " .. tostring(err))
		end
	end
end)

-- ===== AVISOS DEL SERVIDOR =====
fxEvent.OnClientEvent:Connect(function(kind, data)
	if kind ~= "vfx" or type(data) ~= "table" then
		return
	end
	local fn = FX[data.name]
	if not fn then
		return
	end
	local args = type(data.args) == "table" and data.args or {}
	local count = 0
	for index in pairs(args) do
		if type(index) == "number" and index > count then
			count = index
		end
	end
	for i = 1, count do
		if args[i] == NIL then
			args[i] = nil
		end
	end
	local ok, err = pcall(fn, table.unpack(args, 1, count))
	if not ok then
		warn("⚠️ ArenaVFX " .. tostring(data.name) .. ": " .. tostring(err))
	end
end)
