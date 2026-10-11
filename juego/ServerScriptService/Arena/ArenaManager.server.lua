-- ArenaManager (Script en ServerScriptService.Arena)
-- ¡A LA TROMPA! — arena automática para lives de TikTok.
--
-- Los espectadores del live NO usan su usuario de Roblox ni el chat: mandan
-- regalos, dan like o siguen, y el juego les crea un peleador con su nombre de
-- TikTok y un avatar asignado automáticamente. Todo llega por el bridge de Node
-- (Tikfinity). Los ÉLITE y DEFINITIVO entran al ring con una cinemática.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(script.Parent.Config)
local Audio = require(script.Parent.Audio)
local Effects = require(script.Parent.Effects)
local Environment = require(script.Parent.Environment)
local Avatars = require(script.Parent.Avatars)
local Bridge = require(script.Parent.Bridge)
local Online = require(script.Parent.Online) -- (modo online: un streamer por servidor)

local arenaShared = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arenaShared:WaitForChild("Shared"))
local remotes = arenaShared:WaitForChild("Remotes")
local hudEvent = remotes:WaitForChild("HudEvent")
local fxEvent = remotes:WaitForChild("FxEvent")
local devCommand = remotes:WaitForChild("DevCommand")
local settingsFolder = arenaShared:WaitForChild("Settings")
local stateFolder = arenaShared:WaitForChild("State")

local TEAMS = Shared.TEAMS

local ring = Workspace:WaitForChild("Ring")
local dummyTemplate = ServerStorage:WaitForChild("NPCDummy")
local spectatorsFolder = Workspace:WaitForChild("Espectadores")

local spectatorBlocks = {}
for _, child in ipairs(spectatorsFolder:GetChildren()) do
	if child:IsA("BasePart") then
		table.insert(spectatorBlocks, child)
	end
end

local function getOrCreateFolder(name)
	local folder = Workspace:FindFirstChild(name)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
	folder:ClearAllChildren()
	return folder
end

local activeFighters = getOrCreateFolder("ActiveFighters") -- en el ring
local waitingFolder = getOrCreateFolder("WaitingFighters") -- en las gradas, esperando turno

local SPAWN_POINTS = {}
for i = 1, 4 do
	table.insert(SPAWN_POINTS, ring:WaitForChild("SpawnA" .. i))
	table.insert(SPAWN_POINTS, ring:WaitForChild("SpawnB" .. i))
end

Audio.init(Config)
Effects.init(Shared)
Environment.init(SPAWN_POINTS)
Avatars.init(Config)
Bridge.init(Config, stateFolder)
Online.init({ Bridge = Bridge, Config = Config, hudEvent = hudEvent })

-- ===== ESTADO =====

local participants = {} -- userKey -> registro (en el ring o esperando)
local lineup = {} -- registros esperando turno, en orden
local sessionStats = {} -- userKey -> { name, team, wins, kos, bestStreak } (toda la sesión)
local teamWins = { hero = 0, villain = 0 }
local occupiedBlocks = {} -- bloque de grada -> registro
local busy = {} -- npc -> "entering" | "match" | "celebrate"
local fighterTracks = {} -- npc -> animaciones cargadas
local spectatorTracks = {} -- npc -> { idle, cheer }
local idleSince = {} -- npc -> os.clock() desde que está libre sin rival
local wanderState = {} -- npc -> paseo / baile de los que esperan rival
local furyUntil = 0
local cinematicUntil = 0 -- mientras dure una entrada de cine, el juego está en pausa
local totalLikes, likeProgress, likeGoalCount = 0, 0, 0
local viewers = 0
local queueDirty, scoreDirty, topDirty, likesDirty = true, true, true, true
local Battle = {} -- modo batalla (se rellena más abajo: ===== MODO BATALLA =====)

-- ===== AJUSTES EN VIVO =====

local settings = {}
for key, value in pairs(Shared.DEFAULT_SETTINGS) do
	settings[key] = value
	settingsFolder:SetAttribute(key, value)
end

local AUDIO_KEYS = { MusicEnabled = true, MusicVolume = true, SfxVolume = true, CrowdEnabled = true, CrowdVolume = true }
local ENVIRONMENT_KEYS = { LightingPreset = true, StageLights = true }

local function setSetting(key, value, persist)
	local ok, clean = Shared.sanitizeSetting(key, value)
	if not ok then
		return false
	end
	if settings[key] ~= clean then
		settings[key] = clean
		settingsFolder:SetAttribute(key, clean)
		if AUDIO_KEYS[key] then
			Audio.applySettings(settings)
		end
		if ENVIRONMENT_KEYS[key] then
			Environment.applySettings(settings)
		end
		if key == "LikeGoal" then
			likesDirty = true
		end
		if key == "GameMode" and Battle.onModeChanged then
			Battle.onModeChanged(clean)
		end
	end
	if persist then
		Bridge.saveSettings(settings)
	end
	return true
end

Audio.applySettings(settings)
Environment.applySettings(settings)

task.spawn(function()
	local saved = Bridge.loadSettings()
	if saved then
		for key, value in pairs(saved) do
			-- el mensaje viejo invitaba a escribir en el chat (ya no se usa): queda el nuevo
			local oldChatMessage = key == "Message" and type(value) == "string" and string.find(string.upper(value), "ESCRIBE", 1, true)
			if not oldChatMessage then
				setSetting(key, value, false)
			end
		end
		print("💾 Ajustes cargados desde el bridge")
	end
end)

-- ===== UTILIDADES =====

local function hud(kind, data)
	hudEvent:FireAllClients(kind, data)
end

local function fx(kind, data)
	fxEvent:FireAllClients(kind, data)
end

-- Texto flotante sobre un personaje (lo dibuja el cliente).
-- style: "rise" | "pop" | "shake" | "ko"
local function popup(target, text, color, size, style)
	if target and target.Parent then
		fx("popup", { target = target, text = text, color = color, size = size or 1, style = style or "rise" })
	end
end

local function cleanName(name, fallback)
	name = tostring(name or "")
	name = string.gsub(name, "%c", "")
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	if name == "" then
		name = tostring(fallback or "Anónimo")
	end
	local length = utf8.len(name)
	if not length then
		name = string.gsub(name, "[\128-\255]", "")
		if name == "" then
			name = "Anónimo"
		end
		length = #name
	end
	if length > 18 then
		name = string.sub(name, 1, utf8.offset(name, 18) - 1) .. "…"
	end
	return name
end

local function normalizeKey(user)
	local key = string.lower(tostring(user or ""))
	key = string.gsub(key, "[%c%s]", "")
	if key == "" then
		return nil
	end
	return string.sub(key, 1, 40)
end

local function isFury()
	return os.clock() < furyUntil
end

local function inCinematic()
	return os.clock() < cinematicUntil
end

local function arenaCenter()
	local center = Environment.getCenter()
	return center
end

local function fightersCenter()
	local sum, count = Vector3.zero, 0
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			sum += root.Position
			count += 1
		end
	end
	if count > 0 then
		return sum / count
	end
	return arenaCenter()
end

local function faceCenterCFrame(position)
	local center = arenaCenter()
	local flatTarget = Vector3.new(center.X, position.Y, center.Z)
	if (flatTarget - position).Magnitude < 0.1 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, flatTarget)
end

local function getStats(rec)
	local stats = sessionStats[rec.key]
	if not stats then
		stats = { name = rec.name, team = rec.team, wins = 0, kos = 0, bestStreak = 0 }
		sessionStats[rec.key] = stats
	end
	stats.name = rec.name
	stats.team = rec.team
	return stats
end

-- ===== PAYLOADS DEL HUD =====

local function countAlive()
	local alive = { hero = 0, villain = 0 }
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local team = npc:GetAttribute("Team")
		if alive[team] then
			alive[team] += 1
		end
	end
	return alive
end

local function queuePayload()
	local entries = {}
	for i = 1, math.min(8, #lineup) do
		local rec = lineup[i]
		table.insert(entries, {
			name = rec.name,
			team = rec.team,
			boosted = rec.maxHealth > Config.HEALTH_MAX or rec.damageMult > 1,
		})
	end
	return { entries = entries, total = #lineup }
end

local function scorePayload()
	local alive = countAlive()
	return {
		hero = teamWins.hero,
		villain = teamWins.villain,
		aliveHero = alive.hero,
		aliveVillain = alive.villain,
		waiting = #lineup,
	}
end

local function topPayload()
	local list = {}
	for _, stats in pairs(sessionStats) do
		if stats.wins > 0 then
			table.insert(list, stats)
		end
	end
	table.sort(list, function(a, b)
		if a.wins ~= b.wins then
			return a.wins > b.wins
		end
		return a.bestStreak > b.bestStreak
	end)
	local entries = {}
	for i = 1, math.min(5, #list) do
		entries[i] = { name = list[i].name, team = list[i].team, wins = list[i].wins, streak = list[i].bestStreak }
	end
	return { entries = entries }
end

local function likesPayload()
	return {
		total = totalLikes,
		progress = likeProgress,
		goal = settings.LikeGoal,
		nextEvent = (likeGoalCount % 2 == 0) and "MODO FURIA" or "LLUVIA DE CORAZONES",
	}
end

local function sendSnapshot(player)
	hudEvent:FireClient(player, "snapshot", {
		queue = queuePayload(),
		score = scorePayload(),
		top = topPayload(),
		likes = likesPayload(),
		viewers = viewers,
		battle = Battle.payload and Battle.payload() or nil,
	})
end

-- ===== ANIMACIONES =====

local function loadTrack(animator, animationId, looped, priority)
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	local track = animator:LoadAnimation(animation)
	track.Looped = looped
	if priority then
		track.Priority = priority
	end
	return track
end

local function loadFighterTracks(npc)
	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local animator = humanoid:WaitForChild("Animator")
	local tracks = {
		walk = loadTrack(animator, Config.WALK_ANIM_ID, true, Enum.AnimationPriority.Movement),
		idle = loadTrack(animator, Config.IDLE_ANIM_ID, true, Enum.AnimationPriority.Idle),
		cheer = loadTrack(animator, Config.CHEER_ANIM_ID, false, Enum.AnimationPriority.Action2),
		wave = loadTrack(animator, Config.WAVE_ANIM_ID, false, Enum.AnimationPriority.Action),
		dance = loadTrack(animator, Config.DANCE_ANIM_IDS[math.random(1, #Config.DANCE_ANIM_IDS)], true, Enum.AnimationPriority.Action),
	}
	-- (golpes, bloqueos, esquivas y reacciones los anima FighterAnimator en el cliente)
	fighterTracks[npc] = tracks
	return tracks
end

-- ===== CREACIÓN DE PERSONAJES =====

local function applySizeBoost(humanoid)
	for _, scaleName in ipairs({ "HeadScale", "BodyDepthScale", "BodyHeightScale", "BodyWidthScale" }) do
		local scaleValue = humanoid:FindFirstChild(scaleName)
		if scaleValue then
			scaleValue.Value = scaleValue.Value * Config.SIZE_MULTIPLIER
		end
	end
end

-- Crea el NPC y le pone los atributos (sin esperar). El avatar se aplica
-- después con dressNpc, que sí tarda un poco.
local function createNpc(rec, parent, cframe)
	local npc = dummyTemplate:Clone()
	npc.Name = rec.key
	npc:SetAttribute("UserKey", rec.key)
	npc:SetAttribute("DisplayName", rec.name)
	npc:SetAttribute("Team", rec.team)
	npc:SetAttribute("MaxHealth", rec.maxHealth)
	npc:SetAttribute("Health", rec.maxHealth)
	npc:SetAttribute("DamageMultiplier", rec.damageMult)
	npc:SetAttribute("SpeedMultiplier", rec.speedMult)
	npc:SetAttribute("Streak", rec.streak or 0)
	npc:PivotTo(cframe)
	npc.Parent = parent
	return npc
end

local function dressNpc(npc, rec)
	local humanoid = npc:WaitForChild("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	local ok = pcall(function()
		humanoid:ApplyDescription(Avatars.get(rec.key))
	end)
	-- (si el NPC ya no existe es normal: pasó de la grada al ring mientras se vestía)
	if not ok and npc.Parent then
		warn("No se pudo aplicar el avatar de " .. rec.name)
	end
	if npc.Parent then
		applySizeBoost(humanoid)
	end
	return humanoid
end

-- ===== GRADAS: gente esperando su turno =====

local function removeSpectatorNpc(rec)
	if rec.npc and rec.state == "waiting" then
		spectatorTracks[rec.npc] = nil
		if rec.npc.Parent then
			rec.npc:Destroy()
		end
		rec.npc = nil
	end
	if rec.block then
		if occupiedBlocks[rec.block] == rec then
			occupiedBlocks[rec.block] = nil
		end
		rec.block = nil
	end
end

local function spawnSpectator(rec, block)
	occupiedBlocks[block] = rec
	rec.block = block
	local npc = createNpc(rec, waitingFolder, faceCenterCFrame(block.Position + Vector3.new(0, 5, 0)))
	rec.npc = npc
	local humanoid = dressNpc(npc, rec)
	if rec.npc ~= npc or not npc.Parent or rec.state ~= "waiting" then
		if npc.Parent then
			npc:Destroy()
		end
		return
	end

	-- Parado y anclado sobre su bloque, mirando al ring
	local root = npc:FindFirstChild("HumanoidRootPart")
	if root then
		local height = humanoid.HipHeight + root.Size.Y / 2
		npc:PivotTo(faceCenterCFrame(block.Position + Vector3.new(0, block.Size.Y / 2 + height, 0)))
		root.Anchored = true
	end

	local animator = humanoid:WaitForChild("Animator")
	local tracks = {
		idle = loadTrack(animator, Config.SPECTATOR_ANIM_ID, true, Enum.AnimationPriority.Idle),
		cheer = loadTrack(animator, Config.CHEER_ANIM_ID, false, Enum.AnimationPriority.Action),
	}
	tracks.idle:Play()
	spectatorTracks[npc] = tracks
end

local function fillSpectators()
	local free = {}
	for _, block in ipairs(spectatorBlocks) do
		if not occupiedBlocks[block] then
			table.insert(free, block)
		end
	end
	for _, rec in ipairs(lineup) do
		if #free == 0 then
			break
		end
		if not rec.npc and not rec.block then
			local block = table.remove(free, math.random(1, #free))
			task.spawn(spawnSpectator, rec, block)
		end
	end
end

local function spectatorsCheer(amount)
	local list = {}
	for npc, tracks in pairs(spectatorTracks) do
		if npc.Parent then
			table.insert(list, tracks)
		end
	end
	for _ = 1, math.min(amount or 10, #list) do
		local tracks = table.remove(list, math.random(1, #list))
		task.delay(math.random() * 0.4, function()
			tracks.cheer:Play()
		end)
	end
end

-- ===== PARTICIPANTES =====

local function pickBalancedTeam()
	local counts = { hero = 0, villain = 0 }
	for _, rec in pairs(participants) do
		if counts[rec.team] then
			counts[rec.team] += 1
		end
	end
	if counts.hero == counts.villain then
		return math.random() < 0.5 and "hero" or "villain"
	end
	return counts.hero < counts.villain and "hero" or "villain"
end

-- Los que mandan regalos se saltan la fila (quedan detrás de otros donadores).
local function insertIntoLineup(rec, priority)
	if priority then
		rec.priority = true
		local position = 1
		for i, other in ipairs(lineup) do
			if other.priority and other ~= rec then
				position = i + 1
			else
				break
			end
		end
		table.insert(lineup, position, rec)
	else
		table.insert(lineup, rec)
	end
	queueDirty = true
end

local function addParticipant(key, name, team, boost, priority)
	local existing = participants[key]
	if existing then
		return existing, false
	end
	if #lineup >= Config.MAX_LINEUP and not priority then
		return nil, false
	end
	if team ~= "hero" and team ~= "villain" then
		team = pickBalancedTeam()
	end
	boost = boost or {}
	local rec = {
		key = key,
		name = name,
		team = team,
		state = "waiting",
		maxHealth = math.min(Config.MAX_HEALTH_CAP, Config.HEALTH_MAX * (1 + (boost.health or 0))),
		damageMult = math.min(Config.MAX_DAMAGE_MULT, 1 + (boost.damage or 0)),
		speedMult = math.min(Config.MAX_SPEED_MULT, 1 + (boost.speed or 0)),
		streak = 0,
	}
	participants[key] = rec
	insertIntoLineup(rec, priority)
	getStats(rec)
	scoreDirty = true
	hud("toast", { text = TEAMS[team].emoji .. " " .. name .. " se unió a los " .. TEAMS[team].name, team = team })
	return rec, true
end

local function switchTeam(rec, newTeam)
	if rec.team == newTeam or not TEAMS[newTeam] then
		return
	end
	rec.team = newTeam
	local npc = rec.npc
	if npc and npc.Parent then
		npc:SetAttribute("Team", newTeam)
		if rec.state == "ring" then
			if npc:GetAttribute("Aura") then
				Effects.teamAura(npc, newTeam)
			end
			Effects.handParticles(npc, newTeam, npc:GetAttribute("DamageMultiplier"), true)
		end
	end
	getStats(rec)
	queueDirty, scoreDirty = true, true
end

-- ===== PELEADORES EN EL RING =====

local function chooseSpawnPoint()
	local best, bestScore = SPAWN_POINTS[1], -math.huge
	for _, point in ipairs(SPAWN_POINTS) do
		local nearest = 200
		for _, npc in ipairs(activeFighters:GetChildren()) do
			local root = npc:FindFirstChild("HumanoidRootPart")
			if root then
				nearest = math.min(nearest, (root.Position - point.Position).Magnitude)
			end
		end
		local score = nearest + math.random() * 4
		if score > bestScore then
			best, bestScore = point, score
		end
	end
	return best
end

-- Estados del Humanoid que dejaban a los peleadores tirados o congelados
-- después de un empujón fuerte (tropiezo, sentado, trepar...).
local BLOCKED_STATES = {
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
}

-- Movimiento fluido: el Humanoid camina con MoveTo y un AlignOrientation lo
-- gira suave hacia donde debe mirar (nada de teletransportar su CFrame).
local function setupMover(humanoid, root)
	for _, state in ipairs(BLOCKED_STATES) do
		humanoid:SetStateEnabled(state, false)
	end
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = Config.FIGHT_WALK_SPEED
	local attachment = Instance.new("Attachment")
	attachment.Name = "FacingAttachment"
	attachment.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "Facing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.Responsiveness = 16
	align.MaxTorque = math.huge
	align.MaxAngularVelocity = math.huge
	align.CFrame = root.CFrame.Rotation
	align.Parent = root
end

local function releaseFighter(npc)
	fighterTracks[npc] = nil
	busy[npc] = nil
	idleSince[npc] = nil
	wanderState[npc] = nil
end

-- Crea el peleador en el ring y lo deja listo (avatar, física, animaciones y
-- efectos). anchored = nace anclado (lo usan las entradas de cine).
local function prepareFighter(rec, cframe, spawnY, anchored)
	rec.state = "ring"
	local npc = createNpc(rec, activeFighters, cframe)
	if anchored then
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			root.Anchored = true
		end
	end
	rec.npc = npc
	busy[npc] = "entering"
	npc:SetAttribute("Energy", 0)
	npc:SetAttribute("SpawnY", spawnY)
	npc:SetAttribute("FallStreak", 0)
	npc:SetAttribute("OpponentKey", "")
	npc:SetAttribute("Mode", "enter") -- enter | free | fight | dance | celebrate | cinematic (lo usa FighterAnimator)

	local humanoid = dressNpc(npc, rec)
	if rec.npc ~= npc or npc.Parent ~= activeFighters then
		releaseFighter(npc)
		if npc.Parent then
			npc:Destroy()
		end
		return nil
	end
	local root = npc:FindFirstChild("HumanoidRootPart")
	if root then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
		setupMover(humanoid, root)
	end

	local tracks = loadFighterTracks(npc)
	tracks.idle:Play()

	if rec.maxHealth > Config.HEALTH_MAX or rec.damageMult > 1 then
		Effects.teamAura(npc, rec.team)
	end
	Effects.handParticles(npc, rec.team, rec.damageMult, true)
	if isFury() then
		Effects.furyHands(npc, furyUntil - os.clock())
	end
	if (rec.streak or 0) >= 3 then
		Effects.streakSparkles(npc, true)
	end
	return npc, humanoid, root, tracks
end

-- Entrada normal: aparece desvaneciéndose, cae un rayo de luz y saluda
local function normalEntrance(rec)
	local spawnPart = chooseSpawnPoint()
	local npc, _, root, tracks = prepareFighter(rec, faceCenterCFrame(spawnPart.Position + Vector3.new(0, 4, 0)), spawnPart.Position.Y)
	if not npc then
		return nil
	end
	for _, part in ipairs(npc:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 then
			local target = part.Transparency
			part.Transparency = 1
			TweenService:Create(part, TweenInfo.new(0.45, Enum.EasingStyle.Quad), { Transparency = target }):Play()
		end
	end
	local position = root and root.Position or npc:GetPivot().Position
	Effects.entranceBeam(position, rec.team)
	Audio.play("Whoosh", { volume = 0.6, minInterval = 0.2 })
	tracks.wave:Play()
	hud("toast", { text = "⚡ " .. rec.name .. " ENTRÓ AL RING", team = rec.team, big = true })
	fx("focus", { target = npc, duration = 1.8, priority = 1, shot = "entrance" })
	queueDirty, scoreDirty = true, true

	task.delay(1.2, function()
		if busy[npc] == "entering" then
			busy[npc] = nil
		end
		if npc.Parent == activeFighters and npc:GetAttribute("Mode") == "enter" then
			npc:SetAttribute("Mode", "free")
		end
	end)
	return npc
end

-- ===== ENTRADAS DE CINE (Élite y Definitivo) =====
-- Mientras dura una, el juego queda en pausa (nadie camina ni pelea, no entra
-- nadie más y no caen lluvias) y la cámara de todos se va a la cinemática.
-- La coreografía la dibuja cada cliente (EntranceCinematics + FighterAnimator +
-- ArenaVFX + ArenaCamera): el servidor ancla al peleador, avisa con
-- FxEvent("cinematic"), pone los sonidos a tiempo y al final lo deja en su sitio.
-- Las duraciones y los tiempos de los sonidos deben coincidir con el cliente.
local CINEMATIC_DURATION = { elite = 6, definitive = 7.8 }
local CINEMATIC_SOUNDS = {
	elite = {
		{ 0.15, "Explosion", { volume = 0.45, pitch = 0.7 } },
		{ 0.85, "Whoosh", { volume = 0.4 } },
		{ 1.3, "Whoosh", { volume = 0.4, pitch = 1.1 } },
		{ 1.8, "Whoosh", { volume = 0.45 } },
		{ 2.25, "Whoosh", { volume = 0.5, pitch = 0.9 } },
		{ 2.85, "Whoosh", { volume = 0.6, pitch = 0.75 } },
		{ 3.45, "HeavyHit", { volume = 1, pitch = 0.8 } },
		{ 3.45, "Explosion", { volume = 0.4 } },
		{ 3.95, "Cheer", { volume = 0.7, group = "Crowd" } },
	},
	definitive = {
		{ 0.12, "Explosion", { volume = 0.9, pitch = 0.6 } },
		{ 0.2, "Gasp", { volume = 0.6, group = "Crowd" } },
		{ 0.4, "PowerUp", { volume = 0.7, pitch = 0.8 } },
		{ 1.9, "Whoosh", { volume = 0.8, pitch = 0.6 } },
		{ 3.7, "Explosion", { volume = 1, pitch = 0.7 } },
		{ 3.7, "HeavyHit", { volume = 1, pitch = 0.7 } },
		{ 6.3, "AirHorn", { volume = 0.6 } },
		{ 6.3, "Cheer", { volume = 0.8, group = "Crowd" } },
	},
}
local cinematicRunning = false
local pendingEntrances = 0 -- esperando su turno para la cinemática (cuentan como peleadores del ring)

local function entranceKind(rec)
	local level = rec.giftLevel or 0
	if level >= Config.DEFINITIVE_ENTRANCE_LEVEL then
		return "definitive"
	elseif level >= Config.ELITE_ENTRANCE_LEVEL then
		return "elite"
	end
	return nil
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local function groundRay(origin, direction)
	groundParams.FilterDescendantsInstances = { activeFighters, waitingFolder, Effects.folder(), spectatorsFolder }
	return Workspace:Raycast(origin, direction, groundParams)
end

-- Punto del piso del ring (el rayo sale por debajo de las cuerdas)
local function ringFloor(position)
	local _, floorY = Environment.getCenter()
	local hit = groundRay(Vector3.new(position.X, floorY + 2.5, position.Z), Vector3.new(0, -12, 0))
	return Vector3.new(position.X, if hit then hit.Position.Y else floorY, position.Z)
end

-- Punto en el suelo de AFUERA del ring, sin nada encima (de ahí salta el Definitivo)
local function outsidePoint()
	local center, floorY = Environment.getCenter()
	local angles = {}
	for i = 0, 15 do
		table.insert(angles, i * math.pi / 8)
	end
	for i = #angles, 2, -1 do
		local j = math.random(1, i)
		angles[i], angles[j] = angles[j], angles[i]
	end
	for _, angle in ipairs(angles) do
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		for _, distance in ipairs({ 50, 46, 55 }) do
			local p = center + dir * distance
			local hit = groundRay(Vector3.new(p.X, floorY + 60, p.Z), Vector3.new(0, -140, 0))
			if hit and hit.Position.Y < floorY - 8 and hit.Position.Y > floorY - 30 then
				local above = groundRay(hit.Position + Vector3.new(0, 0.5, 0), Vector3.new(0, 30, 0))
				if not above then
					return hit.Position
				end
			end
		end
	end
	return Vector3.new(center.X + 46, floorY - 14, center.Z)
end

local KIND_RANK = { elite = 1, definitive = 2 }

-- existing = NPC que ya está en el ring (mandó el regalo peleando): repite su entrada
local function runEntranceCinematic(rec, kind, existing)
	local center = arenaCenter()
	local spawnPart = chooseSpawnPoint()
	local npc, humanoid, root
	if existing then
		npc = existing
		humanoid = npc:FindFirstChildOfClass("Humanoid")
		root = npc:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root then
			return
		end
		root.Anchored = true
		if not busy[npc] then
			busy[npc] = "entering" -- que no lo emparejen mientras tanto
		end
	else
		-- nace escondido debajo del escenario mientras se viste
		local hidden = CFrame.new(spawnPart.Position + Vector3.new(0, -150, 0))
		npc, humanoid, root = prepareFighter(rec, hidden, spawnPart.Position.Y, true)
		if not npc or not root then
			return
		end
	end
	npc:SetAttribute("Mode", "cinematic")
	local rootHeight = humanoid.HipHeight + root.Size.Y / 2
	local data = {
		kind = kind,
		target = npc,
		team = rec.team,
		name = rec.name,
		rootHeight = rootHeight,
		duration = CINEMATIC_DURATION[kind],
	}
	if kind == "elite" then
		local start = ringFloor(spawnPart.Position)
		local toCenter = Vector3.new(center.X - start.X, 0, center.Z - start.Z)
		local distance = toCenter.Magnitude
		local dir = if distance > 0.1 then toCenter.Unit else Vector3.xAxis
		data.from = start
		data.mid = ringFloor(start + dir * math.min(9, distance * 0.35))
		data.to = ringFloor(start + dir * math.max(4, math.min(19, distance - 5)))
		data.facing = dir
	else
		local land = ringFloor(center + Vector3.new(math.random() * 8 - 4, 0, math.random() * 8 - 4))
		local out = outsidePoint()
		local flat = Vector3.new(land.X - out.X, 0, land.Z - out.Z)
		data.from = out
		data.to = land
		data.facing = if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis
	end
	local startPoint = data.from + Vector3.new(0, rootHeight, 0)
	local finalPoint = data.to + Vector3.new(0, rootHeight, 0)
	root.CFrame = CFrame.lookAt(startPoint, startPoint + data.facing)

	-- Pausa y aviso a los clientes
	cinematicUntil = os.clock() + data.duration + 0.5
	stateFolder:SetAttribute("CinematicTarget", npc.Name)
	stateFolder:SetAttribute("CinematicActive", true)
	for _, other in ipairs(activeFighters:GetChildren()) do
		local otherHumanoid = other ~= npc and other:FindFirstChildOfClass("Humanoid")
		local otherRoot = other:FindFirstChild("HumanoidRootPart")
		if otherHumanoid and otherRoot then
			otherHumanoid:MoveTo(otherRoot.Position)
		end
	end
	Audio.duck(data.duration)
	for _, sound in ipairs(CINEMATIC_SOUNDS[kind]) do
		task.delay(sound[1], function()
			local opts = table.clone(sound[3])
			opts.minInterval = 0
			Audio.play(sound[2], opts)
		end)
	end
	fx("cinematic", data)
	queueDirty, scoreDirty = true, true

	task.wait(data.duration)

	if npc.Parent == activeFighters and root.Parent then
		root.CFrame = CFrame.lookAt(finalPoint, finalPoint + data.facing)
		local align = root:FindFirstChild("Facing")
		if align then
			align.CFrame = CFrame.lookAt(Vector3.zero, data.facing)
		end
		root.Anchored = false
		npc:SetAttribute("SpawnY", data.to.Y)
		npc:SetAttribute("FallStreak", 0)
		npc:SetAttribute("Mode", if busy[npc] == "match" then "fight" else "free")
		if busy[npc] == "entering" then
			busy[npc] = nil
		end
		local tier = if kind == "definitive" then "DEFINITIVO" else "ÉLITE"
		hud("toast", {
			text = (if kind == "definitive" then "👑 " else "⚡ ") .. rec.name .. (if existing then " ¡AHORA ES " .. tier .. "!" else " ENTRÓ AL RING"),
			team = rec.team,
			big = true,
		})
	end
	stateFolder:SetAttribute("CinematicActive", false)
	cinematicUntil = os.clock() + 0.3
end

-- Entrada de cine para alguien que YA está en el ring (mandó un regalo Élite o
-- Definitivo mientras peleaba): sale y vuelve a entrar con su cinemática.
local function replayEntrance(rec, kind)
	while cinematicRunning do
		task.wait(0.2)
	end
	local npc = rec.npc
	if rec.state ~= "ring" or not npc or npc.Parent ~= activeFighters or npc:GetAttribute("KnockedOut") then
		return
	end
	cinematicRunning = true
	local ok, err = pcall(runEntranceCinematic, rec, kind, npc)
	cinematicRunning = false
	if not ok then
		warn("⚠️ Error en la entrada de cine de " .. tostring(rec.name) .. ": " .. tostring(err))
		stateFolder:SetAttribute("CinematicActive", false)
		cinematicUntil = 0
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root and npc.Parent == activeFighters then
			root.Anchored = false
			npc:SetAttribute("Mode", if busy[npc] == "match" then "fight" else "free")
			if busy[npc] == "entering" then
				busy[npc] = nil
			end
		end
	end
end

local function spawnFighter(rec)
	local kind = entranceKind(rec)
	if not kind then
		return normalEntrance(rec)
	end
	-- una cinemática a la vez: los demás esperan su turno
	rec.state = "entering"
	pendingEntrances += 1
	while cinematicRunning do
		task.wait(0.2)
	end
	cinematicRunning = true
	pendingEntrances -= 1
	rec.shownEntrance = kind
	local ok, err = pcall(runEntranceCinematic, rec, kind)
	cinematicRunning = false
	if not ok then
		warn("⚠️ Error en la entrada de cine de " .. tostring(rec.name) .. ": " .. tostring(err))
		stateFolder:SetAttribute("CinematicActive", false)
		cinematicUntil = 0
		local npc = rec.npc
		local root = npc and npc:FindFirstChild("HumanoidRootPart")
		if root and npc.Parent == activeFighters then
			-- algo falló: que entre normal en un punto del ring
			local spawnPart = chooseSpawnPoint()
			root.CFrame = faceCenterCFrame(spawnPart.Position + Vector3.new(0, 4, 0))
			root.Anchored = false
			npc:SetAttribute("Mode", "free")
			busy[npc] = nil
		end
	end
	return rec.npc
end

-- ===== CURACIÓN / BOOSTS =====

local function heal(npc, amount, text, color)
	local maxHealth = npc:GetAttribute("MaxHealth") or Config.HEALTH_MAX
	local health = npc:GetAttribute("Health") or maxHealth
	local newHealth = math.min(maxHealth, health + amount)
	npc:SetAttribute("Health", newHealth)
	if text then
		popup(npc, text, color or Color3.fromRGB(120, 255, 150), 1.1, "rise")
	end
	return newHealth - health
end

local function addEnergy(npc, amount)
	local energy = npc:GetAttribute("Energy") or 0
	if energy >= 100 then
		return
	end
	local newEnergy = math.min(100, energy + amount)
	npc:SetAttribute("Energy", newEnergy)
	if newEnergy >= 100 then
		popup(npc, "⚡ SÚPER LISTO", Color3.fromRGB(90, 225, 255), 0.9, "rise")
	end
end

-- Suma estadísticas a un registro (y a su NPC si existe). Devuelve lo ganado.
local function boostRecord(rec, healthPercent, damagePercent, speedPercent)
	local healthGain = math.min(Config.MAX_HEALTH_CAP - rec.maxHealth, Config.HEALTH_MAX * healthPercent)
	healthGain = math.max(0, healthGain)
	rec.maxHealth += healthGain
	rec.damageMult = math.min(Config.MAX_DAMAGE_MULT, rec.damageMult + damagePercent)
	rec.speedMult = math.min(Config.MAX_SPEED_MULT, rec.speedMult + speedPercent)

	local npc = rec.npc
	if npc and npc.Parent then
		npc:SetAttribute("MaxHealth", rec.maxHealth)
		npc:SetAttribute("DamageMultiplier", rec.damageMult)
		npc:SetAttribute("SpeedMultiplier", rec.speedMult)
		if rec.state == "ring" then
			local health = npc:GetAttribute("Health") or rec.maxHealth
			npc:SetAttribute("Health", math.min(rec.maxHealth, health + healthGain))
			if not npc:GetAttribute("Aura") then
				Effects.teamAura(npc, rec.team)
			end
			Effects.handParticles(npc, rec.team, rec.damageMult)
		else
			npc:SetAttribute("Health", rec.maxHealth)
		end
	end
	queueDirty = true
	return healthGain
end

-- ===== COMBATE =====

-- Mantiene un punto dentro del ring (para que el juego de pies no los saque).
local function clampToRing(position)
	local center = arenaCenter()
	local offset = Vector3.new(position.X - center.X, 0, position.Z - center.Z)
	local limit = Config.WANDER_RADIUS + 6
	if offset.Magnitude > limit then
		offset = offset.Unit * limit
	end
	return Vector3.new(center.X + offset.X, position.Y, center.Z + offset.Z)
end

-- Gira al peleador hacia un punto con suavidad (AlignOrientation, física del
-- servidor) en vez de teletransportar su CFrame: antes se veía a saltitos.
local function faceTowards(npc, targetPosition)
	local root = npc:FindFirstChild("HumanoidRootPart")
	local align = root and root:FindFirstChild("Facing")
	if not align then
		return
	end
	local flat = Vector3.new(targetPosition.X - root.Position.X, 0, targetPosition.Z - root.Position.Z)
	if flat.Magnitude > 0.05 then
		align.CFrame = CFrame.lookAt(Vector3.zero, flat)
	end
end

local function hasFallen(npc)
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root then
		return true
	end
	local spawnY = npc:GetAttribute("SpawnY") or root.Position.Y
	if root.Position.Y < spawnY - Config.FALL_MARGIN then
		local streak = (npc:GetAttribute("FallStreak") or 0) + 1
		npc:SetAttribute("FallStreak", streak)
		return streak >= Config.FALL_TICKS_REQUIRED
	end
	npc:SetAttribute("FallStreak", 0)
	return false
end

-- Velocidad de los golpes (regalos de velocidad y modo furia), con tope para que se vean
local function attackSpeed(npc)
	local speed = (npc:GetAttribute("SpeedMultiplier") or 1) * (isFury() and Config.FURY_SPEED_MULT or 1)
	return math.clamp(speed, 0.75, 1.7)
end

local function rollCooldown(npc)
	local base = Config.ATTACK_COOLDOWN_MIN + math.random() * (Config.ATTACK_COOLDOWN_MAX - Config.ATTACK_COOLDOWN_MIN)
	local speed = (npc:GetAttribute("SpeedMultiplier") or 1) * (isFury() and Config.FURY_SPEED_MULT or 1)
	return base / speed
end

-- Animación hecha por código en los clientes (StarterPlayerScripts.FighterAnimator)
local function anim(npc, move, data)
	data = data or {}
	data.target = npc
	data.move = move
	fx("anim", data)
end

local function stun(side)
	side.stunnedUntil = os.clock() + Config.STUN_DURATION
	fx("icon", { target = side.npc, image = Config.STUN_ICON_ID, duration = Config.STUN_DURATION, spin = true })
	anim(side.npc, "stun", { duration = Config.STUN_DURATION })
	Audio.play("Stun", { volume = 0.6, minInterval = 0.2 })
end

-- Cómo reacciona el que recibe, según el golpe
local function hurtMove(moveName, kind)
	if moveName == "uppercut" or moveName == "superUpper" then
		return "hurtUp"
	elseif moveName == "hook" then
		return "hurtSide"
	elseif moveName == "body" then
		return "hurtBody"
	end
	return kind == "normal" and "hurt" or "hurtHeavy"
end

local function resolveAttack(me, foe, special, moveName)
	if inCinematic() then
		return -- pausa por entrada de cine
	end
	local move = Shared.MOVES[moveName] or Shared.MOVES.cross
	local attacker, defender = me.npc, foe.npc
	local attackerRoot, defenderRoot = me.root, foe.root
	local offset = defenderRoot.Position - attackerRoot.Position
	if offset.Magnitude > Config.FIGHT_RANGE + 2 then
		return -- el rival se alejó: golpe al aire
	end
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local direction = flat.Magnitude > 0.01 and flat.Unit or attackerRoot.CFrame.LookVector
	local height = move.target == "body" and 0.5 or 2.6
	local impact = defenderRoot.Position - direction * 1.2 + Vector3.new(0, height, 0)
	local attackerTeam = attacker:GetAttribute("Team")
	local defenderStunned = os.clock() < foe.stunnedUntil

	if not defenderStunned then
		if math.random() < settings.DodgeChance * (special and 0.5 or 1) then
			local sideSign = math.random() < 0.5 and -1 or 1
			local side = direction:Cross(Vector3.yAxis) * sideSign
			foe.strafeTarget = clampToRing(defenderRoot.Position + side * 4.5)
			foe.strafeUntil = os.clock() + 0.45
			anim(defender, "dodge", { side = sideSign })
			popup(defender, "ESQUIVA", Color3.fromRGB(150, 230, 255), 1, "rise")
			Effects.hit(impact, direction, attackerTeam, "dodge")
			Audio.play("Whoosh", { volume = 0.35, pitch = 1.3, minInterval = 0.1 })
			addEnergy(defender, 5)
			return
		end
		if math.random() < settings.BlockChance * (special and 0.4 or 1) then
			anim(defender, "block")
			fx("hitstop", { a = attacker, b = defender, time = 0.05 })
			fx("icon", { target = defender, image = Config.BLOCKED_IMAGE_ID, duration = 0.6 })
			Effects.hit(impact, direction, attackerTeam, "block")
			Audio.play("Hits", { volume = 0.35, pitch = 1.35, minInterval = 0.06 })
			addEnergy(defender, Config.ENERGY_PER_BLOCK)
			pcall(function()
				defenderRoot:ApplyImpulse(direction * (special and 30 or 8) * defenderRoot.AssemblyMass)
			end)
			if not special then
				return
			end
			-- un SÚPER bloqueado igual hace un poco de daño
			local chip = math.max(1, math.floor(Config.DAMAGE_PER_HIT * (attacker:GetAttribute("DamageMultiplier") or 1) * settings.DamageScale * 0.6 + 0.5))
			defender:SetAttribute("Health", math.max(0, (defender:GetAttribute("Health") or 0) - chip))
			popup(defender, "-" .. chip, Color3.fromRGB(200, 200, 220), 0.9, "rise")
			return
		end
	end

	local crit = not special and math.random() < settings.CritChance
	local kind = special and "special" or (crit and "crit" or "normal")
	local multiplier = special and Config.SPECIAL_MULTIPLIER or (crit and Config.CRIT_MULTIPLIER or 1)
	local damage = Config.DAMAGE_PER_HIT
		* (attacker:GetAttribute("DamageMultiplier") or 1)
		* settings.DamageScale
		* multiplier
		* (isFury() and Config.FURY_DAMAGE_MULT or 1)
	damage = math.max(1, math.floor(damage + 0.5))
	defender:SetAttribute("Health", math.max(0, (defender:GetAttribute("Health") or 0) - damage))
	if not special then
		addEnergy(attacker, Config.ENERGY_PER_HIT)
	end

	-- Reacción del que recibe + un instante de "congelado" en el impacto (se siente el golpe)
	anim(defender, hurtMove(moveName, kind), { heavy = kind ~= "normal" })
	fx("hitstop", { a = attacker, b = defender, time = kind == "special" and 0.16 or (kind == "crit" and 0.1 or 0.06) })
	Effects.hit(impact, direction, attackerTeam, kind)
	Effects.hitFlash(defender, kind == "normal" and Color3.new(1, 1, 1) or Shared.teamColor(attackerTeam))

	-- Empujón (más fuerte en críticos y súper golpes)
	local push = kind == "special" and 55 or (kind == "crit" and 24 or 12)
	local lift = kind == "special" and 32 or (kind == "crit" and 8 or 0)
	if moveName == "uppercut" or moveName == "superUpper" then
		lift += kind == "normal" and 10 or 14
	end
	pcall(function()
		defenderRoot:ApplyImpulse((direction * push + Vector3.new(0, lift, 0)) * defenderRoot.AssemblyMass)
	end)

	if kind == "normal" then
		popup(defender, "-" .. damage, Color3.fromRGB(255, 90, 90), 1, "rise")
		fx("icon", { target = defender, image = Config.BOOM_IMAGE_ID, duration = 0.5 })
		Audio.play("Hits", { volume = 0.55, minInterval = 0.05 })
		fx("shake", { intensity = 0.14, position = impact })
	elseif kind == "crit" then
		popup(defender, "-" .. damage, Color3.fromRGB(255, 170, 40), 1.5, "shake")
		popup(defender, "¡CRÍTICO!", Color3.fromRGB(255, 205, 50), 1.3, "pop")
		Audio.play("HeavyHit", { volume = 0.7, minInterval = 0.1 })
		fx("shake", { intensity = 0.38, position = impact })
		if math.random() < Config.CRIT_STUN_CHANCE then
			stun(foe)
		end
	else
		popup(defender, "-" .. damage, Color3.fromRGB(90, 225, 255), 2, "shake")
		popup(defender, "¡SÚPER GOLPE!", Color3.fromRGB(90, 225, 255), 1.7, "pop")
		Audio.play("HeavyHit", { volume = 1, pitch = 0.85, minInterval = 0.1 })
		Audio.play("Explosion", { volume = 0.45, minInterval = 0.3 })
		fx("shake", { intensity = 0.8, position = impact })
		fx("flash", { color = Shared.teamColor(attackerTeam), intensity = 0.3 })
		fx("focus", { target = defender, duration = 1.4, priority = 2, shot = "impact" })
		Environment.flash(Shared.teamColor(attackerTeam), 0.5, 2)
		stun(foe)
	end
end

local function performAttack(me, foe)
	local attacker, defender = me.npc, foe.npc
	local special = (attacker:GetAttribute("Energy") or 0) >= 100
	local speed = attackSpeed(attacker)
	local moveName = Shared.pickMove(special, me.lastMove)
	local move = Shared.MOVES[moveName]
	local impactDelay = move.impact / speed
	me.lastMove = moveName
	me.attacking = true
	me.lungeUntil = os.clock() + impactDelay + 0.08

	if special then
		attacker:SetAttribute("Energy", 0)
		popup(attacker, "¡SÚPER!", Color3.fromRGB(90, 225, 255), 1.4, "pop")
		Effects.superCharge(attacker, attacker:GetAttribute("Team"), impactDelay)
		Audio.play("PowerUp", { volume = 0.45, pitch = 1.4, minInterval = 0.3 })
	end
	anim(attacker, moveName, { speed = speed })
	task.delay(impactDelay * (special and 0.65 or 0.4), function()
		Audio.play("Whoosh", { volume = special and 0.45 or 0.22, minInterval = 0.08, pitchVariance = 0.15 })
	end)

	task.delay(impactDelay, function()
		me.attacking = false
		if attacker.Parent ~= activeFighters or defender.Parent ~= activeFighters then
			return
		end
		if attacker:GetAttribute("KnockedOut") or defender:GetAttribute("KnockedOut") then
			return
		end
		resolveAttack(me, foe, special, moveName)
	end)
end

local function makeSide(npc)
	return {
		npc = npc,
		humanoid = npc:FindFirstChildOfClass("Humanoid"),
		root = npc:FindFirstChild("HumanoidRootPart"),
		tracks = fighterTracks[npc],
		stunnedUntil = 0,
		nextAttack = os.clock() + 0.6 + math.random() * 0.8,
		nextFootwork = 0,
		orbitDir = math.random() < 0.5 and -1 or 1,
		orbitStep = 10,
		wantDistance = Config.FOOTWORK_MAX,
		lungeUntil = 0,
		strafeUntil = 0,
		strafeTarget = nil,
		attacking = false,
		lastMove = nil,
	}
end

local function isDown(side)
	local npc = side.npc
	return npc.Parent ~= activeFighters
		or npc:GetAttribute("KnockedOut") == true
		or (npc:GetAttribute("Health") or 0) <= 0
		or not side.root
		or not side.root.Parent
		or hasFallen(npc)
end

-- Camina hacia un punto (dentro del ring) a la velocidad dada
local function walkTo(side, position, speed)
	local mult = math.sqrt(side.npc:GetAttribute("SpeedMultiplier") or 1) * (isFury() and 1.1 or 1)
	side.humanoid.WalkSpeed = speed * mult
	side.humanoid:MoveTo(clampToRing(Vector3.new(position.X, side.root.Position.Y, position.Z)))
end

local function stepSide(me, foe, distance)
	local now = os.clock()
	local root, foeRoot = me.root, foe.root
	faceTowards(me.npc, foeRoot.Position)

	if now < me.stunnedUntil then
		-- mareado: se queda donde está (el tambaleo lo anima el cliente)
		walkTo(me, root.Position, Config.FIGHT_WALK_SPEED)
		return
	end

	local offset = root.Position - foeRoot.Position
	local away = Vector3.new(offset.X, 0, offset.Z)
	away = away.Magnitude > 0.1 and away.Unit or Vector3.xAxis

	if now < me.strafeUntil and me.strafeTarget then
		-- esquiva: paso rápido al costado
		walkTo(me, me.strafeTarget, Config.LUNGE_WALK_SPEED)
	elseif now < me.lungeUntil then
		-- paso al frente para que el puño llegue a la cara del rival
		walkTo(me, foeRoot.Position + away * Config.LUNGE_DISTANCE, Config.LUNGE_WALK_SPEED)
	elseif distance > Config.FIGHT_RANGE then
		walkTo(me, foeRoot.Position + away * Config.FOOTWORK_MIN, Config.APPROACH_WALK_SPEED)
	else
		-- Juego de pies: giran alrededor del rival, entrando y saliendo de distancia
		if now >= me.nextFootwork then
			me.nextFootwork = now + 0.7 + math.random() * 1.3
			if math.random() < 0.3 then
				me.orbitDir = -me.orbitDir
			end
			me.orbitStep = ({ 0, 8, 12, 16 })[math.random(1, 4)]
			me.wantDistance = Config.FOOTWORK_MIN + math.random() * (Config.FOOTWORK_MAX - Config.FOOTWORK_MIN)
		end
		local angle = math.atan2(away.Z, away.X) + me.orbitDir * math.rad(me.orbitStep)
		local target = foeRoot.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * me.wantDistance
		walkTo(me, target, Config.FIGHT_WALK_SPEED)
	end

	if now >= me.nextAttack and not me.attacking and distance <= Config.FIGHT_RANGE then
		performAttack(me, foe)
		me.nextAttack = now + rollCooldown(me.npc)
	end
end

local function runCombat(npcA, npcB)
	local a, b = makeSide(npcA), makeSide(npcB)
	if not (a.tracks and b.tracks and a.root and b.root and a.humanoid and b.humanoid) then
		return nil, nil
	end
	a.tracks.dance:Stop(0.2)
	b.tracks.dance:Stop(0.2)
	local startedAt = os.clock()

	while true do
		task.wait(0.1)
		if inCinematic() then
			-- pausa por entrada de cine: quietos, sin golpes y el reloj del duelo no corre
			startedAt += 0.1
			for _, side in ipairs({ a, b }) do
				if side.root and side.root.Parent then
					side.humanoid:MoveTo(side.root.Position)
				end
				side.nextAttack = math.max(side.nextAttack, os.clock() + 0.5 + math.random() * 0.6)
				side.lungeUntil = 0
				side.strafeUntil = 0
				if side.stunnedUntil > os.clock() then
					side.stunnedUntil += 0.1
				end
			end
			continue
		end
		if isDown(a) then
			return npcB, npcA
		end
		if isDown(b) then
			return npcA, npcB
		end
		if os.clock() - startedAt > Config.MATCH_TIMEOUT then
			local ratioA = npcA:GetAttribute("Health") / npcA:GetAttribute("MaxHealth")
			local ratioB = npcB:GetAttribute("Health") / npcB:GetAttribute("MaxHealth")
			if ratioA >= ratioB then
				return npcA, npcB
			end
			return npcB, npcA
		end
		local distance = (a.root.Position - b.root.Position).Magnitude
		stepSide(a, b, distance)
		stepSide(b, a, distance)
	end
end

-- Caminar / quieto según la velocidad REAL del peleador (no la intención) y con
-- el ciclo de pasos ajustado a esa velocidad: así no patina ni parpadea.
local function updateLocomotion()
	for npc, tracks in pairs(fighterTracks) do
		local root = npc.Parent and npc:FindFirstChild("HumanoidRootPart")
		if root and not tracks.dance.IsPlaying and not tracks.wave.IsPlaying then
			local velocity = root.AssemblyLinearVelocity
			local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
			if speed > 2 then
				if not tracks.walk.IsPlaying then
					tracks.idle:Stop(0.25)
					tracks.walk:Play(0.25)
				end
				tracks.walk:AdjustSpeed(math.clamp(speed / 20, 0.45, 1.6))
			elseif speed < 0.8 and tracks.walk.IsPlaying then
				tracks.walk:Stop(0.3)
				tracks.idle:Play(0.3)
			elseif not tracks.walk.IsPlaying and not tracks.idle.IsPlaying then
				tracks.idle:Play(0.3)
			end
		end
	end
end

-- ===== K.O. Y VICTORIA =====

local function knockOut(loser, winner, cause, byName)
	if not loser or loser:GetAttribute("KnockedOut") then
		return
	end
	loser:SetAttribute("KnockedOut", true)
	loser:SetAttribute("Health", 0)
	local key = loser:GetAttribute("UserKey")
	local rec = participants[key]
	if rec and rec.npc == loser then
		participants[key] = nil
		rec.state = "dead"
	end
	releaseFighter(loser)

	local root = loser:FindFirstChild("HumanoidRootPart")
	local position = root and root.Position or loser:GetPivot().Position
	local loserTeam = loser:GetAttribute("Team")
	local loserName = loser:GetAttribute("DisplayName") or loser.Name
	local winnerTeam = winner and winner:GetAttribute("Team") or Shared.otherTeam(loserTeam)
	local winnerColor = Shared.teamColor(winnerTeam)

	-- Deja de contar como peleador activo al instante
	loser.Parent = Effects.folder()

	local humanoid = loser:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local animator = humanoid:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0.1)
			end
		end
	end
	-- Muñeco de trapo: sale volando con brazos y piernas sueltos
	Effects.ragdoll(loser)
	if root then
		local away = Vector3.zero
		local winnerRoot = winner and winner:FindFirstChild("HumanoidRootPart")
		if winnerRoot then
			local offset = root.Position - winnerRoot.Position
			away = Vector3.new(offset.X, 0, offset.Z)
		end
		if away.Magnitude < 0.01 then
			local angle = math.random() * math.pi * 2
			away = Vector3.new(math.cos(angle), 0, math.sin(angle))
		end
		pcall(function()
			root:ApplyImpulse((away.Unit * 38 + Vector3.new(0, 42, 0)) * root.AssemblyMass)
			root.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-4, 4), math.random(-8, 8))
		end)
	end

	Effects.teamBurst(position, loserTeam, 1.3)
	Effects.koBlast(position, winnerColor)
	Effects.groundRing(position - Vector3.new(0, 2.5, 0), winnerColor, 22, 0.6)
	Audio.play("HeavyHit", { volume = 0.9, minInterval = 0.1 })
	Audio.play("Gasp", { volume = 0.45, group = "Crowd", minInterval = 2 })
	popup(loser, "K.O.", Color3.fromRGB(255, 60, 60), 3, "ko")
	fx("ko", { position = position, color = winnerColor })
	Environment.flash(winnerColor, 1, 2.2)
	spectatorsCheer(8)

	task.delay(1.5, function()
		for _, part in ipairs(loser:GetDescendants()) do
			if part:IsA("BasePart") or part:IsA("Decal") then
				TweenService:Create(part, TweenInfo.new(0.6), { Transparency = 1 }):Play()
			end
		end
	end)
	Debris:AddItem(loser, 2.2)

	local winnerName = winner and winner:GetAttribute("DisplayName")
	if not winnerName then
		if cause == "rain" then
			winnerName = byName and ("🥊 Lluvia de " .. byName) or "🥊 Lluvia de guantes"
		elseif cause == "fall" then
			winnerName = "🕳️ Caída"
		else
			winnerName = "💥 Arena"
		end
	end
	hud("feed", {
		winner = winnerName,
		winnerTeam = winnerTeam,
		loser = loserName,
		loserTeam = loserTeam,
		cause = cause,
		streak = winner and ((winner:GetAttribute("Streak") or 0) + 1) or 0,
	})
	queueDirty, scoreDirty = true, true
end

local function celebrateWinner(winner, sparring)
	local key = winner:GetAttribute("UserKey")
	local rec = participants[key]
	local team = winner:GetAttribute("Team")
	local name = winner:GetAttribute("DisplayName") or winner.Name
	local root = winner:FindFirstChild("HumanoidRootPart")

	heal(winner, Config.REGEN_ON_WIN, "+" .. Config.REGEN_ON_WIN .. " ❤", Color3.fromRGB(120, 255, 150))
	addEnergy(winner, 25)

	local streak = (winner:GetAttribute("Streak") or 0) + 1
	winner:SetAttribute("Streak", streak)
	if rec then
		rec.streak = streak
		local stats = getStats(rec)
		stats.wins += 1
		stats.kos += 1
		stats.bestStreak = math.max(stats.bestStreak, streak)
	end
	if teamWins[team] and not sparring then
		teamWins[team] += 1
	end

	winner:SetAttribute("Mode", "celebrate")
	anim(winner, "victory", { duration = 1.6 })
	popup(winner, "¡VICTORIA!", Color3.fromRGB(255, 215, 0), 1.8, "pop")
	if root then
		Effects.confetti(root.Position + Vector3.new(0, 4, 0), 40)
	end
	Audio.play("Cheer", { group = "Crowd", volume = 0.7, minInterval = 0.8 })
	if streak >= 3 then
		Effects.streakSparkles(winner, true)
	end

	if streak == 3 or streak == 5 or streak == 10 or (streak > 10 and streak % 5 == 0) then
		hud("announce", {
			kind = "streak",
			title = "🔥 ¡RACHA DE " .. streak .. "!",
			subtitle = name .. " no para de ganar",
			team = team,
			duration = 3,
		})
		Audio.play("AirHorn", { volume = 0.6, minInterval = 1 })
		Audio.duck(2.5)
		if root then
			Effects.confetti(root.Position + Vector3.new(0, 6, 0), 120)
		end
		Environment.strobe({ Shared.teamColor(team), Color3.new(1, 1, 1) }, 6, 0.18)
		fx("focus", { target = winner, duration = 3, priority = 3, shot = "hero" })
	else
		fx("focus", { target = winner, duration = 1.6, priority = 2, shot = "victory" })
	end
	topDirty, scoreDirty = true, true
	task.wait(1.6)
end

local function runMatch(npcA, npcB, sparring)
	busy[npcA] = "match"
	busy[npcB] = "match"
	for _, npc in ipairs({ npcA, npcB }) do
		idleSince[npc] = nil
		wanderState[npc] = nil
		npc:SetAttribute("Mode", "fight")
	end
	npcA:SetAttribute("OpponentKey", npcB.Name)
	npcB:SetAttribute("OpponentKey", npcA.Name)
	Audio.play("Bell", { volume = 0.5, minInterval = 0.4, pitchVariance = 0 })
	if sparring then
		hud("toast", {
			text = "🤜🤛 Práctica: " .. tostring(npcA:GetAttribute("DisplayName")) .. " vs " .. tostring(npcB:GetAttribute("DisplayName")),
			team = npcA:GetAttribute("Team"),
		})
	end

	local ok, winner, loser = pcall(runCombat, npcA, npcB)
	if not ok then
		warn("⚠️ Error en un duelo: " .. tostring(winner))
		winner, loser = nil, nil
	end

	if loser and loser.Parent == activeFighters then
		local cause = hasFallen(loser) and "fall" or "fight"
		knockOut(loser, winner, cause)
	end

	if winner and winner.Parent == activeFighters and not winner:GetAttribute("KnockedOut") then
		winner:SetAttribute("OpponentKey", "")
		if (winner:GetAttribute("Health") or 0) <= 0 then
			knockOut(winner, nil, "rain")
		else
			busy[winner] = "celebrate"
			local celebrated, err = pcall(celebrateWinner, winner, sparring)
			if not celebrated then
				warn("⚠️ Error celebrando: " .. tostring(err))
			end
		end
	end

	for _, npc in ipairs({ npcA, npcB }) do
		if busy[npc] == "match" or busy[npc] == "celebrate" then
			busy[npc] = nil
		end
		if npc.Parent == activeFighters then
			npc:SetAttribute("OpponentKey", "")
			npc:SetAttribute("Mode", "free")
		end
	end
end

-- ===== EMPAREJAMIENTO =====

local function getFreeFighters()
	local free = {}
	for _, npc in ipairs(activeFighters:GetChildren()) do
		if not busy[npc] and fighterTracks[npc] and not npc:GetAttribute("KnockedOut") then
			table.insert(free, npc)
		end
	end
	return free
end

local function findNearestOpponent(npc, candidates, sameTeam)
	local root = npc:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local team = npc:GetAttribute("Team")
	local nearest, nearestDistance = nil, math.huge
	for _, other in ipairs(candidates) do
		if other ~= npc and (sameTeam or other:GetAttribute("Team") ~= team) then
			local otherRoot = other:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local distance = (root.Position - otherRoot.Position).Magnitude
				if distance < nearestDistance then
					nearest, nearestDistance = other, distance
				end
			end
		end
	end
	return nearest
end

-- Equipo que conviene meter al ring para que los libres tengan rival.
local function neededTeam()
	local counts = { hero = 0, villain = 0 }
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local team = npc:GetAttribute("Team")
		if busy[npc] ~= "match" and counts[team] then
			counts[team] += 1
		end
	end
	if counts.hero > counts.villain then
		return "villain"
	elseif counts.villain > counts.hero then
		return "hero"
	end
	return nil
end

local function takeNextForRing(preferTeam)
	if #lineup == 0 then
		return nil
	end
	local index = 1
	if preferTeam then
		for i = 1, math.min(#lineup, 12) do
			if lineup[i].team == preferTeam then
				index = i
				break
			end
		end
	end
	local rec = table.remove(lineup, index)
	removeSpectatorNpc(rec)
	queueDirty = true
	return rec
end

local function fillRing()
	while #activeFighters:GetChildren() + pendingEntrances < settings.MaxFighters do
		local rec = takeNextForRing(neededTeam())
		if not rec then
			break
		end
		task.spawn(function()
			local ok, err = pcall(spawnFighter, rec)
			if not ok then
				warn("⚠️ No se pudo crear a " .. rec.name .. ": " .. tostring(err))
				participants[rec.key] = nil
			end
		end)
	end
end

-- Ring lleno de un solo equipo y nadie peleando: se cambia a uno por
-- alguien del otro equipo que esté esperando (el cambiado vuelve primero a la fila).
local function breakSameTeamDeadlock()
	if #activeFighters:GetChildren() < settings.MaxFighters then
		return
	end
	for _, npc in ipairs(activeFighters:GetChildren()) do
		if busy[npc] then
			return
		end
	end
	local free = getFreeFighters()
	if #free == 0 then
		return
	end
	local team = free[1]:GetAttribute("Team")
	for _, npc in ipairs(free) do
		if npc:GetAttribute("Team") ~= team then
			return
		end
	end
	local otherTeam = Shared.otherTeam(team)
	local index
	for i, rec in ipairs(lineup) do
		if rec.team == otherTeam then
			index = i
			break
		end
	end
	if not index then
		return
	end

	local newRec = table.remove(lineup, index)
	removeSpectatorNpc(newRec)

	local displaced = free[#free]
	local displacedRec = participants[displaced:GetAttribute("UserKey")]
	releaseFighter(displaced)
	displaced:Destroy()
	if displacedRec then
		displacedRec.state = "waiting"
		displacedRec.npc = nil
		table.insert(lineup, 1, displacedRec)
	end

	task.spawn(spawnFighter, newRec)
	queueDirty = true
end

local function startMatch(npc, opponent, sparring)
	busy[npc] = "match"
	busy[opponent] = "match"
	task.spawn(runMatch, npc, opponent, sparring)
end

local function pairFighters()
	local free = getFreeFighters()
	local leftover = {}
	while #free > 0 do
		local npc = table.remove(free, 1)
		local opponent = findNearestOpponent(npc, free)
		if opponent then
			table.remove(free, table.find(free, opponent))
			startMatch(npc, opponent, false)
		else
			table.insert(leftover, npc)
		end
	end

	-- Práctica entre compañeros: nadie del otro equipo está libre ni esperando turno
	if not settings.SameTeamSparring or #leftover < 2 then
		return
	end
	local waiting = { hero = false, villain = false }
	for _, rec in ipairs(lineup) do
		waiting[rec.team] = true
	end
	local now = os.clock()
	local ready = {}
	for _, npc in ipairs(leftover) do
		local since = idleSince[npc]
		if since and now - since >= Config.SPAR_WAIT and not waiting[Shared.otherTeam(npc:GetAttribute("Team"))] then
			table.insert(ready, npc)
		end
	end
	while #ready >= 2 do
		local npc = table.remove(ready, 1)
		local partner = findNearestOpponent(npc, ready, true)
		if not partner then
			break
		end
		table.remove(ready, table.find(ready, partner))
		startMatch(npc, partner, true)
	end
end

-- Quien se queda sin rival no se queda quieto: pasea por el ring haciendo
-- sombra (golpes al aire, los anima el cliente), mira a los demás y de vez
-- en cuando se echa un baile mientras llega el próximo retador.
local function nearestOther(npc, root)
	local best, bestDistance = nil, math.huge
	for _, other in ipairs(activeFighters:GetChildren()) do
		local otherRoot = other ~= npc and other:FindFirstChild("HumanoidRootPart")
		if otherRoot then
			local distance = (otherRoot.Position - root.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = otherRoot, distance
			end
		end
	end
	return best
end

local function updateIdleFighters()
	local now = os.clock()
	local center = arenaCenter()
	for _, npc in ipairs(getFreeFighters()) do
		if not idleSince[npc] then
			idleSince[npc] = now
		end
		local tracks = fighterTracks[npc]
		local humanoid = npc:FindFirstChildOfClass("Humanoid")
		local root = npc:FindFirstChild("HumanoidRootPart")
		if tracks and humanoid and root then
			local state = wanderState[npc]
			if not state then
				state = { nextMove = now, danceAt = now + 8 + math.random() * 5 }
				wanderState[npc] = state
			end
			if state.danceUntil then
				if now >= state.danceUntil then
					state.danceUntil = nil
					state.danceAt = now + 10 + math.random() * 8
					state.nextMove = now
					tracks.dance:Stop(0.4)
					npc:SetAttribute("Mode", "free")
				end
			elseif now >= state.danceAt then
				state.danceUntil = now + 4 + math.random() * 3
				state.target = nil
				humanoid:MoveTo(root.Position)
				tracks.walk:Stop(0.3)
				tracks.dance:Play(0.4)
				npc:SetAttribute("Mode", "dance")
			else
				if npc:GetAttribute("Mode") ~= "free" then
					npc:SetAttribute("Mode", "free")
				end
				if now >= state.nextMove then
					state.nextMove = now + 1.6 + math.random() * 2
					local angle = math.random() * math.pi * 2
					local radius = math.sqrt(math.random()) * Config.WANDER_RADIUS
					state.target = Vector3.new(center.X + math.cos(angle) * radius, root.Position.Y, center.Z + math.sin(angle) * radius)
					humanoid.WalkSpeed = Config.WANDER_WALK_SPEED
					humanoid:MoveTo(state.target)
				end
				-- mira hacia donde camina; parado, mira (desafiante) al peleador más cercano
				local target = state.target
				if target and (Vector3.new(target.X, 0, target.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude > 2.5 then
					faceTowards(npc, target)
				else
					local other = nearestOther(npc, root)
					if other then
						faceTowards(npc, other.Position)
					end
				end
			end
		end
	end
end

-- ===== LLUVIA DE GUANTES =====

local rainQueue = {}
local rainRunning = false

local function dropGlove(template, position, groundY, isGold, byName, color)
	local glove = template:Clone()
	local hitbox = glove.PrimaryPart or glove:FindFirstChildWhichIsA("BasePart", true)
	if not hitbox then
		glove:Destroy()
		return
	end
	glove:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
	for _, part in ipairs(glove:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
		end
	end
	glove.Parent = Effects.folder()
	hitbox.AssemblyLinearVelocity = Vector3.new(0, -25, 0)

	local exploded = false
	local function explode()
		if exploded then
			return
		end
		exploded = true
		local impact = hitbox.Position
		Effects.gloveImpact(impact, isGold, Config.GLOVE_RAIN_EXPLOSION_RADIUS)
		Audio.play("Explosion", { volume = 0.5, minInterval = 0.12 })
		fx("shake", { intensity = 0.4, position = impact })
		for _, npc in ipairs(activeFighters:GetChildren()) do
			local root = npc:FindFirstChild("HumanoidRootPart")
			local health = npc:GetAttribute("Health")
			if root and health and health > 0 and not npc:GetAttribute("KnockedOut")
				and (root.Position - impact).Magnitude <= Config.GLOVE_RAIN_EXPLOSION_RADIUS then
				local team = npc:GetAttribute("Team")
				if (isGold and team == "villain") or (not isGold and team == "hero") then
					local newHealth = math.max(0, health - Config.GLOVE_RAIN_DAMAGE)
					npc:SetAttribute("Health", newHealth)
					popup(npc, "-" .. Config.GLOVE_RAIN_DAMAGE, color, 1.6, "shake")
					Effects.hitFlash(npc, color)
					local away = root.Position - impact
					away = Vector3.new(away.X, 0, away.Z)
					if away.Magnitude > 0.1 then
						pcall(function()
							root:ApplyImpulse((away.Unit * 25 + Vector3.new(0, 20, 0)) * root.AssemblyMass)
						end)
					end
					if newHealth <= 0 and busy[npc] ~= "match" then
						knockOut(npc, nil, "rain", byName)
					end
				end
			end
		end
		glove:Destroy()
	end

	hitbox.Touched:Connect(function(hit)
		if hit:IsDescendantOf(glove) or hit:IsDescendantOf(Effects.folder()) or hit:IsDescendantOf(waitingFolder) then
			return
		end
		explode()
	end)
	task.spawn(function()
		local startedAt = os.clock()
		while not exploded and glove.Parent and os.clock() - startedAt < Config.GLOVE_RAIN_LIFETIME do
			if hitbox.Position.Y <= groundY + 1.2 then
				explode()
				break
			end
			task.wait(0.03)
		end
		if not exploded and glove.Parent then
			glove:Destroy()
		end
	end)
end

local function runGloveRain(kind, byName)
	local isGold = kind == "gold"
	local template = ServerStorage:FindFirstChild(isGold and "PuñoDorado" or "PuñoOscuro")
	if not template then
		warn("⚠️ Falta el modelo del guante en ServerStorage")
		return
	end
	local color = isGold and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(150, 60, 210)
	hud("alert", { image = isGold and Config.RAIN_ALERT_GOLD or Config.RAIN_ALERT_DARK })
	hud("announce", {
		kind = "rain",
		title = isGold and "🌟 LLUVIA DE GUANTES DORADOS" or "🌑 LLUVIA DE GUANTES OSCUROS",
		subtitle = (byName and ("Regalo de " .. byName .. " • ") or "") .. (isGold and "¡Cuidado VILLANOS!" or "¡Cuidado HÉROES!"),
		team = isGold and "hero" or "villain",
		duration = 3.5,
	})
	Audio.play("Siren", { volume = 0.5, maxLength = 6, minInterval = 1 })
	Audio.duck(4)
	Environment.strobe({ color, Color3.new(1, 1, 1) }, 8, 0.3)
	local totalTime = Config.GLOVE_RAIN_WARNING + Config.GLOVE_RAIN_STAGGER_MAX + 1
	fx("focus", { shot = "wide", duration = totalTime, priority = 3 })

	local center = fightersCenter()
	local _, floorY = Environment.getCenter()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { activeFighters, waitingFolder, Effects.folder() }
	local radius = Config.GLOVE_RAIN_SPAWN_RADIUS

	for _ = 1, Config.GLOVE_RAIN_COUNT do
		local x = center.X + math.random(-radius, radius)
		local z = center.Z + math.random(-radius, radius)
		local groundY = floorY - 0.3
		local hit = Workspace:Raycast(Vector3.new(x, floorY + 60, z), Vector3.new(0, -120, 0), params)
		if hit and hit.Position.Y < floorY + 2 and hit.Position.Y > floorY - 6 then
			groundY = hit.Position.Y
		end
		local dropAt = Config.GLOVE_RAIN_WARNING + math.random() * Config.GLOVE_RAIN_STAGGER_MAX
		task.delay(math.max(0, dropAt - 0.6), function()
			Effects.groundMarker(Vector3.new(x, groundY, z), color, 1.4)
		end)
		task.delay(dropAt, function()
			dropGlove(template, Vector3.new(x, groundY + Config.GLOVE_RAIN_HEIGHT, z), groundY, isGold, byName, color)
		end)
	end
end

local function startGloveRain(kind, byName)
	table.insert(rainQueue, { kind = kind, by = byName })
	if rainRunning then
		return
	end
	rainRunning = true
	task.spawn(function()
		while #rainQueue > 0 do
			while inCinematic() do
				task.wait(0.25) -- las lluvias esperan a que termine la entrada de cine
			end
			local job = table.remove(rainQueue, 1)
			local ok, err = pcall(runGloveRain, job.kind, job.by)
			if not ok then
				warn("⚠️ Error en la lluvia de guantes: " .. tostring(err))
			end
			task.wait(Config.GLOVE_RAIN_WARNING + Config.GLOVE_RAIN_STAGGER_MAX + 1.5)
		end
		rainRunning = false
	end)
end

-- ===== EVENTOS DE LIKES =====

local function triggerFury(byName)
	furyUntil = os.clock() + Config.FURY_DURATION
	stateFolder:SetAttribute("FuryEnd", Workspace:GetServerTimeNow() + Config.FURY_DURATION)
	for _, npc in ipairs(activeFighters:GetChildren()) do
		Effects.furyHands(npc, Config.FURY_DURATION)
	end
	hud("announce", {
		kind = "fury",
		title = "🔥 ¡MODO FURIA!",
		subtitle = "Todos pegan +50% durante " .. Config.FURY_DURATION .. "s" .. (byName and (" • " .. byName) or ""),
		color = Color3.fromRGB(255, 110, 30),
		duration = 3.5,
	})
	Audio.play("AirHorn", { volume = 0.6, minInterval = 1 })
	Audio.duck(3)
	Environment.strobe({ Color3.fromRGB(255, 80, 20), Color3.fromRGB(255, 200, 40) }, 10, 0.2)
	fx("flash", { color = Color3.fromRGB(255, 100, 30), intensity = 0.45 })
	fx("shake", { intensity = 0.6 })
end

local function triggerHeartRain(byName)
	local center = fightersCenter()
	Effects.heartRain(center, 30, 5)
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local maxHealth = npc:GetAttribute("MaxHealth") or Config.HEALTH_MAX
		local gained = heal(npc, maxHealth * Config.HEART_RAIN_HEAL)
		if gained > 0 then
			popup(npc, "+" .. math.floor(gained + 0.5) .. " ❤", Color3.fromRGB(255, 120, 190), 1.2, "rise")
		end
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			Effects.healBurst(root.Position, Color3.fromRGB(255, 120, 190), 18)
		end
	end
	hud("announce", {
		kind = "hearts",
		title = "💖 ¡LLUVIA DE CORAZONES!",
		subtitle = "Todos en el ring se curan" .. (byName and (" • " .. byName) or ""),
		color = Color3.fromRGB(255, 110, 180),
		duration = 3.5,
	})
	Audio.play("Heal", { volume = 0.7, minInterval = 1 })
	Audio.play("Cheer", { group = "Crowd", volume = 0.6, minInterval = 1 })
	Environment.strobe({ Color3.fromRGB(255, 110, 180), Color3.new(1, 1, 1) }, 6, 0.25)
end

-- ===== MODO BATALLA (batallas de TikTok entre dos streamers) =====
-- Con GameMode = "Batalla", cuando el streamer empieza una batalla en TikTok el
-- bridge manda battleStart / battlePoints / battleEnd (ver batalla.js). El ring
-- se vacía (los que estaban vuelven los primeros a la fila) y pelean dos
-- campeones: el del streamer (🦸 dorado) y el del rival (🦹 morado). Cada vez
-- que un lado recibe puntos, su campeón golpea al otro, y con más puntos su
-- poder sube (aura, fuego en los puños y el cuerpo, humo). Los regalos de este
-- live hacen ataques especiales. Nadie cae hasta que TikTok termina la
-- batalla: entonces el que tiene más puntos lanza el ATAQUE FINAL (cinemática:
-- FxEvent "finisher", la dibujan EntranceCinematics y ArenaCamera) y elimina al
-- otro. Después vuelve el juego normal hasta la próxima batalla.
-- Cada streamer corre su propio juego: los dos ven la misma pelea porque
-- TikTok da los mismos puntos a los dos.
-- (Todo vive en la tabla Battle para no pasar el límite de variables locales.)

Battle.MIN_HEALTH = 0.08 -- fracción de vida de la que nadie baja antes del final
Battle.POWER_STEPS = Shared.BATTLE.POWER_STEPS -- puntos para cada nivel de poder
Battle.POWER_DAMAGE = { 1.4, 1.8, 2.3, 3.1 } -- DamageMultiplier por nivel (el aura del cliente crece con él)
-- Ataques especiales por regalo de este live (nivel del regalo en el editor de
-- regalos, o por monedas si el regalo no está en ningún puesto)
Battle.SPECIALS = {
	{ name = "¡COMBO!", points = 40, moves = { "jab", "cross", "hook" } },
	{ name = "¡GANCHO DE FUEGO!", points = 90, moves = { "body", "hook" }, fire = true },
	{ name = "¡SÚPER DIRECTO!", points = 200, moves = { "superStraight" } },
	{ name = "¡UPPERCUT RELÁMPAGO!", points = 450, moves = { "combo", "superUpper" }, lightning = true },
	{ name = "¡ATAQUE METEORO!", points = 1000, moves = { "combo", "superUpper" }, lightning = true, meteor = true },
	rain = { name = "¡LLUVIA DE GUANTES!", points = 300, moves = { "cross", "hook" }, gloves = true },
	crowd = { name = "", points = 150, moves = { "jab", "cross", "superStraight" } }, -- energía del público (likes)
}
for key, def in pairs(Battle.SPECIALS) do
	def.name = Shared.BATTLE.ATTACKS[key].name -- (los nombres viven en Shared: también los muestra el HUD de batalla)
	def.level = key
end
Battle.FINISHER_DURATION = 7.2
Battle.FINISHER_IMPACT = 2.45 -- (superUpper a x1.3 desde el segundo 1.95)
Battle.FINISHER_SOUNDS = {
	{ 0, "PowerUp", { volume = 0.8, pitch = 0.7 } },
	{ 0.1, "Gasp", { volume = 0.6, group = "Crowd" } },
	{ 0.9, "Explosion", { volume = 0.5, pitch = 0.6 } },
	{ 1.95, "Whoosh", { volume = 0.9, pitch = 0.6 } },
	{ 2.45, "HeavyHit", { volume = 1, pitch = 0.6 } },
	{ 2.45, "Explosion", { volume = 1, pitch = 0.75 } },
	{ 4.2, "AirHorn", { volume = 0.7 } },
	{ 4.2, "Cheer", { volume = 0.9, group = "Crowd" } },
}
Battle.current = nil -- batalla en curso
Battle.wins = { me = 0, rival = 0 }
Battle.dirty = true
Battle.counter = 0

-- Efectos de ArenaVFX que no están en Effects (rayos, grietas...)
function Battle.vfx(name, ...)
	local count = select("#", ...)
	local args = table.create(count)
	for i = 1, count do
		local value = select(i, ...)
		args[i] = if value == nil then "__nil" else value
	end
	fx("vfx", { name = name, args = args })
end

function Battle.payload()
	local b = Battle.current
	local data = { mode = settings.GameMode, wins = Battle.wins, likeGoal = settings.BattleLikeGoal }
	if not b then
		data.active = false
		return data
	end
	local function side(s)
		return { name = s.name, points = s.points, power = s.power, team = s.team }
	end
	-- MVP: quién más regaló en esta batalla (solo los de este live)
	local supporters = {}
	for name, coins in pairs(b.supporters) do
		table.insert(supporters, { name = name, coins = coins })
	end
	table.sort(supporters, function(x, y)
		return x.coins > y.coins
	end)
	for i = #supporters, 4, -1 do
		supporters[i] = nil
	end
	data.active = true
	data.phase = b.phase
	data.me = side(b.me)
	data.rival = side(b.rival)
	data.endsAt = b.endsAt
	data.startedAt = b.startedAt
	data.winner = b.winner
	data.crowd = b.crowd
	data.supporters = supporters
	return data
end

function Battle.newSide(id, info, team)
	info = type(info) == "table" and info or {}
	return {
		id = id,
		name = cleanName(info.name, if id == "me" then "Yo" else "Rival"),
		user = tostring(info.user or ""),
		team = team,
		points = 0,
		power = 0,
		pending = 0, -- puntos que todavía no se convirtieron en golpes
		absorb = 0, -- puntos que ya pegaron como ataque especial (regalo de este live)
		absorbUntil = 0,
		specials = {},
		nextHitAt = 0,
		lungeUntil = 0,
		nextFootwork = 0,
		orbit = 0,
		attacking = false,
		busySpecial = false,
	}
end

function Battle.alive(s)
	return s.npc ~= nil and s.npc.Parent == activeFighters and s.root ~= nil and s.root.Parent ~= nil
end

function Battle.flat(vector, fallback)
	local flat = Vector3.new(vector.X, 0, vector.Z)
	return if flat.Magnitude > 0.05 then flat.Unit else (fallback or Vector3.xAxis)
end

-- Los que estaban en el ring vuelven los primeros a la fila (pelean después de la batalla)
function Battle.clearRing()
	local deadline = os.clock() + 12
	while (cinematicRunning or inCinematic()) and os.clock() < deadline do
		task.wait(0.2) -- se deja terminar la entrada de cine que esté en curso
	end
	local returning = {}
	for _, npc in ipairs(activeFighters:GetChildren()) do
		if not npc:GetAttribute("BattleFighter") then
			local rec = participants[npc:GetAttribute("UserKey")]
			npc:SetAttribute("KnockedOut", true) -- (su duelo termina sin K.O.)
			releaseFighter(npc)
			npc:Destroy()
			if rec and rec.npc == npc then
				rec.state = "waiting"
				rec.npc = nil
				table.insert(returning, rec)
			end
		end
	end
	for i = #returning, 1, -1 do
		table.insert(lineup, 1, returning[i])
	end
	queueDirty, scoreDirty = true, true
end

-- Dos puntos del ring frente a frente
function Battle.spots()
	local center = arenaCenter()
	local a, b = SPAWN_POINTS[1].Position, SPAWN_POINTS[2].Position
	local axis = Battle.flat(b - a)
	return ringFloor(center - axis * 6), ringFloor(center + axis * 6)
end

function Battle.spawn(s, floor, lookAt)
	Battle.counter += 1
	local who = normalizeKey(s.user ~= "" and s.user or s.name) or "x"
	local rec = {
		key = "battle_" .. s.id .. "_" .. who, -- (el mismo streamer sale siempre con el mismo avatar)
		name = s.name,
		team = s.team,
		maxHealth = Config.HEALTH_MAX,
		damageMult = 1,
		speedMult = 1,
		streak = 0,
	}
	local height = Vector3.new(0, 4, 0)
	local npc, humanoid, root, tracks = prepareFighter(rec, CFrame.lookAt(floor + height, Vector3.new(lookAt.X, floor.Y, lookAt.Z) + height), floor.Y)
	if not npc or not root then
		return false
	end
	npc:SetAttribute("BattleFighter", s.id)
	busy[npc] = "battle" -- (el emparejador y los paseos lo dejan en paz)
	s.npc, s.humanoid, s.root, s.tracks = npc, humanoid, root, tracks
	Effects.entranceBeam(root.Position, s.team)
	Audio.play("Whoosh", { volume = 0.6, minInterval = 0.1 })
	tracks.wave:Play()
	if s.power > 0 then
		Battle.applyPower(s, false)
	end
	return true
end

-- Fuego / humo / aura según el nivel de poder (puntos de su lado)
function Battle.applyPower(s, announce)
	local npc = s.npc
	if not npc or not npc.Parent then
		return
	end
	local level = s.power
	npc:SetAttribute("BattlePower", level)
	if level <= 0 then
		return
	end
	npc:SetAttribute("DamageMultiplier", Battle.POWER_DAMAGE[level])
	Effects.teamAura(npc, s.team)
	Effects.handParticles(npc, s.team, 1 + 0.15 * level)
	local color = Shared.teamColor(s.team)
	local dark = TEAMS[s.team].dark
	if level >= 2 then
		for _, handName in ipairs({ "LeftHand", "RightHand" }) do
			local hand = npc:FindFirstChild(handName)
			if hand and not hand:FindFirstChild("BattleFire") then
				local fire = Instance.new("Fire")
				fire.Name = "BattleFire"
				fire.Size = 3.2
				fire.Heat = 8
				fire.Color = color:Lerp(Color3.fromRGB(255, 120, 30), 0.5)
				fire.SecondaryColor = dark
				fire.Parent = hand
			end
		end
	end
	local torso = npc:FindFirstChild("UpperTorso")
	if torso and level >= 3 and not torso:FindFirstChild("BattleFire") then
		local fire = Instance.new("Fire")
		fire.Name = "BattleFire"
		fire.Size = 7
		fire.Heat = 12
		fire.Color = color
		fire.SecondaryColor = dark
		fire.Parent = torso
	end
	if torso and level >= 4 and not torso:FindFirstChild("BattleSmoke") then
		local smoke = Instance.new("Smoke")
		smoke.Name = "BattleSmoke"
		smoke.Color = dark:Lerp(Color3.new(0, 0, 0), 0.4)
		smoke.Opacity = 0.35
		smoke.RiseVelocity = 7
		smoke.Size = 4
		smoke.Parent = torso
	end
	if announce and s.root then
		popup(npc, "🔥 PODER " .. level, Color3.fromRGB(255, 160, 50), 1.7, "pop")
		Effects.boostPillar(s.root.Position, s.team, math.min(level + 1, 5))
		Effects.superCharge(npc, s.team, 0.8)
		Audio.play("PowerUp", { volume = 0.7, minInterval = 0.4 })
		Environment.flash(color, 0.7, 2)
		hud("battleEvent", { kind = "power", side = s.id, name = s.name, level = level })
		fx("focus", { target = npc, duration = 1.5, priority = 2, shot = "boost" })
	end
end

function Battle.updatePower(s)
	local level = 0
	for i, need in ipairs(Battle.POWER_STEPS) do
		if s.points >= need then
			level = i
		end
	end
	if level > s.power then
		s.power = level
		Battle.dirty = true
		Battle.applyPower(s, true)
	end
end

-- Humo y chispas en quien va perdiendo mucha vida
function Battle.updateHurtLook(s)
	local npc = s.npc
	local head = npc and npc:FindFirstChild("Head")
	if not head then
		return
	end
	local ratio = (npc:GetAttribute("Health") or 0) / math.max(1, npc:GetAttribute("MaxHealth") or Config.HEALTH_MAX)
	if ratio < 0.45 and not head:FindFirstChild("HurtSmoke") then
		local smoke = Instance.new("Smoke")
		smoke.Name = "HurtSmoke"
		smoke.Color = Color3.fromRGB(70, 70, 78)
		smoke.Opacity = 0.22
		smoke.RiseVelocity = 4
		smoke.Size = 2.4
		smoke.Parent = head
	end
	if ratio < 0.2 and not head:FindFirstChild("HurtSparks") then
		local sparks = Instance.new("Sparkles")
		sparks.Name = "HurtSparks"
		sparks.SparkleColor = Color3.fromRGB(255, 80, 60)
		sparks.Parent = head
	end
end

-- Daño que baja con lo que falta: nunca deja a nadie por debajo del mínimo
function Battle.damage(foe, points, mult)
	local npc = foe.npc
	local maxHealth = npc:GetAttribute("MaxHealth") or Config.HEALTH_MAX
	local health = npc:GetAttribute("Health") or maxHealth
	local room = health - maxHealth * Battle.MIN_HEALTH
	if room <= 0 then
		return 0
	end
	local damage = room * (1 - math.exp(-points / 350)) * 0.55 * (mult or 1)
	damage = math.clamp(damage, math.min(room, 0.5), room)
	npc:SetAttribute("Health", health - damage)
	return damage
end

-- Un golpe del lado s al lado foe por "points" puntos
function Battle.strike(b, s, foe, points, moveName, opts)
	opts = opts or {}
	local special = opts.special
	if special == nil then
		special = points >= 100
	end
	moveName = moveName or Shared.pickMove(special, s.lastMove)
	local move = Shared.MOVES[moveName] or Shared.MOVES.cross
	local speed = opts.speed or 1.15
	local impactDelay = move.impact / speed
	s.lastMove = moveName
	s.attacking = true
	s.lungeUntil = os.clock() + impactDelay + 0.1
	s.nextHitAt = os.clock() + impactDelay + (if special then 0.6 else 0.3)
	if special then
		Effects.superCharge(s.npc, s.team, impactDelay)
		Audio.play("PowerUp", { volume = 0.45, pitch = 1.4, minInterval = 0.3 })
	end
	if not opts.hidePoints then
		popup(s.npc, "+" .. Shared.formatNumber(points) .. " ⚡", Shared.teamColor(s.team), if points >= 1000 then 1.7 elseif points >= 100 then 1.3 else 1, "rise")
	end
	anim(s.npc, moveName, { speed = speed })
	task.delay(impactDelay * 0.4, function()
		Audio.play("Whoosh", { volume = special and 0.45 or 0.22, minInterval = 0.08, pitchVariance = 0.15 })
	end)
	task.delay(impactDelay, function()
		s.attacking = false
		if Battle.current ~= b or b.phase ~= "fight" or not Battle.alive(s) or not Battle.alive(foe) then
			return
		end
		local direction = Battle.flat(foe.root.Position - s.root.Position, s.root.CFrame.LookVector)
		local impact = foe.root.Position - direction * 1.2 + Vector3.new(0, if move.target == "body" then 0.5 else 2.6, 0)
		local damage = Battle.damage(foe, points, opts.mult)
		local kind = if special then "special" elseif points >= 25 then "crit" else "normal"
		anim(foe.npc, hurtMove(moveName, kind), { heavy = kind ~= "normal" })
		fx("hitstop", { a = s.npc, b = foe.npc, time = if kind == "special" then 0.14 elseif kind == "crit" then 0.08 else 0.05 })
		Effects.hit(impact, direction, s.team, kind)
		Effects.hitFlash(foe.npc, if kind == "normal" then Color3.new(1, 1, 1) else Shared.teamColor(s.team))
		local push = if kind == "special" then 30 elseif kind == "crit" then 16 else 8
		pcall(function()
			foe.root:ApplyImpulse((direction * push + Vector3.new(0, if kind == "special" then 14 else 0, 0)) * foe.root.AssemblyMass)
		end)
		local shown = math.max(1, math.floor(damage + 0.5))
		if damage < 0.05 then
			-- ya está al mínimo: aguanta hasta que TikTok termine la batalla
			popup(foe.npc, "¡RESISTE!", Color3.fromRGB(220, 220, 235), 0.9, "rise")
			Audio.play("Hits", { volume = 0.45, minInterval = 0.05 })
			fx("shake", { intensity = 0.12, position = impact })
		elseif kind == "normal" then
			popup(foe.npc, "-" .. shown, Color3.fromRGB(255, 90, 90), 1, "rise")
			Audio.play("Hits", { volume = 0.55, minInterval = 0.05 })
			fx("shake", { intensity = 0.14, position = impact })
		elseif kind == "crit" then
			popup(foe.npc, "-" .. shown, Color3.fromRGB(255, 170, 40), 1.5, "shake")
			Audio.play("HeavyHit", { volume = 0.7, minInterval = 0.1 })
			fx("shake", { intensity = 0.38, position = impact })
		else
			popup(foe.npc, "-" .. shown, Color3.fromRGB(90, 225, 255), 2, "shake")
			Audio.play("HeavyHit", { volume = 1, pitch = 0.85, minInterval = 0.1 })
			Audio.play("Explosion", { volume = 0.45, minInterval = 0.3 })
			fx("shake", { intensity = 0.7, position = impact })
			fx("flash", { color = Shared.teamColor(s.team), intensity = 0.3 })
			fx("focus", { target = foe.npc, duration = 1.3, priority = 2, shot = "impact" })
			Environment.flash(Shared.teamColor(s.team), 0.5, 2)
		end
		Battle.updateHurtLook(foe)
	end)
end

-- Ataque especial por un regalo de este live
function Battle.special(b, s, foe, entry)
	local def = entry.def
	s.busySpecial = true
	local color = Shared.teamColor(s.team)
	popup(s.npc, def.name, Color3.fromRGB(255, 225, 90), 1.8, "pop")
	local function feetOf(side)
		return side.root.Position - Vector3.new(0, side.humanoid.HipHeight + side.root.Size.Y / 2, 0)
	end
	if def.fire then
		Effects.furyHands(s.npc, 4)
	end
	if def.meteor then
		fx("focus", { target = s.npc, duration = 2.2, priority = 3, shot = "hero" })
		anim(s.npc, "powerUp", { duration = 0.9 })
		Effects.superCharge(s.npc, s.team, 0.9)
		Battle.vfx("groundCrack", feetOf(s), color, 8)
		Audio.play("PowerUp", { volume = 0.8, pitch = 0.8 })
		task.wait(0.9)
	end
	if def.lightning and Battle.alive(foe) then
		Battle.vfx("lightningStrike", feetOf(foe), color)
		Audio.play("Explosion", { volume = 0.5, minInterval = 0.2 })
		fx("flash", { color = color, intensity = 0.35 })
	end
	if def.gloves and Battle.alive(foe) then
		for i = 1, 7 do
			task.delay(i * 0.11, function()
				if Battle.alive(foe) then
					local angle = math.random() * math.pi * 2
					local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * math.random() * 4
					Effects.gloveImpact(feetOf(foe) + offset, s.team == "hero", 5)
				end
			end)
		end
		Audio.play("HeavyHit", { volume = 0.6, minInterval = 0.1 })
	end
	local perMove = def.points / #def.moves
	for i, moveName in ipairs(def.moves) do
		if Battle.current ~= b or b.phase ~= "fight" or not Battle.alive(s) or not Battle.alive(foe) then
			break
		end
		local move = Shared.MOVES[moveName]
		Battle.strike(b, s, foe, perMove, moveName, {
			special = move.super == true or (i == #def.moves and def.points >= 200),
			mult = 1.4,
			hidePoints = true,
			speed = 1.3,
		})
		local started = os.clock()
		while s.attacking and os.clock() - started < 2 do
			task.wait(0.05)
		end
		task.wait(0.1)
	end
	if def.meteor and Battle.alive(foe) then
		Effects.koBlast(foe.root.Position, color)
		Battle.vfx("debris", feetOf(foe), 10)
	end
	s.nextHitAt = os.clock() + 0.4
	s.busySpecial = false
end

-- Movimiento y golpes, 10 veces por segundo
function Battle.tick(b)
	-- si alguien más entró al ring (una entrada que estaba en camino), vuelve a la fila
	for _, npc in ipairs(activeFighters:GetChildren()) do
		if not npc:GetAttribute("BattleFighter") and busy[npc] ~= "entering" then
			local rec = participants[npc:GetAttribute("UserKey")]
			npc:SetAttribute("KnockedOut", true)
			releaseFighter(npc)
			npc:Destroy()
			if rec and rec.npc == npc then
				rec.state = "waiting"
				rec.npc = nil
				table.insert(lineup, 1, rec)
				queueDirty = true
			end
		end
	end
	if inCinematic() then
		return
	end
	local me, rival = b.me, b.rival
	if not Battle.alive(me) or not Battle.alive(rival) then
		return
	end
	local now = os.clock()
	local distance = (me.root.Position - rival.root.Position).Magnitude
	for _, pair in ipairs({ { me, rival }, { rival, me } }) do
		local s, foe = pair[1], pair[2]
		faceTowards(s.npc, foe.root.Position)
		local away = Battle.flat(s.root.Position - foe.root.Position)
		if now < s.lungeUntil then
			walkTo(s, foe.root.Position + away * Config.LUNGE_DISTANCE, Config.LUNGE_WALK_SPEED)
		elseif distance > 7.5 or distance < 3.5 then
			walkTo(s, foe.root.Position + away * 5.5, Config.APPROACH_WALK_SPEED)
		else
			-- juego de pies: giran despacio uno alrededor del otro
			if now >= s.nextFootwork then
				s.nextFootwork = now + 0.8 + math.random() * 1.2
				s.orbit = ({ -10, 0, 0, 10 })[math.random(1, 4)]
			end
			local angle = math.atan2(away.Z, away.X) + math.rad(s.orbit)
			walkTo(s, foe.root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 5.5, Config.FIGHT_WALK_SPEED)
		end
		if not s.attacking and not s.busySpecial and now >= s.nextHitAt then
			if #s.specials > 0 then
				task.spawn(Battle.special, b, s, foe, table.remove(s.specials, 1))
			elseif s.pending > 0 then
				local points = s.pending
				s.pending = 0
				Battle.strike(b, s, foe, points)
			end
		end
	end
end

function Battle.run(b)
	Battle.clearRing()
	if Battle.current ~= b then
		return
	end
	local spotMe, spotRival = Battle.spots()
	local spawned = {}
	for _, item in ipairs({ { b.me, spotMe, spotRival }, { b.rival, spotRival, spotMe } }) do
		task.spawn(function()
			spawned[item[1].id] = Battle.spawn(item[1], item[2], item[3])
		end)
	end
	local waitStarted = os.clock()
	while (spawned.me == nil or spawned.rival == nil) and os.clock() - waitStarted < 15 do
		task.wait(0.1)
	end
	if Battle.current ~= b then
		return
	end
	if not spawned.me or not spawned.rival then
		warn("⚠️ No se pudieron crear los campeones de la batalla")
		Battle.finish(b)
		return
	end
	b.me.npc:SetAttribute("OpponentKey", b.rival.npc.Name)
	b.rival.npc:SetAttribute("OpponentKey", b.me.npc.Name)

	-- Presentación
	hud("battleEvent", { kind = "intro", me = b.me.name, rival = b.rival.name }) -- (pantalla VS del HUD de batalla)
	Audio.play("Bell", { volume = 0.7, pitchVariance = 0 })
	Audio.play("AirHorn", { volume = 0.6, minInterval = 1 })
	Audio.duck(2.5)
	Environment.strobe({ TEAMS.hero.color, TEAMS.villain.color }, 8, 0.2)
	fx("focus", { target = b.me.npc, duration = 2.2, priority = 3, shot = "wide" })
	task.wait(0.6)
	for _, s in ipairs({ b.me, b.rival }) do
		if Battle.alive(s) then
			anim(s.npc, "cineRoar", { duration = 1.2 })
			Effects.teamBurst(s.root.Position, s.team, 1)
		end
	end
	task.wait(1.3)
	if Battle.current ~= b then
		return
	end
	for _, s in ipairs({ b.me, b.rival }) do
		if Battle.alive(s) then
			s.npc:SetAttribute("Mode", "fight")
		end
	end
	b.phase = "fight"
	Battle.dirty = true
	if b.pendingEnd then
		b.phase = "finisher"
		Battle.runFinish(b)
		return
	end
	while Battle.current == b and b.phase == "fight" do
		task.wait(0.1)
		local ok, err = pcall(Battle.tick, b)
		if not ok then
			warn("⚠️ Error en la batalla: " .. tostring(err))
		end
	end
end

-- Quita a los campeones y vuelve el juego normal
function Battle.finish(b)
	if Battle.current ~= b then
		return
	end
	Battle.current = nil
	stateFolder:SetAttribute("BattleActive", false)
	stateFolder:SetAttribute("BattleFinisher", false)
	for _, s in ipairs({ b.me, b.rival }) do
		local npc = s.npc
		if npc and npc.Parent == activeFighters then
			releaseFighter(npc)
			npc.Parent = Effects.folder() -- (deja de contar como peleador al instante)
			if s.root then
				Effects.entranceBeam(s.root.Position, s.team)
			end
			for _, part in ipairs(npc:GetDescendants()) do
				if part:IsA("BasePart") or part:IsA("Decal") then
					TweenService:Create(part, TweenInfo.new(0.6), { Transparency = 1 }):Play()
				end
			end
			Debris:AddItem(npc, 0.8)
		end
	end
	Battle.dirty = true
	queueDirty, scoreDirty = true, true
end

-- ATAQUE FINAL: el ganador carga, se lanza y saca volando al perdedor
function Battle.runFinish(b)
	local started = os.clock()
	while (b.me.attacking or b.rival.attacking or b.me.busySpecial or b.rival.busySpecial) and os.clock() - started < 2.5 do
		task.wait(0.05)
	end
	if Battle.current ~= b then
		return
	end
	if b.winner == "tie" or not Battle.alive(b.me) or not Battle.alive(b.rival) then
		Battle.runTie(b)
		return
	end
	local w = if b.winner == "me" then b.me else b.rival
	local l = if w == b.me then b.rival else b.me
	local up = Vector3.yAxis
	local color = Shared.teamColor(w.team)
	local wHeight = w.humanoid.HipHeight + w.root.Size.Y / 2
	local lHeight = l.humanoid.HipHeight + l.root.Size.Y / 2
	local wFloor = ringFloor(w.root.Position)
	local dir = Battle.flat(l.root.Position - w.root.Position)
	local lFloor = ringFloor(wFloor + dir * 10)
	local dashTo = ringFloor(wFloor + dir * 6.3)

	-- quietos y frente a frente
	for _, s in ipairs({ w, l }) do
		s.humanoid:MoveTo(s.root.Position)
		s.root.Anchored = true
	end
	w.root.CFrame = CFrame.lookAt(wFloor + up * wHeight, wFloor + up * wHeight + dir)
	l.root.CFrame = CFrame.lookAt(lFloor + up * lHeight, lFloor + up * lHeight - dir)
	w.npc:SetAttribute("Mode", "cinematic")
	stateFolder:SetAttribute("BattleFinisher", true)
	Battle.dirty = true
	fx("finisher", {
		winner = w.npc,
		loser = l.npc,
		team = w.team,
		winnerName = w.name,
		loserName = l.name,
		from = wFloor,
		to = dashTo,
		loserAt = lFloor,
		facing = dir,
		rootHeight = wHeight,
		duration = Battle.FINISHER_DURATION,
		impact = Battle.FINISHER_IMPACT,
	})
	Audio.duck(Battle.FINISHER_DURATION)
	for _, sound in ipairs(Battle.FINISHER_SOUNDS) do
		task.delay(sound[1], function()
			local opts = table.clone(sound[3])
			opts.minInterval = 0
			Audio.play(sound[2], opts)
		end)
	end

	-- 0 s: el perdedor queda mareado; el ganador carga todo su poder
	anim(l.npc, "stun", { duration = 2.4 })
	fx("icon", { target = l.npc, image = Config.STUN_ICON_ID, duration = 2.4, spin = true })
	anim(w.npc, "powerUp", { duration = 1.7 })
	Effects.superCharge(w.npc, w.team, 1.8)
	Effects.boostPillar(w.root.Position, w.team, 5)
	Battle.vfx("groundCrack", wFloor, color, 7)
	task.delay(0.9, function()
		Battle.vfx("lightningStrike", wFloor, color)
		Effects.teamBurst(w.root.Position, w.team, 1.2)
	end)
	task.delay(1.7, function()
		anim(w.npc, "cineCrouch", { duration = 0.25 })
	end)
	-- 1.95 s: se lanza con un uppercut gigante (el cliente lo mueve hasta dashTo)
	task.delay(1.95, function()
		anim(w.npc, "superUpper", { speed = 1.3 })
		Battle.vfx("dust", wFloor, 10)
		Effects.groundRing(wFloor + up * 0.2, color, 14, 0.4)
	end)
	-- impacto: el perdedor sale volando (K.O.)
	task.delay(Battle.FINISHER_IMPACT, function()
		if Battle.current ~= b then
			return
		end
		w.root.CFrame = CFrame.lookAt(dashTo + up * wHeight, dashTo + up * wHeight + dir)
		local impactPoint = l.root.Position + up
		fx("hitstop", { a = w.npc, b = l.npc, time = 0.2 })
		Effects.koBlast(impactPoint, color)
		Effects.lightBurst(impactPoint, color, 8, 45, 0.7)
		Battle.vfx("shockSprite", impactPoint, color, 26, 0.5)
		Battle.vfx("groundCrack", lFloor, color, 12)
		Battle.vfx("debris", lFloor, 16)
		Environment.flash(color, 1.2, 2.5)
		Environment.strobe({ color, Color3.new(1, 1, 1) }, 8, 0.15)
		local loserNpc, loserRoot = l.npc, l.root
		loserRoot.Anchored = false
		pcall(function()
			loserRoot:SetNetworkOwner(nil) -- (al desanclarlo, Roblox se lo daba al cliente y el empujón no llegaba)
		end)
		knockOut(loserNpc, w.npc, "battle")
		-- sale volando entero (con el muñeco de trapo cada parte del cuerpo va por su cuenta)
		local launch = dir * 70 + Vector3.new(0, 75, 0)
		task.defer(function()
			for _, part in ipairs(loserNpc:GetDescendants()) do
				if part:IsA("BasePart") and not part.Anchored then
					part.AssemblyLinearVelocity = launch
				end
			end
			pcall(function()
				loserRoot.AssemblyAngularVelocity = Vector3.new(math.random(-10, 10), math.random(-5, 5), math.random(-10, 10))
			end)
		end)
	end)
	task.delay(4.2, function()
		if Battle.alive(w) then
			anim(w.npc, "victory", { duration = 1.6, variant = 2 })
			Effects.confetti(w.root.Position + up * 5, 120)
		end
	end)
	task.delay(5.9, function()
		if Battle.alive(w) then
			anim(w.npc, "cineRoar", { duration = 1.2 })
			Effects.teamBurst(w.root.Position + up * 1.5, w.team, 1.5)
		end
	end)
	task.wait(Battle.FINISHER_DURATION)

	stateFolder:SetAttribute("BattleFinisher", false)
	if Battle.current ~= b then
		return
	end
	if Battle.alive(w) then
		w.root.Anchored = false
		w.npc:SetAttribute("Mode", "celebrate")
		w.npc:SetAttribute("OpponentKey", "")
	end
	Battle.wins[w.id] += 1
	b.phase = "over"
	Battle.dirty = true
	-- (la pantalla de resultado la dibuja el HUD de batalla con phase = "over")
	task.wait(6)
	Battle.finish(b)
end

function Battle.runTie(b)
	for _, s in ipairs({ b.me, b.rival }) do
		if Battle.alive(s) then
			s.npc:SetAttribute("Mode", "celebrate")
			anim(s.npc, "victory", { duration = 1.6 })
			popup(s.npc, "🤝 EMPATE", Color3.fromRGB(230, 230, 240), 1.6, "pop")
		end
	end
	b.phase = "over"
	Battle.dirty = true
	Audio.play("Cheer", { group = "Crowd", volume = 0.7 })
	task.wait(5)
	Battle.finish(b)
end

-- ----- Eventos del bridge -----

function Battle.start(event)
	if settings.GameMode ~= "Batalla" then
		print("⚔️ Hay una batalla en TikTok, pero el juego está en modo Solo (cámbialo a Batalla en el panel)")
		return
	end
	local current = Battle.current
	if current then
		if event.id and current.id == event.id then
			return
		end
		Battle.finish(current)
	end
	local b = {
		id = event.id or tostring(os.clock()),
		phase = "intro",
		me = Battle.newSide("me", event.me, "hero"),
		rival = Battle.newSide("rival", event.rival, "villain"),
		startedAt = Workspace:GetServerTimeNow(),
		crowd = 0, -- likes hacia la energía del público
		supporters = {}, -- nombre -> monedas regaladas en esta batalla
	}
	local duration = tonumber(event.duration) or 0
	if duration > 0 then
		b.endsAt = Workspace:GetServerTimeNow() + duration
	end
	Battle.current = b
	stateFolder:SetAttribute("BattleActive", true)
	Battle.dirty = true
	print("⚔️ Batalla: " .. b.me.name .. " vs " .. b.rival.name)
	task.spawn(function()
		local ok, err = pcall(Battle.run, b)
		if not ok then
			warn("⚠️ Error en la batalla: " .. tostring(err))
			Battle.finish(b)
		end
	end)
end

function Battle.points(event)
	local b = Battle.current
	if not b or (event.id and b.id ~= event.id) or b.phase == "finisher" or b.phase == "over" then
		return
	end
	for _, key in ipairs({ "me", "rival" }) do
		local s = b[key]
		local value = tonumber(event[key])
		if value and value > s.points then
			local delta = value - s.points
			s.points = value
			if os.clock() > s.absorbUntil then
				s.absorb = 0
			end
			local absorbed = math.min(s.absorb, delta)
			s.absorb -= absorbed
			s.pending += delta - absorbed
			Battle.updatePower(s)
		elseif value then
			s.points = value
		end
	end
	Battle.dirty = true
end

function Battle.ended(event)
	local b = Battle.current
	if not b or (event.id and b.id ~= event.id) or b.phase == "finisher" or b.phase == "over" then
		return
	end
	for _, key in ipairs({ "me", "rival" }) do
		local value = tonumber(event[key])
		if value then
			b[key].points = math.max(b[key].points, value)
		end
	end
	local winner = event.winner
	if winner ~= "me" and winner ~= "rival" and winner ~= "tie" then
		winner = if b.me.points > b.rival.points then "me" elseif b.rival.points > b.me.points then "rival" else "tie"
	end
	b.winner = winner
	Battle.dirty = true
	if b.phase == "intro" then
		b.pendingEnd = true -- (el final se lanza en cuanto termine la presentación)
		return
	end
	b.phase = "finisher"
	task.spawn(function()
		local ok, err = pcall(Battle.runFinish, b)
		if not ok then
			warn("⚠️ Error en el ataque final: " .. tostring(err))
			stateFolder:SetAttribute("BattleFinisher", false)
			Battle.finish(b)
		end
	end)
end

-- Regalo de este live durante una batalla: ataque especial de MI campeón.
-- Devuelve true si lo usó la batalla (si no, el regalo sigue su camino normal).
function Battle.gift(event)
	local b = Battle.current
	if not b then
		return false
	end
	local name = cleanName(event.name, event.user)
	local giftId = tonumber(event.giftId)
	local count = math.clamp(math.floor(tonumber(event.count) or 1), 1, 100)
	local info = giftId and Shared.GIFTS[giftId]
	local coins = math.max(1, tonumber(event.diamonds) or 1) * count
	local def
	if info and info.action == "rain" then
		def = Battle.SPECIALS.rain
	elseif info then
		def = Battle.SPECIALS[info.level]
	else
		for _, step in ipairs(Shared.BATTLE.COIN_LEVELS) do
			if coins >= step[1] then
				def = Battle.SPECIALS[step[2]]
				break
			end
		end
	end
	local me = b.me
	b.supporters[name] = (b.supporters[name] or 0) + coins
	Battle.dirty = true
	hud("battleEvent", {
		kind = if def then "special" else "gift",
		side = "me",
		user = name,
		gift = if info then info.gift else tostring(event.giftName or "un regalo"),
		image = if info then info.image else nil,
		count = count,
		coins = coins,
		level = if def then def.level else nil,
		attack = if def then def.name else nil,
	})
	Audio.play("Chime", { volume = 0.5, minInterval = 0.2 })
	if def and (b.phase == "intro" or b.phase == "fight") and #me.specials < 6 then
		table.insert(me.specials, { def = def, by = name })
		-- los puntos que traiga este regalo ya pegan en el ataque especial
		me.absorb += coins
		me.absorbUntil = os.clock() + 4
	end
	return true
end

-- Likes durante la batalla: llenan la ENERGÍA DEL PÚBLICO; al llenarse, tu
-- campeón lanza el GOLPE DEL PÚBLICO (los likes no dan puntos en TikTok).
function Battle.like(event)
	local b = Battle.current
	if not b or (b.phase ~= "intro" and b.phase ~= "fight") then
		return
	end
	local amount = math.clamp(math.floor(tonumber(event.count) or 1), 1, 1000)
	local goal = math.max(1, settings.BattleLikeGoal)
	b.crowd += amount
	hud("battleEvent", { kind = "likes", user = cleanName(event.name, event.user), count = amount })
	while b.crowd >= goal do
		b.crowd -= goal
		if #b.me.specials < 6 then
			table.insert(b.me.specials, { def = Battle.SPECIALS.crowd, by = "público" })
		end
		hud("battleEvent", { kind = "crowd", side = "me", name = b.me.name })
		Audio.play("Cheer", { group = "Crowd", volume = 0.7, minInterval = 1 })
		spectatorsCheer(10)
	end
	Battle.dirty = true
end

-- Seguir durante la batalla: cura a tu campeón
function Battle.follow(event)
	local b = Battle.current
	local me = b and b.me
	if not b or (b.phase ~= "intro" and b.phase ~= "fight") or not Battle.alive(me) then
		return
	end
	local name = cleanName(event.name, event.user)
	local maxHealth = me.npc:GetAttribute("MaxHealth") or Config.HEALTH_MAX
	local gained = heal(me.npc, maxHealth * Shared.BATTLE.FOLLOW_HEAL)
	popup(me.npc, "➕ " .. name .. "  +" .. math.floor(gained + 0.5) .. " ❤", Color3.fromRGB(120, 255, 150), 1.3, "pop")
	Effects.healBurst(me.root.Position, Color3.fromRGB(120, 255, 150), 18)
	Audio.play("Heal", { volume = 0.6, minInterval = 0.5 })
	hud("battleEvent", { kind = "follow", side = "me", user = name, heal = gained })
end

-- Si pasan a modo Solo en plena batalla, se termina sin ganador
function Battle.onModeChanged(mode)
	Battle.dirty = true
	if mode ~= "Batalla" and Battle.current then
		Battle.finish(Battle.current)
	end
end

stateFolder:SetAttribute("BattleActive", false)
stateFolder:SetAttribute("BattleFinisher", false)

-- ===== EVENTOS DE TIKTOK =====

local lastLikePopup = {}

local function handleJoin(event)
	local key = normalizeKey(event.user)
	if not key then
		return
	end
	local name = cleanName(event.name, event.user)
	local team = (event.team == "hero" or event.team == "villain") and event.team or nil
	local rec = participants[key]
	if rec then
		if team and rec.team ~= team and rec.state == "waiting" then
			switchTeam(rec, team)
			hud("toast", { text = TEAMS[team].emoji .. " " .. rec.name .. " se cambió a los " .. TEAMS[team].name, team = team })
		end
		return
	end
	addParticipant(key, name, team)
end

local function handleGift(event)
	if Battle.gift(event) then
		return -- en plena batalla de TikTok el regalo es un ataque especial de tu campeón
	end
	local key = normalizeKey(event.user)
	if not key then
		return
	end
	local name = cleanName(event.name, event.user)
	local giftId = tonumber(event.giftId)
	local count = math.clamp(math.floor(tonumber(event.count) or 1), 1, 100)
	local info = giftId and Shared.GIFTS[giftId]

	if info and info.action == "rain" then
		hud("announce", {
			kind = "gift",
			mergeKey = key .. ":" .. giftId,
			user = name,
			gift = info.gift,
			count = count,
			subtitle = info.tier,
			team = info.team,
			image = info.image,
			duration = 2.5,
		})
		Audio.play("Chime", { volume = 0.6, minInterval = 0.2 })
		for _ = 1, math.min(count, 3) do
			startGloveRain(info.rain, name)
		end
		return
	end

	if info then
		local times = math.min(count, 10)
		local rec = participants[key]
		if not rec then
			rec = addParticipant(key, name, info.team, {
				health = info.health * times,
				damage = info.damage * times,
				speed = info.speed * times,
			}, true)
		else
			switchTeam(rec, info.team)
			local gained = boostRecord(rec, info.health * times, info.damage * times, info.speed * times)
			local npc = rec.npc
			if npc and npc.Parent then
				popup(npc, "+" .. math.floor(gained + 0.5) .. " ❤  +" .. math.floor(info.damage * times * 100 + 0.5) .. "% 👊", Shared.teamColor(info.team), 1.3, "pop")
				local root = npc:FindFirstChild("HumanoidRootPart")
				if root then
					Effects.boostPillar(root.Position, info.team, info.level)
				end
				if rec.state == "ring" then
					fx("focus", { target = npc, duration = 1.6, priority = 2, shot = "boost" })
				end
			end
			if rec.state == "waiting" and not rec.priority then
				-- los donadores se adelantan en la fila
				local index = table.find(lineup, rec)
				if index then
					table.remove(lineup, index)
					insertIntoLineup(rec, true)
				end
			end
		end
		hud("announce", {
			kind = "gift",
			mergeKey = key .. ":" .. giftId,
			user = name,
			gift = info.gift,
			count = count,
			subtitle = TEAMS[info.team].single .. " " .. string.upper(info.tier) .. " • " .. Shared.giftEffectText(info),
			team = info.team,
			image = info.image,
			duration = 2.6,
		})
		if rec then
			-- el regalo más alto decide la entrada de cine (Élite / Definitivo)
			rec.giftLevel = math.max(rec.giftLevel or 0, info.level or 0)
			-- si ya está peleando en el ring, también hace su entrada (una vez por nivel)
			local kind = entranceKind(rec)
			if kind and rec.state == "ring" and rec.npc and rec.npc.Parent == activeFighters
				and KIND_RANK[kind] > (KIND_RANK[rec.shownEntrance] or 0) then
				rec.shownEntrance = kind
				task.spawn(replayEntrance, rec, kind)
			end
		end
		Audio.play("PowerUp", { volume = 0.6, minInterval = 0.15 })
		Environment.flash(Shared.teamColor(info.team), 0.7, 2)
		return
	end

	-- Cualquier otro regalo: te mete a pelear, o cura a tu peleador
	local diamonds = math.max(1, tonumber(event.diamonds) or 1)
	local rec = participants[key]
	if rec and rec.npc and rec.npc.Parent and rec.state == "ring" then
		local amount = math.min(Config.UNKNOWN_GIFT_HEAL_MAX, diamonds * count * Config.UNKNOWN_GIFT_HEAL_PER_DIAMOND)
		local gained = heal(rec.npc, amount)
		popup(rec.npc, "🎁 +" .. math.floor(gained + 0.5) .. " ❤", Color3.fromRGB(255, 130, 200), 1.2, "pop")
		local root = rec.npc:FindFirstChild("HumanoidRootPart")
		if root then
			Effects.healBurst(root.Position, Color3.fromRGB(255, 130, 200), 16)
		end
	elseif not rec then
		addParticipant(key, name, nil, nil, true)
	end
	hud("toast", { text = "🎁 " .. name .. " envió " .. tostring(event.giftName or "un regalo") .. (count > 1 and (" x" .. count) or ""), team = rec and rec.team or nil })
	Audio.play("Chime", { volume = 0.45, minInterval = 0.2 })
end

local function handleLike(event)
	Battle.like(event) -- (en plena batalla, además, llenan la energía del público)
	local count = math.clamp(math.floor(tonumber(event.count) or 1), 1, 1000)
	totalLikes += count
	likeProgress += count
	likesDirty = true

	local key = normalizeKey(event.user)
	local rec = key and participants[key]
	if key and not rec and settings.LikeJoins then
		-- un like te mete a la fila para pelear (equipo automático)
		addParticipant(key, cleanName(event.name, event.user), nil)
	end
	if rec and rec.state == "ring" and rec.npc and rec.npc.Parent then
		local amount = math.min(Config.LIKE_HEAL_MAX_PER_EVENT, count * Config.LIKE_HEAL_PER_LIKE)
		local gained = heal(rec.npc, amount)
		local now = os.clock()
		if gained > 0 and (not lastLikePopup[key] or now - lastLikePopup[key] > 1.5) then
			lastLikePopup[key] = now
			popup(rec.npc, "❤ +" .. math.floor(gained + 0.5), Color3.fromRGB(255, 110, 170), 0.9, "rise")
			local root = rec.npc:FindFirstChild("HumanoidRootPart")
			if root then
				Effects.healBurst(root.Position, Color3.fromRGB(255, 110, 170), 8)
			end
		end
	end

	local goal = settings.LikeGoal
	while likeProgress >= goal do
		likeProgress -= goal
		if likeGoalCount % 2 == 0 then
			triggerFury("Meta de likes")
		else
			triggerHeartRain("Meta de likes")
		end
		likeGoalCount += 1
	end
end

local function handleFollow(event)
	Battle.follow(event) -- (en plena batalla, además, cura a tu campeón)
	local key = normalizeKey(event.user)
	local name = cleanName(event.name, event.user)
	hud("announce", { kind = "follow", title = "💖 " .. name, subtitle = "¡Nuevo seguidor!", color = Color3.fromRGB(255, 90, 150), duration = 2.2 })
	Audio.play("Chime", { volume = 0.55, minInterval = 0.3 })
	local rec = key and participants[key]
	if key and not rec and settings.FollowJoins then
		-- seguir te mete a pelear con vida extra
		addParticipant(key, name, nil, { health = Config.FOLLOW_HEALTH_BONUS / Config.HEALTH_MAX })
		return
	end
	if rec then
		local gained = boostRecord(rec, Config.FOLLOW_HEALTH_BONUS / Config.HEALTH_MAX, 0, 0)
		if rec.npc and rec.npc.Parent then
			popup(rec.npc, "+" .. math.floor(gained + 0.5) .. " ❤ SEGUIDOR", Color3.fromRGB(255, 110, 170), 1.2, "pop")
		end
	end
end

local function setViewers(count)
	viewers = math.max(0, math.floor(tonumber(count) or 0))
	stateFolder:SetAttribute("Viewers", viewers)
	hud("viewers", viewers)
end

-- ===== COMANDOS (panel dev dentro del juego y panel web) =====

local function resetFighters()
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local rec = participants[npc:GetAttribute("UserKey")]
		if rec and rec.npc == npc then
			participants[rec.key] = nil
		end
		npc:SetAttribute("KnockedOut", true)
		releaseFighter(npc)
		npc:Destroy()
	end
	queueDirty, scoreDirty = true, true
end

local function resetQueue()
	for _, rec in ipairs(lineup) do
		removeSpectatorNpc(rec)
		participants[rec.key] = nil
		rec.state = "removed"
	end
	table.clear(lineup)
	queueDirty, scoreDirty = true, true
end

local function resetScore()
	teamWins.hero, teamWins.villain = 0, 0
	table.clear(sessionStats)
	for _, rec in pairs(participants) do
		rec.streak = 0
		getStats(rec)
		if rec.npc and rec.npc.Parent then
			rec.npc:SetAttribute("Streak", 0)
			Effects.streakSparkles(rec.npc, false)
		end
	end
	totalLikes, likeProgress = 0, 0
	scoreDirty, topDirty, likesDirty = true, true, true
end

local botCounter = 0

local function simUser(name)
	name = cleanName((name and name ~= "") and name or nil, "Tester")
	return { user = "sim_" .. string.lower(name), name = name }
end

local COMMANDS = {}

COMMANDS.simJoin = function(args)
	local user = simUser(args.name)
	handleJoin({ user = user.user, name = user.name, team = args.team })
end

COMMANDS.simBots = function(args)
	local count = math.clamp(math.floor(tonumber(args.count) or 6), 1, 40)
	for _ = 1, count do
		botCounter += 1
		local base = Config.BOT_NAMES[math.random(1, #Config.BOT_NAMES)]
		local team = args.team
		if team ~= "hero" and team ~= "villain" then
			team = nil
		end
		handleJoin({ user = "bot_" .. botCounter, name = base .. botCounter, team = team })
	end
end

COMMANDS.simGift = function(args)
	local user = simUser(args.name)
	handleGift({
		user = user.user,
		name = user.name,
		giftId = tonumber(args.giftId),
		count = tonumber(args.count) or 1,
		giftName = args.giftName or "Regalo",
		diamonds = tonumber(args.diamonds) or 1,
	})
end

COMMANDS.simLikes = function(args)
	local user = simUser(args.name)
	handleLike({ user = user.user, name = user.name, count = tonumber(args.count) or 50 })
end

COMMANDS.simFollow = function(args)
	local user = simUser(args.name)
	handleFollow({ user = user.user, name = user.name })
end

-- Prueba de entrada de cine: mete a alguien con un regalo Élite o Definitivo y
-- lo hace entrar al ring ya (aunque el ring esté lleno)
COMMANDS.testEntrance = function(args)
	local definitive = args.kind == "definitive"
	local team = args.team
	if team ~= "hero" and team ~= "villain" then
		team = if math.random() < 0.5 then "hero" else "villain"
	end
	local giftId
	if definitive then
		giftId = if team == "hero" then 5660 else 5585
	else
		giftId = if team == "hero" then 8913 else 9947
	end
	botCounter += 1
	local name = (if definitive then "Definitivo" else "Elite") .. botCounter
	local user = "test_" .. string.lower(name)
	handleGift({ user = user, name = name, giftId = giftId, count = 1 })
	local rec = participants[normalizeKey(user)]
	if rec and rec.state == "waiting" then
		local index = table.find(lineup, rec)
		if index then
			table.remove(lineup, index)
		end
		removeSpectatorNpc(rec)
		queueDirty = true
		task.spawn(spawnFighter, rec)
	end
end

COMMANDS.rain = function(args)
	startGloveRain(args.kind == "dark" and "dark" or "gold", args.name)
end

COMMANDS.fury = function()
	triggerFury("Panel")
end

COMMANDS.hearts = function()
	triggerHeartRain("Panel")
end

COMMANDS.healAll = function()
	for _, npc in ipairs(activeFighters:GetChildren()) do
		heal(npc, npc:GetAttribute("MaxHealth") or Config.HEALTH_MAX, "❤ CURADO")
	end
end

COMMANDS.chargeAll = function()
	for _, npc in ipairs(activeFighters:GetChildren()) do
		addEnergy(npc, 100)
	end
end

COMMANDS.koRandom = function()
	local list = activeFighters:GetChildren()
	if #list == 0 then
		return
	end
	local npc = list[math.random(1, #list)]
	npc:SetAttribute("Health", 0)
	if busy[npc] ~= "match" then
		knockOut(npc, nil, "panel")
	end
end

COMMANDS.resetFighters = resetFighters
COMMANDS.resetQueue = resetQueue
COMMANDS.resetScore = resetScore
COMMANDS.resetAll = function()
	resetFighters()
	resetQueue()
	resetScore()
end

COMMANDS.setSetting = function(args)
	setSetting(args.key, args.value, true)
end

COMMANDS.resetSettings = function()
	for key, value in pairs(Shared.DEFAULT_SETTINGS) do
		setSetting(key, value, false)
	end
	Bridge.saveSettings(settings)
end

COMMANDS.announce = function(args)
	local text = string.sub(tostring(args.text or ""), 1, 90)
	if text ~= "" then
		hud("announce", { kind = "custom", title = text, color = Color3.fromRGB(120, 200, 255), duration = 4 })
		Audio.play("Chime", { volume = 0.5 })
	end
end

-- ----- Modo batalla (pruebas sin live) -----
COMMANDS.simBattleStart = function(args)
	if settings.GameMode ~= "Batalla" then
		setSetting("GameMode", "Batalla", true)
	end
	botCounter += 1
	Battle.start({
		id = "sim" .. botCounter,
		me = { name = args.meName or "Yo (prueba)", user = "sim_yo" },
		rival = { name = args.rivalName or "Rival (prueba)", user = "sim_rival" },
		duration = tonumber(args.duration) or 0,
	})
end

COMMANDS.simBattlePoints = function(args)
	local b = Battle.current
	if not b then
		return
	end
	local side = if args.side == "rival" then "rival" else "me"
	local amount = math.clamp(math.floor(tonumber(args.amount) or 10), 1, 100000)
	Battle.points({
		id = b.id,
		me = b.me.points + (if side == "me" then amount else 0),
		rival = b.rival.points + (if side == "rival" then amount else 0),
	})
end

-- level 1..5 = regalo de ese nivel, 6 = regalo de lluvia
COMMANDS.simBattleGift = function(args)
	local b = Battle.current
	if not b then
		return
	end
	local level = math.clamp(math.floor(tonumber(args.level) or 3), 1, 6)
	local giftId
	for id, info in pairs(Shared.GIFTS) do
		if (level == 6 and info.action == "rain") or (info.level == level and info.team == "hero") then
			giftId = id
			break
		end
	end
	local coins = ({ 5, 30, 100, 300, 1000, 199 })[level]
	local user = simUser(args.name)
	Battle.gift({ user = user.user, name = user.name, giftId = giftId, count = 1, diamonds = coins, giftName = "Regalo" })
	-- (en un live de verdad TikTok sumaría estos puntos a tu lado)
	Battle.points({ id = b.id, me = b.me.points + coins, rival = b.rival.points })
end

-- winner = "me" | "rival" | "tie" (sin winner: gana quien tenga más puntos)
COMMANDS.simBattleEnd = function(args)
	local b = Battle.current
	if b then
		Battle.ended({ id = b.id, winner = args.winner })
	end
end
COMMANDS.endBattle = COMMANDS.simBattleEnd

local function runCommand(action, args)
	local command = COMMANDS[action]
	if not command then
		warn("⚠️ Comando desconocido: " .. tostring(action))
		return
	end
	local ok, err = pcall(command, type(args) == "table" and args or {})
	if not ok then
		warn("⚠️ Error en el comando " .. tostring(action) .. ": " .. tostring(err))
	end
end

local function handleEvent(event)
	if type(event) ~= "table" then
		return
	end
	local kind = event.type
	-- (el chat y los compartidos ya no se usan: solo regalos, likes y follows)
	if kind == "gift" then
		handleGift(event)
	elseif kind == "like" then
		handleLike(event)
	elseif kind == "follow" then
		handleFollow(event)
	elseif kind == "viewers" then
		setViewers(event.count)
	elseif kind == "admin" then
		runCommand(event.action, event)
	elseif kind == "battleStart" then
		Battle.start(event)
	elseif kind == "battlePoints" then
		Battle.points(event)
	elseif kind == "battleEnd" then
		Battle.ended(event)
	end
end

Bridge.start(function(events)
	for _, event in ipairs(events) do
		local ok, err = pcall(handleEvent, event)
		if not ok then
			warn("⚠️ Error con un evento de TikTok: " .. tostring(err))
		end
	end
end)

-- ===== JUGADORES (el streamer) =====

local function isDeveloper(player)
	if RunService:IsStudio() then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	-- modo online: el streamer dueño de este servidor (el primero que entró)
	return Online.isOwner(player)
end

local function onPlayerAdded(player)
	Online.playerAdded(player) -- (antes de decidir quién tiene el panel dev)
	player:SetAttribute("ArenaDev", isDeveloper(player))
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

devCommand.OnServerEvent:Connect(function(player, action, args)
	if action == "hello" then
		sendSnapshot(player)
		return
	end
	if not player:GetAttribute("ArenaDev") or type(action) ~= "string" then
		return
	end
	if action == "linkOnline" then
		Online.link(player, args) -- pantalla "Conecta tu TikTok"
		return
	elseif action == "unlinkOnline" then
		Online.unlink(player)
		return
	end
	runCommand(action, args)
end)

-- ===== BUCLES PRINCIPALES =====

-- Arena: gradas -> ring -> duelos
task.spawn(function()
	while true do
		local ok, err = pcall(function()
			if not settings.Paused and not inCinematic() and not Battle.current then
				breakSameTeamDeadlock()
				fillRing()
				pairFighters()
			end
			fillSpectators()
			if not inCinematic() and not Battle.current then
				updateIdleFighters()
			end
		end)
		if not ok then
			warn("⚠️ Error en el bucle de la arena: " .. tostring(err))
		end
		task.wait(0.5)
	end
end)

-- Animación de caminar según la velocidad real de cada peleador
task.spawn(function()
	while true do
		task.wait(0.1)
		local ok, err = pcall(updateLocomotion)
		if not ok then
			warn("⚠️ Error en la animación de caminar: " .. tostring(err))
		end
	end
end)

-- HUD: manda solo lo que cambió, como mucho 4 veces por segundo
task.spawn(function()
	while true do
		task.wait(0.25)
		if queueDirty then
			queueDirty = false
			hud("queue", queuePayload())
			scoreDirty = true
		end
		if scoreDirty then
			scoreDirty = false
			hud("score", scorePayload())
		end
		if topDirty then
			topDirty = false
			hud("top", topPayload())
		end
		if likesDirty then
			likesDirty = false
			hud("likes", likesPayload())
		end
		if Battle.dirty then
			Battle.dirty = false
			hud("battle", Battle.payload())
		end
		stateFolder:SetAttribute("Fighters", #activeFighters:GetChildren())
		stateFolder:SetAttribute("Waiting", #lineup)
		stateFolder:SetAttribute("TotalLikes", totalLikes)
		local loaded, total = Avatars.loadedCount()
		stateFolder:SetAttribute("Avatars", loaded .. "/" .. total)
	end
end)

print("🥊 ¡A LA TROMPA! listo — F2 abre el panel dev")
