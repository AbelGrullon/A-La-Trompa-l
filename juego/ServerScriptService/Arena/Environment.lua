-- Environment (ModuleScript) — iluminación del escenario.
-- * Presets de ambiente (Original / Atardecer / Noche / Neon), elegibles en el panel dev.
--   "Original" deja la iluminación exactamente como la armaste en Studio.
-- * Focos sobre el ring que destellan con el color del equipo en cada KO / entrada.
-- * Reflectores (haces de luz) que barren el cielo en los presets de noche.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Environment = {}

local original = {}
local colorCorrection
local stageLights = {}
local searchlights = {}
local center, floorY
local currentPreset = "Original"
local stageEnabled = true
local flashUntil = 0

local LIGHTING_PROPS = {
	"ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "ColorShift_Top", "ColorShift_Bottom",
	"ExposureCompensation", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "FogEnd", "FogColor",
}
local ATMOSPHERE_PROPS = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }
local BLOOM_PROPS = { "Intensity", "Size", "Threshold" }

local PRESETS = {
	Atardecer = {
		lighting = {
			ClockTime = 17.9, Brightness = 2.2, Ambient = Color3.fromRGB(95, 75, 75), OutdoorAmbient = Color3.fromRGB(130, 95, 85),
			ColorShift_Top = Color3.fromRGB(255, 170, 110), ExposureCompensation = 0.1,
		},
		atmosphere = { Density = 0.35, Color = Color3.fromRGB(255, 175, 125), Decay = Color3.fromRGB(120, 70, 90), Haze = 1.6, Glare = 0.6 },
		cc = { Brightness = 0, Contrast = 0.1, Saturation = 0.12, TintColor = Color3.fromRGB(255, 238, 222) },
		bloom = { Intensity = 0.8, Size = 30, Threshold = 1.3 },
		stageBrightness = 2.5,
		searchlights = false,
	},
	Noche = {
		lighting = {
			ClockTime = 0.2, Brightness = 1.2, Ambient = Color3.fromRGB(50, 50, 72), OutdoorAmbient = Color3.fromRGB(60, 60, 95),
			ColorShift_Top = Color3.fromRGB(150, 170, 255), ExposureCompensation = 0.35,
		},
		atmosphere = { Density = 0.32, Color = Color3.fromRGB(70, 75, 120), Decay = Color3.fromRGB(30, 30, 60), Haze = 1.2, Glare = 0 },
		cc = { Brightness = 0.02, Contrast = 0.15, Saturation = 0.15, TintColor = Color3.fromRGB(235, 240, 255) },
		bloom = { Intensity = 1, Size = 32, Threshold = 1.1 },
		stageBrightness = 5,
		searchlights = true,
	},
	Neon = {
		lighting = {
			ClockTime = 0, Brightness = 0.8, Ambient = Color3.fromRGB(70, 30, 95), OutdoorAmbient = Color3.fromRGB(80, 35, 120),
			ColorShift_Top = Color3.fromRGB(255, 120, 255), ExposureCompensation = 0.4,
		},
		atmosphere = { Density = 0.38, Color = Color3.fromRGB(130, 50, 180), Decay = Color3.fromRGB(40, 10, 80), Haze = 2, Glare = 0.2 },
		cc = { Brightness = 0.03, Contrast = 0.22, Saturation = 0.35, TintColor = Color3.fromRGB(255, 232, 255) },
		bloom = { Intensity = 1.3, Size = 36, Threshold = 0.95 },
		stageBrightness = 6,
		searchlights = true,
	},
}

local function capture(inst, props)
	if not inst then
		return nil
	end
	local values = {}
	for _, prop in ipairs(props) do
		local ok, value = pcall(function()
			return inst[prop]
		end)
		if ok then
			values[prop] = value
		end
	end
	return values
end

local function apply(inst, values, duration)
	if not inst or not values then
		return
	end
	local tweenable = {}
	for prop, value in pairs(values) do
		if typeof(value) == "number" or typeof(value) == "Color3" then
			tweenable[prop] = value
		else
			pcall(function()
				inst[prop] = value
			end)
		end
	end
	-- ClockTime da la vuelta al llegar a 24: se asigna directo, sin tween
	if tweenable.ClockTime then
		inst.ClockTime = tweenable.ClockTime
		tweenable.ClockTime = nil
	end
	pcall(function()
		TweenService:Create(inst, TweenInfo.new(duration or 1.5, Enum.EasingStyle.Sine), tweenable):Play()
	end)
end

local function makeStageLight(position, target)
	local part = Instance.new("Part")
	part.Name = "StageLight"
	part.Size = Vector3.new(1, 1, 1)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.lookAt(position, target)
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Front
	spot.Angle = 60
	spot.Range = 75
	spot.Brightness = 2
	spot.Shadows = true
	spot.Color = Color3.new(1, 1, 1)
	spot.Parent = part
	return part, spot
end

local function makeSearchlight(folder, basePosition, phase)
	local terrain = Workspace.Terrain
	local a0 = Instance.new("Attachment")
	a0.Name = "SearchlightBase"
	a0.Position = basePosition
	a0.Parent = terrain
	local a1 = Instance.new("Attachment")
	a1.Name = "SearchlightTip"
	a1.Position = basePosition + Vector3.new(0, 140, 0)
	a1.Parent = terrain
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 3
	beam.Width1 = 16
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Color = ColorSequence.new(Color3.fromRGB(200, 220, 255))
	beam.Enabled = false
	beam.Parent = folder
	return { beam = beam, base = a0, tip = a1, basePosition = basePosition, phase = phase }
end

function Environment.init(spawnPoints)
	-- Guarda la iluminación tal como está en Studio para el preset "Original"
	original.lighting = capture(Lighting, LIGHTING_PROPS)
	original.atmosphere = capture(Lighting:FindFirstChildOfClass("Atmosphere"), ATMOSPHERE_PROPS)
	original.bloom = capture(Lighting:FindFirstChildOfClass("BloomEffect"), BLOOM_PROPS)

	colorCorrection = Lighting:FindFirstChild("ArenaColor") or Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "ArenaColor"
	colorCorrection.Parent = Lighting

	-- Límites del ring a partir de los puntos de spawn
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local sumY = 0
	for _, point in ipairs(spawnPoints) do
		local p = point.Position
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		sumY += p.Y
	end
	floorY = sumY / #spawnPoints
	center = Vector3.new((minX + maxX) / 2, floorY, (minZ + maxZ) / 2)

	local folder = Workspace:FindFirstChild("ArenaStage") or Instance.new("Folder")
	folder.Name = "ArenaStage"
	folder.Parent = Workspace
	folder:ClearAllChildren()

	local margin = 6
	local corners = {
		Vector3.new(minX - margin, floorY + 28, minZ - margin),
		Vector3.new(maxX + margin, floorY + 28, minZ - margin),
		Vector3.new(minX - margin, floorY + 28, maxZ + margin),
		Vector3.new(maxX + margin, floorY + 28, maxZ + margin),
	}
	for _, corner in ipairs(corners) do
		local part, spot = makeStageLight(corner, center)
		part.Parent = folder
		table.insert(stageLights, spot)
	end

	local spread = 70
	for i, offset in ipairs({
		Vector3.new(-spread, 0, -spread), Vector3.new(spread, 0, -spread),
		Vector3.new(-spread, 0, spread), Vector3.new(spread, 0, spread),
	}) do
		table.insert(searchlights, makeSearchlight(folder, Vector3.new(center.X, 2, center.Z) + offset, i * 1.7))
	end

	-- Animación continua: los reflectores barren el cielo y los focos cambian
	-- de color despacito cuando no hay ningún destello activo.
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 1 / 20 then
			return
		end
		accumulator = 0
		local t = os.clock()
		for _, light in ipairs(searchlights) do
			if light.beam.Enabled then
				local angle = t * 0.35 + light.phase
				local tilt = 45 + math.sin(t * 0.5 + light.phase) * 25
				light.tip.Position = light.basePosition + Vector3.new(math.cos(angle) * tilt, 140, math.sin(angle) * tilt)
				if currentPreset == "Neon" then
					light.beam.Color = ColorSequence.new(Color3.fromHSV((t * 0.05 + light.phase * 0.1) % 1, 0.6, 1))
				end
			end
		end
		if stageEnabled and t > flashUntil then
			local hue = (t * 0.03) % 1
			local idleColor = currentPreset == "Original" and Color3.new(1, 1, 1) or Color3.fromHSV(hue, 0.25, 1)
			for _, spot in ipairs(stageLights) do
				spot.Color = idleColor
			end
		end
	end)
end

function Environment.getCenter()
	return center, floorY
end

function Environment.applySettings(settings)
	local preset = settings.LightingPreset
	if preset ~= currentPreset then
		currentPreset = preset
		local data = PRESETS[preset]
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
		if data then
			apply(Lighting, data.lighting)
			apply(atmosphere, data.atmosphere)
			apply(bloom, data.bloom)
			apply(colorCorrection, data.cc)
		else
			apply(Lighting, original.lighting)
			apply(atmosphere, original.atmosphere)
			apply(bloom, original.bloom)
			apply(colorCorrection, { Brightness = 0, Contrast = 0, Saturation = 0, TintColor = Color3.new(1, 1, 1) })
		end
		for _, light in ipairs(searchlights) do
			light.beam.Enabled = data ~= nil and data.searchlights == true
		end
	end

	stageEnabled = settings.StageLights
	local data = PRESETS[currentPreset]
	local brightness = data and data.stageBrightness or 1.2
	for _, spot in ipairs(stageLights) do
		spot.Enabled = stageEnabled
		spot.Brightness = brightness
		spot:SetAttribute("BaseBrightness", brightness)
	end
end

-- Destello de todos los focos con un color (KO, entradas, regalos grandes).
function Environment.flash(color, duration, intensity)
	if not stageEnabled then
		return
	end
	duration = duration or 0.8
	flashUntil = os.clock() + duration
	for _, spot in ipairs(stageLights) do
		local base = spot:GetAttribute("BaseBrightness") or 2
		spot.Color = color
		spot.Brightness = base * (intensity or 3)
		TweenService:Create(spot, TweenInfo.new(duration, Enum.EasingStyle.Quad), { Brightness = base }):Play()
	end
end

-- Estroboscopio corto (rachas, metas de likes, lluvias).
function Environment.strobe(colors, times, interval)
	if not stageEnabled then
		return
	end
	task.spawn(function()
		for i = 1, times do
			Environment.flash(colors[(i - 1) % #colors + 1], interval * 0.9, 3.5)
			task.wait(interval)
		end
	end)
end

return Environment
