-- Effects (ModuleScript) — efectos visuales 3D.
--
-- Los efectos de un solo uso (golpes, explosiones, anillos, rayos, confeti...)
-- los dibuja CADA CLIENTE en StarterPlayerScripts.ArenaVFX: así se animan a
-- 60 FPS y no a saltos como cuando el servidor anima piezas por la red.
-- Aquí solo se manda el aviso por FxEvent ("vfx", { name, args }).
--
-- En el servidor quedan los efectos pegados al peleador que necesitan
-- plantillas de ServerStorage (partículas de las manos) o que deben durar
-- (fuego de la furia, brillo de racha). Las auras de poder también las
-- dibuja el cliente a partir de los atributos del NPC (Aura, MaxHealth,
-- DamageMultiplier, SpeedMultiplier, Energy, Streak, Team).

local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Effects = {}

local Shared
local fxFolder
local fxEvent
local handTemplates = { hero = {}, villain = {} }

-- Los argumentos nil viajan como este texto (una tabla con huecos no se puede mandar por la red)
local NIL = "__nil"

local CLIENT_EFFECTS = {
	"sparks", -- (position, color, count, speedMin, speedMax, size, lifetime)
	"groundRing", -- (position, color, maxDiameter, duration, startTransparency)
	"facingRing", -- (position, direction, color, maxDiameter, duration)
	"windBurst", -- (position, color, lines, reach)
	"flashBall", -- (position, color, maxDiameter, duration)
	"lightBurst", -- (position, color, brightness, range, duration)
	"hit", -- (position, direction, team, kind) kind: normal | crit | special | block | dodge
	"teamBurst", -- (position, team, scale)
	"entranceBeam", -- (position, team)
	"boostPillar", -- (position, team, level)
	"healBurst", -- (position, color, amount)
	"confetti", -- (position, count)
	"gloveImpact", -- (position, isGold, radius)
	"groundMarker", -- (position, color, lifetime)
	"heartRain", -- (center, radius, duration)
	"hitFlash", -- (npc, color)
	"superCharge", -- (npc, team, duration) energía que se junta en el puño antes del SÚPER
	"koBlast", -- (position, color) explosión del K.O.
}

for _, name in ipairs(CLIENT_EFFECTS) do
	Effects[name] = function(...)
		if not fxEvent then
			return
		end
		local count = select("#", ...)
		local args = table.create(count)
		for i = 1, count do
			local value = select(i, ...)
			args[i] = if value == nil then NIL else value
		end
		fxEvent:FireAllClients("vfx", { name = name, args = args })
	end
end

function Effects.init(shared)
	Shared = shared
	fxEvent = ReplicatedStorage:WaitForChild("Arena"):WaitForChild("Remotes"):WaitForChild("FxEvent")
	fxFolder = Workspace:FindFirstChild("ArenaFX")
	if not fxFolder then
		fxFolder = Instance.new("Folder")
		fxFolder.Name = "ArenaFX"
		fxFolder.Parent = Workspace
	end
	for level = 1, 4 do
		handTemplates.hero[level] = ServerStorage:FindFirstChild("ParticulaAmarillaLVL" .. level)
		handTemplates.villain[level] = ServerStorage:FindFirstChild("ParticulaMoradaLVL" .. level)
	end
end

function Effects.folder()
	return fxFolder
end

-- ===== EFECTOS PEGADOS AL PELEADOR =====

-- Aura de poder: solo marca al NPC. El cliente (ArenaVFX) la dibuja según
-- lo fuerte que esté (vida, daño y velocidad extra) y el color de su equipo.
function Effects.teamAura(npc, _team)
	npc:SetAttribute("Aura", true)
end

local HAND_THRESHOLDS = { 0.25, 0.35, 0.45, 0.55 }

local function handLevel(damageMultiplier)
	local percent = (damageMultiplier or 1) - 1
	local level = 0
	for i, threshold in ipairs(HAND_THRESHOLDS) do
		if percent >= threshold - 0.001 then
			level = i
		end
	end
	return level
end

-- Partículas en las manos según el daño acumulado (plantillas de ServerStorage).
function Effects.handParticles(npc, team, damageMultiplier, force)
	local level = handLevel(damageMultiplier)
	if not force and level == (npc:GetAttribute("HandParticleLevel") or 0) then
		return
	end
	npc:SetAttribute("HandParticleLevel", level)
	for _, child in ipairs(npc:GetChildren()) do
		if child:GetAttribute("HandFX") then
			child:Destroy()
		end
	end
	if level == 0 then
		return
	end
	local template = handTemplates[team] and handTemplates[team][level]
	if not template then
		return
	end
	for _, handName in ipairs({ "LeftHand", "RightHand" }) do
		local hand = npc:FindFirstChild(handName)
		if hand then
			local particlePart = template:Clone()
			particlePart.Anchored = false
			particlePart.CanCollide = false
			particlePart.CanQuery = false
			particlePart.CanTouch = false
			particlePart.Massless = true
			particlePart.Transparency = 1
			particlePart.CFrame = hand.CFrame
			particlePart:SetAttribute("HandFX", true)
			particlePart.Parent = npc
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = particlePart
			weld.Parent = particlePart
		end
	end
end

-- Fuego en los puños durante el modo FURIA.
function Effects.furyHands(npc, duration)
	for _, handName in ipairs({ "LeftHand", "RightHand" }) do
		local hand = npc:FindFirstChild(handName)
		if hand and not hand:FindFirstChild("FuryFire") then
			local fire = Instance.new("Fire")
			fire.Name = "FuryFire"
			fire.Size = 3
			fire.Heat = 7
			fire.Color = Color3.fromRGB(255, 120, 30)
			fire.SecondaryColor = Color3.fromRGB(255, 40, 20)
			fire.Parent = hand
			Debris:AddItem(fire, duration)
		end
	end
end

-- Brillo dorado en la cabeza de quien lleva racha de victorias
-- (el cliente además le pone una corona de luz que gira).
function Effects.streakSparkles(npc, enabled)
	local head = npc:FindFirstChild("Head")
	if not head then
		return
	end
	local existing = head:FindFirstChild("StreakFX")
	if not enabled then
		if existing then
			existing:Destroy()
		end
		return
	end
	if existing then
		return
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "StreakFX"
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 215, 60), Color3.fromRGB(255, 255, 200))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	emitter.Lifetime = NumberRange.new(0.6, 1)
	emitter.Speed = NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 4, 0)
	emitter.LightEmission = 1
	emitter.Rate = 14
	emitter.Parent = head
end

-- K.O.: el cuerpo queda suelto (muñeco de trapo) gracias a las rótulas
-- (BallSocketConstraint) que ya trae el avatar R15 junto a sus AnimationConstraint.
function Effects.ragdoll(npc)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local root = npc:FindFirstChild("HumanoidRootPart")
	if root then
		local facing = root:FindFirstChild("Facing")
		if facing then
			facing:Destroy()
		end
	end
	if humanoid then
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end)
	end
	local hasSockets = false
	for _, item in ipairs(npc:GetDescendants()) do
		if item:IsA("BallSocketConstraint") then
			item.Enabled = true
			hasSockets = true
		end
	end
	if not hasSockets then
		return -- avatar sin rótulas: se queda con el empujón de siempre
	end
	for _, item in ipairs(npc:GetDescendants()) do
		if item:IsA("AnimationConstraint") and item.Name ~= "Root" then
			item.Enabled = false
		elseif item:IsA("BasePart") and item ~= root and item.Parent == npc and not item:GetAttribute("HandFX") then
			item.CanCollide = true
		end
	end
end

return Effects
