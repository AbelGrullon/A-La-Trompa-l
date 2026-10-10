// Regalos de cada peleador: catálogo y puestos (lo comparten el bridge local y
// el servidor online).
//
// Catálogo (regalos/catalogo.json): los regalos de TikTok que ya tienen imagen
// subida a Roblox (los mismos que usa "A Correr"). En el panel se elige qué
// regalos van en cada puesto; eso se guarda en el ajuste GiftRoles (JSON) y el
// juego lo aplica al instante (Shared.applyGiftRoles).

const fs = require('fs');
const path = require('path');

const CATALOG_FILE = path.join(__dirname, 'regalos', 'catalogo.json');
let catalog = [];
try {
	catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf8'));
} catch (err) {
	console.warn('⚠️ No se pudo leer regalos/catalogo.json:', err.message);
}
const catalogById = new Map(catalog.map((g) => [g.id, g]));

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

// Puestos actuales (a partir del ajuste GiftRoles) como { rol: [ids] }
function currentGiftRoles(settings) {
	try {
		const parsed = JSON.parse((settings && settings.GiftRoles) || '');
		const roles = {};
		for (const role of GIFT_ROLES) {
			roles[role.id] = (parsed[role.id] || []).map((g) => Number(g.id)).filter(Boolean);
		}
		return roles;
	} catch (err) {
		return JSON.parse(JSON.stringify(DEFAULT_GIFT_ROLES));
	}
}

function giftRoleLabel(settings, giftId) {
	const roles = currentGiftRoles(settings);
	const role = GIFT_ROLES.find((r) => (roles[r.id] || []).includes(Number(giftId)));
	return role ? role.label : null;
}

// De { rol: [ids] } (lo que manda el panel) al valor del ajuste GiftRoles.
// Un regalo solo puede estar en un puesto y cada puesto tiene como mucho 6.
function buildGiftRoles(input) {
	const used = new Set();
	const out = {};
	for (const role of GIFT_ROLES) {
		out[role.id] = [];
		for (const raw of Array.isArray(input && input[role.id]) ? input[role.id] : []) {
			const gift = catalogById.get(Number(raw));
			if (!gift || used.has(gift.id) || out[role.id].length >= 6) continue;
			used.add(gift.id);
			out[role.id].push({ id: gift.id, name: gift.name, image: gift.image });
		}
	}
	return JSON.stringify(out);
}

module.exports = { catalog, catalogById, GIFT_ROLES, DEFAULT_GIFT_ROLES, currentGiftRoles, giftRoleLabel, buildGiftRoles };
