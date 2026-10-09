// Batallas de TikTok (modo batalla del juego).
//
// Cuando el streamer hace una batalla (PK / "link mic battle") en TikTok,
// Tikfinity manda:
//   linkMicBattle  -> empieza una batalla (quiénes pelean)
//   linkMicArmies  -> cada vez que un lado recibe puntos (puntos de los dos lados)
//   linkMicBattlePunishFinish -> terminó el castigo (la batalla ya había acabado)
// Aquí se traducen a tres eventos simples para el juego:
//   { type: 'battleStart', id, me: {name, user}, rival: {name, user}, duration }
//   { type: 'battlePoints', id, me, rival }               (puntos totales)
//   { type: 'battleEnd', id, me, rival, winner: 'me' | 'rival' | 'tie' }
//
// El formato exacto depende de la versión de Tikfinity, así que se aceptan las
// dos formas conocidas (TikTok-Live-Connector 1.x: battleUsers / battleArmies,
// y la de la librería nueva: anchorInfo / battleItems / battleGroups). Todo lo
// que llega se guarda además en batallas_capturadas.jsonl (ver server.js) para
// ajustar esto con datos reales si hiciera falta.
//
// "Yo" (el streamer de este PC) se decide así: el ajuste BattleMe (@usuario de
// TikTok) si está puesto; si no, el que recibe los regalos de este live
// (receiverUserId de los regalos); si no, el primero. BattleSwap los invierte.

const BATTLE_FALLBACK_MS = 6 * 60 * 1000; // sin aviso de fin, la batalla se cierra sola
const END_GRACE_MS = 2500; // al acabar el tiempo se esperan los últimos puntos
const NEW_BATTLE_GAP_MS = 20000; // tras un fin, otro linkMicArmies sin aviso = batalla nueva

const SIM_ME = '7000000000000000001';
const SIM_RIVAL = '7000000000000000002';

function createBattles({ pushEvent, getSettings, log = console.log }) {
	let battle = null; // batalla en curso (o la última, ya terminada)
	let myHostId = null; // id de TikTok de este streamer (aprendido de los regalos)
	const knownUsers = new Map(); // id -> { id, name, user }
	let endTimer = null;
	const sim = { points: new Map(), status: 1, n: 0 };

	const asId = (v) => (v === undefined || v === null || v === '' || typeof v === 'object' ? null : String(v));
	const num = (v) => {
		const n = Number(v);
		return Number.isFinite(n) ? n : null;
	};

	// ----- quién pelea -----
	function rememberUser(obj) {
		if (!obj || typeof obj !== 'object') return null;
		const id = asId(obj.userId ?? obj.id ?? obj.anchorId ?? obj.hostUserId ?? obj.uid);
		const name = obj.nickname ?? obj.nickName ?? obj.displayName;
		const user = obj.uniqueId ?? obj.displayId ?? obj.username;
		if (!id || !/^\d{3,}$/.test(id) || (!name && !user)) return null;
		const previous = knownUsers.get(id) || {};
		const entry = {
			id,
			name: String(name || previous.name || user).slice(0, 40),
			user: String(user || previous.user || '').slice(0, 40),
		};
		knownUsers.set(id, entry);
		return entry;
	}

	// Busca los streamers de la batalla dentro del evento linkMicBattle
	function battleUsers(data) {
		const found = new Map();
		const add = (obj) => {
			const entry = rememberUser(obj && typeof obj.user === 'object' ? { ...obj, ...obj.user } : obj);
			if (entry) found.set(entry.id, entry);
		};
		if (Array.isArray(data.battleUsers)) data.battleUsers.forEach(add);
		for (const key of ['anchorInfo', 'anchors', 'battleUserInfoMap', 'battleUserInfo']) {
			const value = data[key];
			if (Array.isArray(value)) value.forEach(add);
			else if (value && typeof value === 'object') {
				for (const [id, info] of Object.entries(value)) {
					add({ userId: id, ...(info || {}), ...((info && info.user) || {}) });
				}
			}
		}
		if (found.size < 2) {
			// forma desconocida: se recorre el objeto buscando usuarios
			const walk = (obj, depth) => {
				if (!obj || typeof obj !== 'object' || depth > 5 || found.size >= 4) return;
				if (Array.isArray(obj)) return obj.forEach((x) => walk(x, depth + 1));
				add(obj);
				for (const value of Object.values(obj)) if (value && typeof value === 'object') walk(value, depth + 1);
			};
			walk(data, 0);
		}
		return [...found.values()];
	}

	// ----- puntos -----
	function sumGroups(groups) {
		if (!Array.isArray(groups)) return null;
		let total = 0;
		for (const g of groups) total += num(g && (g.points ?? g.score)) || 0;
		return total;
	}

	function armyPoints(data) {
		const points = new Map();
		const add = (id, value) => {
			id = asId(id);
			value = num(value);
			if (id && value !== null) points.set(id, Math.max(points.get(id) || 0, value));
		};
		const list = data.battleArmies || data.armies;
		if (Array.isArray(list)) {
			for (const army of list) {
				if (army) add(army.hostUserId ?? army.anchorId ?? army.userId, army.points ?? army.score ?? sumGroups(army.battleGroups));
			}
		}
		const items = data.battleItems;
		if (items && typeof items === 'object') {
			for (const [key, army] of Object.entries(items)) {
				if (army) add(army.hostUserId ?? army.anchorId ?? (Array.isArray(items) ? null : key), army.points ?? army.score ?? sumGroups(army.battleGroups));
			}
		}
		return points;
	}

	function statusOf(data) {
		const s = data.battleStatus ?? data.status ?? (data.battleSetting && data.battleSetting.status);
		return s === undefined || s === null ? null : String(s);
	}

	function battleIdOf(data) {
		return asId(data.battleId ?? (data.battleSetting && data.battleSetting.battleId) ?? data.channelId) || null;
	}

	function durationOf(data) {
		const setting = data.battleSetting || data.battleSettings || {};
		const seconds = num(setting.duration ?? data.duration ?? data.battleDuration);
		return seconds && seconds > 10 && seconds < 3600 ? seconds : null;
	}

	// ----- lados -----
	function decideSides(ids) {
		const settings = getSettings() || {};
		const wanted = String(settings.BattleMe || '').replace(/^@/, '').trim().toLowerCase();
		let me = null;
		if (ids.includes(SIM_ME)) me = SIM_ME;
		if (!me && wanted) me = ids.find((id) => (knownUsers.get(id)?.user || '').toLowerCase() === wanted) || null;
		if (!me && myHostId && ids.includes(myHostId)) me = myHostId;
		if (!me) me = ids[0];
		if (settings.BattleSwap === true && ids.length > 1) {
			me = ids.find((id) => id !== me); // los lados salieron al revés: se cambian
		}
		return { me, rivals: ids.filter((id) => id !== me) };
	}

	function sideInfo(ids, fallback) {
		const users = ids.map((id) => knownUsers.get(id)).filter(Boolean);
		if (users.length === 0) return { name: fallback, user: '' };
		return {
			name: users.map((u) => u.name).join(' & ').slice(0, 40),
			user: users[0].user,
		};
	}

	function totals() {
		const me = battle.points.get(battle.me) || 0;
		let rival = 0;
		for (const id of battle.rivals) rival += battle.points.get(id) || 0;
		return { me, rival };
	}

	// ----- ciclo de una batalla -----
	function startBattle(id, ids, data) {
		if (battle && !battle.ended) endBattle('nueva batalla');
		const { me, rivals } = decideSides(ids);
		const duration = data ? durationOf(data) : null;
		battle = {
			id: id || `b${Date.now()}`,
			ids,
			me,
			rivals,
			points: new Map(),
			status: null,
			startedAt: Date.now(),
			duration,
			ended: false,
			endedAt: 0,
			lastSent: null,
		};
		const meInfo = sideInfo([me], 'Yo');
		const rivalInfo = sideInfo(rivals, 'Rival');
		pushEvent({ type: 'battleStart', id: battle.id, me: meInfo, rival: rivalInfo, duration: duration || 0 });
		log(`⚔️ ¡Batalla en TikTok! ${meInfo.name} vs ${rivalInfo.name}${duration ? ` (${duration}s)` : ''}`);
		clearTimeout(endTimer);
		endTimer = setTimeout(() => endBattle('tiempo'), duration ? duration * 1000 + END_GRACE_MS : BATTLE_FALLBACK_MS);
	}

	function sendPoints() {
		const t = totals();
		const key = `${t.me}|${t.rival}`;
		if (key === battle.lastSent) return;
		battle.lastSent = key;
		pushEvent({ type: 'battlePoints', id: battle.id, me: t.me, rival: t.rival });
	}

	function endBattle(reason, forcedWinner) {
		if (!battle || battle.ended) return;
		clearTimeout(endTimer);
		battle.ended = true;
		battle.endedAt = Date.now();
		const t = totals();
		const winner = forcedWinner || (t.me > t.rival ? 'me' : t.rival > t.me ? 'rival' : 'tie');
		battle.winner = winner;
		pushEvent({ type: 'battleEnd', id: battle.id, me: t.me, rival: t.rival, winner });
		log(`🏁 Fin de la batalla (${reason}): ${t.me} vs ${t.rival} → ${winner === 'me' ? 'GANASTE' : winner === 'rival' ? 'ganó el rival' : 'empate'}`);
	}

	// ----- eventos de Tikfinity -----
	function onLinkMicBattle(data) {
		const users = battleUsers(data);
		const id = battleIdOf(data);
		if (battle && !battle.ended && (id ? id === battle.id : Date.now() - battle.startedAt < NEW_BATTLE_GAP_MS)) {
			return; // aviso repetido de la misma batalla
		}
		if (users.length < 2) {
			log('⚠️ Batalla sin los dos streamers en los datos (se espera a los puntos)');
			return;
		}
		startBattle(id, users.map((u) => u.id), data);
	}

	function onLinkMicArmies(data) {
		const points = armyPoints(data);
		const id = battleIdOf(data);
		const status = statusOf(data);
		if (points.size === 0) return;
		const hosts = [...points.keys()];
		const sameBattle = battle && (id ? id === battle.id : hosts.every((h) => battle.ids.includes(h)));
		if (!battle || (battle.ended && (!sameBattle || Date.now() - battle.endedAt > NEW_BATTLE_GAP_MS))) {
			// llegaron puntos sin aviso de inicio: se arma la batalla con lo que hay
			startBattle(id, hosts, data);
		}
		if (battle.ended) return; // puntos tardíos de una batalla que ya acabó
		for (const host of hosts) {
			if (!battle.ids.includes(host)) {
				battle.ids.push(host);
				if (host !== battle.me) battle.rivals.push(host);
			}
			battle.points.set(host, points.get(host));
		}
		sendPoints();
		// el estado cambia cuando TikTok cierra la batalla
		if (status !== null) {
			if (battle.status === null) battle.status = status;
			else if (status !== battle.status) endBattle('TikTok');
		}
	}

	function handle(eventName, data) {
		data = data || {};
		if (eventName === 'linkMicBattle') onLinkMicBattle(data);
		else if (eventName === 'linkMicArmies') onLinkMicArmies(data);
		else if (eventName === 'linkMicBattlePunishFinish') endBattle('castigo terminado');
		else return false;
		return true;
	}

	// Los regalos de este live dicen quién es el streamer (el que los recibe)
	function noteGift(data) {
		const id = asId(data && (data.receiverUserId ?? data.toUserId ?? data.hostUserId));
		if (id && /^\d{3,}$/.test(id)) myHostId = id;
	}

	// ----- pruebas sin live (panel web): mensajes falsos con el formato 1.x -----
	function simulate(action, args = {}) {
		if (action === 'start') {
			sim.n += 1;
			sim.points = new Map([[SIM_ME, 0], [SIM_RIVAL, 0]]);
			sim.status = 1;
			handle('linkMicBattle', {
				battleId: `sim${Date.now()}`,
				battleSetting: { duration: Number(args.duration) || 0 },
				battleUsers: [
					{ userId: SIM_ME, uniqueId: 'yo_streamer', nickname: String(args.meName || 'Yo (prueba)') },
					{ userId: SIM_RIVAL, uniqueId: 'rival_streamer', nickname: String(args.rivalName || 'Rival (prueba)') },
				],
			});
			return true;
		}
		if (!battle || battle.ended || !battle.ids.includes(SIM_ME)) return false;
		if (action === 'points') {
			const host = args.side === 'rival' ? SIM_RIVAL : SIM_ME;
			sim.points.set(host, (sim.points.get(host) || 0) + Math.max(1, Math.min(100000, Number(args.amount) || 1)));
			handle('linkMicArmies', {
				battleId: battle.id,
				battleStatus: sim.status,
				battleArmies: [...sim.points].map(([hostUserId, points]) => ({ hostUserId, points })),
			});
			return true;
		}
		if (action === 'end') {
			handle('linkMicArmies', {
				battleId: battle.id,
				battleStatus: 2,
				battleArmies: [...sim.points].map(([hostUserId, points]) => ({ hostUserId, points })),
			});
			return true;
		}
		return false;
	}

	function forceEnd(winner) {
		if (!battle || battle.ended) return false;
		endBattle('panel', ['me', 'rival', 'tie'].includes(winner) ? winner : undefined);
		return true;
	}

	function status() {
		if (!battle) return { active: false };
		const t = totals();
		return {
			active: !battle.ended,
			id: battle.id,
			me: { ...sideInfo([battle.me], 'Yo'), points: t.me },
			rival: { ...sideInfo(battle.rivals, 'Rival'), points: t.rival },
			startedAt: battle.startedAt,
			duration: battle.duration,
			winner: battle.winner || null,
			myHostKnown: Boolean(myHostId),
		};
	}

	return { handle, noteGift, simulate, forceEnd, status };
}

module.exports = { createBattles };
