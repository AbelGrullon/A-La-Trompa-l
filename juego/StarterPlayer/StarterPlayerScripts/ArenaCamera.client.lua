-- ArenaCamera (LocalScript en StarterPlayerScripts)
-- Cámara del stream. Modos (se eligen en el panel dev → Cámara):
--   Director   : realizador automático, cambia de plano solo y corta a los
--                momentos importantes (KO, súper golpes, regalos, rachas).
--   Orbita     : vuelta lenta alrededor de todos los peleadores.
--   General    : plano fijo abierto de todo el ring.
--   Accion     : siempre pegada al duelo más intenso.
--   Cenital    : desde arriba.
--   Cinematica : travellings lentos, sin cortes por eventos.
--   Libre      : la manejas tú (clic derecho + WASD, Q/E, Shift = rápido).
-- Además: sacudidas, zoom de impacto, destellos de color y desenfoque.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local arena = ReplicatedStorage:WaitForChild("Arena")
local Shared = require(arena:WaitForChild("Shared"))
local settingsFolder = arena:WaitForChild("Settings")
local fxEvent = arena:WaitForChild("Remotes"):WaitForChild("FxEvent")
local stateFolder = arena:WaitForChild("State")

local ring = Workspace:WaitForChild("Ring")
local activeFighters = Workspace:WaitForChild("ActiveFighters")

local function setting(key)
	local value = settingsFolder:GetAttribute(key)
	if value == nil then
		value = Shared.DEFAULT_SETTINGS[key]
	end
	return value
end

-- ===== CENTRO DEL RING =====
local ringCenter
do
	local sum, count = Vector3.zero, 0
	for i = 1, 4 do
		for _, prefix in ipairs({ "SpawnA", "SpawnB" }) do
			local point = ring:WaitForChild(prefix .. i)
			sum += point.Position
			count += 1
		end
	end
	ringCenter = sum / count
end

-- ===== EFECTOS DE PANTALLA (solo en este cliente) =====
local flashEffect = Instance.new("ColorCorrectionEffect")
flashEffect.Name = "CameraFlash"
flashEffect.Parent = Lighting

local blurEffect = Instance.new("BlurEffect")
blurEffect.Name = "CameraBlur"
blurEffect.Size = 0
blurEffect.Parent = Lighting

local function screenFlash(color, intensity)
	if not setting("ScreenFlashes") then
		return
	end
	intensity = intensity or 0.3
	flashEffect.TintColor = color:Lerp(Color3.new(1, 1, 1), 0.55)
	flashEffect.Brightness = intensity
	flashEffect.Contrast = intensity * 0.5
	TweenService:Create(flashEffect, TweenInfo.new(0.45, Enum.EasingStyle.Quad), {
		TintColor = Color3.new(1, 1, 1),
		Brightness = 0,
		Contrast = 0,
	}):Play()
end

local function blurPulse(size, duration)
	if not setting("ScreenFlashes") then
		return
	end
	blurEffect.Size = size
	TweenService:Create(blurEffect, TweenInfo.new(duration or 0.5, Enum.EasingStyle.Quad), { Size = 0 }):Play()
end

-- ===== ESTADO DE CÁMARA =====
local camera = Workspace.CurrentCamera
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera = Workspace.CurrentCamera
end)

local currentCFrame = CFrame.lookAt(ringCenter + Vector3.new(0, 30, 60), ringCenter)
local currentFov = 70
local trauma = 0
local fovKick = 0
local clock = 0

local focus = nil -- { target, position, shot, priority, untilTime, startedAt }
local lastFocusAt = -100
local directorShot = nil -- { name, untilTime, data }
local lastMode = nil

-- Cámara libre
local freeYaw, freePitch = 0, -0.3
local freePosition = currentCFrame.Position

local function aspectFactor()
	local viewport = camera.ViewportSize
	local aspect = viewport.X / math.max(viewport.Y, 1)
	if aspect >= 1.3 then
		return 1
	end
	-- En vertical el campo horizontal es estrecho: hay que alejarse más
	return math.clamp(1.45 / aspect, 1, 2.6)
end

local function isPortrait()
	local viewport = camera.ViewportSize
	return viewport.Y > viewport.X
end

-- Para planos de grupo: en vertical no hace falta alejarse todo el factor,
-- se sacrifica un poco de ancho a cambio de ver a los peleadores más grandes.
local function groupFactor()
	return aspectFactor() ^ 0.7
end

local function fighterRoots()
	local roots = {}
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local root = npc:FindFirstChild("HumanoidRootPart")
		if root then
			table.insert(roots, root)
		end
	end
	return roots
end

local function groupFrame()
	local roots = fighterRoots()
	if #roots == 0 then
		return ringCenter, 30
	end
	local center = Vector3.zero
	for _, root in ipairs(roots) do
		center += root.Position
	end
	center /= #roots
	local maxDistance = 0
	for _, root in ipairs(roots) do
		maxDistance = math.max(maxDistance, (root.Position - center).Magnitude)
	end
	-- el centro tira un poco hacia el centro del ring para que no se vaya al borde
	center = center:Lerp(ringCenter, 0.25)
	return center, math.clamp(maxDistance * 1.6 + 14, 28, 80)
end

local function findDuels()
	local duels, seen = {}, {}
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local opponentKey = npc:GetAttribute("OpponentKey")
		if opponentKey and opponentKey ~= "" and not seen[npc] then
			local opponent = activeFighters:FindFirstChild(opponentKey)
			if opponent then
				seen[npc], seen[opponent] = true, true
				local ratioA = (npc:GetAttribute("Health") or 1) / (npc:GetAttribute("MaxHealth") or 1)
				local ratioB = (opponent:GetAttribute("Health") or 1) / (opponent:GetAttribute("MaxHealth") or 1)
				table.insert(duels, { a = npc, b = opponent, intensity = 2 - math.min(ratioA, ratioB) })
			end
		end
	end
	table.sort(duels, function(x, y)
		return x.intensity > y.intensity
	end)
	return duels
end

local function champion()
	local best, bestStreak = nil, 1
	for _, npc in ipairs(activeFighters:GetChildren()) do
		local streak = npc:GetAttribute("Streak") or 0
		if streak > bestStreak then
			best, bestStreak = npc, streak
		end
	end
	return best
end

-- ===== ANTI-OBSTÁCULOS =====
-- Si una estatua, pared o decorado sólido queda entre la cámara y lo que
-- mira, la cámara se adelanta hasta quedar delante del obstáculo.
local occlusionParams = RaycastParams.new()
occlusionParams.FilterType = Enum.RaycastFilterType.Exclude
local ignoredParts = {}

local function refreshOcclusionFilter()
	local list = {}
	for _, name in ipairs({ "ActiveFighters", "WaitingFighters", "ArenaFX", "ArenaStage", "Mapa", "Espectadores" }) do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(list, folder)
		end
	end
	if player.Character then
		table.insert(list, player.Character)
	end
	for part in pairs(ignoredParts) do
		if part.Parent then
			table.insert(list, part)
		else
			ignoredParts[part] = nil
		end
	end
	occlusionParams.FilterDescendantsInstances = list
end
refreshOcclusionFilter()
task.spawn(function()
	while true do
		task.wait(3)
		refreshOcclusionFilter()
	end
end)

local function unobstructed(lookAt, position)
	local offset = position - lookAt
	if offset.Magnitude < 2 then
		return position
	end
	for _ = 1, 4 do
		local hit = Workspace:Raycast(lookAt, offset, occlusionParams)
		if not hit then
			return position
		end
		local part = hit.Instance
		if part:IsA("BasePart") and (part.Transparency >= 0.8 or (not part.CanCollide and part.Size.Magnitude < 6)) then
			-- vidrio, partes invisibles o detalles finos: no cuentan como obstáculo
			ignoredParts[part] = true
			occlusionParams:AddToFilter(part)
		else
			return hit.Position - offset.Unit * 1.5
		end
	end
	return position
end

-- ===== PLANOS =====
-- Cada plano devuelve: posición, punto al que mira, desplazamiento de FOV.

local SHOTS = {}

function SHOTS.orbit(data)
	local center, radius = groupFrame()
	radius *= groupFactor()
	local angle = (data.angle or 0) + clock * 0.06 * setting("CameraSpeed")
	local height = 10 + radius * 0.5
	return center + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius), center + Vector3.new(0, 3, 0), 0
end

-- El plano general busca solo el ángulo despejado más cercano al frente
-- (hay estatuas y decorados grandes alrededor del ring).
local generalAngle = 0
local function chooseGeneralAngle()
	refreshOcclusionFilter()
	local origin = ringCenter + Vector3.new(0, 3, 0)
	for _, degrees in ipairs({ 0, 12, -12, 22, -22, 32, -32, 45, -45, 60, -60, 90, -90, 135, -135, 180 }) do
		local angle = math.rad(degrees)
		local target = origin + Vector3.new(math.sin(angle) * 130, 68, math.cos(angle) * 130)
		if (unobstructed(origin, target) - target).Magnitude < 0.1 then
			generalAngle = angle
			return
		end
	end
end
task.delay(2, chooseGeneralAngle)

function SHOTS.general()
	local factor = groupFactor()
	local sway = math.sin(clock * 0.25) * 3
	local forward = Vector3.new(math.sin(generalAngle), 0, math.cos(generalAngle))
	local side = Vector3.new(forward.Z, 0, -forward.X)
	local position = ringCenter + forward * 62 * factor + side * sway + Vector3.new(0, 34 * factor, 0)
	return position, ringCenter + Vector3.new(0, 2, 0), 0
end

function SHOTS.wide()
	local center = groupFrame()
	local factor = groupFactor()
	local angle = clock * 0.04
	return center + Vector3.new(math.cos(angle) * 55 * factor, 50 * factor, math.sin(angle) * 55 * factor), center, 5
end

function SHOTS.top(data)
	local center = groupFrame()
	local angle = (data.angle or 0) + clock * 0.05
	local position = center + Vector3.new(0, 70 * groupFactor(), 0)
	return position, center, 0, Vector3.new(math.cos(angle), 0, math.sin(angle))
end

function SHOTS.dolly(data)
	local factor = groupFactor()
	local progress = ((clock - (data.startedAt or 0)) / (data.duration or 8))
	local side = data.side or 1
	local along = -45 + math.clamp(progress, 0, 1) * 90
	local axis = data.axis or Vector3.new(1, 0, 0)
	local normal = axis:Cross(Vector3.yAxis) * side
	local position = ringCenter + axis * along * 0.6 + normal * 48 * factor + Vector3.new(0, 10 + math.sin(progress * math.pi) * 10, 0)
	return position, ringCenter + Vector3.new(0, 3, 0), -5
end

function SHOTS.fight(data)
	local duel = data.duel
	if not duel or duel.a.Parent ~= activeFighters or duel.b.Parent ~= activeFighters then
		duel = findDuels()[1]
		data.duel = duel
	end
	if not duel then
		return SHOTS.orbit(data)
	end
	local rootA = duel.a:FindFirstChild("HumanoidRootPart")
	local rootB = duel.b:FindFirstChild("HumanoidRootPart")
	if not rootA or not rootB then
		return SHOTS.orbit(data)
	end
	local mid = (rootA.Position + rootB.Position) / 2
	local axis = rootB.Position - rootA.Position
	axis = Vector3.new(axis.X, 0, axis.Z)
	local separation = axis.Magnitude
	axis = separation > 0.1 and axis.Unit or Vector3.new(1, 0, 0)
	local perpendicular = axis:Cross(Vector3.yAxis) * (data.side or 1)
	-- se queda del lado del ring que da hacia afuera para no atravesar cosas
	if (mid + perpendicular - ringCenter).Magnitude < (mid - ringCenter).Magnitude then
		perpendicular = -perpendicular
	end
	local distance = 22 + separation * 0.8
	local direction = perpendicular
	if isPortrait() then
		-- en vertical se mira el duelo más "de frente" (uno delante del otro)
		local along = axis * (data.side or 1)
		direction = (perpendicular * math.cos(math.rad(55)) + along * math.sin(math.rad(55))).Unit
		distance *= math.sqrt(aspectFactor())
	end
	local drift = axis * math.sin(clock * 0.4) * 3
	return mid + direction * distance + Vector3.new(0, 9, 0) + drift, mid + Vector3.new(0, 3, 0), -4
end

local function closeShot(target, style)
	local root = target and target.Parent and target:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	-- los peleadores miden 175%: los planos cerrados van más lejos que con un avatar normal
	local factor = math.sqrt(aspectFactor())
	local head = root.Position + Vector3.new(0, 4.2, 0)
	if style == "entrance" then
		local look = root.CFrame.LookVector
		return root.Position + look * 21 * factor + Vector3.new(0, 7, 0), head, -6
	elseif style == "hero" then
		local angle = clock * 0.35
		return root.Position + Vector3.new(math.cos(angle) * 16, 1.2, math.sin(angle) * 16) * factor, head + Vector3.new(0, 1.5, 0), -8
	elseif style == "victory" then
		local angle = clock * 0.7
		return root.Position + Vector3.new(math.cos(angle) * 19 * factor, 7, math.sin(angle) * 19 * factor), head, -8
	elseif style == "impact" then
		local angle = clock * 0.25 + 1
		return root.Position + Vector3.new(math.cos(angle) * 17 * factor, 6, math.sin(angle) * 17 * factor), head, -10
	else -- boost
		local angle = clock * 0.5
		return root.Position + Vector3.new(math.cos(angle) * 19 * factor, 4, math.sin(angle) * 19 * factor), head + Vector3.new(0, 1, 0), -8
	end
end

local function focusShot()
	if not focus then
		return nil
	end
	if focus.shot == "wide" then
		return SHOTS.wide()
	end
	if focus.shot == "ko" and focus.position then
		local elapsed = clock - focus.startedAt
		local factor = math.sqrt(aspectFactor())
		local away = (currentCFrame.Position - focus.position) * Vector3.new(1, 0, 1)
		away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
		local distance = (18 - math.min(elapsed, 1.5) * 3) * factor
		return focus.position + away * distance + Vector3.new(0, 7, 0), focus.position + Vector3.new(0, 2, 0), -10
	end
	return closeShot(focus.target, focus.shot)
end

-- ===== DIRECTOR =====
local DIRECTOR_PLAN = {
	{ name = "orbit", weight = 3, duration = { 6, 9 } },
	{ name = "fight", weight = 4, duration = { 5, 8 } },
	{ name = "dolly", weight = 2, duration = { 6, 9 } },
	{ name = "top", weight = 1, duration = { 4, 6 } },
	{ name = "champion", weight = 1.5, duration = { 4, 5 } },
}
local CINEMATIC_PLAN = {
	{ name = "dolly", weight = 3, duration = { 9, 13 } },
	{ name = "orbit", weight = 2, duration = { 10, 14 } },
	{ name = "top", weight = 1, duration = { 7, 9 } },
}

local function pickShot(plan, previous)
	local total = 0
	local options = {}
	for _, entry in ipairs(plan) do
		local valid = entry.name ~= previous
		-- en una batalla de TikTok: planos del duelo (y alguna órbita)
		if stateFolder:GetAttribute("BattleActive") and entry.name ~= "fight" and entry.name ~= "orbit" then
			valid = false
		end
		if entry.name == "fight" and #findDuels() == 0 then
			valid = false
		end
		if entry.name == "champion" and not champion() then
			valid = false
		end
		if valid then
			table.insert(options, entry)
			total += entry.weight
		end
	end
	if #options == 0 then
		return plan[1]
	end
	local roll = math.random() * total
	for _, entry in ipairs(options) do
		roll -= entry.weight
		if roll <= 0 then
			return entry
		end
	end
	return options[#options]
end

local function startDirectorShot(plan)
	local entry = pickShot(plan, directorShot and directorShot.name)
	local duration = entry.duration[1] + math.random() * (entry.duration[2] - entry.duration[1])
	local data = {
		angle = math.random() * math.pi * 2,
		side = math.random() < 0.5 and -1 or 1,
		startedAt = clock,
		duration = duration,
		axis = math.random() < 0.5 and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1),
	}
	if entry.name == "champion" then
		data.target = champion()
	end
	directorShot = { name = entry.name, untilTime = clock + duration, data = data, cut = true }
end

local function directorFrame(plan)
	if not directorShot or clock >= directorShot.untilTime then
		startDirectorShot(plan)
	end
	local shot = directorShot
	if shot.name == "champion" then
		local position, lookAt, fov = closeShot(shot.data.target, "hero")
		if position then
			return position, lookAt, fov
		end
		return SHOTS.orbit(shot.data)
	end
	return SHOTS[shot.name](shot.data)
end

-- ===== CÁMARA LIBRE =====
local freeLooking = false
UserInputService.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 and setting("CameraMode") == "Libre" then
		freeLooking = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		freeLooking = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if freeLooking and input.UserInputType == Enum.UserInputType.MouseMovement then
		freeYaw -= input.Delta.X * 0.004
		freePitch = math.clamp(freePitch - input.Delta.Y * 0.004, -1.45, 1.45)
	end
end)

local function freeFrame(dt)
	local rotation = CFrame.fromEulerAnglesYXZ(freePitch, freeYaw, 0)
	if not UserInputService:GetFocusedTextBox() then
		local move = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += Vector3.new(0, 0, -1) end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then move += Vector3.new(0, 0, 1) end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then move += Vector3.new(-1, 0, 0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += Vector3.new(1, 0, 0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.E) then move += Vector3.new(0, 1, 0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.Q) then move += Vector3.new(0, -1, 0) end
		local speed = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 90 or 30
		if move.Magnitude > 0 then
			freePosition += rotation:VectorToWorldSpace(move.Unit) * speed * dt
		end
	end
	return CFrame.new(freePosition) * rotation
end

-- ===== EVENTOS DEL SERVIDOR =====

local function addTrauma(amount, position)
	if not setting("CameraShake") then
		return
	end
	local scale = setting("CameraShakeStrength")
	if position then
		local distance = (camera.CFrame.Position - position).Magnitude
		scale *= math.clamp(1.4 - distance / 90, 0.25, 1.2)
	end
	trauma = math.min(1, trauma + amount * scale)
end

local function eventFocusAllowed()
	local mode = setting("CameraMode")
	return setting("CameraEventFocus") and (mode == "Director" or mode == "Accion")
end

local function requestFocus(data)
	if not eventFocusAllowed() then
		return
	end
	local priority = data.priority or 1
	if focus and clock < focus.untilTime and (focus.priority or 1) > priority then
		return
	end
	-- las entradas (prioridad 1) no interrumpen nada y no se encadenan
	if priority <= 1 and ((focus and clock < focus.untilTime) or clock - lastFocusAt < 3) then
		return
	end
	focus = {
		target = data.target,
		position = data.position,
		shot = data.shot or "boost",
		priority = priority,
		startedAt = clock,
		untilTime = clock + (data.duration or 1.6),
	}
	lastFocusAt = clock
end

-- ===== ENTRADAS DE CINE (planos de la Élite y la Definitiva) =====
-- El aviso "cinematic" llega aquí y a EntranceCinematics en el mismo fotograma,
-- así los planos van sincronizados con el recorrido del peleador.
local cinematic = nil -- { data, startedAt, segment, hits }

local function flatUnit(v)
	local flat = if typeof(v) == "Vector3" then Vector3.new(v.X, 0, v.Z) else Vector3.zero
	return if flat.Magnitude > 0.01 then flat.Unit else Vector3.new(0, 0, -1)
end

-- Sacudida + destello una sola vez por momento (aterrizaje, rugido...)
local function cinematicImpact(key, amount)
	if cinematic.hits[key] then
		return
	end
	cinematic.hits[key] = true
	addTrauma(amount)
	if amount >= 0.6 then
		screenFlash(Color3.new(1, 1, 1), 0.25)
		blurPulse(8, 0.4)
		fovKick = -8
	end
end

local function cinematicFrame()
	local c = cinematic
	local data = c.data
	local t = clock - c.startedAt
	local npc = data.target
	local root = typeof(npc) == "Instance" and npc.Parent and npc:FindFirstChild("HumanoidRootPart")
	if t >= (tonumber(data.duration) or 6) or not root or typeof(data.from) ~= "Vector3" or typeof(data.to) ~= "Vector3" then
		cinematic = nil
		return nil
	end
	local rp = root.Position
	local h = tonumber(data.rootHeight) or 4.5
	local dir = flatUnit(data.facing)
	local side = dir:Cross(Vector3.yAxis)
	local up = Vector3.yAxis
	local from, to = data.from, data.to
	local segment, position, lookAt, fov, blend

	if data.kind == "elite" then
		local mid = if typeof(data.mid) == "Vector3" then data.mid else from
		if t < 0.5 then
			-- plano de presentación: la nube de humo en la esquina
			segment, fov = 1, 55
			position = from + dir * 16 + side * 4 + up * (h + 1.5)
			lookAt = from + up * (h + 0.5)
		elseif t < 2.6 then
			-- travelling de frente mientras avanza golpeando
			segment, fov, blend = 2, 50, 10
			position = rp + dir * 15.5 + side * 4 + up * 1.4
			lookAt = rp + up * 2.2
		elseif t < 3.45 then
			-- el salto, de lado y abierto
			segment, fov, blend = 3, 58, 9
			position = (mid + to) / 2 + side * 20 + up * (h + 6) + dir * 2
			lookAt = rp + up * 0.5
		elseif t < 4 then
			-- caída: plano bajo de frente
			segment, fov = 4, 62
			position = to + dir * 11.5 + side * 2 + up * 2
			lookAt = to + up * (h * 0.85)
			cinematicImpact("land", 0.75)
		else
			-- se acerca despacio a la cara mientras posa
			local u = math.clamp((t - 4) / 2, 0, 1)
			segment, fov, blend = 5, 50 - 8 * u, 3
			position = to + dir * (13 - 4 * u) + side * (2 - u) + up * (h + 1.2)
			lookAt = to + up * (h + 1.6)
		end
	else
		if t < 1.9 then
			-- afuera del ring, con el ring de fondo, cargando poder
			segment, fov, blend = 1, 55, 4
			position = from + side * 16 - dir * 3 + up * (h + 3)
			lookAt = from + up * (h + 0.5) + dir * 5
		elseif t < 3.7 then
			-- el salto gigante, plano muy abierto de lado
			segment, fov, blend = 2, 62, 6
			position = (from + to) / 2 + side * 46 + up * 20
			lookAt = rp
		elseif t < 4 then
			-- impacto: cámara a ras del piso
			segment, fov = 3, 66
			position = to + dir * 12.5 + side * 1.5 + up * 2.2
			lookAt = to + up * 3.4
			cinematicImpact("land", 1)
		elseif t < 5.3 then
			-- gira despacio alrededor mientras sigue agachado
			local angle = math.rad(-25 + 50 * ((t - 4) / 1.3))
			local around = CFrame.Angles(0, angle, 0):VectorToWorldSpace(dir)
			segment, fov, blend = 4, 55, 6
			position = to + around * 11.5 + up * 2.6
			lookAt = to + up * 3.4
		elseif t < 6.3 then
			-- se levanta: contrapicado heroico
			segment, fov, blend = 5, 52, 4
			position = to + dir * 10 + up * 1.6
			lookAt = rp + up * 1.8
		else
			-- ruge: se acerca a la cara
			local u = math.clamp((t - 6.3) / 1.5, 0, 1)
			segment, fov, blend = 6, 48 - 6 * u, 3
			position = to + dir * (11 - 3 * u) + up * (h + 1)
			lookAt = to + up * (h + 1.8)
			cinematicImpact("roar", 0.35)
		end
	end

	local cut = segment ~= c.segment
	c.segment = segment
	return { position = position, lookAt = lookAt, fov = fov, blend = blend or 6, cut = cut }
end

-- ===== ATAQUE FINAL DE LA BATALLA DE TIKTOK =====
-- El aviso "finisher" llega a la vez aquí y a EntranceCinematics (que mueve al
-- ganador): carga de poder, lanzamiento, impacto, vuelo del perdedor y
-- celebración. Los tiempos deben coincidir con Battle.FINISHER_* (servidor).
local finisher = nil -- { data, startedAt, segment, hit }

local function finisherFrame()
	local c = finisher
	local data = c.data
	local t = clock - c.startedAt
	local duration = tonumber(data.duration) or 7
	if t >= duration or typeof(data.from) ~= "Vector3" or typeof(data.to) ~= "Vector3" then
		finisher = nil
		return nil
	end
	local function rootOf(npc)
		return typeof(npc) == "Instance" and npc.Parent and npc:FindFirstChild("HumanoidRootPart")
	end
	local wRoot, lRoot = rootOf(data.winner), rootOf(data.loser)
	local dir = flatUnit(data.facing)
	local side = dir:Cross(Vector3.yAxis)
	local up = Vector3.yAxis
	local h = tonumber(data.rootHeight) or 4.5
	local from, to = data.from, data.to
	local loserAt = if typeof(data.loserAt) == "Vector3" then data.loserAt else to + dir * 4
	local impact = tonumber(data.impact) or 2.45
	local wp = if wRoot then wRoot.Position else from + up * h
	local segment, position, lookAt, fov, blend
	if t < 1.7 then
		-- carga de poder: contrapicado que se acerca despacio
		local u = t / 1.7
		segment, fov, blend = 1, 52 - 8 * u, 3
		position = from + dir * (9 - 2 * u) + side * 13 + up * 3
		lookAt = wp + up * 1.6
	elseif t < impact - 0.05 then
		-- el lanzamiento: plano lateral abierto con los dos
		local mid = (from + loserAt) / 2
		segment, fov, blend = 2, 60, 12
		position = mid + side * 24 + up * (h + 4)
		lookAt = mid + up * (h * 0.7)
	elseif t < impact + 0.4 then
		-- impacto: a ras del piso junto al perdedor
		segment, fov = 3, 68
		position = loserAt - dir * 3 + side * 10 + up * 2.2
		lookAt = loserAt + up * (h + 0.5)
		if not c.hit then
			c.hit = true
			addTrauma(1)
			screenFlash(Shared.teamColor(data.team), 0.45)
			blurPulse(12, 0.5)
			fovKick = -12
		end
	elseif t < 4.3 then
		-- sale volando: la cámara lo sigue desde detrás del ganador
		segment, fov, blend = 4, 66, 5
		position = to - dir * 10 + side * 5 + up * (h + 6)
		lookAt = if lRoot then lRoot.Position else loserAt + up * 8
	else
		-- el ganador celebra: gira despacio delante de él
		local u = math.clamp((t - 4.3) / math.max(0.5, duration - 4.3), 0, 1)
		local around = CFrame.Angles(0, math.rad(-35 + 70 * u), 0):VectorToWorldSpace(dir)
		segment, fov, blend = 5, 50, 4
		position = to + around * 12 + up * (h + 1.5)
		lookAt = wp + up * 1.8
	end
	local cut = segment ~= c.segment
	c.segment = segment
	return { position = position, lookAt = lookAt, fov = fov, blend = blend or 6, cut = cut }
end

fxEvent.OnClientEvent:Connect(function(kind, data)
	data = data or {}
	if kind == "shake" then
		addTrauma(data.intensity or 0.3, data.position)
	elseif kind == "flash" then
		screenFlash(data.color or Color3.new(1, 1, 1), data.intensity)
	elseif kind == "focus" then
		requestFocus(data)
	elseif kind == "ko" then
		addTrauma(0.7, data.position)
		screenFlash(data.color or Color3.new(1, 1, 1), 0.2)
		blurPulse(10, 0.6)
		fovKick = -10
		requestFocus({ position = data.position, shot = "ko", priority = 2, duration = 1.8 })
	elseif kind == "fov" then
		fovKick = data.amount or -8
	elseif kind == "finisher" then
		focus = nil
		local localVfx = Workspace:FindFirstChild("ArenaVFXLocal")
		if localVfx and not ignoredParts[localVfx] then
			ignoredParts[localVfx] = true
			occlusionParams:AddToFilter(localVfx)
		end
		finisher = { data = data, startedAt = clock, segment = nil, hit = false }
	elseif kind == "cinematic" then
		focus = nil
		-- los efectos que dibuja este cliente (grietas, anillos...) no son obstáculos para la cámara
		local localVfx = Workspace:FindFirstChild("ArenaVFXLocal")
		if localVfx and not ignoredParts[localVfx] then
			ignoredParts[localVfx] = true
			occlusionParams:AddToFilter(localVfx)
		end
		cinematic = { data = data, startedAt = clock, segment = nil, hits = {} }
	end
end)

-- ===== PERSONAJE DEL STREAMER (oculto, no debe salir en cámara) =====
local function hideCharacter(character)
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CanCollide = false
		elseif descendant:IsA("Decal") then
			descendant.Transparency = 1
		end
	end
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if root then
		root.Anchored = true
	end
end
if player.Character then
	hideCharacter(player.Character)
end
player.CharacterAdded:Connect(hideCharacter)

-- ===== BUCLE PRINCIPAL =====

RunService:BindToRenderStep("ArenaCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	clock += dt
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local mode = setting("CameraMode")
	if mode ~= lastMode then
		if mode == "Libre" then
			freePosition = currentCFrame.Position
			local look = currentCFrame.LookVector
			freeYaw = math.atan2(-look.X, -look.Z)
			freePitch = math.asin(math.clamp(look.Y, -1, 1))
		end
		directorShot = nil
		focus = nil
		lastMode = mode
	end

	if focus and clock >= focus.untilTime then
		focus = nil
	end

	local targetCFrame
	local fovOffset = 0
	local blendSpeed = 4
	local instantCut = false

	local cineShot = if cinematic then cinematicFrame() else nil
	if not cineShot and finisher then
		cineShot = finisherFrame()
	end
	if cineShot then
		-- entrada de cine: manda sobre cualquier modo de cámara
		targetCFrame = CFrame.lookAt(unobstructed(cineShot.lookAt, cineShot.position), cineShot.lookAt)
		fovOffset = cineShot.fov - setting("CameraFov")
		blendSpeed = cineShot.blend
		instantCut = cineShot.cut
	elseif mode == "Libre" then
		targetCFrame = freeFrame(dt)
		blendSpeed = 20
	else
		local position, lookAt, fov, up
		if focus then
			position, lookAt, fov = focusShot()
			if position then
				blendSpeed = 6
			else
				focus = nil
			end
		end
		if not position then
			if mode == "Director" then
				position, lookAt, fov, up = directorFrame(DIRECTOR_PLAN)
			elseif mode == "Cinematica" then
				position, lookAt, fov, up = directorFrame(CINEMATIC_PLAN)
				blendSpeed = 1.5
			elseif mode == "Accion" then
				if not directorShot or directorShot.name ~= "fight" or clock >= directorShot.untilTime then
					directorShot = { name = "fight", untilTime = clock + 6, data = { side = math.random() < 0.5 and -1 or 1 } }
				end
				position, lookAt, fov = SHOTS.fight(directorShot.data)
			elseif mode == "Cenital" then
				position, lookAt, fov, up = SHOTS.top({ angle = 0 })
			elseif mode == "General" then
				position, lookAt, fov = SHOTS.general()
			else
				position, lookAt, fov = SHOTS.orbit({ angle = 0 })
			end
			if directorShot and directorShot.cut then
				directorShot.cut = false
				instantCut = true
			end
		end
		fovOffset = fov or 0
		position = unobstructed(lookAt, position)
		targetCFrame = CFrame.lookAt(position, lookAt, up or Vector3.yAxis)
	end

	if instantCut then
		currentCFrame = targetCFrame
	else
		local alpha = 1 - math.exp(-dt * blendSpeed * setting("CameraSpeed"))
		currentCFrame = currentCFrame:Lerp(targetCFrame, alpha)
	end

	-- Sacudida (trauma² con ruido suave)
	trauma = math.max(0, trauma - dt * 1.5)
	local shake = CFrame.identity
	if trauma > 0 then
		local amount = trauma * trauma
		local t = clock * 28
		shake = CFrame.new(
			math.noise(t, 1.3) * amount * 0.8,
			math.noise(t, 7.1) * amount * 0.8,
			0
		) * CFrame.Angles(
			math.rad(math.noise(t, 3.7) * amount * 3),
			math.rad(math.noise(t, 5.9) * amount * 3),
			math.rad(math.noise(t, 9.2) * amount * 4)
		)
	end

	fovKick += (0 - fovKick) * (1 - math.exp(-dt * 3))
	local targetFov = math.clamp(setting("CameraFov") + fovOffset + fovKick, 20, 120)
	currentFov += (targetFov - currentFov) * (1 - math.exp(-dt * 5))

	camera.CFrame = currentCFrame * shake
	camera.FieldOfView = currentFov
end)
