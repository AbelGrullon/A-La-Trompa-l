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
const { createChannel } = require('./canal');

// ===== CONFIGURACIÓN =====
const PORT = Number(process.env.PORT || 3000);
const ACCESS_TOKEN = (process.env.ACCESS_TOKEN || '').trim(); // clave para que solo tu juego y tu panel usen el bridge
const TIKFINITY_URL = process.env.TIKFINITY_URL || 'ws://127.0.0.1:21213/';

const app = express();
app.use(express.json({ limit: '100kb' }));

// Red de seguridad: un error aislado no debe tumbar todo el bridge.
process.on('uncaughtException', (err) => {
	console.error('⚠️ Error no capturado (el servidor sigue corriendo):', err);
});
process.on('unhandledRejection', (reason) => {
	console.error('⚠️ Promesa rechazada sin manejar (el servidor sigue corriendo):', reason);
});

// ===== EL CANAL (tu live): eventos, ajustes, regalos y batalla (ver canal.js) =====
// El juego funciona SOLO con regalos, likes y follows: el chat y los
// compartidos de Tikfinity se ignoran a propósito.
const channel = createChannel({
	settingsFile: path.join(__dirname, 'settings.json'),
	captureFile: path.join(__dirname, 'batallas_capturadas.jsonl'),
});

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

	socket.on('message', (raw) => channel.handleTikfinity(raw.toString()));

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

// ===== API QUE USA ROBLOX =====

app.get('/events/pull', checkAccess, (req, res) => {
	res.json({ events: channel.pull(), tikfinity: tikfinityConnected });
});

app.get('/settings', checkAccess, (req, res) => {
	res.json({ settings: channel.getSettings() });
});

app.post('/settings', checkAccess, (req, res) => {
	channel.setSettings(req.body && req.body.settings);
	res.json({ ok: true });
});

// ===== API DEL PANEL WEB (las mismas rutas en el servidor online) =====

// Catálogo + puestos actuales (para el editor de regalos del panel)
app.get('/gifts/roles', checkAccess, (req, res) => {
	res.json(channel.giftRoles());
});

// Guarda los puestos { rol: [ids] }. Un regalo solo puede estar en un puesto.
app.post('/gifts/roles', checkAccess, (req, res) => {
	res.json({ ok: true, roles: channel.setGiftRoles((req.body && req.body.roles) || {}) });
});

// Órdenes para el juego (las mismas que el panel dev de Roblox, ver canal.js → ADMIN_ACTIONS)
app.post('/admin', checkAccess, (req, res) => {
	const error = channel.admin(req.body);
	if (error) return res.status(400).json({ error });
	res.json({ ok: true });
});

// ----- Modo batalla -----
// Estado de la batalla actual (para el panel)
app.get('/battle/status', checkAccess, (req, res) => {
	res.json(channel.battles.status());
});

// Pruebas sin live: { action: 'start' | 'points' | 'end', side: 'me' | 'rival', amount }
// (pasan por el mismo lector que las batallas reales de Tikfinity)
app.post('/battle/sim', checkAccess, (req, res) => {
	const body = req.body || {};
	const ok = channel.battles.simulate(String(body.action || ''), body);
	if (!ok) return res.status(400).json({ error: 'No hay una batalla de prueba en curso (pulsa "Empezar batalla de prueba")' });
	res.json({ ok: true, battle: channel.battles.status() });
});

// Terminar la batalla ya (por si TikTok no avisó): { winner: 'me' | 'rival' | 'tie' } o sin winner = por puntos
app.post('/battle/end', checkAccess, (req, res) => {
	const ok = channel.battles.forceEnd(req.body && req.body.winner);
	if (!ok) return res.status(400).json({ error: 'No hay ninguna batalla en curso' });
	res.json({ ok: true, battle: channel.battles.status() });
});

app.get('/admin/gift-log', checkAccess, (req, res) => {
	res.json({ gifts: channel.giftLogList() });
});

app.get('/status', (req, res) => {
	res.json({
		connectedToTikfinity: tikfinityConnected,
		robloxConnected: channel.robloxConnected(),
		pendingEvents: channel.pendingCount(),
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
