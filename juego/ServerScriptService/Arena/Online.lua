-- Online (ModuleScript) — el juego publicado con el servidor online (online.js).
-- Solo hace algo si Config.ONLINE_URL tiene una dirección.
--
--   • Un streamer por servidor: quien entra a un servidor PÚBLICO se manda al
--     momento a una arena PRIVADA solo suya (servidor reservado, con su código
--     del panel). Así dos streamers nunca caen juntos aunque Roblox los junte
--     por ser amigos. En su arena es el DUEÑO y tiene el panel dev (ArenaDev).
--   • Se enlaza solo con su canal de TikTok si entró con el botón "▶ ABRIR EL
--     JUEGO" del panel web (el código viaja en launchData), o con el enlace que
--     se guardó la última vez (DataStore). Si no, la pantalla OnlineConnect le
--     pide su @usuario y el código de 6 cifras del panel.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")

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

-- Servidor público (en Studio no: allí no hay teletransportes)
local function isPublicServer()
	return game.PrivateServerId == "" and not RunService:IsStudio()
end

function Online.isPublicServer()
	return Online.enabled() and isPublicServer()
end

-- Datos con los que entró el jugador: { launch = "<launchData del panel>" }
local function launchOf(player)
	local okJoin, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not okJoin or type(joinData) ~= "table" then
		return nil
	end
	if type(joinData.LaunchData) == "string" and joinData.LaunchData ~= "" then
		return joinData.LaunchData
	end
	local teleportData = joinData.TeleportData
	if type(teleportData) == "table" and type(teleportData.launch) == "string" and teleportData.launch ~= "" then
		return teleportData.launch
	end
	return nil
end

local function showOpening(player)
	local gui = Instance.new("ScreenGui")
	gui.Name = "ArenaOpening"
	gui.DisplayOrder = 1000
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(12, 10, 24)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = "🥊 Abriendo tu arena…"
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = 42
	limit.Parent = label
	label.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui", 10)
end

-- Manda al jugador a una arena privada nueva solo para él
local function sendToOwnArena(player)
	local launch = launchOf(player)
	pcall(showOpening, player)
	for attempt = 1, 3 do
		local ok, err = pcall(function()
			local accessCode = TeleportService:ReserveServer(game.PlaceId)
			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = accessCode
			options:SetTeleportData({ launch = launch })
			TeleportService:TeleportAsync(game.PlaceId, { player }, options)
		end)
		if ok then
			return
		end
		warn("🌐 No se pudo abrir la arena de " .. player.Name .. " (intento " .. attempt .. "): " .. tostring(err))
		task.wait(2)
	end
	if player.Parent then
		player:Kick("No se pudo abrir tu arena. Vuelve a entrar.")
	end
end

function Online.isOwner(player)
	return Online.enabled() and ownerUserId == player.UserId
end

-- Se llama al entrar cada jugador (ANTES de decidir quién tiene el panel dev)
function Online.playerAdded(player)
	if not Online.enabled() then
		return
	end
	if isPublicServer() then
		task.spawn(sendToOwnArena, player)
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
	local launch = launchOf(player)
	if launch then
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
