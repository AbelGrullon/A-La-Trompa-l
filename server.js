const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const crypto = require('crypto');

// ===== TOKEN (se pide una sola vez y se guarda en .env) =====
// Si .env no tiene un ACCESS_TOKEN válido se abre una ventana para escribirlo
// (o generarlo). Después el juego lo recibe solo por /handshake y el panel web
// lo trae puesto: no hay que copiarlo en ningún archivo.
// Para cambiarlo: npm run token (o CAMBIAR_TOKEN.bat).
const ENV_FILE = path.join(__dirname, '.env');
const TOKEN_RE = /^[A-Za-z0-9_-]{6,64}$/;

function readSavedToken() {
	try {
		const match = fs.readFileSync(ENV_FILE, 'utf8').match(/^ACCESS_TOKEN=(.*)$/m);
		const token = match ? match[1].trim() : '';
		return TOKEN_RE.test(token) && token !== 'cambia-esto-por-algo-secreto' ? token : '';
	} catch (err) {
		return '';
	}
}

function saveToken(token) {
	let text = '';
	try {
		text = fs.readFileSync(ENV_FILE, 'utf8');
	} catch (err) {
		try {
			text = fs.readFileSync(path.join(__dirname, '.env.example'), 'utf8');
		} catch (err2) {}
	}
	text = /^ACCESS_TOKEN=/m.test(text)
		? text.replace(/^ACCESS_TOKEN=.*$/m, 'ACCESS_TOKEN=' + token)
		: text.replace(/\s*$/, '\n') + 'ACCESS_TOKEN=' + token + '\n';
	fs.writeFileSync(ENV_FILE, text);
}

function ensureToken(forceAsk) {
	if (!forceAsk && (process.env.ACCESS_TOKEN || readSavedToken())) return; // (la variable de entorno gana: sirve para pruebas)
	if (process.platform === 'win32') {
		const result = spawnSync(
			'powershell',
			['-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', path.join(__dirname, 'pedir_token.ps1')],
			{ stdio: 'inherit' }
		);
		if (result.status === 0 && readSavedToken()) return;
		if (result.status === 1) {
			console.log('Cancelado: el bridge no se ha iniciado.');
			process.exit(1);
		}
	}
	// Sin ventana (otro sistema o PowerShell no disponible): se genera uno y se guarda
	const token = crypto.randomBytes(18).toString('base64url');
	saveToken(token);
	console.log('🔑 Token generado y guardado en .env (el juego lo recibe solo).');
}

ensureToken(process.argv.includes('--token'));
if (process.argv.includes('--token') && !process.argv.includes('--start')) {
	process.exit(0); // npm run token: solo cambia el token y sale
}

require('dotenv').config();
const express = require('express');
const WebSocket = require('ws');

// ===== CONFIGURACIÓN =====
const PORT = Number(process.env.PORT || 3000);
const ACCESS_TOKEN = (process.env.ACCESS_TOKEN || '').trim(); // clave para que solo tu juego y tu panel usen el bridge
const TIKFINITY_URL = process.env.TIKFINITY_URL || 'ws://127.0.0.1:21213/';
const SETTINGS_FILE = path.join(__dirname, 'settings.json');

const app = express();
app.use(express.json({ limit: '100kb' }));

// Red de seguridad: un error aislado no debe tumbar todo el bridge.
process.on('uncaughtException', (err) => {
	console.error('⚠️ Error no capturado (el servidor sigue corriendo):', err);
});
process.on('unhandledRejection', (reason) => {
	console.error('⚠️ Promesa rechazada sin manejar (el servidor sigue corriendo):', reason);
});

// (qué regalo va con cada peleador se edita en el panel: ver "REGALOS DE CADA PELEADOR")

// ===== COLA DE EVENTOS PARA ROBLOX =====
// Todo lo que pasa en el live se convierte en un evento simple y se guarda
// aquí hasta que Roblox lo pide con GET /events/pull (una vez por segundo).
let events = [];
const MAX_EVENTS = 3000;
let pendingLikes = new Map(); // user -> evento "like" aún no entregado (se van sumando)
let pendingViewers = null;
let lastPullAt = 0;

function pushEvent(event) {
	events.push(event);
	if (events.length > MAX_EVENTS) {
		events.splice(0, events.length - MAX_EVENTS);
	}
}

// ===== IDENTIDAD DEL ESPECTADOR =====
// Tikfinity manda los datos del usuario a veces en data y a veces en data.user.
function userOf(data) {
	const source = data?.user && typeof data.user === 'object' ? { ...data, ...data.user } : data || {};
	const user = String(source.uniqueId || source.userId || source.nickname || '').trim();
	const name = String(source.nickname || source.uniqueId || '').trim();
	return { user, name: name || user };
}

// El juego funciona SOLO con regalos, likes y follows: el chat y los
// compartidos de Tikfinity se ignoran a propósito.

// ===== REGALOS =====
// Los regalos "combo" (giftType 1, como la rosa) llegan varias veces mientras
// dura la racha con repeatCount 1, 2, 3... y una última vez con repeatEnd.
// Solo mandamos la diferencia, así cada rosa cuenta una sola vez.
const giftStreaks = new Map(); // `${user}:${giftId}` -> { count, at }
const giftLog = new Map(); // giftId -> { count, names: Set, lastSeen }

function logGift(giftId, giftName) {
	if (!giftLog.has(giftId)) {
		giftLog.set(giftId, { count: 0, names: new Set(), lastSeen: null });
	}
	const entry = giftLog.get(giftId);
	entry.count += 1;
	entry.lastSeen = new Date().toISOString();
	if (giftName) entry.names.add(giftName);
}

function handleGift(data) {
	const giftId = Number(data?.giftId);
	if (!giftId) return;
	const { user, name } = userOf(data);
	const giftName = data?.giftName || data?.gift?.name || data?.extendedGiftInfo?.name || data?.describe || null;
	const repeatCount = Math.max(1, Number(data?.repeatCount) || 1);
	const repeatEnd = Boolean(data?.repeatEnd);
	const giftType = data?.giftType === undefined ? undefined : Number(data.giftType);
	const diamonds = Number(data?.diamondCount) || 1;
	logGift(giftId, giftName);
	battles.noteGift(data); // (así se sabe cuál de los dos streamers de una batalla eres tú)

	let count;
	if (giftType !== undefined && giftType !== 1) {
		count = repeatCount;
	} else {
		const key = `${user}:${giftId}`;
		const now = Date.now();
		const previous = giftStreaks.get(key);
		// si no sabemos el tipo, una racha "vieja" de hace más de 4 s ya no cuenta
		const last = previous && (giftType === 1 || now - previous.at < 4000) ? previous.count : 0;
		count = repeatCount >= last ? repeatCount - last : repeatCount;
		if (repeatEnd) giftStreaks.delete(key);
		else giftStreaks.set(key, { count: repeatCount, at: now });
	}
	if (count <= 0 || !user) return;
	pushEvent({ type: 'gift', user, name, giftId, giftName, count, diamonds });
	const role = giftRoleLabel(giftId);
	console.log(`🎁 ${name} envió ${giftName || giftId} x${count}${role ? ' (' + role + ')' : ''}`);
}

// ===== LIKES, SEGUIDORES, ESPECTADORES =====
function handleLike(data) {
	const { user, name } = userOf(data);
	const count = Math.max(1, Number(data?.likeCount) || 1);
	const pending = user && pendingLikes.get(user);
	if (pending) {
		pending.count += count; // se agrupan los likes de la misma persona
		return;
	}
	const event = { type: 'like', user, name, count };
	pushEvent(event);
	if (user) pendingLikes.set(user, event);
}

const followed = new Set();

function handleFollow(data) {
	const { user, name } = userOf(data);
	if (!user || followed.has(user)) return; // seguir/dejar de seguir no se puede spamear
	followed.add(user);
	pushEvent({ type: 'follow', user, name });
	console.log(`💖 ${name} empezó a seguir`);
}

function handleViewers(data) {
	const count = Number(data?.viewerCount);
	if (!Number.isFinite(count)) return;
	if (pendingViewers) {
		pendingViewers.count = count;
		return;
	}
	pendingViewers = { type: 'viewers', count };
	pushEvent(pendingViewers);
}

// ===== CAPTURA DE BATALLAS (para preparar el modo batalla) =====
// Guarda tal cual en batallas_capturadas.jsonl todo lo que Tikfinity mande de
// las batallas de TikTok (linkMicBattle, linkMicArmies...), y anota una vez
// cada tipo de evento nuevo que llegue, para saber qué datos hay disponibles.
const BATTLE_CAPTURE_FILE = path.join(__dirname, 'batallas_capturadas.jsonl');
const BATTLE_CAPTURE_MAX = 5 * 1024 * 1024;
const seenEvents = new Set();

function noteOtherEvent(name, raw) {
	name = String(name || '?');
	const isBattle = /linkmic|battle|armies|pk/i.test(name);
	if (!seenEvents.has(name)) {
		seenEvents.add(name);
		console.log(isBattle ? `⚔️ Evento de batalla recibido: ${name} (se guarda en batallas_capturadas.jsonl)` : `ℹ️ Tikfinity envía también: ${name}`);
	}
	if (!isBattle) return;
	try {
		const size = fs.existsSync(BATTLE_CAPTURE_FILE) ? fs.statSync(BATTLE_CAPTURE_FILE).size : 0;
		if (size < BATTLE_CAPTURE_MAX) {
			fs.appendFileSync(BATTLE_CAPTURE_FILE, JSON.stringify({ at: new Date().toISOString(), raw: raw.toString() }) + '\n');
		}
	} catch (err) {}
}

// ===== MODO BATALLA (batallas de TikTok entre streamers, ver batalla.js) =====
const { createBattles } = require('./batalla');
const battles = createBattles({ pushEvent, getSettings: () => savedSettings });
const BATTLE_EVENTS = new Set(['linkMicBattle', 'linkMicArmies', 'linkMicBattlePunishFinish']);

// ===== CONEXIÓN A TIKFINITY (local) =====
let socket = null;
let reconnectTimer = null;
let tikfinityConnected = false;
let warnedOffline = false;

function connectToTikfinity() {
	socket = new WebSocket(TIKFINITY_URL);

	socket.on('open', () => {
		tikfinityConnected = true;
		warnedOffline = false;
		console.log(`✅ Conectado a Tikfinity en ${TIKFINITY_URL}`);
	});

	socket.on('message', (raw) => {
		let message;
		try {
			message = JSON.parse(raw.toString());
		} catch (err) {
			return;
		}
		const data = message.data || {};
		switch (message.event) {
			case 'gift':
				handleGift(data);
				break;
			case 'like':
				handleLike(data);
				break;
			case 'follow':
				handleFollow(data);
				break;
			case 'social': {
				const kind = String(data.displayType || data.label || '').toLowerCase();
				if (kind.includes('follow')) handleFollow(data);
				break;
			}
			case 'roomUser':
				handleViewers(data);
				break;
			case 'liveStatusChange':
				console.log(data.isLive ? '🔴 El live empezó' : '⚫ El live terminó');
				break;
			default:
				noteOtherEvent(message.event, raw);
				if (BATTLE_EVENTS.has(message.event)) {
					try {
						battles.handle(message.event, data);
					} catch (err) {
						console.error('⚠️ Error leyendo la batalla:', err.message);
					}
				}
				break;
		}
	});

	socket.on('close', () => {
		if (tikfinityConnected) {
			console.warn('⚠️ Se perdió la conexión con Tikfinity. Reintentando cada 5 segundos...');
		}
		tikfinityConnected = false;
		scheduleReconnect();
	});

	socket.on('error', (err) => {
		if (!warnedOffline) {
			warnedOffline = true;
			console.error(`❌ No se pudo conectar a Tikfinity (${err.message || err}). ¿Está abierto Tikfinity Desktop? Sigo intentando...`);
		}
	});
}

function scheduleReconnect() {
	if (reconnectTimer) return;
	reconnectTimer = setTimeout(() => {
		reconnectTimer = null;
		connectToTikfinity();
	}, 5000);
}

connectToTikfinity();

// ===== SEGURIDAD BÁSICA =====
function checkAccess(req, res, next) {
	if (!ACCESS_TOKEN) return next();
	const provided = String(req.query.token || req.get('x-access-token') || '').trim();
	if (provided !== ACCESS_TOKEN) {
		return res.status(401).json({ error: 'Token inválido o faltante' });
	}
	next();
}

// ===== AJUSTES DEL JUEGO (los guarda el panel dev de Roblox) =====
function loadSettings() {
	try {
		return JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'));
	} catch (err) {
		return {};
	}
}

// Ajustes de texto largos (JSON): el resto se corta a 200 caracteres.
// Deben coincidir con Shared.STRING_MAX en el juego.
const LONG_SETTINGS = { HudCustom: 4000, GiftRoles: 8000 };

function cleanSettings(input) {
	const clean = {};
	if (!input || typeof input !== 'object') return clean;
	for (const [key, value] of Object.entries(input).slice(0, 200)) {
		if (!/^[A-Za-z0-9_]{1,40}$/.test(key)) continue;
		if (typeof value === 'number' && Number.isFinite(value)) clean[key] = value;
		else if (typeof value === 'boolean') clean[key] = value;
		else if (typeof value === 'string') clean[key] = value.slice(0, LONG_SETTINGS[key] || 200);
	}
	return clean;
}

let savedSettings = loadSettings();

function saveSettingsFile() {
	fs.writeFile(SETTINGS_FILE, JSON.stringify(savedSettings, null, 2), (err) => {
		if (err) console.error('⚠️ No se pudieron guardar los ajustes:', err.message);
	});
}

// ===== REGALOS DE CADA PELEADOR =====
// Catálogo (regalos/catalogo.json): los regalos de TikTok que ya tienen imagen
// subida a Roblox (los mismos que usa "A Correr"). En el panel se elige qué
// regalos van en cada puesto; eso se guarda en el ajuste GiftRoles (JSON) y el
// juego lo aplica al instante (Shared.applyGiftRoles).
const CATALOG_FILE = path.join(__dirname, 'regalos', 'catalogo.json');
let giftCatalog = [];
try {
	giftCatalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf8'));
} catch (err) {
	console.warn('⚠️ No se pudo leer regalos/catalogo.json:', err.message);
}
const catalogById = new Map(giftCatalog.map((g) => [g.id, g]));

// Puestos: 5 niveles por equipo + una lluvia por equipo (mismo orden que Shared.ROLES)
const GIFT_ROLES = [
	{ id: 'hero1', label: 'Héroe Experimentado' }, { id: 'hero2', label: 'Héroe Profesional' },
	{ id: 'hero3', label: 'Héroe Élite' }, { id: 'hero4', label: 'Héroe Legendario' },
	{ id: 'hero5', label: 'Héroe Definitivo' }, { id: 'rainGold', label: 'Lluvia dorada (daña villanos)' },
	{ id: 'villain1', label: 'Villano Experimentado' }, { id: 'villain2', label: 'Villano Profesional' },
	{ id: 'villain3', label: 'Villano Élite' }, { id: 'villain4', label: 'Villano Legendario' },
	{ id: 'villain5', label: 'Villano Definitivo' }, { id: 'rainDark', label: 'Lluvia oscura (daña héroes)' },
];
// Igual que Shared.DEFAULT_GIFT_ROLES en el juego
const DEFAULT_GIFT_ROLES = {
	hero1: [5655], hero2: [5487], hero3: [8913], hero4: [14488], hero5: [5660], rainGold: [5659],
	villain1: [6064], villain2: [105781], villain3: [9947], villain4: [5879], villain5: [5585], rainDark: [6427],
};

// Puestos actuales como { rol: [ids] }
function currentGiftRoles() {
	try {
		const parsed = JSON.parse(savedSettings.GiftRoles || '');
		const roles = {};
		for (const role of GIFT_ROLES) {
			roles[role.id] = (parsed[role.id] || []).map((g) => Number(g.id)).filter(Boolean);
		}
		return roles;
	} catch (err) {
		return JSON.parse(JSON.stringify(DEFAULT_GIFT_ROLES));
	}
}

function giftRoleLabel(giftId) {
	const roles = currentGiftRoles();
	const role = GIFT_ROLES.find((r) => (roles[r.id] || []).includes(Number(giftId)));
	return role ? role.label : null;
}

// ===== API QUE USA ROBLOX =====

app.get('/events/pull', checkAccess, (req, res) => {
	const batch = events;
	events = [];
	pendingLikes = new Map();
	pendingViewers = null;
	lastPullAt = Date.now();
	res.json({ events: batch, tikfinity: tikfinityConnected });
});

app.get('/settings', checkAccess, (req, res) => {
	res.json({ settings: savedSettings });
});

app.post('/settings', checkAccess, (req, res) => {
	savedSettings = cleanSettings(req.body && req.body.settings);
	saveSettingsFile();
	res.json({ ok: true });
});

// Catálogo + puestos actuales (para el editor de regalos del panel)
app.get('/gifts/roles', checkAccess, (req, res) => {
	res.json({ catalog: giftCatalog, roles: currentGiftRoles(), roleList: GIFT_ROLES, defaults: DEFAULT_GIFT_ROLES });
});

// Guarda los puestos { rol: [ids] }. Un regalo solo puede estar en un puesto.
app.post('/gifts/roles', checkAccess, (req, res) => {
	const input = (req.body && req.body.roles) || {};
	const used = new Set();
	const out = {};
	for (const role of GIFT_ROLES) {
		out[role.id] = [];
		for (const raw of Array.isArray(input[role.id]) ? input[role.id] : []) {
			const gift = catalogById.get(Number(raw));
			if (!gift || used.has(gift.id) || out[role.id].length >= 6) continue;
			used.add(gift.id);
			out[role.id].push({ id: gift.id, name: gift.name, image: gift.image });
		}
	}
	const value = JSON.stringify(out);
	savedSettings.GiftRoles = value;
	saveSettingsFile();
	// el juego lo aplica en cuanto pida eventos (si no está abierto, lo leerá de settings.json al empezar)
	pushEvent({ type: 'admin', action: 'setSetting', key: 'GiftRoles', value });
	console.log('🎁 [panel] regalos de los peleadores actualizados');
	res.json({ ok: true, roles: currentGiftRoles() });
});

// ===== API DEL PANEL WEB =====

// Órdenes para el juego (las mismas que el panel dev de Roblox):
// simJoin, simBots, simGift, simLikes, simFollow, testEntrance, rain, fury, hearts,
// healAll, chargeAll, koRandom, resetFighters, resetQueue, resetScore,
// resetAll, setSetting, resetSettings, announce
const ADMIN_ACTIONS = new Set([
	'simJoin', 'simBots', 'simGift', 'simLikes', 'simFollow', 'testEntrance', 'rain', 'fury', 'hearts',
	'healAll', 'chargeAll', 'koRandom', 'resetFighters', 'resetQueue', 'resetScore', 'resetAll',
	'setSetting', 'resetSettings', 'announce',
	'simBattleStart', 'simBattlePoints', 'simBattleGift', 'simBattleEnd', 'endBattle',
]);

app.post('/admin', checkAccess, (req, res) => {
	const body = req.body || {};
	if (!ADMIN_ACTIONS.has(body.action)) {
		return res.status(400).json({ error: 'Acción desconocida' });
	}
	const event = { type: 'admin', action: body.action };
	for (const [key, value] of Object.entries(body)) {
		if (key === 'action' || key === 'type') continue;
		if (['string', 'number', 'boolean'].includes(typeof value)) {
			event[key] = typeof value === 'string' ? value.slice(0, 200) : value;
		}
	}
	pushEvent(event);
	console.log(`🛠️ [panel] ${body.action}`);
	res.json({ ok: true });
});

// ----- Modo batalla -----
// Estado de la batalla actual (para el panel)
app.get('/battle/status', checkAccess, (req, res) => {
	res.json(battles.status());
});

// Pruebas sin live: { action: 'start' | 'points' | 'end', side: 'me' | 'rival', amount }
// (pasan por el mismo lector que las batallas reales de Tikfinity)
app.post('/battle/sim', checkAccess, (req, res) => {
	const body = req.body || {};
	const ok = battles.simulate(String(body.action || ''), body);
	if (!ok) return res.status(400).json({ error: 'No hay una batalla de prueba en curso (pulsa "Empezar batalla de prueba")' });
	res.json({ ok: true, battle: battles.status() });
});

// Terminar la batalla ya (por si TikTok no avisó): { winner: 'me' | 'rival' | 'tie' } o sin winner = por puntos
app.post('/battle/end', checkAccess, (req, res) => {
	const ok = battles.forceEnd(req.body && req.body.winner);
	if (!ok) return res.status(400).json({ error: 'No hay ninguna batalla en curso' });
	res.json({ ok: true, battle: battles.status() });
});

app.get('/admin/gift-log', checkAccess, (req, res) => {
	const gifts = [];
	for (const [giftId, data] of giftLog.entries()) {
		gifts.push({
			giftId,
			count: data.count,
			names: Array.from(data.names),
			lastSeen: data.lastSeen,
			knownTier: giftRoleLabel(giftId),
		});
	}
	gifts.sort((a, b) => b.count - a.count);
	res.json({ gifts });
});

app.get('/status', (req, res) => {
	res.json({
		connectedToTikfinity: tikfinityConnected,
		robloxConnected: Date.now() - lastPullAt < 5000,
		pendingEvents: events.length,
		tokenRequired: Boolean(ACCESS_TOKEN),
	});
});

// Imágenes de los regalos para el panel
app.use('/regalos/img', express.static(path.join(__dirname, 'regalos', 'img')));

// Solo este PC puede pedir el token (handshake) o recibirlo puesto en el panel
function isLocal(req) {
	const address = String(req.socket.remoteAddress || '');
	return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

// El juego (Studio) pide aquí el token al darle a Play: no hay que escribirlo en sus archivos
app.get('/handshake', (req, res) => {
	if (!isLocal(req)) return res.status(403).json({ error: 'Solo desde este PC' });
	res.json({ token: ACCESS_TOKEN });
});

app.get('/panel', (req, res) => {
	let html = fs.readFileSync(path.join(__dirname, 'panel.html'), 'utf8');
	if (ACCESS_TOKEN && isLocal(req)) {
		html = html.replace('"__TOKEN__"', () => JSON.stringify(ACCESS_TOKEN));
	}
	res.set('Cache-Control', 'no-store').type('html').send(html);
});

app.get('/', (req, res) => res.redirect('/panel'));

app.listen(PORT, () => {
	console.log(`🚀 Bridge escuchando en http://localhost:${PORT}  •  panel: http://localhost:${PORT}/panel`);
	console.log(`🔑 Token cargado (${ACCESS_TOKEN.length} caracteres) — el juego lo recibe solo al darle a Play; para cambiarlo: npm run token`);
});
