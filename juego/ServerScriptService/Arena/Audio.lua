-- Audio (ModuleScript) — música, público y efectos, con grupos de volumen
-- que se controlan desde el panel dev (MusicVolume, SfxVolume, CrowdVolume).

local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local Audio = {}

local config
local groups = {}
local music, crowd
local lastPlayed = {}
local musicBaseVolume = 0.45
local duckToken = 0

local function makeGroup(name, volume)
	local group = SoundService:FindFirstChild(name)
	if not group then
		group = Instance.new("SoundGroup")
		group.Name = name
		group.Parent = SoundService
	end
	group.Volume = volume
	return group
end

function Audio.init(cfg)
	config = cfg
	groups.Music = makeGroup("ArenaMusic", 0.45)
	groups.Sfx = makeGroup("ArenaSFX", 0.8)
	groups.Crowd = makeGroup("ArenaCrowd", 0.35)

	music = Instance.new("Sound")
	music.Name = "BackgroundMusic"
	music.SoundId = config.SOUNDS.Music
	music.Looped = true
	music.Volume = 1
	music.SoundGroup = groups.Music
	music.Parent = SoundService

	crowd = Instance.new("Sound")
	crowd.Name = "CrowdAmbience"
	crowd.SoundId = config.SOUNDS.CrowdLoop
	crowd.Looped = true
	crowd.Volume = 0.6
	crowd.SoundGroup = groups.Crowd
	crowd.Parent = SoundService

	-- Precarga y avisa en la consola qué sonido no cargó (ID borrado o privado)
	task.spawn(function()
		local list = {}
		for name, id in pairs(config.SOUNDS) do
			if type(id) == "string" then
				local s = Instance.new("Sound")
				s.Name = name
				s.SoundId = id
				table.insert(list, s)
			end
		end
		pcall(function()
			ContentProvider:PreloadAsync(list, function(assetId, status)
				if status ~= Enum.AssetFetchStatus.Success then
					warn("🔇 [Audio] No se pudo cargar el sonido " .. tostring(assetId) .. " (" .. tostring(status) .. ")")
				end
			end)
		end)
		for _, s in ipairs(list) do
			s:Destroy()
		end
	end)
end

function Audio.applySettings(settings)
	musicBaseVolume = settings.MusicVolume
	groups.Music.Volume = settings.MusicVolume
	groups.Sfx.Volume = settings.SfxVolume
	groups.Crowd.Volume = settings.CrowdVolume

	if settings.MusicEnabled then
		if not music.IsPlaying then
			music:Play()
		end
	else
		music:Stop()
	end

	if settings.CrowdEnabled then
		if not crowd.IsPlaying then
			crowd:Play()
		end
	else
		crowd:Stop()
	end
end

-- Reproduce un sonido de una sola vez. opts: volume, pitch, pitchVariance,
-- minInterval (anti-spam por nombre), group ("Sfx" | "Crowd").
function Audio.play(name, opts)
	opts = opts or {}
	local id = config.SOUNDS[name]
	if type(id) == "table" then
		id = id[math.random(1, #id)]
	end
	if not id then
		return
	end

	local now = os.clock()
	local minInterval = opts.minInterval or 0.05
	if lastPlayed[name] and now - lastPlayed[name] < minInterval then
		return
	end
	lastPlayed[name] = now

	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = opts.volume or 0.7
	local variance = opts.pitchVariance or 0.08
	sound.PlaybackSpeed = (opts.pitch or 1) * (1 + (math.random() * 2 - 1) * variance)
	sound.SoundGroup = groups[opts.group or "Sfx"]
	sound.Parent = SoundService
	sound:Play()

	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	task.delay(opts.maxLength or 8, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	return sound
end

-- Baja la música un momento para que se escuche un anuncio importante.
function Audio.duck(duration)
	duckToken += 1
	local token = duckToken
	TweenService:Create(groups.Music, TweenInfo.new(0.2), { Volume = musicBaseVolume * 0.35 }):Play()
	task.delay(duration or 2, function()
		if token == duckToken then
			TweenService:Create(groups.Music, TweenInfo.new(0.8), { Volume = musicBaseVolume }):Play()
		end
	end)
end

return Audio
