-- Avatars (ModuleScript) — da un avatar a cada espectador de TikTok SIN que
-- tenga que escribir su usuario de Roblox. Se precargan los avatares de la
-- lista AVATAR_POOL (Config) y a cada nombre de TikTok le toca siempre el
-- mismo (hash del nombre). Si un avatar no cargó, se genera uno con colores.

local Players = game:GetService("Players")

local Avatars = {}

local pool = {} -- index -> HumanoidDescription
local poolSize = 0
local loadedCount = 0

local SKIN_TONES = {
	Color3.fromRGB(255, 204, 153), Color3.fromRGB(234, 184, 146), Color3.fromRGB(204, 142, 105),
	Color3.fromRGB(175, 121, 85), Color3.fromRGB(124, 92, 70), Color3.fromRGB(86, 66, 54),
}
local OUTFIT_COLORS = {
	Color3.fromRGB(196, 40, 28), Color3.fromRGB(13, 105, 172), Color3.fromRGB(40, 127, 71),
	Color3.fromRGB(245, 205, 48), Color3.fromRGB(107, 50, 124), Color3.fromRGB(218, 133, 65),
	Color3.fromRGB(27, 42, 53), Color3.fromRGB(255, 102, 204), Color3.fromRGB(0, 143, 156),
}

local function hash(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + string.byte(text, i)) % 2147483647
	end
	return h
end

function Avatars.init(config)
	poolSize = #config.AVATAR_POOL
	for index, username in ipairs(config.AVATAR_POOL) do
		task.spawn(function()
			local okId, userId = pcall(function()
				return Players:GetUserIdFromNameAsync(username)
			end)
			if not okId or not userId then
				warn("👤 [Avatars] No existe la cuenta de respaldo '" .. username .. "'")
				return
			end
			local okDesc, description = pcall(function()
				return Players:GetHumanoidDescriptionFromUserId(userId)
			end)
			if okDesc and description then
				pool[index] = description
				loadedCount += 1
			end
		end)
	end
end

function Avatars.loadedCount()
	return loadedCount, poolSize
end

local function generated(seed)
	local rng = Random.new(seed)
	local description = Instance.new("HumanoidDescription")
	local skin = SKIN_TONES[rng:NextInteger(1, #SKIN_TONES)]
	local shirt = OUTFIT_COLORS[rng:NextInteger(1, #OUTFIT_COLORS)]
	local pants = OUTFIT_COLORS[rng:NextInteger(1, #OUTFIT_COLORS)]
	description.HeadColor = skin
	description.LeftArmColor = skin
	description.RightArmColor = skin
	description.TorsoColor = shirt
	description.LeftLegColor = pants
	description.RightLegColor = pants
	return description
end

-- Devuelve una HumanoidDescription NUEVA (se puede aplicar sin miedo).
function Avatars.get(key)
	local seed = hash(string.lower(key or "?"))
	if poolSize > 0 then
		local start = seed % poolSize + 1
		-- si el avatar que le toca no cargó, prueba el siguiente de la lista
		for offset = 0, poolSize - 1 do
			local index = (start - 1 + offset) % poolSize + 1
			if pool[index] then
				return pool[index]:Clone()
			end
		end
	end
	return generated(seed)
end

return Avatars
