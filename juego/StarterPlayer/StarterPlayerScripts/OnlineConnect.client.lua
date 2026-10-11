-- OnlineConnect (LocalScript en StarterPlayerScripts)
-- Pantalla "Conecta tu TikTok" del juego publicado (modo online, ver el módulo
-- Online del servidor). Sale si el streamer no entró con el botón
-- "▶ ABRIR EL JUEGO" del panel web y no hay un enlace guardado: escribe su
-- @usuario de TikTok y el código de 6 cifras que sale en el panel.
-- Vuelve a salir si el código deja de valer (por ejemplo, si hizo uno nuevo).

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local arena = ReplicatedStorage:WaitForChild("Arena")
local stateFolder = arena:WaitForChild("State")
local remotes = arena:WaitForChild("Remotes")
local devCommand = remotes:WaitForChild("DevCommand")
local hudEvent = remotes:WaitForChild("HudEvent")

local startedWaiting = os.clock()
while (stateFolder:GetAttribute("OnlineMode") == nil or player:GetAttribute("ArenaDev") == nil) and os.clock() - startedWaiting < 15 do
	task.wait(0.25)
end
if not stateFolder:GetAttribute("OnlineMode") or not player:GetAttribute("ArenaDev") then
	return
end

local WHITE = Color3.new(1, 1, 1)
local GOLD = Color3.fromRGB(255, 205, 60)
local MUTED = Color3.fromRGB(185, 180, 205)

local function new(className, props, children)
	local inst = Instance.new(className)
	local parent
	for key, value in pairs(props or {}) do
		if key == "Parent" then
			parent = value
		else
			inst[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function tween(inst, seconds, goal, style)
	local t = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

local function text(props)
	local label = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		TextScaled = true,
		TextWrapped = true,
	})
	for key, value in pairs(props) do
		if key ~= "Parent" then
			label[key] = value
		end
	end
	label.Parent = props.Parent
	return label
end

local function box(placeholder, position)
	local frame = new("Frame", {
		Size = UDim2.new(1, -80, 0, 62),
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = Color3.fromRGB(28, 26, 40),
		BorderSizePixel = 0,
	}, { new("UICorner", { CornerRadius = UDim.new(0, 14) }), new("UIStroke", { Color = Color3.fromRGB(80, 70, 110), Thickness = 2 }) })
	local input = new("TextBox", {
		Size = UDim2.new(1, -28, 0.7, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = WHITE,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Color3.fromRGB(120, 115, 140),
		Text = "",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	return frame, input
end

-- ===== PANTALLA =====
local gui = new("ScreenGui", {
	Name = "ArenaOnlineConnect",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 210, -- (encima del menú Solo / Batalla)
	Enabled = false,
	Parent = playerGui,
})
local blur = new("BlurEffect", { Name = "OnlineConnectBlur", Size = 0, Enabled = false, Parent = Lighting })
local overlay = new("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(6, 6, 12),
	BackgroundTransparency = 0.25,
	Parent = gui,
})
local card = new("Frame", {
	Size = UDim2.fromOffset(640, 600),
	Position = UDim2.fromScale(0.5, 0.5),
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = WHITE,
	BorderSizePixel = 0,
	Parent = overlay,
}, {
	new("UICorner", { CornerRadius = UDim.new(0, 26) }),
	new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(40, 22, 44), Color3.fromRGB(14, 12, 22)), Rotation = 90 }),
})
local cardStroke = new("UIStroke", { Color = GOLD, Thickness = 3, Transparency = 0.2, Parent = card })
local cardScale = new("UIScale", { Parent = card })

text({ Size = UDim2.new(1, -60, 0, 64), Position = UDim2.fromOffset(30, 26), Font = Enum.Font.GothamBlack, Text = "🔗 CONECTA TU TIKTOK", Parent = card })
local steps = text({
	Size = UDim2.new(1, -70, 0, 120),
	Position = UDim2.fromOffset(35, 100),
	Font = Enum.Font.GothamMedium,
	TextColor3 = Color3.fromRGB(225, 220, 240),
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "",
	Parent = card,
})
local userFrame, userBox = box("@tu_usuario de TikTok", UDim2.new(0.5, 0, 0, 236))
userFrame.Parent = card
local codeFrame, codeBox = box("Código de 6 cifras del panel", UDim2.new(0.5, 0, 0, 312))
codeFrame.Parent = card
local button = new("TextButton", {
	Size = UDim2.new(1, -80, 0, 70),
	Position = UDim2.new(0.5, 0, 0, 398),
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = WHITE,
	AutoButtonColor = true,
	Font = Enum.Font.GothamBlack,
	TextScaled = true,
	TextColor3 = Color3.fromRGB(26, 16, 4),
	Text = "CONECTAR",
	Parent = card,
}, {
	new("UICorner", { CornerRadius = UDim.new(1, 0) }),
	new("UIGradient", { Color = ColorSequence.new(GOLD, Color3.fromRGB(255, 122, 60)) }),
	new("UIPadding", { PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 16) }),
})
local status = text({
	Size = UDim2.new(1, -70, 0, 34),
	Position = UDim2.fromOffset(35, 482),
	Font = Enum.Font.GothamBold,
	TextColor3 = Color3.fromRGB(255, 120, 120),
	Text = "",
	Parent = card,
})
text({
	Size = UDim2.new(1, -70, 0, 50),
	Position = UDim2.fromOffset(35, 526),
	Font = Enum.Font.Gotham,
	TextColor3 = MUTED,
	Text = "Consejo: si entras al juego con el botón ▶ ABRIR EL JUEGO del panel web, te conectas solo.",
	Parent = card,
})

local function fit()
	local viewport = Workspace.CurrentCamera.ViewportSize
	cardScale.Scale = math.clamp(math.min(viewport.X / 700, viewport.Y / 660), 0.4, 1.5)
end
fit()
Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)

local showing = false
local function show()
	if showing then
		return
	end
	showing = true
	local url = tostring(stateFolder:GetAttribute("OnlineUrl") or "")
	steps.Text = "1. Abre " .. (if url ~= "" then url else "el panel web") .. " en tu navegador (junto a Tikfinity) y entra con tu @usuario.\n2. Escribe aquí tu @usuario y el código de 6 cifras que sale en el panel."
	status.Text = ""
	gui.Enabled = true
	blur.Enabled = true
	blur.Size = 0
	tween(blur, 0.4, { Size = 18 })
	fit()
	local target = cardScale.Scale
	cardScale.Scale = target * 0.8
	tween(cardScale, 0.4, { Scale = target }, Enum.EasingStyle.Back)
end

local function hide(message)
	if not showing then
		return
	end
	showing = false
	status.TextColor3 = Color3.fromRGB(120, 240, 150)
	status.Text = message or ""
	cardStroke.Color = Color3.fromRGB(120, 240, 150)
	task.wait(if message then 1 else 0)
	tween(blur, 0.3, { Size = 0 })
	tween(cardScale, 0.3, { Scale = cardScale.Scale * 0.85 })
	task.wait(0.3)
	gui.Enabled = false
	blur.Enabled = false
	cardStroke.Color = GOLD
	status.TextColor3 = Color3.fromRGB(255, 120, 120)
end

local busy = false
local function submit()
	if busy then
		return
	end
	local user = string.gsub(userBox.Text, "%s", "")
	local code = string.gsub(codeBox.Text, "%D", "")
	if #user < 2 then
		status.Text = "Escribe tu @usuario de TikTok"
		return
	end
	if #code ~= 6 then
		status.Text = "El código tiene 6 cifras (está en el panel web)"
		return
	end
	busy = true
	status.TextColor3 = MUTED
	status.Text = "Conectando…"
	devCommand:FireServer("linkOnline", { user = user, code = code })
	task.delay(10, function()
		if busy then
			busy = false
			status.TextColor3 = Color3.fromRGB(255, 120, 120)
			status.Text = "El servidor no responde. Inténtalo otra vez."
		end
	end)
end
button.Activated:Connect(submit)
codeBox.FocusLost:Connect(function(enter)
	if enter then
		submit()
	end
end)

hudEvent.OnClientEvent:Connect(function(kind, data)
	if kind ~= "online" or type(data) ~= "table" then
		return
	end
	busy = false
	if data.linked then
		task.spawn(hide, "✅ Conectado como @" .. tostring(data.user or ""))
	elseif data.error then
		status.TextColor3 = Color3.fromRGB(255, 120, 120)
		status.Text = tostring(data.error)
		local x = card.Position
		task.spawn(function()
			for i = 1, 6 do
				card.Position = x + UDim2.fromOffset(if i % 2 == 0 then 10 else -10, 0)
				task.wait(0.04)
			end
			card.Position = x
		end)
	end
end)

-- Sale si no está enlazado (se espera un poco: puede llegar el enlace del botón o el guardado)
local function refresh()
	if stateFolder:GetAttribute("OnlineLinked") then
		task.spawn(hide, "✅ Conectado como @" .. tostring(stateFolder:GetAttribute("OnlineUser") or ""))
	else
		task.delay(2.5, function()
			if not stateFolder:GetAttribute("OnlineLinked") then
				show()
			end
		end)
	end
end
stateFolder:GetAttributeChangedSignal("OnlineLinked"):Connect(refresh)
refresh()
