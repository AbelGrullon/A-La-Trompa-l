-- Bridge (ModuleScript) — habla con el servidor de eventos de TikTok. Dos formas:
--   • LOCAL (Config.ONLINE_URL = ""): el bridge de Node (server.js) en este PC,
--     conectado a Tikfinity. El token se pide solo por /handshake.
--   • ONLINE (Config.ONLINE_URL = "https://..."): el servidor online (online.js)
--     en un VPS. Cada streamer tiene su canal; el juego se enlaza con el código
--     del botón "Abrir el juego" del panel web (launchData, lo lee el módulo
--     Online) o con @usuario + código de 6 cifras (pantalla OnlineConnect).
-- Un solo endpoint trae TODOS los eventos de TikTok (regalos, likes, seguidores,
-- espectadores, batallas) y las órdenes del panel web. También guarda los
-- ajustes del panel dev.
-- En un juego publicado, los nombres que llegan de TikTok (y los anuncios del
-- panel) pasan por el filtro de texto de Roblox antes de mostrarse.

local HttpService = game:GetService("HttpService")
local TextService = game:GetService("TextService")
local RunService = game:GetService("RunService")

local Bridge = {}

local config
local state -- Configuration con atributos que leen el panel dev y la pantalla de conexión
local saveToken = 0
local warnedOffline = false
local accessToken = "" -- LOCAL: el bridge lo da solo por /handshake (se guarda una vez en su .env)
local channelToken = nil -- ONLINE: código secreto del canal del streamer
local ownerUserId = nil -- dueño del servidor (para el filtro de texto)
local linkListeners = {}
local filterCache = {}
local filterCacheSize = 0

local function isOnline()
	return type(config.ONLINE_URL) == "string" and config.ONLINE_URL ~= ""
end

local function baseUrl()
	if isOnline() then
		return (string.gsub(config.ONLINE_URL, "/+$", ""))
	end
	return config.BRIDGE_URL
end

-- Petición HTTP que devuelve (ok, código, datos JSON)
local function request(method, url, body)
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = method,
			Headers = { ["Content-Type"] = "application/json" },
			Body = if body then HttpService:JSONEncode(body) else nil,
		})
	end)
	if not ok then
		return false, 0, tostring(response)
	end
	local decoded = nil
	pcall(function()
		decoded = HttpService:JSONDecode(response.Body)
	end)
	return response.Success, response.StatusCode, decoded
end

-- Pide el token al bridge local (solo responde a este PC). true si lo consiguió.
local function handshake()
	local ok, _, data = request("GET", config.BRIDGE_URL .. "/handshake")
	if ok and type(data) == "table" and type(data.token) == "string" then
		accessToken = data.token
		return true
	end
	return false
end

local function buildUrl(path)
	if isOnline() then
		return baseUrl() .. "/game" .. path .. (string.find(path, "?", 1, true) and "&" or "?") .. "t=" .. HttpService:UrlEncode(channelToken or "")
	end
	local url = config.BRIDGE_URL .. path
	local token = if config.BRIDGE_ACCESS_TOKEN ~= "" then config.BRIDGE_ACCESS_TOKEN else accessToken
	if token ~= "" then
		url ..= (string.find(path, "?", 1, true) and "&" or "?") .. "token=" .. HttpService:UrlEncode(token)
	end
	return url
end

local function notifyLink()
	for _, callback in ipairs(linkListeners) do
		task.spawn(callback, channelToken ~= nil, state:GetAttribute("OnlineUser"), channelToken)
	end
end

local function setLinked(token, user)
	channelToken = token
	state:SetAttribute("OnlineLinked", token ~= nil)
	state:SetAttribute("OnlineUser", if token then tostring(user or "") else "")
	notifyLink()
end

local function getJson(path)
	local ok, status, data = request("GET", buildUrl(path))
	if not ok then
		if status == 401 then
			if isOnline() then
				if channelToken then
					warn("🔌 [Bridge] El código del juego ya no vale (¿hiciste uno nuevo en el panel?). Vuelve a conectar.")
					setLinked(nil)
				end
			elseif config.BRIDGE_ACCESS_TOKEN == "" then
				accessToken = "" -- el bridge cambió de token: se vuelve a pedir
			end
		end
		return nil, if status ~= 0 then ("HTTP " .. status) else data
	end
	if type(data) ~= "table" then
		return nil, "JSON inválido"
	end
	return data
end

-- ===== FILTRO DE TEXTO (juego publicado) =====
local function filterText(text)
	if RunService:IsStudio() or not ownerUserId or type(text) ~= "string" or text == "" then
		return text
	end
	local cached = filterCache[text]
	if cached then
		return cached
	end
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, ownerUserId, Enum.TextFilterContext.PublicChat):GetNonChatStringForBroadcastAsync()
	end)
	local clean = if ok and type(result) == "string" then result else "Espectador"
	if filterCacheSize > 3000 then
		table.clear(filterCache)
		filterCacheSize = 0
	end
	filterCache[text] = clean
	filterCacheSize += 1
	return clean
end

-- Filtra en paralelo los nombres nuevos de un lote (como mucho 4 s)
local function filterEvents(events)
	if RunService:IsStudio() or not ownerUserId then
		return
	end
	local pending = {}
	for _, event in ipairs(events) do
		if type(event) == "table" then
			for _, field in ipairs({ "name", "text" }) do
				local value = event[field]
				if type(value) == "string" and value ~= "" and not filterCache[value] then
					pending[value] = true
				end
			end
		end
	end
	local waiting = 0
	for text in pairs(pending) do
		waiting += 1
		task.spawn(function()
			filterText(text)
			waiting -= 1
		end)
	end
	local started = os.clock()
	while waiting > 0 and os.clock() - started < 4 do
		task.wait(0.05)
	end
	for _, event in ipairs(events) do
		if type(event) == "table" then
			for _, field in ipairs({ "name", "text" }) do
				if type(event[field]) == "string" and event[field] ~= "" then
					event[field] = filterCache[event[field]] or "Espectador"
				end
			end
		end
	end
end

-- ===== API =====

function Bridge.init(cfg, stateFolder)
	config = cfg
	state = stateFolder
	state:SetAttribute("BridgeOnline", false)
	state:SetAttribute("TikfinityOnline", false)
	state:SetAttribute("OnlineMode", isOnline())
	state:SetAttribute("OnlineUrl", if isOnline() then baseUrl() else "")
	state:SetAttribute("OnlineLinked", false)
	state:SetAttribute("OnlineUser", "")
end

function Bridge.isOnline()
	return isOnline()
end

-- callback(enlazado, usuario, token) cada vez que se enlaza o se pierde el canal
function Bridge.onLinkChanged(callback)
	table.insert(linkListeners, callback)
end

function Bridge.setOwner(userId)
	ownerUserId = userId
end

-- ONLINE: usa un código de canal ya conocido (botón del panel o el de la última vez)
function Bridge.setToken(token, user)
	if type(token) == "string" and token ~= "" then
		setLinked(token, user)
	end
end

-- ONLINE: enlaza con @usuario + código de 6 cifras. Devuelve (true, usuario) o (false, mensaje)
function Bridge.link(user, code)
	if not isOnline() then
		return false, "El juego no está en modo online"
	end
	local url = baseUrl() .. "/game/link?user=" .. HttpService:UrlEncode(tostring(user or "")) .. "&code=" .. HttpService:UrlEncode(tostring(code or ""))
	local ok, status, data = request("GET", url)
	if ok and type(data) == "table" and type(data.token) == "string" then
		setLinked(data.token, data.user)
		return true, data.user
	end
	if type(data) == "table" and type(data.error) == "string" then
		return false, data.error
	end
	return false, if status == 0 then "No se pudo conectar con el servidor" else ("Error " .. status)
end

function Bridge.unlink()
	setLinked(nil)
end

-- Llama a onEvents(listaDeEventos) cada vez que llegan eventos nuevos.
function Bridge.start(onEvents)
	task.spawn(function()
		while true do
			if isOnline() and not channelToken then
				-- (esperando a que el streamer conecte su TikTok)
				state:SetAttribute("BridgeOnline", false)
				state:SetAttribute("TikfinityOnline", false)
				task.wait(1)
				continue
			end
			if not isOnline() and config.BRIDGE_ACCESS_TOKEN == "" and accessToken == "" then
				handshake()
			end
			local data, err = getJson(if isOnline() then "/pull" else "/events/pull")
			if data then
				if not state:GetAttribute("BridgeOnline") then
					print("🔌 [Bridge] Conectado a " .. baseUrl() .. (if isOnline() then (" como @" .. tostring(data.user)) else ""))
				end
				if isOnline() and type(data.user) == "string" and state:GetAttribute("OnlineUser") ~= data.user then
					state:SetAttribute("OnlineUser", data.user)
					notifyLink()
				end
				warnedOffline = false
				state:SetAttribute("BridgeOnline", true)
				state:SetAttribute("TikfinityOnline", data.tikfinity == true)
				if type(data.events) == "table" and #data.events > 0 then
					filterEvents(data.events)
					local ok, handlerError = pcall(onEvents, data.events)
					if not ok then
						warn("⚠️ [Bridge] Error procesando eventos: " .. tostring(handlerError))
					end
				end
				task.wait(config.BRIDGE_POLL_INTERVAL)
			else
				state:SetAttribute("BridgeOnline", false)
				state:SetAttribute("TikfinityOnline", false)
				if not warnedOffline then
					warnedOffline = true
					warn("🔌 [Bridge] Sin conexión con " .. baseUrl() .. " (" .. tostring(err) .. ")." .. (if isOnline() then " Sigo intentando..." else " ¿Está corriendo 'npm start'? Sigo intentando..."))
				end
				task.wait(3)
			end
		end
	end)
end

-- Ajustes guardados (settings.json del bridge o del canal online). nil si no hay.
-- En modo online espera a que el streamer conecte su TikTok.
function Bridge.loadSettings()
	if isOnline() then
		while not channelToken do
			task.wait(0.5)
		end
	elseif config.BRIDGE_ACCESS_TOKEN == "" and accessToken == "" then
		handshake()
	end
	local data = getJson("/settings")
	if data and type(data.settings) == "table" then
		return data.settings
	end
	return nil
end

-- Guarda los ajustes (con un pequeño retraso para agrupar varios cambios).
function Bridge.saveSettings(settings)
	saveToken += 1
	local token = saveToken
	task.delay(1.5, function()
		if token ~= saveToken or (isOnline() and not channelToken) then
			return
		end
		local ok, status, data = request("POST", buildUrl("/settings"), { settings = settings })
		if not ok then
			warn("💾 [Bridge] No se pudieron guardar los ajustes: " .. tostring(if status ~= 0 then ("HTTP " .. status) else data))
		end
	end)
end

return Bridge
