// Canal de UN streamer: todo lo que el bridge hace con su live.
//
//   • Traduce los mensajes de Tikfinity ({ event, data }) a eventos simples para
//     el juego (gift / like / follow / viewers + battleStart/Points/End) y los
//     guarda en una cola hasta que Roblox los pide (pull, una vez por segundo).
//   • Guarda los ajustes del juego (los cambia el panel dev de Roblox y el panel
//     web), los regalos de cada peleador y la batalla de TikTok en curso.
//
// Lo usan el bridge local (server.js: un solo canal, con Tikfinity de este PC)
// y el servidor online (online.js: un canal por streamer, con los mensajes de
// Tikfinity reenviados desde el navegador del streamer).

const fs = require('fs');
const path = require('path');
const { createBattles } = require('./batalla');
const Regalos = require('./regalos');

const MAX_EVENTS = 3000;
const MAX_FOLLOWED = 50000;
const BATTLE_CAPTURE_MAX = 5 * 1024 * 1024;
const BATTLE_EVENTS = new Set(['linkMicBattle', 'linkMicArmies', 'linkMicBattlePunishFinish']);

// Ajustes de texto largos (JSON): el resto se corta a 200 caracteres.
// Deben coincidir con Shared.STRING_MAX en el juego.
const LONG_SETTINGS = { HudCustom: 4000, GiftRoles: 8000 };

// Órdenes para el juego (las mismas que el panel dev de Roblox)
const ADMIN_ACTIONS = new Set([
	'simJoin', 'simBots', 'simGift', 'simLikes', 'simFollow', 'testEntrance', 'rain', 'fury', 'hearts',
	'healAll', 'chargeAll', 'koRandom', 'resetFighters', 'resetQueue', 'resetScore', 'resetAll',
	'setSetting', 'resetSettings', 'announce',
	'simBattleStart', 'simBattlePoints', 'simBattleGift', 'simBattleEnd', 'endBattle',
]);

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

// Tikfinity manda los datos del usuario a veces en data y a veces en data.user.
function userOf(data) {
	const source = data?.user && typeof data.user === 'object' ? { ...data, ...data.user } : data || {};
	const user = String(source.uniqueId || source.userId || source.nickname || '').trim();
	const name = String(source.nickname || source.uniqueId || '').trim();
	return { user, name: name || user };
}

// options: { label, settingsFile, captureFile, log }
function createChannel(options = {}) {
	const label = options.label || '';
	const prefix = label ? `[${label}] ` : '';
	const log = (...args) => (options.log || console.log)(prefix + args.join(' '));

	// ----- cola de eventos para Roblox -----
	let events = [];
	let pendingLikes = new Map(); // user -> evento "like" aún no entregado (se van sumando)
	let pendingViewers = null;
	let lastPullAt = 0;
	let lastTikfinityAt = 0;

	function pushEvent(event) {
		events.push(event);
		if (events.length > MAX_EVENTS) {
			events.splice(0, events.length - MAX_EVENTS);
		}
	}

	function pull() {
		const batch = events;
		events = [];
		pendingLikes = new Map();
		pendingViewers = null;
		lastPullAt = Date.now();
		return batch;
	}

	// ----- ajustes -----
	function loadSettings() {
		if (!options.settingsFile) return {};
		try {
			return JSON.parse(fs.readFileSync(options.settingsFile, 'utf8'));
		} catch (err) {
			return {};
		}
	}
	let settings = loadSettings();
	let saveTimer = null;

	function saveSettingsFile() {
		if (!options.settingsFile) return;
		clearTimeout(saveTimer);
		saveTimer = setTimeout(() => {
			fs.mkdir(path.dirname(options.settingsFile), { recursive: true }, () => {
				fs.writeFile(options.settingsFile, JSON.stringify(settings, null, 2), (err) => {
					if (err) log('⚠️ No se pudieron guardar los ajustes:', err.message);
				});
			});
		}, 300);
	}

	function setSettings(input) {
		settings = cleanSettings(input);
		saveSettingsFile();
	}

	// ----- batalla de TikTok (ver batalla.js) -----
	const battles = createBattles({ pushEvent, getSettings: () => settings, log });

	// ----- regalos -----
	// Los regalos "combo" (giftType 1, como la rosa) llegan varias veces mientras
	// dura la racha con repeatCount 1, 2, 3... y una última vez con repeatEnd.
	// Solo mandamos la diferencia, así cada rosa cuenta una sola vez.
	const giftStreaks = new Map(); // `${user}:${giftId}` -> { count, at }
	const giftLog = new Map(); // giftId -> { count, names: Set, lastSeen }

	function logGift(giftId, giftName) {
		if (!giftLog.has(giftId)) {
			if (giftLog.size > 500) return;
			giftLog.set(giftId, { count: 0, names: new Set(), lastSeen: null });
		}
		const entry = giftLog.get(giftId);
		entry.count += 1;
		entry.lastSeen = new Date().toISOString();
		if (giftName && entry.names.size < 5) entry.names.add(String(giftName).slice(0, 60));
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
			if (giftStreaks.size > 5000) giftStreaks.clear();
		}
		if (count <= 0 || !user) return;
		pushEvent({ type: 'gift', user, name, giftId, giftName, count, diamonds });
		const role = Regalos.giftRoleLabel(settings, giftId);
		log(`🎁 ${name} envió ${giftName || giftId} x${count}${role ? ' (' + role + ')' : ''}`);
	}

	// ----- likes, seguidores, espectadores -----
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
		if (followed.size > MAX_FOLLOWED) followed.clear();
		followed.add(user);
		pushEvent({ type: 'follow', user, name });
		log(`💖 ${name} empezó a seguir`);
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

	// ----- captura de batallas -----
	// Guarda tal cual todo lo que Tikfinity mande de las batallas de TikTok
	// (linkMicBattle, linkMicArmies...) y anota una vez cada tipo de evento nuevo,
	// para ajustar batalla.js con datos reales si hiciera falta.
	const seenEvents = new Set();

	function noteOtherEvent(name, raw) {
		name = String(name || '?').slice(0, 60);
		const isBattle = /linkmic|battle|armies|pk/i.test(name);
		if (!seenEvents.has(name) && seenEvents.size < 200) {
			seenEvents.add(name);
			log(isBattle ? `⚔️ Evento de batalla recibido: ${name} (se guarda en la captura)` : `ℹ️ Tikfinity envía también: ${name}`);
		}
		if (!isBattle || !options.captureFile) return;
		try {
			const size = fs.existsSync(options.captureFile) ? fs.statSync(options.captureFile).size : 0;
			if (size < BATTLE_CAPTURE_MAX) {
				fs.mkdirSync(path.dirname(options.captureFile), { recursive: true });
				fs.appendFileSync(options.captureFile, JSON.stringify({ at: new Date().toISOString(), raw: String(raw) }) + '\n');
			}
		} catch (err) {}
	}

	// Un mensaje de Tikfinity (texto JSON tal cual llega del WebSocket)
	function handleTikfinity(raw) {
		let message;
		try {
			message = JSON.parse(String(raw));
		} catch (err) {
			return;
		}
		if (!message || typeof message !== 'object') return;
		lastTikfinityAt = Date.now();
		const data = message.data && typeof message.data === 'object' ? message.data : {};
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
				log(data.isLive ? '🔴 El live empezó' : '⚫ El live terminó');
				break;
			default:
				noteOtherEvent(message.event, raw);
				if (BATTLE_EVENTS.has(message.event)) {
					try {
						battles.handle(message.event, data);
					} catch (err) {
						log('⚠️ Error leyendo la batalla:', err.message);
					}
				}
				break;
		}
	}

	// ----- regalos de cada peleador -----
	function giftRoles() {
		return {
			catalog: Regalos.catalog,
			roles: Regalos.currentGiftRoles(settings),
			roleList: Regalos.GIFT_ROLES,
			defaults: Regalos.DEFAULT_GIFT_ROLES,
		};
	}

	function setGiftRoles(input) {
		const value = Regalos.buildGiftRoles(input);
		settings.GiftRoles = value;
		saveSettingsFile();
		// el juego lo aplica en cuanto pida eventos (si no está abierto, lo leerá de los ajustes al empezar)
		pushEvent({ type: 'admin', action: 'setSetting', key: 'GiftRoles', value });
		log('🎁 [panel] regalos de los peleadores actualizados');
		return Regalos.currentGiftRoles(settings);
	}

	// ----- órdenes del panel web -----
	// Devuelve un texto de error, o null si se mandó al juego
	function admin(body) {
		body = body || {};
		if (!ADMIN_ACTIONS.has(body.action)) return 'Acción desconocida';
		const event = { type: 'admin', action: body.action };
		for (const [key, value] of Object.entries(body).slice(0, 20)) {
			if (key === 'action' || key === 'type') continue;
			if (['string', 'number', 'boolean'].includes(typeof value)) {
				event[key] = typeof value === 'string' ? value.slice(0, 200) : value;
			}
		}
		pushEvent(event);
		log(`🛠️ [panel] ${body.action}`);
		return null;
	}

	function giftLogList() {
		const gifts = [];
		for (const [giftId, data] of giftLog.entries()) {
			gifts.push({
				giftId,
				count: data.count,
				names: Array.from(data.names),
				lastSeen: data.lastSeen,
				knownTier: Regalos.giftRoleLabel(settings, giftId),
			});
		}
		gifts.sort((a, b) => b.count - a.count);
		return gifts;
	}

	return {
		pull,
		pushEvent,
		handleTikfinity,
		getSettings: () => settings,
		setSettings,
		giftRoles,
		setGiftRoles,
		admin,
		giftLogList,
		battles,
		robloxConnected: () => Date.now() - lastPullAt < 5000,
		lastTikfinityAt: () => lastTikfinityAt,
		pendingCount: () => events.length,
	};
}

module.exports = { createChannel, cleanSettings, ADMIN_ACTIONS };
