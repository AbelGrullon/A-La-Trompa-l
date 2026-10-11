-- Online (ModuleScript) — el juego publicado con el servidor online (online.js).
-- Solo hace algo si Config.ONLINE_URL tiene una dirección.
--
--   • Un streamer por servidor (la experiencia se publica con 1 jugador máximo):
--     el primero que entra es el DUEÑO y tiene el panel dev (ArenaDev).
--   • Se enlaza solo con su canal de TikTok si entró con el botón "▶ ABRIR EL
--     JUEGO" del panel web (el código viaja en launchData), o con el enlace que
--     se guardó la última vez (DataStore). Si no, la pantalla OnlineConnect le
--     pide su @usuario y el código de 6 cifras del panel.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")

local Online = {}

local bridge
local config
local hudEvent
local ownerUserId = nil
local linking = false
local store = nil

function Online.enabled()
	return type(config.ONLINE_URL) == "string" and config.ONLINE_URL ~= ""
end

function Online.init(deps)
	bridge = deps.Bridge
	config = deps.Config
	hudEvent = deps.hudEvent
	if not Online.enabled() then
		return
	end
	pcall(function()
		store = DataStoreService:GetDataStore("TrompaOnline_v1")
	end)
	-- Se guarda el enlace para la próxima vez (y se avisa a la pantalla de conexión)
	bridge.onLinkChanged(function(linked, user, token)
		local owner = ownerUserId and Players:GetPlayerByUserId(ownerUserId)
		if owner then
			hudEvent:FireClient(owner, "online", { linked = linked, user = user })
		end
		if not ownerUserId or not store then
			return
		end
		pcall(function()
			if linked then
				store:SetAsync("u" .. ownerUserId, { t = token, user = user })
			else
				store:RemoveAsync("u" .. ownerUserId)
			end
		end)
	end)
	print("🌐 Modo ONLINE: " .. config.ONLINE_URL)
end

function Online.isOwner(player)
	return Online.enabled() and ownerUserId == player.UserId
end

-- Se llama al entrar cada jugador (ANTES de decidir quién tiene el panel dev)
function Online.playerAdded(player)
	if not Online.enabled() then
		return
	end
	if ownerUserId == nil then
		ownerUserId = player.UserId
		bridge.setOwner(player.UserId)
	end
	if ownerUserId ~= player.UserId then
		return
	end
	-- 1) Entró con el botón del panel: el código viene en launchData
	local okJoin, joinData = pcall(function()
		return player:GetJoinData()
	end)
	local launch = okJoin and type(joinData) == "table" and joinData.LaunchData
	if type(launch) == "string" and launch ~= "" then
		local okDecode, data = pcall(HttpService.JSONDecode, HttpService, launch)
		if okDecode and type(data) == "table" and type(data.t) == "string" then
			print("🌐 Canal recibido por el botón del panel")
			bridge.setToken(data.t)
			return
		end
	end
	-- 2) El enlace de la última vez
	task.spawn(function()
		if not store then
			return
		end
		local okGet, saved = pcall(function()
			return store:GetAsync("u" .. player.UserId)
		end)
		if okGet and type(saved) == "table" and type(saved.t) == "string" and not player:GetAttribute("OnlineLinkTried") then
			print("🌐 Canal de la última vez: @" .. tostring(saved.user))
			bridge.setToken(saved.t, saved.user)
		end
	end)
end

-- Pantalla "Conecta tu TikTok": { user, code }
function Online.link(player, args)
	if not Online.isOwner(player) or linking or type(args) ~= "table" then
		return
	end
	linking = true
	player:SetAttribute("OnlineLinkTried", true)
	local ok, result = bridge.link(string.sub(tostring(args.user or ""), 1, 40), string.sub(tostring(args.code or ""), 1, 12))
	linking = false
	if not ok then
		hudEvent:FireClient(player, "online", { linked = false, error = result })
	end
	-- (si salió bien, onLinkChanged ya avisó)
end

function Online.unlink(player)
	if Online.isOwner(player) then
		bridge.unlink()
	end
end

return Online
