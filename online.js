// Servidor ONLINE de ¡A la trompa! — para un VPS (Contabo, etc.).
//
// Con esto los streamers NO instalan el bridge:
//   1. Abren https://TU-DOMINIO/ , escriben su @usuario de TikTok y una
//      contraseña (la primera vez se crea la cuenta) y pulsan Conectar.
//   2. Esa página, abierta en SU navegador junto a Tikfinity, lee Tikfinity
//      (ws://localhost:21213) y reenvía aquí los mensajes por /relay. Por eso
//      la pestaña debe quedarse abierta durante el directo.
//   3. "▶ Abrir el juego" abre la experiencia de Roblox con su código en
//      launchData y el juego se conecta solo. Si entran por otro lado, el juego
//      pide el @usuario y el código de 6 cifras que sale en el panel.
//
// Cada streamer tiene su CANAL (canal.js): su cola de eventos, sus ajustes, sus
// regalos y su batalla. Todo se guarda en DATA_DIR/canales/<usuario>/.
//
// Variables de entorno (o el archivo online.env junto a este):
//   PORT (8080) · HOST (127.0.0.1: detrás de nginx) · PLACE_ID (el juego en Roblox)
//   DATA_DIR (./datos_online) · MAX_CHANNELS (300) · ADMIN_KEY (para /soporte, opcional)
//   VERBOSE=1 para ver cada regalo/seguidor en el log.

const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
require('dotenv').config({ path: path.join(__dirname, 'online.env') });
const express = require('express');
const WebSocket = require('ws');
const { createChannel } = require('./canal');

// ===== CONFIGURACIÓN =====
const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || '127.0.0.1';
const PLACE_ID = String(process.env.PLACE_ID || '77774451323374').replace(/\D/g, '');
const DATA_DIR = path.resolve(process.env.DATA_DIR || path.join(__dirname, 'datos_online'));
const CHANNELS_DIR = path.join(DATA_DIR, 'canales');
const MAX_CHANNELS = Number(process.env.MAX_CHANNELS || 300);
const ADMIN_KEY = String(process.env.ADMIN_KEY || '').trim();
const VERBOSE = process.env.VERBOSE === '1';
const RELAY_MAX_PER_SECOND = 300; // mensajes de Tikfinity por segundo y canal (lo demás se descarta)
const IDLE_UNLOAD_MS = 2 * 60 * 60 * 1000; // canal sin actividad: se descarga de memoria (sus archivos quedan)

process.on('uncaughtException', (err) => console.error('⚠️ Error no capturado (el servidor sigue):', err));
process.on('unhandledRejection', (reason) => console.error('⚠️ Promesa rechazada (el servidor sigue):', reason));

fs.mkdirSync(CHANNELS_DIR, { recursive: true });

// ===== CUENTAS =====
// cuenta.json: { user, salt, hash, key (panel), token (juego), code (6 cifras), createdAt, lastSeen }
const accounts = new Map(); // user -> cuenta
const byKey = new Map(); // key -> user
const byToken = new Map(); // token -> user
const byCode = new Map(); // code -> user

function normalizeUser(raw) {
	const user = String(raw || '').trim().replace(/^@+/, '').toLowerCase();
	return /^[a-z0-9._]{2,24}$/.test(user) ? user : null;
}

function accountDir(user) {
	return path.join(CHANNELS_DIR, user);
}

function saveAccount(account) {
	fs.mkdirSync(accountDir(account.user), { recursive: true });
	fs.writeFileSync(path.join(accountDir(account.user), 'cuenta.json'), JSON.stringify(account, null, 2));
}

function indexAccount(account) {
	accounts.set(account.user, account);
	byKey.set(account.key, account.user);
	byToken.set(account.token, account.user);
	byCode.set(account.code, account.user);
}

function unindexAccount(account) {
	accounts.delete(account.user);
	byKey.delete(account.key);
	byToken.delete(account.token);
	byCode.delete(account.code);
}

function newCode() {
	for (;;) {
		const code = String(crypto.randomInt(100000, 1000000));
		if (!byCode.has(code)) return code;
	}
}

const randomKey = (bytes) => crypto.randomBytes(bytes).toString('base64url');

function hashPassword(password, salt) {
	return crypto.scryptSync(String(password), salt, 32).toString('hex');
}

function checkPassword(account, password) {
	const expected = Buffer.from(account.hash, 'hex');
	const given = Buffer.from(hashPassword(password, account.salt), 'hex');
	return expected.length === given.length && crypto.timingSafeEqual(expected, given);
}

// Al arrancar se cargan todas las cuentas guardadas
for (const user of fs.readdirSync(CHANNELS_DIR)) {
	try {
		const account = JSON.parse(fs.readFileSync(path.join(accountDir(user), 'cuenta.json'), 'utf8'));
		if (normalizeUser(account.user) === user) indexAccount(account);
	} catch (err) {}
}

// ===== CANALES (en memoria mientras se usan) =====
const channels = new Map(); // user -> { channel, relay, tikfinityUp, tikfinityAt, lastActivity }

function channelOf(user) {
	let entry = channels.get(user);
	if (!entry) {
		entry = {
			channel: createChannel({
				label: '@' + user,
				settingsFile: path.join(accountDir(user), 'settings.json'),
				captureFile: path.join(accountDir(user), 'batallas_capturadas.jsonl'),
				log: (text) => {
					// (sin VERBOSE solo se ven las líneas importantes: batallas, errores, avisos)
					if (VERBOSE || /⚔️|🏁|⚠️|❌|🔴|⚫/.test(text)) console.log(text);
				},
			}),
			relay: null,
			tikfinityUp: false,
			tikfinityAt: 0,
			lastActivity: Date.now(),
		};
		channels.set(user, entry);
	}
	entry.lastActivity = Date.now();
	return entry;
}

function tikfinityOnline(entry) {
	return Boolean(entry.relay) && entry.tikfinityUp && Date.now() - entry.tikfinityAt < 30000;
}

// Canales sin relay ni juego desde hace rato: fuera de memoria
setInterval(() => {
	const now = Date.now();
	for (const [user, entry] of channels) {
		if (!entry.relay && now - entry.lastActivity > IDLE_UNLOAD_MS) {
			channels.delete(user);
		}
	}
}, 10 * 60 * 1000);

// ===== LÍMITES (contra abusos y para que no adivinen contraseñas o códigos) =====
const buckets = new Map(); // clave -> { count, resetAt }
function allow(key, max, windowMs) {
	const now = Date.now();
	let bucket = buckets.get(key);
	if (!bucket || now > bucket.resetAt) {
		bucket = { count: 0, resetAt: now + windowMs };
		buckets.set(key, bucket);
	}
	bucket.count += 1;
	return bucket.count <= max;
}
setInterval(() => {
	const now = Date.now();
	for (const [key, bucket] of buckets) {
		if (now > bucket.resetAt) buckets.delete(key);
	}
}, 60 * 1000);

// ===== SERVIDOR WEB =====
const app = express();
app.set('trust proxy', 'loopback'); // (nginx delante en el mismo VPS: la IP real viene en X-Forwarded-For)
app.disable('x-powered-by');
app.use(express.json({ limit: '100kb' }));
app.use((req, res, next) => {
	res.set('X-Content-Type-Options', 'nosniff');
	res.set('Referrer-Policy', 'no-referrer');
	res.set('X-Frame-Options', 'DENY');
	next();
});

function launchUrl(account) {
	const data = encodeURIComponent(JSON.stringify({ t: account.token }));
	return `https://www.roblox.com/games/start?placeId=${PLACE_ID}&launchData=${data}`;
}

function sessionOf(account) {
	return { user: account.user, key: account.key, code: account.code, placeId: PLACE_ID, launchUrl: launchUrl(account) };
}

// ----- Panel: entrar / crear cuenta -----
app.post('/api/login', (req, res) => {
	if (!allow('login:' + req.ip, 15, 5 * 60 * 1000)) {
		return res.status(429).json({ error: 'Demasiados intentos. Espera unos minutos.' });
	}
	const user = normalizeUser(req.body && req.body.user);
	const password = String((req.body && req.body.password) || '');
	if (!user) return res.status(400).json({ error: 'Usuario de TikTok no válido (letras, números, punto o guion bajo).' });
	if (password.length < 4 || password.length > 64) return res.status(400).json({ error: 'La contraseña debe tener entre 4 y 64 caracteres.' });
	let account = accounts.get(user);
	if (account) {
		if (!allow('login-user:' + user, 10, 15 * 60 * 1000) || !checkPassword(account, password)) {
			return res.status(401).json({ error: 'Contraseña incorrecta para @' + user + '.' });
		}
	} else {
		if (accounts.size >= MAX_CHANNELS) return res.status(503).json({ error: 'El servidor está lleno ahora mismo.' });
		const salt = randomKey(16);
		account = {
			user,
			salt,
			hash: hashPassword(password, salt),
			key: randomKey(24),
			token: randomKey(18),
			code: newCode(),
			createdAt: new Date().toISOString(),
			lastSeen: null,
		};
		indexAccount(account);
		console.log(`🆕 Canal creado: @${user}`);
	}
	account.lastSeen = new Date().toISOString();
	saveAccount(account);
	res.json(sessionOf(account));
});

// ----- Panel: todo lo demás va con la clave de la sesión -----
function panelAuth(req, res, next) {
	const user = byKey.get(String(req.get('x-canal-key') || ''));
	const account = user && accounts.get(user);
	if (!account) return res.status(401).json({ error: 'Sesión caducada: vuelve a entrar.' });
	req.account = account;
	req.entry = channelOf(account.user);
	next();
}

app.get('/api/me', panelAuth, (req, res) => res.json(sessionOf(req.account)));

// Código nuevo para el juego (el anterior y el enlace viejo dejan de valer)
app.post('/api/code/new', panelAuth, (req, res) => {
	const account = req.account;
	byToken.delete(account.token);
	byCode.delete(account.code);
	account.token = randomKey(18);
	account.code = newCode();
	byToken.set(account.token, account.user);
	byCode.set(account.code, account.user);
	saveAccount(account);
	res.json(sessionOf(account));
});

// Mismas rutas que el bridge local (así el panel es el mismo)
app.get('/gifts/roles', panelAuth, (req, res) => res.json(req.entry.channel.giftRoles()));
app.post('/gifts/roles', panelAuth, (req, res) => {
	res.json({ ok: true, roles: req.entry.channel.setGiftRoles((req.body && req.body.roles) || {}) });
});
app.post('/admin', panelAuth, (req, res) => {
	if (!allow('admin:' + req.account.user, 120, 60 * 1000)) return res.status(429).json({ error: 'Demasiadas órdenes seguidas.' });
	const error = req.entry.channel.admin(req.body);
	if (error) return res.status(400).json({ error });
	res.json({ ok: true });
});
app.get('/battle/status', panelAuth, (req, res) => res.json(req.entry.channel.battles.status()));
app.post('/battle/sim', panelAuth, (req, res) => {
	const body = req.body || {};
	const ok = req.entry.channel.battles.simulate(String(body.action || ''), body);
	if (!ok) return res.status(400).json({ error: 'No hay una batalla de prueba en curso (pulsa "Empezar batalla de prueba")' });
	res.json({ ok: true, battle: req.entry.channel.battles.status() });
});
app.post('/battle/end', panelAuth, (req, res) => {
	const ok = req.entry.channel.battles.forceEnd(req.body && req.body.winner);
	if (!ok) return res.status(400).json({ error: 'No hay ninguna batalla en curso' });
	res.json({ ok: true, battle: req.entry.channel.battles.status() });
});
app.get('/admin/gift-log', panelAuth, (req, res) => res.json({ gifts: req.entry.channel.giftLogList() }));
app.get('/status', panelAuth, (req, res) => {
	res.json({
		connectedToTikfinity: tikfinityOnline(req.entry),
		relayConnected: Boolean(req.entry.relay),
		robloxConnected: req.entry.channel.robloxConnected(),
		pendingEvents: req.entry.channel.pendingCount(),
	});
});

// ----- Juego (Roblox) -----
// Enlazar por @usuario + código de 6 cifras (si no entró con el botón del panel)
app.get('/game/link', (req, res) => {
	const user = normalizeUser(req.query.user);
	const code = String(req.query.code || '').replace(/\D/g, '');
	if (!allow('link:' + req.ip, 30, 5 * 60 * 1000) || (user && !allow('link-user:' + user, 10, 5 * 60 * 1000))) {
		return res.status(429).json({ error: 'Demasiados intentos. Espera unos minutos.' });
	}
	const account = user && accounts.get(user);
	if (!account || byCode.get(code) !== user) {
		return res.status(401).json({ error: 'Usuario o código incorrecto. El código está en el panel web.' });
	}
	res.json({ token: account.token, user: account.user });
});

function gameAuth(req, res, next) {
	const user = byToken.get(String(req.query.t || req.get('x-game-token') || ''));
	const account = user && accounts.get(user);
	if (!account) return res.status(401).json({ error: 'Código del juego no válido (vuelve a conectar desde el panel)' });
	if (!allow('game:' + account.user, 600, 60 * 1000)) return res.status(429).json({ error: 'Demasiadas peticiones' });
	req.account = account;
	req.entry = channelOf(account.user);
	next();
}

app.get('/game/pull', gameAuth, (req, res) => {
	res.json({ events: req.entry.channel.pull(), tikfinity: tikfinityOnline(req.entry), user: req.account.user });
});
app.get('/game/settings', gameAuth, (req, res) => res.json({ settings: req.entry.channel.getSettings() }));
app.post('/game/settings', gameAuth, (req, res) => {
	req.entry.channel.setSettings(req.body && req.body.settings);
	res.json({ ok: true });
});

// ----- Soporte (opcional): borrar una cuenta si alguien olvidó su contraseña -----
app.post('/soporte/borrar', (req, res) => {
	if (!ADMIN_KEY || String(req.get('x-admin-key') || '') !== ADMIN_KEY) return res.status(403).json({ error: 'No' });
	const user = normalizeUser(req.body && req.body.user);
	const account = user && accounts.get(user);
	if (!account) return res.status(404).json({ error: 'No existe' });
	unindexAccount(account);
	channels.delete(user);
	fs.rmSync(accountDir(user), { recursive: true, force: true });
	console.log(`🗑️ Cuenta borrada por soporte: @${user}`);
	res.json({ ok: true });
});

// ----- Panel (la misma página que el bridge local, en modo online) -----
app.use('/regalos/img', express.static(path.join(__dirname, 'regalos', 'img'), { maxAge: '1d' }));
function sendPanel(req, res) {
	let html = fs.readFileSync(path.join(__dirname, 'panel.html'), 'utf8');
	html = html.replace('"__ONLINE__"', () => JSON.stringify({ placeId: PLACE_ID }));
	res.set('Cache-Control', 'no-store').type('html').send(html);
}
app.get('/', sendPanel);
app.get('/panel', sendPanel);
app.get('/salud', (req, res) => res.json({ ok: true, canales: accounts.size, activos: channels.size }));

// ===== RELAY: Tikfinity del streamer → aquí (WebSocket /relay?key=...) =====
// El navegador manda { t: "tf", m: "<mensaje de Tikfinity tal cual>" } y
// { t: "estado", tikfinity: true|false }. Cada 2 s se le devuelve el estado.
const server = http.createServer(app);
const wss = new WebSocket.Server({ noServer: true, maxPayload: 256 * 1024 });

server.on('upgrade', (req, socket, head) => {
	const url = new URL(req.url, 'http://x');
	if (url.pathname !== '/relay') {
		socket.destroy();
		return;
	}
	const user = byKey.get(url.searchParams.get('key') || '');
	if (!user || !accounts.get(user)) {
		socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
		socket.destroy();
		return;
	}
	wss.handleUpgrade(req, socket, head, (ws) => {
		const entry = channelOf(user);
		if (entry.relay) {
			// (una sola pestaña por canal: la nueva reemplaza a la vieja)
			try {
				entry.relay.close(4000, 'Abriste el panel en otra pestaña');
			} catch (err) {}
		}
		entry.relay = ws;
		console.log(`🔗 @${user}: panel conectado (retransmitiendo Tikfinity)`);
		let windowStart = Date.now();
		let windowCount = 0;
		ws.on('message', (raw) => {
			const now = Date.now();
			if (now - windowStart > 1000) {
				windowStart = now;
				windowCount = 0;
			}
			windowCount += 1;
			if (windowCount > RELAY_MAX_PER_SECOND) return;
			let packet;
			try {
				packet = JSON.parse(raw.toString());
			} catch (err) {
				return;
			}
			entry.lastActivity = now;
			if (packet.t === 'tf' && typeof packet.m === 'string') {
				entry.tikfinityUp = true;
				entry.tikfinityAt = now;
				entry.channel.handleTikfinity(packet.m);
			} else if (packet.t === 'estado') {
				entry.tikfinityUp = packet.tikfinity === true;
				entry.tikfinityAt = now;
			}
		});
		const timer = setInterval(() => {
			if (ws.readyState === WebSocket.OPEN) {
				ws.send(JSON.stringify({ t: 'estado', roblox: entry.channel.robloxConnected(), pendientes: entry.channel.pendingCount() }));
			}
		}, 2000);
		ws.on('close', () => {
			clearInterval(timer);
			if (entry.relay === ws) {
				entry.relay = null;
				entry.tikfinityUp = false;
				console.log(`🔌 @${user}: panel desconectado`);
			}
		});
		ws.on('error', () => {});
	});
});

server.listen(PORT, HOST, () => {
	console.log(`🌐 ¡A la trompa! ONLINE en http://${HOST}:${PORT}  •  ${accounts.size} canales guardados  •  juego ${PLACE_ID}`);
});
