-- Shared (ModuleScript en ReplicatedStorage.Arena)
-- Datos que usan a la vez el servidor, el HUD, la cámara y el panel dev:
-- equipos, catálogo de regalos de TikTok y ajustes por defecto.

local Shared = {}

-- ===== EQUIPOS =====
Shared.TEAMS = {
	hero = {
		id = "hero",
		name = "HÉROES",
		single = "HÉROE",
		emoji = "🦸",
		color = Color3.fromRGB(255, 205, 40),
		dark = Color3.fromRGB(110, 70, 0),
		light = Color3.fromRGB(255, 245, 200),
		pulse = Color3.fromRGB(255, 255, 255),
	},
	villain = {
		id = "villain",
		name = "VILLANOS",
		single = "VILLANO",
		emoji = "🦹",
		color = Color3.fromRGB(170, 75, 235),
		dark = Color3.fromRGB(40, 10, 65),
		light = Color3.fromRGB(225, 185, 255),
		pulse = Color3.fromRGB(35, 10, 45),
	},
}

function Shared.otherTeam(team)
	return team == "hero" and "villain" or "hero"
end

function Shared.teamColor(team)
	local t = Shared.TEAMS[team]
	return t and t.color or Color3.fromRGB(120, 200, 255)
end

-- ===== REGALOS DE TIKTOK =====
-- Qué regalo convierte a alguien en qué peleador se elige en el panel web
-- (tarjeta "Regalos de cada peleador"). Se guarda en el ajuste GiftRoles (JSON):
--   { hero1 = { { id = 5655, name = "Rosa", image = "rbxassetid://..." }, ... }, ... }
-- Si está vacío se usan DEFAULT_GIFT_ROLES. Cada puesto es un nivel de peleador
-- de un equipo o una lluvia de guantes. Los efectos de cada nivel están en TIERS:
-- health/damage/speed son fracciones sobre la base (0.50 = +50%).
Shared.TIERS = {
	{ level = 1, tier = "Experimentado", health = 0.50, damage = 0.10, speed = 0 },
	{ level = 2, tier = "Profesional", health = 0.75, damage = 0.25, speed = 0 },
	{ level = 3, tier = "Élite", health = 1.00, damage = 0.35, speed = 0 },
	{ level = 4, tier = "Legendario", health = 1.25, damage = 0.45, speed = 0.25 },
	{ level = 5, tier = "Definitivo", health = 1.50, damage = 0.55, speed = 0.50 },
}

-- Puestos, en el orden en que se muestran (mismo orden que GIFT_ROLES en server.js)
Shared.ROLES = {}
for _, team in ipairs({ "hero", "villain" }) do
	for level = 1, 5 do
		table.insert(Shared.ROLES, { id = team .. level, team = team, level = level })
	end
	table.insert(Shared.ROLES, {
		id = if team == "hero" then "rainGold" else "rainDark",
		team = team,
		rain = if team == "hero" then "gold" else "dark",
	})
end

Shared.DEFAULT_GIFT_ROLES = {
	hero1 = { { id = 5655, name = "Rosa", image = "rbxassetid://78391551606488" } },
	hero2 = { { id = 5487, name = "Corazón coreano", image = "rbxassetid://105967271322438" } },
	hero3 = { { id = 8913, name = "Rosa Élite", image = "rbxassetid://124074653912143" } },
	hero4 = { { id = 14488, name = "Capibara", image = "rbxassetid://75252912505558" } },
	hero5 = { { id = 5660, name = "Corazón con las manos", image = "rbxassetid://71267330169900" } },
	rainGold = { { id = 5659, name = "Cisne de papel", image = "rbxassetid://72311849878983" } },
	villain1 = { { id = 6064, name = "GG", image = "rbxassetid://98313885470997" } },
	villain2 = { { id = 105781, name = "Balón giratorio", image = "rbxassetid://127912705718078" } },
	villain3 = { { id = 9947, name = "Collar de amistad", image = "rbxassetid://83141439228571" } },
	villain4 = { { id = 5879, name = "Rosquilla", image = "rbxassetid://123896768276049" } },
	villain5 = { { id = 5585, name = "Confeti con las manos", image = "rbxassetid://125869536078101" } },
	rainDark = { { id = 6427, name = "Sombrero y bigote", image = "rbxassetid://93375599254886" } },
}

-- Tablas que usa todo el juego. Se rellenan en applyGiftRoles (se modifican en
-- su sitio, así quien guardó la referencia ve los cambios).
Shared.GIFTS = {} -- giftId -> { team, level, gift, tier, health, damage, speed, image } o { action = "rain", ... }
Shared.GIFT_ORDER = { hero = {}, villain = {} } -- ids en el orden de los paneles
Shared.giftsChanged = Instance.new("BindableEvent") -- se dispara cuando cambian los regalos

local HttpService = game:GetService("HttpService")

function Shared.applyGiftRoles(text)
	local roles = nil
	if type(text) == "string" and text ~= "" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, text)
		if ok and type(decoded) == "table" then
			roles = decoded
		end
	end
	roles = roles or Shared.DEFAULT_GIFT_ROLES

	table.clear(Shared.GIFTS)
	table.clear(Shared.GIFT_ORDER.hero)
	table.clear(Shared.GIFT_ORDER.villain)
	for _, role in ipairs(Shared.ROLES) do
		local list = roles[role.id]
		if type(list) == "table" then
			for _, entry in ipairs(list) do
				local id = type(entry) == "table" and tonumber(entry.id)
				if id and not Shared.GIFTS[id] then -- un regalo solo puede estar en un puesto
					local name = tostring(entry.name or id)
					local image = type(entry.image) == "string" and entry.image or ""
					if role.rain then
						Shared.GIFTS[id] = {
							action = "rain",
							rain = role.rain,
							team = role.team,
							gift = name,
							tier = if role.rain == "gold" then "Lluvia de guantes dorados" else "Lluvia de guantes oscuros",
							image = image,
						}
					else
						local tier = Shared.TIERS[role.level]
						Shared.GIFTS[id] = {
							team = role.team,
							level = role.level,
							gift = name,
							tier = tier.tier,
							health = tier.health,
							damage = tier.damage,
							speed = tier.speed,
							image = image,
						}
					end
					table.insert(Shared.GIFT_ORDER[role.team], id)
				end
			end
		end
	end
	Shared.giftsChanged:Fire()
end

function Shared.giftEffectText(info)
	if info.action == "rain" then
		return info.rain == "gold" and "Daña VILLANOS" or "Daña HÉROES"
	end
	local parts = { "+" .. math.floor(info.health * 100 + 0.5) .. "% ❤", "+" .. math.floor(info.damage * 100 + 0.5) .. "% 👊" }
	if info.speed > 0 then
		table.insert(parts, "+" .. math.floor(info.speed * 100 + 0.5) .. "% ⚡")
	end
	return table.concat(parts, " ")
end

-- ===== GOLPES =====
-- Los usan el servidor (cuándo conecta el golpe) y FighterAnimator en el
-- cliente (la animación). impact = segundos hasta que conecta a velocidad x1,
-- duration = lo que dura la animación entera, target = dónde pega (head | body).
Shared.MOVES = {
	jab = { impact = 0.17, duration = 0.42, weight = 3, target = "head", hand = "Left" },
	cross = { impact = 0.24, duration = 0.52, weight = 3, target = "head", hand = "Right" },
	hook = { impact = 0.3, duration = 0.62, weight = 2, target = "head", hand = "Right" },
	uppercut = { impact = 0.32, duration = 0.64, weight = 1.5, target = "head", hand = "Right" },
	body = { impact = 0.27, duration = 0.56, weight = 1.5, target = "body", hand = "Left" },
	combo = { impact = 0.4, duration = 0.74, weight = 1.5, target = "head", hand = "Right" },
	superStraight = { impact = 0.62, duration = 1.05, weight = 1, super = true, target = "head", hand = "Right" },
	superUpper = { impact = 0.66, duration = 1.15, weight = 1, super = true, target = "head", hand = "Right" },
}

-- Elige un golpe al azar (por peso) sin repetir el anterior.
function Shared.pickMove(super, last)
	local total = 0
	for name, move in pairs(Shared.MOVES) do
		if (move.super == true) == (super == true) and name ~= last then
			total += move.weight
		end
	end
	local roll = math.random() * total
	for name, move in pairs(Shared.MOVES) do
		if (move.super == true) == (super == true) and name ~= last then
			roll -= move.weight
			if roll <= 0 then
				return name
			end
		end
	end
	return super and "superStraight" or "cross"
end

-- ===== AJUSTES (se guardan en el bridge, se cambian desde el panel dev) =====
-- Solo string / number / boolean: viven como atributos de
-- ReplicatedStorage.Arena.Settings para que los clientes reaccionen al instante.
Shared.DEFAULT_SETTINGS = {
	-- HUD
	HudLayout = "Auto", -- Auto | Horizontal | Vertical
	HudScale = 1,
	HudSafeTop = 0,
	HudSafeBottom = 0,
	HudSafeSide = 0,
	HudShowTitle = true,
	HudShowScore = true,
	HudShowGifts = true,
	HudShowQueue = true,
	HudShowFeed = true,
	HudShowTop = true,
	HudShowLikes = true,
	HudShowOverheads = true,
	HudShowPopups = true,
	Message = "🥊 DALE LIKE, SIGUE O ENVÍA UN REGALO PARA PELEAR",
	HudCustom = "", -- JSON: secciones movidas/escaladas/ocultas desde el editor del HUD (H y V por separado)
	GiftRoles = "", -- JSON: qué regalos van con cada peleador (lo edita el panel web); vacío = los de siempre

	-- Cámara
	CameraMode = "Director", -- Director | Orbita | General | Accion | Cenital | Cinematica | Libre
	CameraShake = true,
	CameraShakeStrength = 1,
	CameraFov = 70,
	CameraSpeed = 1,
	CameraEventFocus = true,
	ScreenFlashes = true,

	-- Sonido
	MusicEnabled = true,
	MusicVolume = 0.45,
	SfxVolume = 0.8,
	CrowdEnabled = true,
	CrowdVolume = 0.35,

	-- Entorno
	LightingPreset = "Original", -- Original | Atardecer | Noche | Neon
	StageLights = true,

	-- Juego
	Paused = false,
	MaxFighters = 8,
	DamageScale = 1,
	LikeGoal = 1000,
	CritChance = 0.12,
	BlockChance = 0.22,
	DodgeChance = 0.08,
	SameTeamSparring = true, -- si no hay rival del otro equipo, pelean entre compañeros
	LikeJoins = true, -- un like te mete a la fila para pelear (el chat no se usa)
	FollowJoins = true, -- seguir te mete a pelear con vida extra

	-- Modo batalla (batallas de TikTok entre streamers)
	GameMode = "Solo", -- Solo | Batalla (se elige al entrar al juego)
	BattleMe = "", -- tu @usuario de TikTok (opcional: así el bridge sabe cuál de los dos eres)
	BattleSwap = false, -- si en la batalla tu campeón sale del lado del rival, actívalo
	BattleLikeGoal = 300, -- likes para llenar la ENERGÍA DEL PÚBLICO (lanza el golpe del público)

	-- Efectos
	FighterAuras = true, -- auras de poder, anillos y brillos en los peleadores
	PunchTrails = true, -- estelas de color en los puños
}

Shared.SETTING_LIMITS = {
	HudScale = { 0.4, 2 },
	HudSafeTop = { 0, 600 },
	HudSafeBottom = { 0, 900 },
	HudSafeSide = { 0, 300 },
	CameraShakeStrength = { 0, 3 },
	CameraFov = { 30, 110 },
	CameraSpeed = { 0.2, 3 },
	MusicVolume = { 0, 1 },
	SfxVolume = { 0, 1 },
	CrowdVolume = { 0, 1 },
	MaxFighters = { 2, 8 },
	DamageScale = { 0.25, 4 },
	LikeGoal = { 50, 100000 },
	BattleLikeGoal = { 20, 50000 },
	CritChance = { 0, 0.6 },
	BlockChance = { 0, 0.6 },
	DodgeChance = { 0, 0.5 },
}

-- Largo máximo de los ajustes de texto (los demás: 140)
Shared.STRING_MAX = { HudCustom = 4000, GiftRoles = 8000 } -- (igual que LONG_SETTINGS en server.js)

Shared.SETTING_CHOICES = {
	HudLayout = { "Auto", "Horizontal", "Vertical" },
	CameraMode = { "Director", "Orbita", "General", "Accion", "Cenital", "Cinematica", "Libre" },
	LightingPreset = { "Original", "Atardecer", "Noche", "Neon" },
	GameMode = { "Solo", "Batalla" },
}

-- Valida y normaliza un ajuste. Devuelve (ok, valorFinal).
function Shared.sanitizeSetting(key, value)
	local default = Shared.DEFAULT_SETTINGS[key]
	if default == nil then
		return false
	end
	if type(default) == "number" then
		value = tonumber(value)
		if not value or value ~= value then
			return false
		end
		local limits = Shared.SETTING_LIMITS[key]
		if limits then
			value = math.clamp(value, limits[1], limits[2])
		end
		return true, value
	elseif type(default) == "boolean" then
		if type(value) == "string" then
			value = (value == "true" or value == "1")
		end
		return type(value) == "boolean", value
	else
		if type(value) ~= "string" then
			return false
		end
		local choices = Shared.SETTING_CHOICES[key]
		if choices and not table.find(choices, value) then
			return false
		end
		return true, string.sub(value, 1, Shared.STRING_MAX[key] or 140)
	end
end

-- ===== MODO BATALLA (lo usan el servidor y el HUD de batalla) =====
Shared.BATTLE = {
	POWER_STEPS = { 100, 1000, 5000, 20000 }, -- puntos de un lado para cada nivel de poder
	-- Ataques especiales de los regalos de tu live (nivel del regalo en el editor
	-- de regalos; rain = regalos de lluvia; crowd = al llenarse la energía del público)
	ATTACKS = {
		{ name = "¡COMBO!", emoji = "👊" },
		{ name = "¡GANCHO DE FUEGO!", emoji = "🔥" },
		{ name = "¡SÚPER DIRECTO!", emoji = "💥" },
		{ name = "¡UPPERCUT RELÁMPAGO!", emoji = "⚡" },
		{ name = "¡ATAQUE METEORO!", emoji = "☄️" },
		rain = { name = "¡LLUVIA DE GUANTES!", emoji = "🥊" },
		crowd = { name = "¡GOLPE DEL PÚBLICO!", emoji = "❤️" },
	},
	-- Regalos que no están en ningún puesto: el ataque depende de lo que cuestan
	COIN_LEVELS = { { 1000, 5 }, { 300, 4 }, { 100, 3 }, { 30, 2 } },
	FOLLOW_HEAL = 0.10, -- seguir cura a tu campeón (fracción de su vida)
}

function Shared.formatNumber(n)
	n = math.floor(n or 0)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 10000 then
		return string.format("%.1fK", n / 1000)
	end
	return tostring(n)
end

-- Regalos: se aplican ya y cada vez que cambie el ajuste GiftRoles (en el servidor y en cada cliente)
do
	local settingsFolder = script.Parent:FindFirstChild("Settings")
	Shared.applyGiftRoles(settingsFolder and settingsFolder:GetAttribute("GiftRoles"))
	if settingsFolder then
		settingsFolder:GetAttributeChangedSignal("GiftRoles"):Connect(function()
			Shared.applyGiftRoles(settingsFolder:GetAttribute("GiftRoles"))
		end)
	end
end

return Shared
