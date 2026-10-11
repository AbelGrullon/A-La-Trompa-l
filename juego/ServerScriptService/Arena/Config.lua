-- Config (ModuleScript) — constantes del servidor que NO cambian en vivo.
-- Lo que sí se ajusta en vivo (cámara, HUD, volumen, daño...) está en
-- ReplicatedStorage.Arena.Shared.DEFAULT_SETTINGS y se cambia desde el panel dev.

return {
	-- ===== SERVIDOR ONLINE (VPS) =====
	-- Con una dirección aquí ("https://trompa.tudominio.com") el juego usa el
	-- servidor online (online.js): los streamers no instalan nada, se conectan
	-- desde el panel web. Vacío = el bridge local de este PC (abajo).
	ONLINE_URL = "",

	-- ===== BRIDGE LOCAL (Node + Tikfinity en este PC) =====
	BRIDGE_URL = "http://localhost:3000",
	BRIDGE_ACCESS_TOKEN = "", -- vacío: el bridge se lo da al juego solo (no hace falta escribirlo aquí)
	BRIDGE_POLL_INTERVAL = 1,

	-- ===== COMBATE =====
	HEALTH_MAX = 100,
	DAMAGE_PER_HIT = 8,
	FIGHT_RANGE = 11, -- personajes al 175%
	MIN_FIGHT_DISTANCE = 7,
	ATTACK_COOLDOWN_MIN = 1.1,
	ATTACK_COOLDOWN_MAX = 1.9,
	PUNCH_IMPACT_DELAY = 0.3,
	CRIT_MULTIPLIER = 1.8,
	SPECIAL_MULTIPLIER = 2.5,
	ENERGY_PER_HIT = 20,
	ENERGY_PER_BLOCK = 15,
	STUN_DURATION = 1.6,
	CRIT_STUN_CHANCE = 0.3,
	REGEN_ON_WIN = 75,
	FALL_MARGIN = 5,
	FALL_TICKS_REQUIRED = 5,
	SIZE_MULTIPLIER = 1.75,
	MATCH_TIMEOUT = 120, -- un duelo no puede durar más que esto (evita atascos)

	-- ===== MOVIMIENTO EN EL RING =====
	FIGHT_WALK_SPEED = 13, -- juego de pies mientras se estudian
	APPROACH_WALK_SPEED = 18, -- ir a buscar al rival
	LUNGE_WALK_SPEED = 26, -- paso al frente al lanzar un golpe
	WANDER_WALK_SPEED = 10, -- los que esperan rival pasean por el ring
	FOOTWORK_MIN = 6.6, -- distancia mínima mientras giran alrededor del rival
	FOOTWORK_MAX = 8.6,
	LUNGE_DISTANCE = 5.2, -- distancia a la que el puño llega a la cara del rival
	WANDER_RADIUS = 20, -- radio (desde el centro del ring) por el que pasean
	SPAR_WAIT = 7, -- segundos sin rival antes de una pelea de práctica entre compañeros

	-- ===== ENTRADAS DE CINE =====
	-- Nivel del regalo más alto que mandó la persona (1 Experimentado … 5 Definitivo)
	ELITE_ENTRANCE_LEVEL = 3, -- Élite y Legendario: entrada con humo, golpes y salto
	DEFINITIVE_ENTRANCE_LEVEL = 5, -- Definitivo: salta desde fuera del ring

	-- Límites de boosts acumulados por regalos
	MAX_HEALTH_CAP = 700,
	MAX_DAMAGE_MULT = 3.5,
	MAX_SPEED_MULT = 2.2,

	-- ===== COLA / ESPECTADORES =====
	MAX_LINEUP = 80, -- gente esperando (visible en bloques + cola invisible)
	SPECTATOR_ANIM_ID = "rbxassetid://99263851255941",

	-- ===== INTERACCIONES TIKTOK =====
	LIKE_HEAL_PER_LIKE = 0.5, -- vida que recupera tu peleador por cada like
	LIKE_HEAL_MAX_PER_EVENT = 12,
	FOLLOW_HEALTH_BONUS = 25,
	SHARE_DAMAGE_BONUS = 0.10,
	UNKNOWN_GIFT_HEAL_PER_DIAMOND = 5,
	UNKNOWN_GIFT_HEAL_MAX = 60,
	FURY_DURATION = 20,
	FURY_DAMAGE_MULT = 1.5,
	FURY_SPEED_MULT = 1.35,
	HEART_RAIN_HEAL = 0.35, -- % de la vida máxima

	-- ===== LLUVIA DE GUANTES =====
	GLOVE_RAIN_COUNT = 45,
	GLOVE_RAIN_HEIGHT = 60,
	GLOVE_RAIN_SPAWN_RADIUS = 16,
	GLOVE_RAIN_STAGGER_MAX = 4.5,
	GLOVE_RAIN_EXPLOSION_RADIUS = 12,
	GLOVE_RAIN_DAMAGE = 40,
	GLOVE_RAIN_LIFETIME = 8,
	GLOVE_RAIN_WARNING = 1.2, -- segundos de marcas en el piso antes de que empiecen a caer

	-- ===== ANIMACIONES =====
	WALK_ANIM_ID = "rbxassetid://913402848",
	IDLE_ANIM_ID = "rbxassetid://107589616310404",
	-- (los golpes, bloqueos, esquivas y reacciones se animan por código en
	-- StarterPlayerScripts.FighterAnimator; estos IDs quedan de respaldo)
	PUNCH_ANIM_IDS = {
		"rbxassetid://104387521934805",
		"rbxassetid://84238644583375",
		"rbxassetid://106628468470867",
	},
	BLOCK_ANIM_ID = "rbxassetid://103278281479227",
	-- Emotes estándar de Roblox (R15)
	CHEER_ANIM_ID = "rbxassetid://507770677",
	WAVE_ANIM_ID = "rbxassetid://507770239",
	DANCE_ANIM_IDS = { "rbxassetid://507771019", "rbxassetid://507771955", "rbxassetid://507772104" },

	-- ===== IMÁGENES =====
	BOOM_IMAGE_ID = "rbxassetid://110449530369400",
	BLOCKED_IMAGE_ID = "rbxassetid://90642108973827",
	STUN_ICON_ID = "rbxassetid://90676545548082",
	RAIN_ALERT_GOLD = "rbxassetid://71981344068380",
	RAIN_ALERT_DARK = "rbxassetid://88522051020137",

	-- ===== SONIDOS =====
	SOUNDS = {
		Music = "rbxassetid://93616367708595",
		CrowdLoop = "rbxassetid://9112766176",
		Bell = "rbxassetid://77267160233967",
		Hits = {
			"rbxassetid://107880347380356",
			"rbxassetid://105646646799559",
			"rbxassetid://110161496671275",
			"rbxassetid://125432357024120",
			"rbxassetid://131678220004053",
			"rbxassetid://106274302977627",
		},
		HeavyHit = "rbxassetid://82235785832022",
		Stun = "rbxassetid://135182670866586",
		Whoosh = "rbxassetid://123796710194563",
		Explosion = "rbxassetid://138533090376585",
		Cheer = "rbxassetid://126615573673174",
		Gasp = "rbxassetid://9114013034",
		AirHorn = "rbxassetid://132844961288199",
		Siren = "rbxassetid://129496339606661",
		Chime = "rbxassetid://104000340117740",
		PowerUp = "rbxassetid://102241706777824",
		Heal = "rbxassetid://99399743166094",
	},

	-- Cuentas de Roblox SOLO para sacar avatares variados. Los espectadores
	-- de TikTok nunca escriben su usuario de Roblox: a cada nombre de TikTok
	-- se le asigna siempre el mismo avatar de esta lista (por hash del nombre).
	AVATAR_POOL = {
		"Eltoyverificado", "Elmmmssi8", "alexpigyyYT", "pinoquinhow828", "gbfieell57",
		"sub_zero02011", "edgarc595", "matesu513", "eu_joseph004", "pipoieto2444",
		"Dark_r170", "davizinho777733", "pietroooo348", "Bernardox_x244", "kkss_42",
		"yuriyuri897", "davilu_1241", "Gojovegita", "kauanagro",
	},

	-- Nombres para los bots de prueba del panel dev
	BOT_NAMES = {
		"ElTrompas", "PuñoDeHierro", "LaMole", "Chispita", "ElBravo", "Tormenta", "Relampago",
		"LaFiera", "Martillo", "Canelita", "ElJefe", "Bombón", "Titan", "Sombra", "Rayito",
		"Pantera", "Gladiador", "Tiburon", "Coco", "LaRoca", "Fenix", "Zeta", "Lobo", "Nube",
	},
}
