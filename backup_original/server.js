require('dotenv').config();
const express = require('express');
const WebSocket = require('ws');

// ===== CONFIGURACIÓN =====
const PORT = process.env.PORT || 3000;
const ACCESS_TOKEN = (process.env.ACCESS_TOKEN || '').trim(); // clave secreta para que solo tu juego pueda consultar la cola
const TIKFINITY_URL = process.env.TIKFINITY_URL || 'ws://127.0.0.1:21213/';
// Formato válido de un username de Roblox: 3 a 20 caracteres, letras/números/guion bajo.
const USERNAME_REGEX = /^[A-Za-z0-9_]{3,20}$/;
// Evita que el mismo nombre entre varias veces seguidas si alguien repite su username en el chat.
const REJOIN_COOLDOWN_MS = Number(process.env.REJOIN_COOLDOWN_MS || 60000);

const app = express();

// Red de seguridad: un error aislado no debe tumbar todo el bridge.
process.on('uncaughtException', (err) => {
	console.error('⚠️ Error no capturado (el servidor sigue corriendo):', err);
});
process.on('unhandledRejection', (reason) => {
	console.error('⚠️ Promesa rechazada sin manejar (el servidor sigue corriendo):', reason);
});

// Cola en memoria: candidatos a username de Roblox, esperando que Roblox los valide y los spawnee.
// Se vacía cada vez que Roblox la consulta (ver /queue/pull más abajo).
let joinQueue = [];

// Los 5 regalos válidos y su boost asociado. healthPercent/damagePercent/
// speedPercent son fracciones (0.50 = +50%), no puntos planos — el % se
// aplica sobre las estadísticas base del peleador.
const GIFT_TIERS = {
	// Héroes
	5655: { name: 'Peleador Experimentado', team: 'hero', healthPercent: 0.50, damagePercent: 0.10, speedPercent: 0 },
	5487: { name: 'Peleador Profesional', team: 'hero', healthPercent: 0.75, damagePercent: 0.25, speedPercent: 0 },
	8913: { name: 'Peleador Elite', team: 'hero', healthPercent: 1.00, damagePercent: 0.35, speedPercent: 0 },
	14488: { name: 'Peleador Legendario', team: 'hero', healthPercent: 1.25, damagePercent: 0.45, speedPercent: 0.25 },
	5660: { name: 'Peleador Definitivo', team: 'hero', healthPercent: 1.50, damagePercent: 0.55, speedPercent: 0.50 },
	// Villanos (mismos 5 niveles de boost, mismos montos, pero reclutan para el otro equipo)
	6064: { name: 'Peleador Experimentado', team: 'villain', healthPercent: 0.50, damagePercent: 0.10, speedPercent: 0 },
	105781: { name: 'Peleador Profesional', team: 'villain', healthPercent: 0.75, damagePercent: 0.25, speedPercent: 0 },
	9947: { name: 'Peleador Elite', team: 'villain', healthPercent: 1.00, damagePercent: 0.35, speedPercent: 0 },
	5879: { name: 'Peleador Legendario', team: 'villain', healthPercent: 1.25, damagePercent: 0.45, speedPercent: 0.25 },
	5585: { name: 'Peleador Definitivo', team: 'villain', healthPercent: 1.50, damagePercent: 0.55, speedPercent: 0.50 },
};

// Cuentas de Roblox de respaldo: si alguien manda un regalo válido pero NUNCA
// escribió un username de Roblox antes, se le asigna una de estas al azar
// (para el avatar), mostrando igual su nombre real de TikTok en el juego.
const FALLBACK_AVATAR_POOL = [
	'Eltoyverificado', 'Elmmmssi8', 'alexpigyyYT', 'pinoquinhow828', 'gbfieell57',
	'sub_zero02011', 'edgarc595', 'matesu513', 'eu_joseph004', 'pipoieto2444',
	'Dark_r170', 'davizinho777733', 'pietroooo348', 'Bernardox_x244', 'kkss_42',
	'yuriyuri897', 'davilu_1241', 'Gojovegita', 'kauanagro',
];

// Boosts para peleadores YA conocidos (con username de Roblox asociado):
// { username, healthPercent, damagePercent, speedPercent }
let boostQueue = [];
// Regalos de gente que NUNCA escribió un username: { tiktokUsername, healthPercent, damagePercent, speedPercent }
let giftSpawnQueue = [];

// Cola de eventos de regalos generales/especiales (ej: Lluvia de guantes 6427 y 5659)
let giftEventsQueue = [];

// Registro de TODOS los regalos que llegan alguna vez, tengan o no uno de
// nuestros 5 IDs conocidos — para poder revisar después qué otros IDs/nombres
// mandó la gente, sin depender de mirar la consola en el momento.
// giftId (number) -> { count, names: Set<string>, lastSeen: string }
let giftLog = new Map();

// username (en minúsculas) -> timestamp del último ingreso, para el cooldown anti-spam.
const recentlyQueued = new Map();

// Cuenta de TikTok -> último username de Roblox que esa cuenta escribió en el
// chat. Es la única forma de saber, cuando llega una rosa, A QUIÉN boostear:
// el regalo trae la identidad de TikTok del que dona, no el username de
// Roblox directamente.
const robloxUsernameByTiktokUser = new Map();

// Palabra clave al inicio del mensaje -> equipo. Si el mensaje no empieza con
// ninguna de estas, el candidato entra sin equipo (neutral).
const TEAM_KEYWORDS = {
	VILLANO: 'villain',
	HEROE: 'hero',
};

function tryQueueUsername(rawText, source, tiktokUsername) {
	if (!rawText) {
		return;
	}

	const words = rawText.trim().split(/\s+/);
	const keyword = words[0].toUpperCase();

	// Escribió SOLO "Heroe" o "Villano", sin username después. Si esta cuenta
	// de TikTok nunca escribió un username de Roblox, la hacemos aparecer con
	// una cuenta de respaldo del pool, ya asignada a ese equipo.
	if (TEAM_KEYWORDS[keyword] && !words[1]) {
		if (tiktokUsername && !robloxUsernameByTiktokUser.has(tiktokUsername)) {
			giftSpawnQueue.push({
				tiktokUsername,
				team: TEAM_KEYWORDS[keyword],
				healthPercent: 0,
				damagePercent: 0,
				speedPercent: 0,
			});
			// Se referencia a sí mismo: de ahora en más, "su personaje" para
			// efectos de boost es el que aparece bajo su propio nombre de
			// TikTok (así una rosa después de esto lo encuentra y lo boostea,
			// en vez de intentar crearle un personaje nuevo por error).
			robloxUsernameByTiktokUser.set(tiktokUsername, tiktokUsername);
			console.log(`🎭 [${source}] Escribió "${keyword}" solo, sin username — aparecerá con cuenta de respaldo (equipo: ${TEAM_KEYWORDS[keyword]})`);
		}
		return;
	}

	// Si la primera palabra es VILLANO o HEROE, el candidato real es la SEGUNDA palabra.
	// Si no, tratamos la primera palabra como el candidato de siempre, sin equipo.
	let team = null;
	let candidate = words[0];

	if (TEAM_KEYWORDS[keyword] && words[1]) {
		team = TEAM_KEYWORDS[keyword];
		candidate = words[1];
	}

	if (!USERNAME_REGEX.test(candidate)) {
		return;
	}

	const key = candidate.toLowerCase();
	const now = Date.now();
	const lastQueuedAt = recentlyQueued.get(key);
	if (lastQueuedAt && now - lastQueuedAt < REJOIN_COOLDOWN_MS) {
		return;
	}
	recentlyQueued.set(key, now);

	if (tiktokUsername) {
		robloxUsernameByTiktokUser.set(tiktokUsername, candidate);
	}

	joinQueue.push({ username: candidate, team });
	console.log(
		`🎮 [${source}] Candidato: ${candidate}${team ? ' (' + team + ')' : ''} (cola: ${joinQueue.length})`
	);
}

// ===== CONEXIÓN A TIKFINITY (local) =====
let socket = null;
let reconnectTimer = null;

function connectToTikfinity() {
	socket = new WebSocket(TIKFINITY_URL);

	socket.on('open', () => {
		console.log(`✅ Conectado a Tikfinity en ${TIKFINITY_URL}`);
	});

	socket.on('message', (raw) => {
		let message;
		try {
			message = JSON.parse(raw.toString());
		} catch (err) {
			return;
		}

		if (message.event === 'chat') {
			const comment = message.data?.comment;
			const username = message.data?.uniqueId || message.data?.nickname || 'desconocido';
			console.log(`💬 @${username}: ${comment}`);
			tryQueueUsername(comment, `chat de @${username}`, username);
		} else if (message.event === 'gift') {
			console.log('🎁 Evento de regalo crudo:', JSON.stringify(message.data));

			const giftId = Number(message.data?.giftId);
			const giftName =
				message.data?.giftName ||
				message.data?.gift?.name ||
				message.data?.giftDetails?.name ||
				message.data?.describe ||
				null;

			if (!Number.isNaN(giftId)) {
				if (!giftLog.has(giftId)) {
					giftLog.set(giftId, { count: 0, names: new Set(), lastSeen: null });
				}
				const logEntry = giftLog.get(giftId);
				logEntry.count += 1;
				logEntry.lastSeen = new Date().toISOString();
				if (giftName) {
					logEntry.names.add(giftName);
				}
			}

			const tiktokUsername =
				message.data?.user?.uniqueId ||
				message.data?.uniqueId ||
				message.data?.user?.nickname ||
				message.data?.nickname;

			// Registramos todo evento de regalo para que Roblox lo procese (ej: Lluvias de Guantes)
			if (!Number.isNaN(giftId)) {
				giftEventsQueue.push({ giftId, tiktokUsername, giftName });
			}

			const tier = GIFT_TIERS[giftId];

			if (tier && tiktokUsername) {
				const robloxUsername = robloxUsernameByTiktokUser.get(tiktokUsername);
				const boostData = {
					team: tier.team,
					healthPercent: tier.healthPercent,
					damagePercent: tier.damagePercent,
					speedPercent: tier.speedPercent,
				};

				if (robloxUsername) {
					// Ya sabemos qué personaje es suyo: boost directo.
					boostQueue.push({ username: robloxUsername, ...boostData });
					console.log(`🎁 @${tiktokUsername} donó "${tier.name}" → boost para ${robloxUsername} (Roblox)`);
				} else {
					// Nunca escribió un username: lo hacemos aparecer con una
					// cuenta de respaldo, mostrando su nombre real de TikTok.
					giftSpawnQueue.push({ tiktokUsername, ...boostData });
					// Se referencia a sí mismo, para que un PRÓXIMO regalo lo
					// encuentre como boost directo en vez de intentar crearle
					// un personaje nuevo otra vez.
					robloxUsernameByTiktokUser.set(tiktokUsername, tiktokUsername);
					console.log(`🎁 @${tiktokUsername} donó "${tier.name}" sin haber escrito un username antes → aparecerá con cuenta de respaldo`);
				}
			}
		} else if (message.event === 'liveStatusChange') {
			console.log(message.data?.isLive ? '🔴 El live empezó' : '⚫ El live terminó');
		}
	});

	socket.on('close', () => {
		console.warn('⚠️ Desconectado de Tikfinity. Reintentando en 5 segundos...');
		scheduleReconnect();
	});

	socket.on('error', (err) => {
		console.error('❌ Error de conexión con Tikfinity:', err.message || err);
	});
}

function scheduleReconnect() {
	if (reconnectTimer) {
		return;
	}
	reconnectTimer = setTimeout(() => {
		reconnectTimer = null;
		connectToTikfinity();
	}, 5000);
}

connectToTikfinity();

// ===== SEGURIDAD BÁSICA =====
function checkAccess(req, res, next) {
	if (!ACCESS_TOKEN) {
		return next();
	}
	const providedToken = (req.query.token || '').trim();
	if (providedToken !== ACCESS_TOKEN) {
		return res.status(401).json({ error: 'Token inválido o faltante' });
	}
	next();
}

console.log(`🔑 Token cargado (${ACCESS_TOKEN.length} caracteres): [${ACCESS_TOKEN}]`);

// ===== API QUE CONSULTA ROBLOX =====

app.get('/queue/pull', checkAccess, (req, res) => {
	const names = joinQueue;
	joinQueue = [];
	res.json({ names });
});

// Endpoint para consultar eventos de regalos especiales (ej. Lluvia de guantes)
app.get('/gifts/pull', checkAccess, (req, res) => {
	const gifts = giftEventsQueue;
	giftEventsQueue = [];
	res.json({ gifts });
});

// Endpoint de prueba: agrega un username directo a la cola, sin pasar por TikTok/Tikfinity.
app.get('/debug/add', checkAccess, (req, res) => {
	const username = req.query.username;
	if (!username) {
		return res.status(400).json({ error: 'Falta el parámetro username, ej: /debug/add?username=Builderman&team=villano&tier=5655&token=...' });
	}

	const teamParam = (req.query.team || '').toUpperCase();
	let team = null;
	if (teamParam === 'VILLANO') {
		team = 'villain';
	} else if (teamParam === 'HEROE') {
		team = 'hero';
	}

	const tier = GIFT_TIERS[Number(req.query.tier)] || null;
	// Si eligieron un regalo con nivel, ESE regalo ya trae su propio equipo
	// (reemplaza cualquier selección manual de equipo).
	if (tier) {
		team = tier.team;
	}
	const healthPercent = tier ? tier.healthPercent : 0;
	const damagePercent = tier ? tier.damagePercent : 0;
	const speedPercent = tier ? tier.speedPercent : 0;

	joinQueue.push({ username, team, healthPercent, damagePercent, speedPercent });
	console.log(
		`🧪 [debug] Agregado manualmente a la cola: ${username}${team ? ' (' + team + ')' : ''}${tier ? ' 🎁 ' + tier.name : ''} (cola: ${joinQueue.length})`
	);
	res.json({ ok: true, username, team, tier: tier ? tier.name : null, queueLength: joinQueue.length });
});

// Endpoint de prueba: simula regalos especiales (ej: 6427 o 5659 para lluvias)
app.get('/debug/special-gift', checkAccess, (req, res) => {
	const giftId = Number(req.query.giftId);
	if (!giftId) {
		return res.status(400).json({ error: 'Falta el parámetro giftId, ej: /debug/special-gift?giftId=6427&token=...' });
	}
	const tiktokUsername = req.query.tiktokUsername || 'usuario_debug';
	const giftName = giftId === 6427 ? 'Sombrero y bigote' : (giftId === 5659 ? 'Cisne de papel' : 'Regalo especial');

	giftEventsQueue.push({ giftId, tiktokUsername, giftName });
	console.log(`🧪 [debug] Regalo especial simulado: ID ${giftId} (${giftName}) para @${tiktokUsername}`);
	res.json({ ok: true, giftId, giftName, tiktokUsername });
});

// Mete a los 19 del pool de una sola vez
const POOL_TIER_ROTATION = [5655, 6064, 5487, 105781, 8913, 9947, 14488, 5879, 5660, 5585];
app.get('/debug/add-pool', checkAccess, (req, res) => {
	const added = [];

	FALLBACK_AVATAR_POOL.forEach((username, index) => {
		const tierId = POOL_TIER_ROTATION[index % POOL_TIER_ROTATION.length];
		const tier = GIFT_TIERS[tierId];

		joinQueue.push({
			username,
			team: tier.team,
			healthPercent: tier.healthPercent,
			damagePercent: tier.damagePercent,
			speedPercent: tier.speedPercent,
		});
		added.push({ username, team: tier.team, tier: tier.name });
	});

	console.log(`🧪 [debug] Agregados los ${FALLBACK_AVATAR_POOL.length} peleadores del pool, con niveles y equipos variados`);
	res.json({ ok: true, added, count: added.length });
});

app.get('/boost/pull', checkAccess, (req, res) => {
	const boosts = boostQueue;
	boostQueue = [];
	res.json({ boosts });
});

app.get('/giftspawn/pull', checkAccess, (req, res) => {
	const spawns = giftSpawnQueue;
	giftSpawnQueue = [];
	res.json({ spawns });
});

app.get('/debug/boost', checkAccess, (req, res) => {
	const username = req.query.username;
	if (!username) {
		return res.status(400).json({ error: 'Falta el parámetro username, ej: /debug/boost?username=Builderman&tier=5655&token=...' });
	}
	const tier = GIFT_TIERS[Number(req.query.tier)] || GIFT_TIERS[5655];
	boostQueue.push({
		username,
		team: tier.team,
		healthPercent: tier.healthPercent,
		damagePercent: tier.damagePercent,
		speedPercent: tier.speedPercent,
	});
	console.log(`🧪 [debug] Boost "${tier.name}" simulado para: ${username}`);
	res.json({ ok: true, username, team: tier.team, tier: tier.name });
});

app.get('/debug/giftspawn', checkAccess, (req, res) => {
	const tiktokUsername = req.query.tiktokUsername;
	if (!tiktokUsername) {
		return res.status(400).json({ error: 'Falta el parámetro tiktokUsername, ej: /debug/giftspawn?tiktokUsername=alguien&tier=5655&token=...' });
	}
	const tier = GIFT_TIERS[Number(req.query.tier)] || GIFT_TIERS[5655];
	giftSpawnQueue.push({
		tiktokUsername,
		team: tier.team,
		healthPercent: tier.healthPercent,
		damagePercent: tier.damagePercent,
		speedPercent: tier.speedPercent,
	});
	console.log(`🧪 [debug] Gift-spawn "${tier.name}" simulado para: ${tiktokUsername}`);
	res.json({ ok: true, tiktokUsername, team: tier.team, tier: tier.name });
});

// ===== PANEL DE ADMINISTRACIÓN =====
let adminCommands = [];
const DEFAULT_MESSAGE = '🥊 ESCRIBE TU USERNAME EN EL CHAT Y ENTRA A PELEAR';
let currentMessage = DEFAULT_MESSAGE;

app.get('/admin/reset-queue', checkAccess, (req, res) => {
	joinQueue = [];
	adminCommands.push({ action: 'reset_queue' });
	console.log('🧹 [admin] Reseteo de cola de espera solicitado');
	res.json({ ok: true });
});

app.get('/admin/reset-fighters', checkAccess, (req, res) => {
	adminCommands.push({ action: 'reset_fighters' });
	console.log('🧹 [admin] Reseteo de peleadores activos solicitado');
	res.json({ ok: true });
});

app.get('/admin/set-message', checkAccess, (req, res) => {
	const message = req.query.message;
	if (!message) {
		return res.status(400).json({ error: 'Falta el parámetro message' });
	}
	currentMessage = message;
	adminCommands.push({ action: 'set_message', message });
	console.log(`📝 [admin] Mensaje del HUD actualizado: ${message}`);
	res.json({ ok: true, message });
});

app.get('/admin/current-message', (req, res) => {
	res.json({ message: currentMessage });
});

app.get('/admin/gift-log', checkAccess, (req, res) => {
	const entries = [];
	for (const [giftId, data] of giftLog.entries()) {
		entries.push({
			giftId,
			count: data.count,
			names: Array.from(data.names),
			lastSeen: data.lastSeen,
			knownTier: GIFT_TIERS[giftId] ? GIFT_TIERS[giftId].name : null,
		});
	}
	entries.sort((a, b) => b.count - a.count);
	res.json({ gifts: entries });
});

app.get('/admin/pull-commands', checkAccess, (req, res) => {
	const commands = adminCommands;
	adminCommands = [];
	res.json({ commands });
});

// Panel web completo
app.get('/panel', (req, res) => {
	res.type('html').send(`<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Panel de control — Arena</title>
<style>
	* { box-sizing: border-box; }
	body {
		margin: 0;
		min-height: 100vh;
		background: radial-gradient(circle at top, #1a1a22, #0a0a0e);
		font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
		color: #eee;
		padding: 24px;
	}
	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		flex-wrap: wrap;
		gap: 16px;
		max-width: 1400px;
		margin: 0 auto 24px;
	}
	h1 {
		font-size: 22px;
		margin: 0;
		background: linear-gradient(90deg, #78c8ff, #b482ff, #78c8ff);
		-webkit-background-clip: text;
		background-clip: text;
		color: transparent;
	}
	.token-box {
		display: flex;
		align-items: center;
		gap: 8px;
	}
	.token-box label {
		font-size: 12px;
		color: #999;
		text-transform: uppercase;
		letter-spacing: 0.05em;
	}
	input[type="text"], input[type="password"], select, textarea {
		background: #1a1a22;
		border: 1px solid #333;
		border-radius: 8px;
		padding: 10px 12px;
		color: #fff;
		font-size: 14px;
		font-family: inherit;
	}
	.grid {
		max-width: 1400px;
		margin: 0 auto;
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(340px, 1fr));
		gap: 20px;
	}
	.card {
		background: #111116;
		border: 1px solid #2a2a33;
		border-radius: 16px;
		padding: 22px;
		box-shadow: 0 10px 40px rgba(0,0,0,0.4);
	}
	.card h2 {
		font-size: 14px;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		color: #999;
		margin: 0 0 16px;
	}
	label.field-label {
		display: block;
		font-size: 12px;
		color: #999;
		margin: 12px 0 6px;
		text-transform: uppercase;
		letter-spacing: 0.05em;
	}
	input[type="text"], select, textarea { width: 100%; }
	.teams {
		display: flex;
		gap: 8px;
	}
	.team-btn {
		flex: 1;
		padding: 10px;
		border-radius: 8px;
		border: 1px solid #333;
		background: #1a1a22;
		color: #aaa;
		font-weight: bold;
		cursor: pointer;
		text-align: center;
		font-size: 13px;
		transition: all 0.15s;
	}
	.team-btn.active[data-team="villano"] { background: #7a2fa8; border-color: #a855f7; color: #fff; }
	.team-btn.active[data-team="heroe"] { background: #7a6600; border-color: #ffd700; color: #fff; }
	.team-btn.active[data-team=""] { background: #333; border-color: #555; color: #fff; }
	button.submit {
		width: 100%;
		margin-top: 18px;
		padding: 12px;
		border: none;
		border-radius: 8px;
		background: linear-gradient(90deg, #78c8ff, #b482ff);
		color: #0a0a0e;
		font-weight: bold;
		font-size: 14px;
		cursor: pointer;
	}
	.reset-row {
		display: flex;
		gap: 8px;
	}
	.reset-btn {
		flex: 1;
		padding: 10px;
		border-radius: 8px;
		border: 1px solid #5a2020;
		background: #2a1414;
		color: #ff8888;
		font-size: 12px;
		font-weight: bold;
		cursor: pointer;
	}
	.msg-option {
		display: block;
		width: 100%;
		text-align: left;
		padding: 10px 12px;
		margin-bottom: 6px;
		border-radius: 8px;
		border: 1px solid #333;
		background: #1a1a22;
		color: #ccc;
		font-size: 12px;
		cursor: pointer;
	}
	.msg-option:hover { border-color: #78c8ff; }
	textarea { resize: vertical; min-height: 50px; }
	.current-msg {
		font-size: 11px;
		color: #666;
		margin-top: 6px;
		font-style: italic;
	}
	.status {
		max-width: 1400px;
		margin: 20px auto 0;
		font-size: 13px;
		text-align: center;
		color: #888;
		min-height: 18px;
	}
</style>
</head>
<body>
	<header>
		<h1>⚔️ PANEL DE CONTROL — ARENA</h1>
		<div class="token-box">
			<label>Token</label>
			<input type="password" id="token" placeholder="Tu ACCESS_TOKEN" style="width: 220px;" />
		</div>
	</header>

	<div class="grid">
		<div class="card">
			<h2>Agregar peleador</h2>
			<label class="field-label">Username de Roblox</label>
			<input type="text" id="username" placeholder="ej: Builderman" />

			<label class="field-label">Equipo</label>
			<div class="teams">
				<div class="team-btn active" data-team="">Neutral</div>
				<div class="team-btn" data-team="villano">👹 Villano</div>
				<div class="team-btn" data-team="heroe">🦸 Héroe</div>
			</div>

			<label class="field-label">Regalo / nivel de boost</label>
			<select id="tierSelect">
				<option value="">Sin boost</option>
				<option value="5655">🌹 Rosa — Héroe Experimentado (+50% vida, +10% daño)</option>
				<option value="5487">💗 Corazón Coreano — Héroe Profesional (+75% vida, +25% daño)</option>
				<option value="8913">🌹 Rosa Elite — Héroe Elite (+100% vida, +35% daño)</option>
				<option value="14488">🦫 Capibara — Héroe Legendario (+125% vida, +45% daño, +25% velocidad)</option>
				<option value="5660">💞 Corazón con las manos — Héroe Definitivo (+150% vida, +55% daño, +50% velocidad)</option>
				<option value="6064">😂 GG — Villano Experimentado (+50% vida, +10% daño)</option>
				<option value="105781">⚽ Balón Giratorio — Villano Profesional (+75% vida, +25% daño)</option>
				<option value="9947">🎗️ Collar de Amistad — Villano Elite (+100% vida, +35% daño)</option>
				<option value="5879">🍩 Rosquilla — Villano Legendario (+125% vida, +45% daño, +25% velocidad)</option>
				<option value="5585">🎉 Confeti con las manos — Villano Definitivo (+150% vida, +55% daño, +50% velocidad)</option>
			</select>

			<button class="submit" id="addBtn">Agregar a la cola</button>
		</div>

		<div class="card">
			<h2>⚡ Lluvia de Guantes (Regalo Especial)</h2>
			<label class="field-label">Selecciona Regalo Especial</label>
			<select id="specialGiftSelect">
				<option value="6427">🎩 Sombrero y bigote (ID 6427) → Lluvia de Guantes Oscuros</option>
				<option value="5659">🦢 Cisne de papel (ID 5659) → Lluvia de Guantes Dorados</option>
			</select>
			<button class="submit" id="specialGiftBtn" style="background: linear-gradient(90deg, #ff82b4, #b482ff); color: #fff;">Disparar Lluvia de Guantes</button>
		</div>

		<div class="card">
			<h2>Probar aparición sin username (regalo)</h2>
			<label class="field-label">Username de TikTok (simulado)</label>
			<input type="text" id="tiktokUsername" placeholder="ej: usuario_de_tiktok" />

			<label class="field-label">Regalo / nivel de boost</label>
			<select id="giftSpawnTierSelect">
				<option value="5655">🌹 Rosa — Héroe Experimentado</option>
				<option value="5487">💗 Corazón Coreano — Héroe Profesional</option>
				<option value="8913">🌹 Rosa Elite — Héroe Elite</option>
				<option value="14488">🦫 Capibara — Héroe Legendario</option>
				<option value="5660">💞 Corazón con las manos — Héroe Definitivo</option>
				<option value="6064">😂 GG — Villano Experimentado</option>
				<option value="105781">⚽ Balón Giratorio — Villano Profesional</option>
				<option value="9947">🎗️ Collar de Amistad — Villano Elite</option>
				<option value="5879">🍩 Rosquilla — Villano Legendario</option>
				<option value="5585">🎉 Confeti con las manos — Villano Definitivo</option>
			</select>

			<button class="submit" id="giftSpawnBtn">Simular regalo sin username</button>
		</div>

		<div class="card">
			<h2>Aplicar boost a alguien en partida</h2>
			<label class="field-label">Username (de Roblox, o de TikTok si entró sin username)</label>
			<input type="text" id="boostUsername" placeholder="ej: Builderman" />

			<label class="field-label">Regalo / nivel de boost</label>
			<select id="boostTierSelect">
				<option value="5655">🌹 Rosa — Héroe Experimentado</option>
				<option value="5487">💗 Corazón Coreano — Héroe Profesional</option>
				<option value="8913">🌹 Rosa Elite — Héroe Elite</option>
				<option value="14488">🦫 Capibara — Héroe Legendario</option>
				<option value="5660">💞 Corazón con las manos — Héroe Definitivo</option>
				<option value="6064">😂 GG — Villano Experimentado</option>
				<option value="105781">⚽ Balón Giratorio — Villano Profesional</option>
				<option value="9947">🎗️ Collar de Amistad — Villano Elite</option>
				<option value="5879">🍩 Rosquilla — Villano Legendario</option>
				<option value="5585">🎉 Confeti con las manos — Villano Definitivo</option>
			</select>

			<button class="submit" id="applyBoostBtn">Aplicar boost ahora</button>
		</div>

		<div class="card">
			<h2>Prueba rápida: los 19 del pool</h2>
			<p style="font-size:12px;color:#999;margin:0 0 12px;">
				Agrega a los 19 peleadores de respaldo de una sola vez, repartidos entre los 5 niveles de boost
				y alternando villano/héroe. Los primeros 8 entran directo a pelear, los otros 11 quedan en la cola.
			</p>
			<button class="submit" id="addPoolBtn">Agregar los 19 del pool</button>
		</div>

		<div class="card" style="grid-column: 1 / -1;">
			<h2>Regalos vistos (todos, no solo los 5 conocidos)</h2>
			<p style="font-size:12px;color:#999;margin:0 0 12px;">
				Se va llenando solo, cada vez que llega un regalo real durante el live (tenga o no uno
				de nuestros 5 IDs configurados). Dale a "Refrescar" para ver los últimos.
			</p>
			<button class="submit" id="refreshGiftLogBtn" style="margin-top:0;">Refrescar</button>
			<div id="giftLogTable" style="margin-top:14px; font-size:13px;"></div>
		</div>

		<div class="card">
			<h2>Reseteos</h2>
			<div class="reset-row">
				<button class="reset-btn" id="resetQueueBtn">Resetear cola</button>
				<button class="reset-btn" id="resetFightersBtn">Resetear peleadores</button>
			</div>
		</div>

		<div class="card">
			<h2>Mensaje en pantalla</h2>
			<div id="msgOptions"></div>
			<textarea id="customMsg" placeholder="O escribe un mensaje personalizado..."></textarea>
			<button class="submit" id="applyMsgBtn">Aplicar mensaje</button>
			<div class="current-msg" id="currentMsg"></div>
		</div>
	</div>

	<div class="status" id="status"></div>

<script>
	const tokenInput = document.getElementById('token');
	const params = new URLSearchParams(location.search);
	tokenInput.value = params.get('token') || localStorage.getItem('arenaToken') || '';
	tokenInput.addEventListener('input', () => {
		localStorage.setItem('arenaToken', tokenInput.value.trim());
	});

	let selectedTeam = '';
	document.querySelectorAll('.team-btn').forEach(btn => {
		btn.addEventListener('click', () => {
			document.querySelectorAll('.team-btn').forEach(b => b.classList.remove('active'));
			btn.classList.add('active');
			selectedTeam = btn.dataset.team;
		});
	});

	function setStatus(text, ok) {
		const el = document.getElementById('status');
		el.textContent = text;
		el.style.color = ok ? '#7fffab' : '#ff8888';
	}

	async function call(path) {
		const token = tokenInput.value.trim();
		if (!token) {
			setStatus('Falta el token de acceso', false);
			return null;
		}
		const url = path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(token);
		try {
			const res = await fetch(url);
			const data = await res.json();
			if (!res.ok) {
				setStatus(data.error || 'Error', false);
				return null;
			}
			return data;
		} catch (err) {
			setStatus('No se pudo conectar con el bridge', false);
			return null;
		}
	}

	document.getElementById('addBtn').addEventListener('click', async () => {
		const username = document.getElementById('username').value.trim();
		if (!username) {
			setStatus('Escribe un username primero', false);
			return;
		}
		const teamParam = selectedTeam ? '&team=' + selectedTeam : '';
		const tier = document.getElementById('tierSelect').value;
		const tierParam = tier ? '&tier=' + tier : '';
		const data = await call('/debug/add?username=' + encodeURIComponent(username) + teamParam + tierParam);
		if (data) {
			setStatus(
				'✅ ' + username + ' agregado' +
					(data.team ? ' (' + data.team + ')' : '') +
					(data.tier ? ' 🎁 ' + data.tier : ''),
				true
			);
			document.getElementById('username').value = '';
		}
	});

	document.getElementById('specialGiftBtn').addEventListener('click', async () => {
		const giftId = document.getElementById('specialGiftSelect').value;
		const data = await call('/debug/special-gift?giftId=' + giftId);
		if (data) {
			setStatus('✅ Lluvia de guantes (ID ' + data.giftId + ') enviada a la cola de Roblox', true);
		}
	});

	document.getElementById('giftSpawnBtn').addEventListener('click', async () => {
		const tiktokUsername = document.getElementById('tiktokUsername').value.trim();
		if (!tiktokUsername) {
			setStatus('Escribe un username de TikTok primero', false);
			return;
		}
		const tier = document.getElementById('giftSpawnTierSelect').value;
		const data = await call('/debug/giftspawn?tiktokUsername=' + encodeURIComponent(tiktokUsername) + '&tier=' + tier);
		if (data) {
			setStatus('✅ Gift-spawn simulado para ' + tiktokUsername + ' (' + data.tier + ')', true);
			document.getElementById('tiktokUsername').value = '';
		}
	});

	document.getElementById('applyBoostBtn').addEventListener('click', async () => {
		const username = document.getElementById('boostUsername').value.trim();
		if (!username) {
			setStatus('Escribe un username primero', false);
			return;
		}
		const tier = document.getElementById('boostTierSelect').value;
		const data = await call('/debug/boost?username=' + encodeURIComponent(username) + '&tier=' + tier);
		if (data) {
			setStatus('✅ Boost "' + data.tier + '" aplicado a ' + username, true);
			document.getElementById('boostUsername').value = '';
		}
	});

	document.getElementById('addPoolBtn').addEventListener('click', async () => {
		const data = await call('/debug/add-pool');
		if (data) {
			setStatus('✅ Se agregaron ' + data.count + ' peleadores del pool (niveles y equipos variados)', true);
		}
	});

	document.getElementById('refreshGiftLogBtn').addEventListener('click', async () => {
		const data = await call('/admin/gift-log');
		const container = document.getElementById('giftLogTable');
		if (!data) {
			return;
		}
		if (data.gifts.length === 0) {
			container.innerHTML = '<p style="color:#888;">Todavía no llegó ningún regalo.</p>';
			setStatus('✅ Actualizado (0 regalos vistos por ahora)', true);
			return;
		}
		let html = '<table style="width:100%; border-collapse: collapse;">';
		html += '<tr style="color:#999; text-align:left; font-size:11px; text-transform:uppercase;">' +
			'<th style="padding:6px;">ID</th><th style="padding:6px;">Nombre(s) vistos</th>' +
			'<th style="padding:6px;">Veces</th><th style="padding:6px;">Última vez</th><th style="padding:6px;">¿Ya configurado?</th></tr>';
		data.gifts.forEach(g => {
			const lastSeen = g.lastSeen ? new Date(g.lastSeen).toLocaleTimeString() : '—';
			const known = g.knownTier
				? '<span style="color:#7fffab;">✅ ' + g.knownTier + '</span>'
				: '<span style="color:#ff8888;">❌ sin configurar</span>';
			html += '<tr style="border-top:1px solid #2a2a33;">' +
				'<td style="padding:6px;">' + g.giftId + '</td>' +
				'<td style="padding:6px;">' + (g.names.join(', ') || '—') + '</td>' +
				'<td style="padding:6px;">' + g.count + '</td>' +
				'<td style="padding:6px;">' + lastSeen + '</td>' +
				'<td style="padding:6px;">' + known + '</td>' +
				'</tr>';
		});
		html += '</table>';
		container.innerHTML = html;
		setStatus('✅ Actualizado (' + data.gifts.length + ' regalos distintos vistos)', true);
	});

	document.getElementById('resetQueueBtn').addEventListener('click', async () => {
		const data = await call('/admin/reset-queue');
		if (data) setStatus('✅ Cola de espera reseteada', true);
	});

	document.getElementById('resetFightersBtn').addEventListener('click', async () => {
		const data = await call('/admin/reset-fighters');
		if (data) setStatus('✅ Peleadores reseteados', true);
	});

	const MESSAGE_PRESETS = [
		'🥊 ESCRIBE TU USERNAME EN EL CHAT Y ENTRA A PELEAR',
		'✍️ ESCRIBE TU NOMBRE PARA AGREGARTE AL JUEGO',
		'⚔️ ESCRIBE TU NOMBRE Y TU ROL: VILLANO O HEROE',
		'🌟 ESCRIBE VILLANO O HEROE + TU USERNAME PARA ELEGIR BANDO',
		'👀 MIRA LA LISTA DE ESPERA Y ÚNETE ANTES DE QUE SE LLENE',
		'🔥 TU PERSONAJE DE ROBLOX PELEARÁ POR TI, ¡ESCRIBE TU NOMBRE!',
		"🎭  ESCRIBE SOLO 'HEROE' O 'VILLANO' Y Y UNETE A LA LUCHA",
	];

	const msgOptionsEl = document.getElementById('msgOptions');
	MESSAGE_PRESETS.forEach(msg => {
		const btn = document.createElement('button');
		btn.className = 'msg-option';
		btn.type = 'button';
		btn.textContent = msg;
		btn.addEventListener('click', async () => {
			const data = await call('/admin/set-message?message=' + encodeURIComponent(msg));
			if (data) {
				setStatus('✅ Mensaje actualizado', true);
				document.getElementById('currentMsg').textContent = 'Actual: ' + msg;
			}
		});
		msgOptionsEl.appendChild(btn);
	});

	document.getElementById('applyMsgBtn').addEventListener('click', async () => {
		const custom = document.getElementById('customMsg').value.trim();
		if (!custom) {
			setStatus('Escribe un mensaje personalizado primero', false);
			return;
		}
		const data = await call('/admin/set-message?message=' + encodeURIComponent(custom));
		if (data) {
			setStatus('✅ Mensaje actualizado', true);
			document.getElementById('currentMsg').textContent = 'Actual: ' + custom;
			document.getElementById('customMsg').value = '';
		}
	});

	(async () => {
		try {
			const res = await fetch('/admin/current-message');
			const data = await res.json();
			if (data.message) {
				document.getElementById('currentMsg').textContent = 'Actual: ' + data.message;
			}
		} catch (err) {
			// silencioso: no es crítico si esto falla al cargar
		}
	})();
</script>
</body>
</html>`);
});

app.get('/status', (req, res) => {
	res.json({
		connectedToTikfinity: Boolean(socket && socket.readyState === WebSocket.OPEN),
		pendingInQueue: joinQueue.length,
	});
});

app.listen(PORT, () => {
	console.log(`🚀 Bridge escuchando en el puerto ${PORT}`);
});