-- LightFlicker (Script dentro de la Part que tiene la luz)

local TweenService = game:GetService("TweenService")

local lightPart = script.Parent
local light = lightPart:FindFirstChildWhichIsA("Light")

if not light then
	warn("No se encontró ningún objeto de luz dentro de " .. lightPart.Name .. " — agrega un PointLight o SpotLight ahí")
	return
end

-- ===== PARPADEO =====
local MIN_ON_TIME = 0.05
local MAX_ON_TIME = 0.15
local MIN_OFF_TIME = 0.03
local MAX_OFF_TIME = 0.12
local baseBrightness = light.Brightness

task.spawn(function()
	while true do
		light.Enabled = true
		light.Brightness = baseBrightness
		task.wait(MIN_ON_TIME + math.random() * (MAX_ON_TIME - MIN_ON_TIME))

		light.Enabled = false
		task.wait(MIN_OFF_TIME + math.random() * (MAX_OFF_TIME - MIN_OFF_TIME))
	end
end)

-- ===== CAMBIO DE COLOR ALEATORIO =====
local COLOR_CHANGE_MIN_INTERVAL = 0.4
local COLOR_CHANGE_MAX_INTERVAL = 1.2
local COLOR_TRANSITION_TIME = 0.15

task.spawn(function()
	while true do
		local randomColor = Color3.fromHSV(math.random(), 0.85, 1)

		local colorTween = TweenService:Create(
			light,
			TweenInfo.new(COLOR_TRANSITION_TIME, Enum.EasingStyle.Linear),
			{ Color = randomColor }
		)
		colorTween:Play()

		task.wait(COLOR_CHANGE_MIN_INTERVAL + math.random() * (COLOR_CHANGE_MAX_INTERVAL - COLOR_CHANGE_MIN_INTERVAL))
	end
end)