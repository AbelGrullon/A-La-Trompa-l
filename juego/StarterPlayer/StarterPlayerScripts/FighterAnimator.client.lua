-- FighterAnimator (LocalScript en StarterPlayerScripts)
-- Animaciones de pelea hechas por código, encima de las animaciones de Roblox,
-- para cada peleador del ring (misma técnica que RunnerAnimations de "A Correr"):
--   🥊 guardia de boxeador que rebota sobre las puntas y juego de pies en
--      cualquier dirección (adelante, atrás y de lado, sin "patinar")
--   👊 golpes: jab, directo, gancho, uppercut, gancho al cuerpo, combo 1-2 y
--      dos SÚPER (golpe cargado con estocada y uppercut del dragón girando)
--   💢 reacciones: golpe en la cara, gancho (la cabeza gira), uppercut (la
--      cabeza sale hacia arriba), al cuerpo (se dobla), bloqueo, esquiva,
--      mareo y celebración de victoria (3 estilos)
--   🌈 estelas de color en los puños durante los golpes
--   🥷 los que esperan rival hacen sombra (golpes al aire) mientras pasean
--
-- El servidor (ArenaManager) avisa por FxEvent:
--   "anim"    { target = npc, move = "jab" | "hurt" | "block" | ..., speed, heavy, side, duration }
--   "hitstop" { a = npc, b = npc, time } congela a los dos un instante en el impacto
-- y el atributo Mode del NPC dice qué está haciendo:
--   fight (peleando) | free (sin rival) | enter (entrando) | dance | celebrate
--
-- Cada fotograma (PreSimulation, justo después de que el Animator pone su pose)
-- mezclamos la nuestra en las articulaciones (AnimationConstraint o Motor6D).
-- Para pruebas: atributo DebugPose del NPC, p. ej. "jab:0.17", "hurtUp:0.08",
-- "superUpper:0.6", "victory:0.8:2" o "guard".

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local fxEvent = arena:WaitForChild("Remotes"):WaitForChild("FxEvent")
local settingsFolder = arena:WaitForChild("Settings")
local stateFolder = arena:WaitForChild("State")
local activeFighters = Workspace:WaitForChild("ActiveFighters")

-- ===== CONFIGURACIÓN =====
local BLEND_SPEED = 9 -- rapidez con la que entra y sale nuestra capa
local POSE_SMOOTH = 30 -- suavizado entre poses (más alto = más seco)
local STEP_LENGTH = 5 -- studs que avanza una zancada completa del juego de pies
local MAX_CADENCE = 2.6 -- zancadas por segundo como máximo
local BOUNCE_HZ = 1.7 -- rebote del boxeador sobre las puntas de los pies
local SCALE = 1.75 -- tamaño de los peleadores (los desplazamientos van en studs)
local SHADOW_MOVES = { "jab", "jab", "cross", "hook", "combo", "uppercut", "body" }

local JOINT_NAMES = {
	"Root", "Waist", "Neck", "LeftShoulder", "RightShoulder", "LeftElbow", "RightElbow",
	"LeftWrist", "RightWrist", "LeftHip", "RightHip", "LeftKnee", "RightKnee", "LeftAnkle", "RightAnkle",
}

local rad = math.rad

local function smooth01(u)
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

-- 0 → 1 entre a y b, se mantiene en 1 hasta c y vuelve a 0 en d
local function env(t, a, b, c, d)
	if t <= a or t >= d then
		return 0
	elseif t < b then
		return smooth01((t - a) / (b - a))
	elseif t <= c then
		return 1
	end
	return 1 - smooth01((t - c) / (d - c))
end

local function ramp(t, a, b)
	return smooth01((t - a) / (b - a))
end

-- ===== POSE DEL FOTOGRAMA (se arma capa por capa) =====
local pose = {} -- articulación -> Vector3 (grados X, Y, Z)
local rootMove = Vector3.zero -- desplazamiento de todo el cuerpo (studs)

local function add(name, x, y, z)
	local value = Vector3.new(x or 0, y or 0, z or 0)
	pose[name] = if pose[name] then pose[name] + value else value
end

-- Lleva una articulación hacia un ángulo fijo (k = 0..1 cuánto)
local function set(name, x, y, z, k)
	if k <= 0 then
		return
	end
	local current = pose[name] or Vector3.zero
	pose[name] = current:Lerp(Vector3.new(x, y, z), math.min(k, 1))
end

local function move(x, y, z)
	rootMove += Vector3.new(x, y, z) * SCALE
end

-- ===== GUARDIA Y JUEGO DE PIES =====

-- Guardia ortodoxa: pie izquierdo adelante, puños arriba, rebotando
local function guardLayer(k, t)
	local b = math.sin(t * math.pi * 2 * BOUNCE_HZ)
	local sway = math.sin(t * math.pi * BOUNCE_HZ + 1)
	add("Root", -5 * k, -16 * k, 0)
	add("Waist", 2 * sway * k, 8 * k + 3 * sway * k, 0)
	add("Neck", -6 * k, 8 * k - 3 * sway * k, 0)
	move(0, (-0.16 + 0.045 * b) * k, 0)
	add("LeftHip", (20 - 3 * b) * k, 0, -5 * k)
	add("LeftKnee", (-26 + 6 * b) * k)
	add("LeftAnkle", (6 - 3 * b) * k)
	add("RightHip", (-10 - 3 * b) * k, 0, 6 * k)
	add("RightKnee", (-30 + 6 * b) * k)
	add("RightAnkle", (22 - 3 * b) * k)
	add("LeftShoulder", (62 + 4 * b) * k, 0, 14 * k)
	add("LeftElbow", 115 * k)
	add("RightShoulder", (48 + 4 * b) * k, 0, -18 * k)
	add("RightElbow", 130 * k)
	add("LeftWrist", 0)
	add("RightWrist", 0)
end

-- Pasos cortos en la dirección en que se mueve (relativa a hacia donde mira)
local function footworkLayer(rig, k, forward, side, speed, dt)
	local amp = math.clamp(speed / 12, 0, 1) * k
	if amp < 0.02 then
		return
	end
	rig.phase = (rig.phase + dt * 2 * math.pi * math.min(speed / STEP_LENGTH, MAX_CADENCE)) % (2 * math.pi)
	local fShare = forward / math.max(speed, 0.01)
	local sShare = side / math.max(speed, 0.01)
	for _, leg in ipairs({ "Left", "Right" }) do
		local q = rig.phase + (if leg == "Left" then 0 else math.pi)
		local s = math.sin(q)
		add(leg .. "Hip", 26 * amp * fShare * s, 0, 12 * amp * sShare * s)
		add(leg .. "Knee", -38 * amp * math.max(0, math.sin(q + 1.3)))
		add(leg .. "Ankle", 10 * amp * math.sin(q - 0.5))
	end
	move(0, -0.05 * amp * math.cos(2 * rig.phase), 0)
	add("Root", -5 * amp * fShare, 0, -5 * amp * sShare)
	add("LeftShoulder", 4 * amp * math.sin(rig.phase))
	add("RightShoulder", -4 * amp * math.sin(rig.phase))
end

-- ===== GOLPES =====
-- Cada uno recibe t (segundos desde que empezó, ya ajustado a su velocidad) y
-- devuelve: giro extra de todo el cuerpo (o nil), qué puños dejan estela y si es súper.
local ATTACKS = {}

ATTACKS.jab = function(t)
	local e = env(t, 0.03, 0.15, 0.21, 0.42)
	set("LeftShoulder", 90, 0, 8, e)
	set("LeftElbow", 4, 0, 0, e)
	add("Waist", 0, -16 * e, 0)
	add("Root", -6 * e, -6 * e, 0)
	add("Neck", -4 * e, 18 * e, 0)
	add("RightShoulder", 6 * e)
	add("LeftKnee", -8 * e)
	move(0, -0.03 * e, -0.3 * e)
	return nil, { Left = t > 0.02 and t < 0.24 }
end

ATTACKS.cross = function(t)
	local load = env(t, 0, 0.08, 0.08, 0.16)
	local e = env(t, 0.08, 0.23, 0.3, 0.52)
	add("Waist", 0, -8 * load + 34 * e, 0)
	add("Root", -8 * e, 14 * e, 0)
	add("Neck", -4 * e, 8 * load - 38 * e, 0)
	set("RightShoulder", 90, 0, -10, e)
	set("RightElbow", 4, 0, 0, e)
	set("LeftShoulder", 58, 0, 24, e * 0.6)
	set("LeftElbow", 135, 0, 0, e * 0.6)
	add("RightHip", -8 * e)
	add("RightKnee", 10 * e)
	add("RightAnkle", 12 * e)
	add("LeftKnee", -10 * e)
	move(0, -0.04 * e, -0.45 * e)
	return nil, { Right = t > 0.05 and t < 0.32 }
end

ATTACKS.hook = function(t)
	local load = env(t, 0, 0.12, 0.12, 0.24)
	local e = env(t, 0.12, 0.29, 0.36, 0.62)
	local sweep = ramp(t, 0.12, 0.29)
	add("Waist", 0, -20 * load + 40 * e, 0)
	add("Root", -4 * e, -6 * load + 12 * e, 4 * load)
	add("Neck", 0, 20 * load - 45 * e, 0)
	set("RightShoulder", 35, 10, 55, load)
	set("RightElbow", 95, 0, 0, load)
	set("RightShoulder", 0, 10 + 42 * sweep, 85, e)
	set("RightElbow", 82, 0, 0, e)
	add("RightHip", -6 * e)
	add("RightAnkle", 15 * e)
	add("LeftKnee", -12 * load)
	move(0, -0.06 * load, -0.25 * e)
	return nil, { Right = t > 0.1 and t < 0.38 }
end

ATTACKS.uppercut = function(t)
	local load = env(t, 0, 0.14, 0.14, 0.3)
	local e = env(t, 0.14, 0.31, 0.38, 0.64)
	move(0, -0.28 * load + 0.12 * e, -0.15 * e)
	add("LeftHip", 22 * load)
	add("RightHip", 22 * load)
	add("LeftKnee", -40 * load)
	add("RightKnee", -40 * load)
	add("Root", -14 * load + 6 * e, -10 * load + 10 * e, 0)
	add("Waist", 0, -14 * load + 26 * e, -6 * load)
	add("Neck", 12 * load - 6 * e, 14 * load - 30 * e, 0)
	set("RightShoulder", 15, 0, -5, load)
	set("RightElbow", 105, 0, 0, load)
	set("RightShoulder", 100, 0, -12, e)
	set("RightElbow", 72, 0, 0, e)
	return nil, { Right = t > 0.1 and t < 0.38 }
end

ATTACKS.body = function(t)
	local load = env(t, 0, 0.1, 0.1, 0.22)
	local e = env(t, 0.1, 0.26, 0.33, 0.56)
	local dip = math.max(load, e)
	local sweep = ramp(t, 0.1, 0.26)
	move(0, -0.22 * dip, -0.2 * e)
	add("LeftHip", 24 * dip)
	add("RightHip", 18 * dip)
	add("LeftKnee", -38 * dip)
	add("RightKnee", -34 * dip)
	add("Root", -10 * dip, 0, -8 * dip)
	add("Waist", 0, 16 * load - 34 * e, 0)
	add("Neck", 8 * dip, -12 * load + 30 * e, 0)
	set("LeftShoulder", 20, 0, -40, load)
	set("LeftElbow", 90, 0, 0, load)
	set("LeftShoulder", 10, -(10 + 55 * sweep), -72, e)
	set("LeftElbow", 85, 0, 0, e)
	return nil, { Left = t > 0.08 and t < 0.35 }
end

ATTACKS.combo = function(t)
	local j = env(t, 0.02, 0.12, 0.15, 0.26)
	set("LeftShoulder", 90, 0, 8, j)
	set("LeftElbow", 4, 0, 0, j)
	add("Waist", 0, -14 * j, 0)
	add("Neck", 0, 14 * j, 0)
	local e = env(t, 0.22, 0.38, 0.45, 0.74)
	add("Waist", 0, 34 * e, 0)
	add("Root", -8 * e, 14 * e, 0)
	add("Neck", -4 * e, -38 * e, 0)
	set("RightShoulder", 90, 0, -10, e)
	set("RightElbow", 4, 0, 0, e)
	add("RightAnkle", 12 * e)
	move(0, -0.04 * math.max(j, e), -0.25 * j - 0.45 * e)
	return nil, { Left = t < 0.2, Right = t > 0.2 and t < 0.46 }
end

-- SÚPER 1: se carga temblando con el puño atrás y sale disparado en estocada
ATTACKS.superStraight = function(t)
	local load = env(t, 0, 0.4, 0.46, 0.6)
	local e = env(t, 0.46, 0.6, 0.78, 1.05)
	local shake = load * math.sin(t * 70) * 1.5
	move(0, -0.22 * load, 0.25 * load)
	add("Root", 4 * load + shake, -22 * load, 0)
	add("Waist", 0, -40 * load, 0)
	add("Neck", -6 * load, 50 * load, 0)
	add("LeftHip", 18 * load)
	add("RightHip", 10 * load)
	add("LeftKnee", -30 * load)
	add("RightKnee", -40 * load)
	set("RightShoulder", -30, 0, 12, load)
	set("RightElbow", 100, 0, 0, load)
	set("LeftShoulder", 80, 0, 10, load)
	set("LeftElbow", 25, 0, 0, load)
	move(0, -0.18 * e, -1 * e)
	add("Root", -14 * e, 16 * e, 0)
	add("Waist", 0, 40 * e, 0)
	add("Neck", 8 * e, -50 * e, 0)
	set("RightShoulder", 92, 0, -8, e)
	set("RightElbow", 0, 0, 0, e)
	set("LeftShoulder", -25, 0, -10, e)
	set("LeftElbow", 95, 0, 0, e)
	add("LeftHip", 38 * e)
	add("LeftKnee", -50 * e)
	add("RightHip", -28 * e)
	add("RightKnee", -4 * e)
	add("RightAnkle", 20 * e)
	return nil, { Right = t > 0.35 and t < 0.8 }, true
end

-- SÚPER 2: uppercut del dragón — se agacha cargando y sube girando con el puño al cielo
ATTACKS.superUpper = function(t)
	local load = env(t, 0, 0.38, 0.42, 0.55)
	local up = env(t, 0.42, 0.62, 0.72, 0.95)
	local land = env(t, 0.85, 0.92, 0.95, 1.15)
	local spin = ramp(t, 0.42, 0.8)
	local shake = load * math.sin(t * 70) * 1.5
	move(0, -0.5 * load - 0.25 * land + 0.9 * up, 0)
	add("LeftHip", 50 * load + 35 * land + 55 * up)
	add("RightHip", 45 * load + 35 * land + 10 * up)
	add("LeftKnee", -85 * load - 60 * land - 95 * up)
	add("RightKnee", -80 * load - 60 * land - 20 * up)
	add("Root", -22 * load + shake, -20 * load, 0)
	add("Waist", 0, -28 * load, 0)
	add("Neck", 25 * load + 20 * up, 30 * load, 0)
	set("RightShoulder", 0, 0, -8, load)
	set("RightElbow", 110, 0, 0, load)
	set("RightShoulder", 168, 0, -8, up)
	set("RightElbow", 12, 0, 0, up)
	set("LeftShoulder", 30, 0, -45, up)
	set("LeftElbow", 60, 0, 0, up)
	local extra = nil
	if spin > 0 and spin < 1 then
		extra = CFrame.Angles(0, -2 * math.pi * spin, 0)
	end
	return extra, { Right = t > 0.3 and t < 0.85, Left = t > 0.42 and t < 0.8 }, true
end

-- ===== REACCIONES =====
local REACTIONS = {}
local REACTION_TIME = {
	hurt = 0.42, hurtHeavy = 0.7, hurtSide = 0.52, hurtUp = 0.58, hurtBody = 0.58,
	block = 0.45, dodge = 0.45,
}

-- La guardia se abre con el golpe
local function openGuard(e)
	add("LeftShoulder", -25 * e, 0, -15 * e)
	add("RightShoulder", -25 * e, 0, 15 * e)
	add("LeftElbow", -40 * e)
	add("RightElbow", -40 * e)
end

-- Golpe en la cara: la cabeza sale hacia atrás (más fuerte en críticos)
REACTIONS.hurt = function(t, data)
	local h = if data.heavy then 1.7 else 1
	local e = env(t, 0, 0.05, 0.1, if data.heavy then 0.7 else 0.42)
	add("Neck", 26 * h * e, 8 * e, 0)
	add("Waist", 12 * h * e, 0, 0)
	add("Root", 8 * h * e, 0, 0)
	openGuard(e)
	add("LeftKnee", -8 * h * e)
	add("RightKnee", -10 * h * e)
	move(0, 0, 0.3 * h * e)
	if data.heavy then
		-- se tambalea
		local wobble = env(t, 0.1, 0.2, 0.45, 0.7) * math.sin(t * 22)
		add("Root", 0, 0, 7 * wobble)
		add("Neck", 0, 0, -9 * wobble)
	end
end

REACTIONS.hurtHeavy = function(t, data)
	REACTIONS.hurt(t, { heavy = true })
end

-- Gancho: la cabeza gira hacia un lado
REACTIONS.hurtSide = function(t, data)
	local h = if data.heavy then 1.5 else 1
	local e = env(t, 0, 0.05, 0.1, 0.52)
	add("Neck", 6 * e, -38 * h * e, -15 * h * e)
	add("Waist", 0, -16 * h * e, -6 * e)
	add("Root", 4 * e, -6 * e, -6 * h * e)
	openGuard(e)
	move(0.18 * h * e, 0, 0.12 * e)
end

-- Uppercut: la cabeza sale disparada hacia arriba
REACTIONS.hurtUp = function(t, data)
	local h = if data.heavy then 1.5 else 1
	local e = env(t, 0, 0.05, 0.12, 0.58)
	add("Neck", 45 * h * e)
	add("Waist", 14 * h * e)
	add("Root", 10 * h * e)
	openGuard(e * 1.2)
	add("LeftKnee", 12 * e)
	add("RightKnee", 12 * e)
	move(0, 0.25 * h * e, 0.2 * e)
end

-- Al cuerpo: se dobla y se tapa la panza
REACTIONS.hurtBody = function(t, data)
	local h = if data.heavy then 1.4 else 1
	local e = env(t, 0, 0.06, 0.16, 0.58)
	add("Waist", -28 * h * e)
	add("Root", -10 * e)
	add("Neck", 20 * e)
	set("LeftShoulder", 30, 0, 25, e)
	set("LeftElbow", 95, 0, 0, e)
	set("RightShoulder", 30, 0, -25, e)
	set("RightElbow", 95, 0, 0, e)
	add("LeftKnee", -15 * e)
	add("RightKnee", -15 * e)
	move(0, -0.15 * e, 0.25 * e)
end

-- Bloqueo: cierra la guardia y aguanta el empujón
REACTIONS.block = function(t)
	local e = env(t, 0, 0.05, 0.22, 0.45)
	local hit = env(t, 0.02, 0.06, 0.08, 0.2)
	set("LeftShoulder", 75, 0, 32, e)
	set("LeftElbow", 140, 0, 0, e)
	set("RightShoulder", 75, 0, -32, e)
	set("RightElbow", 140, 0, 0, e)
	add("Neck", -14 * e)
	add("Waist", -6 * e + 6 * hit)
	add("LeftKnee", -10 * e)
	add("RightKnee", -10 * e)
	move(0, -0.06 * e, 0.22 * e)
end

-- Esquiva: se agacha y se hace a un lado (slip)
REACTIONS.dodge = function(t, data)
	local e = env(t, 0, 0.08, 0.22, 0.45)
	local s = data.side or 1
	add("Root", -10 * e, 0, -20 * s * e)
	add("Waist", 0, 10 * s * e, -6 * s * e)
	add("Neck", 0, 0, 10 * s * e)
	add("LeftHip", 10 * e)
	add("RightHip", 10 * e)
	add("LeftKnee", -18 * e)
	add("RightKnee", -18 * e)
	move(0.4 * s * e, -0.18 * e, 0.1 * e)
end

-- Mareado: el cuerpo y la cabeza dan vueltecitas y baja la guardia
REACTIONS.stun = function(t, data)
	local duration = data.duration or 1.6
	local fade = env(t, 0, 0.15, duration - 0.25, duration)
	local w = t * 6
	add("Root", 7 * fade * math.cos(w), 0, 10 * fade * math.sin(w))
	add("Neck", 12 * fade * math.sin(w * 1.3), 15 * fade * math.cos(w), 14 * fade * math.sin(w))
	set("LeftShoulder", 10, 0, -12, fade * 0.8)
	set("LeftElbow", 25, 0, 0, fade * 0.8)
	set("RightShoulder", 10, 0, 12, fade * 0.8)
	set("RightElbow", 25, 0, 0, fade * 0.8)
	add("LeftKnee", -15 * fade)
	add("RightKnee", -10 * fade)
	move(0, -0.08 * fade, 0)
end

-- Victoria: brazos arriba saltando, posando con bíceps, o señalando al cielo
REACTIONS.victory = function(t, data, action)
	local duration = data.duration or 1.6
	local e = env(t, 0, 0.2, duration - 0.3, duration)
	local variant = data.variant or (action and action.variant) or 1
	if variant == 1 then
		local pump = math.sin(t * 9)
		set("LeftShoulder", 165 + 8 * pump, 0, -22, e)
		set("LeftElbow", 25 + 15 * pump, 0, 0, e)
		set("RightShoulder", 165 - 8 * pump, 0, 22, e)
		set("RightElbow", 25 - 15 * pump, 0, 0, e)
		add("Neck", 18 * e)
		add("Root", 6 * e)
		move(0, 0.12 * e * math.abs(math.sin(t * 4.5)), 0)
	elseif variant == 2 then
		set("LeftShoulder", 90, 0, -90, e)
		set("LeftElbow", 115, 0, 0, e)
		set("RightShoulder", 90, 0, 90, e)
		set("RightElbow", 115, 0, 0, e)
		add("Waist", 0, 15 * math.sin(t * 3) * e, 0)
		add("Neck", 8 * e)
		add("LeftHip", 0, 0, -10 * e)
		add("RightHip", 0, 0, 10 * e)
		add("LeftKnee", -15 * e)
		add("RightKnee", -15 * e)
		move(0, -0.08 * e, 0)
	else
		set("RightShoulder", 170, 0, 10, e)
		set("RightElbow", 0, 0, 0, e)
		set("LeftShoulder", 10, 0, -35, e)
		set("LeftElbow", 95, 0, 0, e)
		add("Root", 0, 12 * math.sin(t * 2.5) * e, 0)
		add("Neck", 15 * e)
	end
end

-- ===== ENTRADAS DE CINE (las dispara EntranceCinematics con el evento local LocalAnim) =====

-- Caminata amenazante con la guardia arriba (va en la capa "base": los golpes se suman encima)
REACTIONS.cineStalk = function(t, data)
	local duration = data.duration or 2
	local e = env(t, 0, 0.2, duration - 0.15, duration)
	local q = t * math.pi * 2 * 1.4
	guardLayer(e, t)
	for _, leg in ipairs({ "Left", "Right" }) do
		local p = q + (if leg == "Left" then 0 else math.pi)
		add(leg .. "Hip", 30 * e * math.sin(p))
		add(leg .. "Knee", -42 * e * math.max(0, math.sin(p + 1.3)))
		add(leg .. "Ankle", 10 * e * math.sin(p - 0.5))
	end
	add("Root", -4 * e, 8 * e * math.sin(q), 0)
	add("Waist", 0, -10 * e * math.sin(q), 0)
	move(0, -0.05 * e * math.cos(2 * q), 0)
end

-- Se agacha para tomar impulso con los brazos atrás
REACTIONS.cineCrouch = function(t, data)
	local duration = data.duration or 0.3
	local d = if data.deep then 1.3 else 1
	local e = env(t, 0, duration * 0.6, duration, duration + 1)
	move(0, -0.42 * d * e, 0.1 * e)
	add("Root", -22 * e)
	add("LeftHip", 48 * d * e)
	add("RightHip", 48 * d * e)
	add("LeftKnee", -85 * d * e)
	add("RightKnee", -85 * d * e)
	add("LeftAnkle", 22 * e)
	add("RightAnkle", 22 * e)
	set("LeftShoulder", -45, 0, -15, e)
	set("RightShoulder", -45, 0, 15, e)
	set("LeftElbow", 25, 0, 0, e)
	set("RightElbow", 25, 0, 0, e)
	add("Neck", 22 * e)
end

-- En el aire: despega estirado, se encoge (con mortal si data.flip) y baja las piernas para caer
REACTIONS.cineLeap = function(t, data)
	local duration = data.duration or 0.6
	local u = math.clamp(t / duration, 0, 1)
	local takeoff = 1 - ramp(u, 0, 0.25)
	local tuck = env(u, 0.1, 0.35, 0.65, 0.88)
	local reach = ramp(u, 0.75, 1)
	set("LeftShoulder", 160, 0, -15, takeoff)
	set("RightShoulder", 160, 0, 15, takeoff)
	add("LeftHip", -10 * takeoff)
	add("RightHip", -10 * takeoff)
	add("LeftHip", 80 * tuck)
	add("RightHip", 70 * tuck)
	add("LeftKnee", -110 * tuck)
	add("RightKnee", -100 * tuck)
	set("RightShoulder", 120, 0, -10, tuck)
	set("RightElbow", 20, 0, 0, tuck)
	set("LeftShoulder", -30, 0, -35, tuck)
	set("LeftElbow", 40, 0, 0, tuck)
	add("Waist", -10 * tuck)
	add("Neck", 10 * tuck)
	add("LeftHip", 25 * reach)
	add("RightHip", 15 * reach)
	add("LeftKnee", -35 * reach)
	add("RightKnee", -30 * reach)
	set("LeftShoulder", 40, 0, -55, reach)
	set("RightShoulder", 40, 0, 55, reach)
	local extra = nil
	if data.flip then
		local spin = ramp(u, 0.2, 0.75)
		if spin > 0 and spin < 1 then
			extra = CFrame.Angles(-2 * math.pi * spin, 0, 0)
		end
	end
	return extra, { Left = true, Right = true }, data.super == true
end

-- Cae flexionando todo el cuerpo
REACTIONS.cineLand = function(t, data)
	local duration = data.duration or 0.55
	local e = env(t, 0, 0.05, 0.15, duration)
	move(0, -0.5 * e, 0)
	add("Root", -25 * e)
	add("LeftHip", 55 * e)
	add("RightHip", 55 * e)
	add("LeftKnee", -95 * e)
	add("RightKnee", -95 * e)
	add("LeftAnkle", 25 * e)
	add("RightAnkle", 25 * e)
	set("LeftShoulder", 30, 0, -60, e)
	set("RightShoulder", 30, 0, 60, e)
	set("LeftElbow", 20, 0, 0, e)
	set("RightElbow", 20, 0, 0, e)
	add("Neck", 25 * e)
end

-- Aterrizaje de superhéroe: rodilla derecha y puño al piso, cabeza abajo; aguanta 'hold'
-- segundos y luego se levanta despacio en 'rise' (la cabeza sube primero, desafiante)
REACTIONS.superLand = function(t, data)
	local hold = data.hold or 1.5
	local rise = data.rise or 1
	local impact = env(t, 0, 0.04, 0.08, 0.3) -- rebote del golpe contra el piso
	local k = if t < hold then 1 else 1 - smooth01((t - hold) / rise)
	local head = if t < hold then 0 else smooth01((t - hold) / (rise * 0.6))
	move(0, (-0.8 - 0.12 * impact) * k, 0)
	add("Root", -32 * k)
	add("Waist", -8 * k)
	add("LeftHip", 117 * k, 0, -8 * k)
	add("LeftKnee", -85 * k)
	add("LeftAnkle", 10 * k)
	add("RightHip", 27 * k, 0, 6 * k)
	add("RightKnee", -85 * k)
	add("RightAnkle", 35 * k)
	set("RightShoulder", 50, 0, -8, k)
	set("RightElbow", 5, 0, 0, k)
	set("LeftShoulder", -40, 0, -30, k)
	set("LeftElbow", 25, 0, 0, k)
	add("Neck", (-10 + 40 * head) * k + 10 * head * (1 - k))
end

-- Rugido: brazos abiertos, pecho afuera, cabeza atrás temblando de poder
REACTIONS.cineRoar = function(t, data)
	local duration = data.duration or 1.4
	local e = env(t, 0, 0.25, duration - 0.3, duration)
	local shake = math.sin(t * 40) * 2 * env(t, 0.2, 0.3, duration - 0.4, duration - 0.2)
	set("LeftShoulder", 25, 0, -75, e)
	set("RightShoulder", 25, 0, 75, e)
	set("LeftElbow", 45, 0, 0, e)
	set("RightElbow", 45, 0, 0, e)
	add("Waist", 12 * e + shake * 0.5)
	add("Root", 4 * e)
	add("Neck", 28 * e + shake)
	add("LeftHip", 0, 0, -12 * e)
	add("RightHip", 0, 0, 12 * e)
	add("LeftKnee", -18 * e)
	add("RightKnee", -18 * e)
	move(0, -0.1 * e, 0)
end

-- Cargando poder: agachado, puños apretados a los costados, temblando
REACTIONS.powerUp = function(t, data)
	local duration = data.duration or 1.3
	local e = env(t, 0, 0.3, duration - 0.15, duration)
	local tremble = math.sin(t * 55) * 1.6 * e
	move(0, -0.18 * e, 0)
	add("Root", -10 * e + tremble, 0, tremble * 0.5)
	add("Waist", 6 * e)
	add("Neck", -12 * e)
	add("LeftHip", 22 * e, 0, -10 * e)
	add("RightHip", 22 * e, 0, 10 * e)
	add("LeftKnee", -40 * e)
	add("RightKnee", -40 * e)
	add("LeftAnkle", 12 * e)
	add("RightAnkle", 12 * e)
	set("LeftShoulder", -15, 0, -28, e)
	set("RightShoulder", -15, 0, 28, e)
	set("LeftElbow", 75, 0, 0, e)
	set("RightElbow", 75, 0, 0, e)
end

-- ===== PELEADORES =====
local rigs = {} -- npc -> estado

local function newRig(npc)
	local rig = {
		npc = npc,
		joints = {},
		smoothed = {},
		lastWritten = {},
		jw = {}, -- cuánto se ve nuestra pose en cada articulación (0..1)
		t = math.random() * 10, -- reloj propio (se congela en el impacto)
		phase = 0,
		freezeUntil = 0,
		slots = {}, -- attack | react | stun -> acción en curso
		nextShadow = os.clock() + 1 + math.random() * 2,
		trails = {},
		trailsOn = false,
	}
	local function scan(item)
		if (item:IsA("AnimationConstraint") or item:IsA("Motor6D")) and table.find(JOINT_NAMES, item.Name) then
			rig.joints[item.Name] = item
		end
	end
	for _, item in ipairs(npc:GetDescendants()) do
		scan(item)
	end
	rig.conn = npc.DescendantAdded:Connect(scan)
	return rig
end

-- ===== ESTELAS DE LOS PUÑOS =====
local function destroyTrails(rig)
	for _, entry in pairs(rig.trails) do
		entry.trail:Destroy()
		entry.a0:Destroy()
		entry.a1:Destroy()
	end
	table.clear(rig.trails)
end

local function ensureTrails(rig)
	for _, handName in ipairs({ "LeftHand", "RightHand" }) do
		local hand = rig.npc:FindFirstChild(handName)
		local entry = rig.trails[handName]
		if hand and hand:IsA("BasePart") and (not entry or entry.hand ~= hand or not entry.trail.Parent) then
			if entry then
				entry.trail:Destroy()
				entry.a0:Destroy()
				entry.a1:Destroy()
			end
			local a0 = Instance.new("Attachment")
			a0.Name = "PunchTrailTop"
			a0.Position = Vector3.new(0, 0.4, 0)
			a0.Parent = hand
			local a1 = Instance.new("Attachment")
			a1.Name = "PunchTrailBottom"
			a1.Position = Vector3.new(0, -0.4, 0)
			a1.Parent = hand
			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Lifetime = 0.16
			trail.MinLength = 0.05
			trail.LightEmission = 1
			trail.FaceCamera = true
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.05),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.WidthScale = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1.3),
				NumberSequenceKeypoint.new(1, 0),
			})
			trail.Enabled = false
			trail.Parent = hand
			rig.trails[handName] = { hand = hand, trail = trail, a0 = a0, a1 = a1 }
		end
	end
end

local function setTrails(rig, flags, super)
	local allowed = settingsFolder:GetAttribute("PunchTrails") ~= false
	for handName, entry in pairs(rig.trails) do
		local on = allowed and flags ~= nil and flags[string.gsub(handName, "Hand", "")] == true
		if on and not entry.trail.Enabled then
			local color = Shared.teamColor(rig.npc:GetAttribute("Team"))
			local tip = if super then Color3.fromRGB(120, 235, 255) else Color3.new(1, 1, 1)
			entry.trail.Color = ColorSequence.new(tip, color)
			entry.trail.Lifetime = if super then 0.3 else 0.16
		end
		if entry.trail.Enabled ~= on then
			entry.trail.Enabled = on
		end
	end
end

-- ===== ACCIONES =====
local function startAction(rig, slot, name, speed, data)
	local fn = ATTACKS[name] or REACTIONS[name]
	if not fn then
		return
	end
	local info = Shared.MOVES[name]
	local duration = (info and info.duration) or data.duration or REACTION_TIME[name] or 0.5
	if name == "hurt" and data.heavy then
		duration = REACTION_TIME.hurtHeavy
	end
	rig.slots[slot] = {
		fn = fn,
		name = name,
		start = rig.t,
		speed = math.max(speed or 1, 0.1),
		duration = duration,
		data = data,
		variant = math.random(1, 3),
	}
	ensureTrails(rig)
end

-- ===== MEZCLA CON LAS ANIMACIONES DE ROBLOX =====
local function rootPivot(rig)
	local joint = rig.joints.Root
	if not joint then
		return Vector3.new(0, 1.25 * SCALE, 0)
	end
	local offset
	if joint:IsA("AnimationConstraint") then
		offset = if joint.Attachment0 then joint.Attachment0.Position else Vector3.new(0, -1, 0)
	else
		offset = joint.C0.Position
	end
	return Vector3.new(0, 0.25 * SCALE, 0) - offset
end

local function apply(rig, dt, want, extraRoot)
	local blend = 1 - math.exp(-BLEND_SPEED * dt)
	local k = 1 - math.exp(-POSE_SMOOTH * dt)
	local pivot = nil
	for _, name in ipairs(JOINT_NAMES) do
		local joint = rig.joints[name]
		if joint and joint.Parent then
			local has = want > 0
				and (pose[name] ~= nil or (name == "Root" and (rootMove ~= Vector3.zero or extraRoot ~= nil)))
			local w = rig.jw[name] or 0
			w += ((if has then 1 else 0) - w) * blend
			if not has and w < 0.02 then
				-- ya no la usamos: la devolvemos a su sitio si el Animator no la tocó
				local last = rig.lastWritten[name]
				if last then
					if joint.Transform == last then
						joint.Transform = CFrame.identity
					end
					rig.lastWritten[name] = nil
				end
				rig.smoothed[name] = nil
				rig.jw[name] = 0
			else
				rig.jw[name] = w
				local current
				if has then
					local angles = pose[name] or Vector3.zero
					local target = CFrame.Angles(rad(angles.X), rad(angles.Y), rad(angles.Z))
					if name == "Root" then
						target = CFrame.new(rootMove) * target
					end
					current = if rig.smoothed[name] then rig.smoothed[name]:Lerp(target, k) else target
					rig.smoothed[name] = current
				else
					current = rig.smoothed[name] or CFrame.identity -- se desvanece desde la última pose
				end
				local final = current
				if name == "Root" and extraRoot and has then
					-- el giro va alrededor del centro del cuerpo; el desplazamiento no gira con él
					pivot = pivot or rootPivot(rig)
					local turn = current - current.Position
					final = CFrame.new(current.Position) * CFrame.new(pivot) * extraRoot * CFrame.new(-pivot) * turn
				end
				local base = joint.Transform
				if rig.lastWritten[name] and base == rig.lastWritten[name] then
					base = CFrame.identity -- el Animator no la movió en este fotograma
				end
				local written = if w > 0.995 then final else base:Lerp(final, w)
				joint.Transform = written
				rig.lastWritten[name] = written
			end
		end
	end
end

-- Pose fija para pruebas (atributo DebugPose del NPC)
local function debugPose(rig, text)
	local parts = string.split(text, ":")
	local name, at = parts[1], tonumber(parts[2]) or 0
	local withGuard = ATTACKS[name] ~= nil or name == "guard" or name == "block" or name == "dodge" or string.sub(name, 1, 4) == "hurt"
	guardLayer(if withGuard then 1 else 0, 0)
	local fn = ATTACKS[name] or REACTIONS[name]
	local extra, flags, super = nil, nil, nil
	if fn then
		extra, flags, super = fn(at, { duration = 2, side = 1, heavy = parts[3] == "heavy", hold = 1.5, rise = 1, flip = parts[3] == "flip" }, { variant = tonumber(parts[3]) or 1 })
	end
	ensureTrails(rig)
	setTrails(rig, flags, super)
	apply(rig, 1, 1, extra)
end

local SLOT_ORDER = { "base", "attack", "react", "stun" }

local function step(rig, dt, now)
	local npc = rig.npc
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	table.clear(pose)
	rootMove = Vector3.zero

	local debug = npc:GetAttribute("DebugPose")
	if typeof(debug) == "string" and debug ~= "" then
		debugPose(rig, debug)
		return
	end

	-- Durante una entrada de cine el resto del ring queda congelado (pausa)
	local cineTarget = stateFolder:GetAttribute("CinematicActive") == true and stateFolder:GetAttribute("CinematicTarget")
	local frozen = now < rig.freezeUntil or (cineTarget and npc.Name ~= cineTarget)
	local adt = if frozen then 0 else dt
	rig.t += adt

	local mode = npc:GetAttribute("Mode")
	local localVelocity = root.CFrame:VectorToObjectSpace(root.AssemblyLinearVelocity)
	local forward, side = -localVelocity.Z, localVelocity.X
	local speed = math.sqrt(forward * forward + side * side)
	local want = 0

	if mode == "fight" then
		guardLayer(1, rig.t)
		footworkLayer(rig, 1, forward, side, speed, adt)
		want = 1
	elseif mode == "free" and speed < 2.5 then
		guardLayer(0.85, rig.t)
		footworkLayer(rig, 0.8, forward, side, speed, adt)
		want = 1
		-- sombra: golpes al aire mientras espera rival
		if not frozen and not rig.slots.attack and now >= rig.nextShadow then
			rig.nextShadow = now + 1.4 + math.random() * 2.2
			startAction(rig, "attack", SHADOW_MOVES[math.random(1, #SHADOW_MOVES)], 0.9, { shadow = true })
		end
	end

	local extra, trailFlags, super = nil, nil, false
	for _, slot in ipairs(SLOT_ORDER) do
		local action = rig.slots[slot]
		if action then
			local at = (rig.t - action.start) * action.speed
			if at >= action.duration then
				rig.slots[slot] = nil
			else
				local x, flags, isSuper = action.fn(at, action.data, action)
				extra = extra or x
				if flags then
					trailFlags = flags
					super = super or isSuper == true
				end
				want = 1
			end
		end
	end

	setTrails(rig, trailFlags, super)
	apply(rig, dt, want, extra)
end

local function track(npc)
	if rigs[npc] or not npc:IsA("Model") then
		return
	end
	rigs[npc] = newRig(npc)
end

local function untrack(npc)
	local rig = rigs[npc]
	if not rig then
		return
	end
	rigs[npc] = nil
	rig.conn:Disconnect()
	for name, value in pairs(rig.lastWritten) do
		local joint = rig.joints[name]
		if joint and joint.Parent and joint.Transform == value then
			joint.Transform = CFrame.identity
		end
	end
	destroyTrails(rig)
end

activeFighters.ChildAdded:Connect(track)
activeFighters.ChildRemoved:Connect(untrack)
for _, npc in ipairs(activeFighters:GetChildren()) do
	track(npc)
end

-- Evento solo de este cliente: EntranceCinematics dispara aquí las poses de las
-- entradas de cine con el mismo reloj que mueve al peleador (sincronía perfecta).
local localAnim = Instance.new("BindableEvent")
localAnim.Name = "LocalAnim"
localAnim.Parent = arena
localAnim.Event:Connect(function(npc, name, data)
	local rig = npc and rigs[npc]
	if not rig then
		return
	end
	data = if type(data) == "table" then data else {}
	if ATTACKS[name] then
		startAction(rig, "attack", name, data.speed, data)
	elseif name == "cineStalk" then
		startAction(rig, "base", name, 1, data)
	elseif name == "stun" then
		startAction(rig, "stun", name, 1, data)
	elseif REACTIONS[name] then
		startAction(rig, "react", name, 1, data)
	end
end)

fxEvent.OnClientEvent:Connect(function(kind, data)
	if type(data) ~= "table" then
		return
	end
	if kind == "anim" then
		local rig = data.target and rigs[data.target]
		if not rig then
			return
		end
		local name = data.move
		if ATTACKS[name] then
			startAction(rig, "attack", name, data.speed, data)
		elseif name == "stun" then
			startAction(rig, "stun", name, 1, data)
		elseif REACTIONS[name] then
			startAction(rig, "react", name, 1, data)
		end
	elseif kind == "hitstop" then
		local untilTime = os.clock() + math.clamp(tonumber(data.time) or 0.06, 0, 0.3)
		for _, npc in ipairs({ data.a, data.b }) do
			local rig = npc and rigs[npc]
			if rig then
				rig.freezeUntil = untilTime
			end
		end
	end
end)

local lastWarn = 0

RunService.PreSimulation:Connect(function(dt)
	local now = os.clock()
	for npc, rig in pairs(rigs) do
		if npc.Parent ~= activeFighters then
			untrack(npc)
		else
			local ok, err = pcall(step, rig, dt, now)
			if not ok then
				if now - lastWarn > 3 then
					lastWarn = now
					warn("⚠️ FighterAnimator: " .. tostring(err))
				end
				rig.slots = {}
			end
		end
	end
end)
