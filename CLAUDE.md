# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"¡A la trompa!" is an automatic boxing arena for TikTok lives. Viewers never touch Roblox. The game works **only with gifts, likes and follows** (the TikTok chat and shares are deliberately ignored since 2026-10-01). It turns those into fighters, named after their TikTok name, with an avatar picked by hashing the name. The fighters battle on their own while the streamer captures the Roblox window.

The project has two halves:

1. **This folder:** the Node side. It runs in one of two ways and both share the same per-streamer logic, `canal.js`:
   - **Local bridge** (`server.js` + `panel.html`): reads the live from **Tikfinity Desktop**'s local WebSocket (`ws://127.0.0.1:21213`) on the streamer's PC and exposes the events over HTTP.
   - **Online server** (`online.js`, for a VPS): many streamers, nothing to install. See "Online mode" below and `GUIA_ONLINE.md`.
2. **The Roblox place** "A la trompa!" (placeId 77774451323374). **All game code lives only inside the place in Roblox Studio.** `juego/` is a read-only *export* of the place's scripts for git history (Rojo naming: `.server.lua` / `.client.lua` / `.lua`, see `juego/LEEME.md`). Editing it does not change the game. Re-export it after changing the place (POST each script's Source from Studio to a tiny localhost receiver, skipping `ServerStorage` backups and Roblox default scripts). Rojo is not used even though the plugin is installed. Read and edit it with the Roblox Studio MCP tools (`script_read`, `multi_edit`, `execute_luau`, `start_stop_play`, `get_console_output`, `screen_capture`). Changes only persist once the user saves or publishes the place in Studio.

All comments, logs and UI text are in Spanish. Keep it that way.

## Commands

```bash
npm install
npm start            # node server.js → http://localhost:3000/panel (INICIAR_BRIDGE.bat does the same)
npm run token        # change the saved token (CAMBIAR_TOKEN.bat)
npm run online       # node online.js → online server on :8080 (reads online.env; for the VPS)
```

**Token flow (asked once, like A Correr).** On start, `ensureToken()` at the top of `server.js` checks `.env` for a valid `ACCESS_TOKEN` (6–64 chars of `A-Za-z0-9_-`, not the example value). If missing it opens the Windows Forms dialog `pedir_token.ps1` (type or generate a token; it saves it to `.env`; cancel exits). It falls back to a random token if PowerShell fails. After that nothing is asked again. The game never needs the token typed anywhere:
- `GET /handshake` returns the token only to loopback requests. `ServerScriptService.Arena.Bridge` calls it when `Config.BRIDGE_ACCESS_TOKEN` is `""` and again whenever a request answers 401 (bridge restarted with a new token).
- `GET /panel` injects the token into `panel.html` (replacing `"__TOKEN__"`) for loopback requests, and the token field is hidden.
- A non-empty `Config.BRIDGE_ACCESS_TOKEN` still works as a manual override.
- An `ACCESS_TOKEN` environment variable skips the dialog (used for throwaway test bridges).
- `pedir_token.ps1` must stay UTF-8 **with BOM** (Windows PowerShell 5.1 reads it as ANSI otherwise).

There are no tests, linter or build step.

`.env` keys: `PORT`, `ACCESS_TOKEN`, `TIKFINITY_URL`. Environment variables override `.env`, because dotenv does not overwrite existing vars. That lets you run a throwaway bridge without touching the user's setup:

```powershell
$env:PORT='3099'; $env:ACCESS_TOKEN='testtoken'; $env:TIKFINITY_URL='ws://127.0.0.1:21299/'; node server.js
```

To exercise the Tikfinity parsing, point `TIKFINITY_URL` at a tiny fake `ws` server that sends `{event, data}` messages (gift/like/follow/social/roomUser; chat and share are ignored). Then read `GET /events/pull?token=...`.

## Data flow (spans both halves)

```
Tikfinity WS → canal.js handleTikfinity → events[] queue
   (local: server.js connects to Tikfinity · online: the streamer's browser relays it to online.js)
   → Roblox Bridge module polls GET /events/pull (local) or /game/pull (online) every 1 s
   → ArenaManager.handleEvent (gift | like | follow | viewers | admin | battle*)
   → server state + HudEvent / FxEvent remotes → ArenaHUD / BattleHUD / ArenaCamera on the client
```

### Node modules

- `canal.js`: everything for one streamer's live. Tikfinity parsing, the event queue (`pull`), settings (`settingsFile`), gift roles, admin commands (`ADMIN_ACTIONS`), gift log, battle capture file and `batalla.js`.
- `regalos.js`: the gift catalog and roles, shared by all channels.
- `server.js`: token flow + one channel + local Tikfinity socket + routes.
- `online.js`: accounts + many channels + relay WebSocket + routes.
- The panel routes are the same in both servers (`/admin`, `/gifts/roles`, `/battle/*`, `/admin/gift-log`, `/status`); only the auth header differs. So `panel.html` is one file for both.

### Bridge (`server.js`)

- **Event normalization.** The bridge only normalizes. The game decides what an event means: boost vs spawn, team, effects.
- **How people join.** No chat. A gift joins you (team from the gift, skips the line). A like joins you (`LikeJoins`, auto team) and heals you if you're in the ring. A follow joins you with extra health (`FollowJoins`). `simJoin` remains as a dev-only test command.
- **Gifts.** Combo gifts (`giftType === 1`, e.g. roses) arrive several times with a growing `repeatCount`. Only the delta is emitted, so each gift counts once.
- **Coalescing.** Likes from the same user are merged until the next pull, and so is the viewer count.

### Settings

- `GET`/`POST /settings` persist the game's live settings to `settings.json`. The game loads them on start and saves them, debounced, whenever a setting changes.
- Delete `settings.json` after tests so test values don't leak into the user's stream.

### Admin and test commands

There is one command table: `COMMANDS` in `ArenaManager`. It is reached two ways:

- The in-game dev panel (F2) → `DevCommand` remote. The server only accepts this from `ArenaDev` players: Studio or the place owner.
- The web panel → `POST /admin` → an event with `type: "admin"`.

Adding a command means touching four places:
- the `COMMANDS` entry in ArenaManager
- the `ADMIN_ACTIONS` whitelist in `canal.js`
- a button in `DevPanel`
- a button in `panel.html`

## Online mode (VPS, `online.js`)

- **Streamer flow.**
  1. Open `https://DOMAIN/` and log in with @user + password; the first time creates the account.
  2. Keep the tab open: the page connects to Tikfinity at `ws://localhost:21213` (changeable under "Avanzado") and relays `{t:"tf", m:<raw Tikfinity JSON>}` plus `{t:"estado", tikfinity}` heartbeats over `wss://DOMAIN/relay?key=`. Only gift/like/follow/social/roomUser/liveStatusChange and battle events are relayed; chat is not.
  3. Press "▶ ABRIR EL JUEGO" (`https://www.roblox.com/games/start?placeId=PLACE_ID&launchData={"t":token}`).
- **Accounts.** `datos_online/canales/<user>/cuenta.json`: scrypt password hash, `key` (panel, header `x-canal-key`), `token` (game, query `t=`) and `code` (6 digits, typed in-game). Each channel also has its `settings.json` and `batallas_capturadas.jsonl` there.
  - `POST /api/code/new` rotates the token and the code.
  - Rate limits: login, game link and admin commands are limited per IP or per user; the relay takes at most 300 msgs/s per channel.
  - One relay per channel: a new tab closes the old one with code 4000.
  - `POST /soporte/borrar` (header `x-admin-key` = `ADMIN_KEY`) deletes an account.
- **Game routes.** `GET /game/link?user=&code=` → `{token}`. With the token, `GET /game/pull?t=` (also returns `user`) and `GET`/`POST /game/settings?t=`.
- **Panel.** `GET /` serves `panel.html` with `"__ONLINE__"` replaced by `{placeId}`. That turns on the login overlay, the online bar (code, launch button, logout) and the relay code at the end of the script. The replacement hits the *first* occurrence, so never write that placeholder in a comment above it.
- **Roblox side.**
  - `Config.ONLINE_URL` (`""` = local bridge).
  - `ServerScriptService.Arena.Bridge` handles both modes. In online mode it waits for a channel token before polling. It uses `RequestAsync`. On 401 it unlinks, so the connect screen comes back. In published games it filters TikTok names and announce text with `TextService` (cached, in parallel, "Espectador" on failure; skipped in Studio).
  - `ServerScriptService.Arena.Online`: the first player is the server owner and gets `ArenaDev` (the place must use Max Players = 1). It links from `player:GetJoinData().LaunchData`, otherwise from DataStore `TrompaOnline_v1` (last link). It handles `DevCommand` `linkOnline {user, code}` / `unlinkOnline`.
  - `StarterPlayerScripts.OnlineConnect` is the "Conecta tu TikTok" screen (DisplayOrder 210). `ModeSelect` waits until `State.OnlineLinked`.
  - State attributes: `OnlineMode`, `OnlineUrl`, `OnlineLinked`, `OnlineUser`.
- **Deploy.** `vps/instalar.sh DOMAIN EMAIL` (Ubuntu): installs Node 20, rsyncs the app to `/opt/trompa` (keeping `datos_online/` and `online.env`), sets up the systemd service `trompa`, nginx (WebSocket upgrade, `proxy_read_timeout 3600s`), ufw and certbot. Re-run it to update. `.sh` files must stay LF (`.gitattributes`).
- **Local test.**
  1. Run `PORT=8080 DATA_DIR=<scratch> node online.js` and a fake Tikfinity `ws` server on 21299.
  2. Open `http://localhost:8080`, log in, and set "Avanzado" to `ws://localhost:21299/`.
  3. Set `Config.ONLINE_URL = "http://localhost:8080"` temporarily (Studio can reach localhost) and link in-game with the panel code.
  4. Revert `ONLINE_URL` to `""` afterwards.

## Roblox place layout (things that need several scripts to understand)

- **`ReplicatedStorage.Arena.Shared`** is the single source of truth for:
  - teams and their colors
  - the gift tables `GIFTS` / `GIFT_ORDER`, built at runtime by `Shared.applyGiftRoles` (see below)
  - the live-settings schema: `DEFAULT_SETTINGS`, `SETTING_LIMITS`, `SETTING_CHOICES` and `sanitizeSetting`
- **Editable gifts.** Which TikTok gift makes which fighter is chosen in the web panel ("🎁 Regalos de cada peleador"):
  - The pickable gifts are `regalos/catalogo.json` (the A Correr gifts that have a Roblox image; PNGs in `regalos/img/`, served at `/regalos/img`).
  - Roles: `hero1..5`, `villain1..5`, `rainGold`, `rainDark` (same order in `GIFT_ROLES` in `server.js` and `Shared.ROLES`). Each role holds up to 6 gifts, and a gift belongs to one role only.
  - `GET`/`POST /gifts/roles` read and save them as the `GiftRoles` setting (JSON of `{ role: [{id, name, image}] }`); empty means `Shared.DEFAULT_GIFT_ROLES` (mirrored by `DEFAULT_GIFT_ROLES` in `server.js`).
  - `Shared.applyGiftRoles` rebuilds `GIFTS`/`GIFT_ORDER` in place whenever `GiftRoles` changes and fires `Shared.giftsChanged`; ArenaHUD and DevPanel rebuild their gift panels on it. Tier stats per level are in `Shared.TIERS`.
- **Long string settings.** Strings are cut to 200 chars except those in `Shared.STRING_MAX` (`HudCustom`, `GiftRoles`), which must match `LONG_SETTINGS` in `server.js`.
- **Settings at runtime.** They live as attributes on `ReplicatedStorage.Arena.Settings`. Clients react through `AttributeChanged`. To add a setting, add its default (and limits) in Shared and read it where needed.
- **State.** `ReplicatedStorage.Arena.State` holds attributes for the dev panel's status tab: bridge/Tikfinity online, counts, avatars loaded.
- **`ServerScriptService.Arena`:**
  - `ArenaManager`: all game logic.
  - `Config`: constants, asset IDs, `BRIDGE_URL` / `BRIDGE_ACCESS_TOKEN`.
  - `Audio`: SoundGroups and one-shot sounds.
  - `Effects`: one-shot VFX are only forwarded to clients (`FxEvent("vfx", {name, args})`, nil args sent as `"__nil"`) and drawn by `ArenaVFX`. It still owns hand particles, fury fire, streak sparkles and `Effects.ragdoll` (K.O.). `teamAura` only sets the NPC attribute `Aura`.
  - `Environment`: lighting presets, stage lights, searchlights.
  - `Avatars`: preloads `Config.AVATAR_POOL` descriptions.
  - `Bridge`: HTTP polling and settings persistence.
- **`StarterPlayerScripts`:**
  - `ArenaHUD`: HUD plus overhead tags and floating popups.
  - HUD editor (inside `ArenaHUD`, dev only): every section (Title, Score, Likes, VillainGifts, HeroGifts, Queue, Top, Feed) can be clicked and dragged. A small panel bottom-right (collapsed until a section is picked) hides, shrinks, centers, pushes to the edge or resizes it. Offsets, scale and hidden flags are stored per layout (`H`/`V`) as JSON in the setting `HudCustom` (`Shared.STRING_MAX` allows 4000 chars). `layout` positions in `applyLayout` are the base; `applyCustom` adds the offsets on top. Vertical layout: gift lists as columns on each side, queue at the very bottom. Horizontal: small likes goal under the title.
  - `ArenaCamera`: Director, Orbita, General, Accion, Cenital, Cinematica and Libre modes; shake/flash/blur; occlusion avoidance.
  - `DevPanel`: on-screen pill bar bottom-left (🛠️ DEV, 🎥 CÁMARA, ⚡ ACCIONES) like "A Correr"; each opens an animated panel (one at a time). F2 toggles DEV, F3 hides the bar. The bar moves itself above HUD panels it would cover (e.g. the likes goal).
  - `FighterAnimator`: procedural boxing animation layered over the Animator in `PreSimulation` (same technique as A Correr's `RunnerAnimations`): guard + footwork, punches (`Shared.MOVES`), reactions, stun, victory, fist trails. Driven by the NPC attribute `Mode` (`enter | free | fight | dance | celebrate`) and `FxEvent("anim" | "hitstop")`.
  - `EntranceCinematics`: entrance cinematics (see below). Exposes nothing; it drives poses through the client-only BindableEvents `Arena.LocalAnim` (created by FighterAnimator) and `Arena.LocalVfx` (created by ArenaVFX).
  - `ArenaVFX`: client VFX (hits, super charge, K.O. blast, entrances, rains…) and tiered fighter auras computed from NPC attributes.
- **Participant lifecycle in ArenaManager:**
  - `participants` is keyed by the lowercase TikTok id.
  - `lineup` is the waiting order. Gift senders get `priority` and skip ahead.
  - The first waiters get an anchored NPC on a `Workspace.Espectadores` block, in the `WaitingFighters` folder.
  - Then they move to the ring in `ActiveFighters`, at most `MaxFighters`, spawning at `Ring.SpawnA1..B4`.
  - The NPC `Name` is the user key. Attributes (`DisplayName`, `Team`, `Health`, `MaxHealth`, `Energy`, `Streak`, `OpponentKey`…) drive all client UI.
  - `busy[npc]` holds the fighter state: `entering`, `match` or `celebrate`.
  - On K.O. the loser is re-parented to `Workspace.ArenaFX` so it stops counting immediately, then ragdolled (the R15 rig uses AnimationConstraints + BallSocketConstraints).
  - **Movement:** ring fighters walk with `Humanoid:MoveTo` and turn with an `AlignOrientation` named `Facing` on the root (`faceTowards`). Never set `root.CFrame` on them every tick: that teleport is what made walking look like flickering. Fight AI = footwork orbit + lunge on attack (`Config.FOOTWORK_*`, `LUNGE_*`). Free fighters wander, shadowbox and dance; with `SameTeamSparring` they spar teammates after `Config.SPAR_WAIT` if no rival is free or waiting (no team point).
- **Templates in ServerStorage:** `NPCDummy` (R15), `PuñoDorado` / `PuñoOscuro` (glove rain), `ParticulaAmarillaLVL1-4` / `ParticulaMoradaLVL1-4` (hand particles).
- **Originals:** the pre-remodel scripts are in `ServerStorage.Backup_Original_v1` and in `backup_original/` here. The scripts before the combat/animation rework (2026-10-01) are in `ServerStorage.Backup_v2_AntesCombate`; before the entrance cinematics / no-chat change, in `ServerStorage.Backup_v3_AntesCinematicas`.

## Entrance cinematics (Élite / Definitivo)

- `rec.giftLevel` = highest gift level the viewer sent. On entering the ring, `spawnFighter` picks `entranceKind`: level ≥ `Config.DEFINITIVE_ENTRANCE_LEVEL` (5) → `definitive`, ≥ `Config.ELITE_ENTRANCE_LEVEL` (3, so Élite and Legendario) → `elite`, else the normal entrance.
- Fighters already in the ring also get it: when a gift raises their tier, `handleGift` calls `replayEntrance` (same cinematic on the existing NPC; their duel resumes afterwards). `rec.shownEntrance` + `KIND_RANK` make it play once per tier (Élite, then Definitivo).
- One cinematic at a time (`cinematicRunning`; waiting ones count in `pendingEntrances` so `fillRing` doesn't overfill). The NPC is dressed hidden 150 studs below, then its root is **anchored** at the start point and the server fires `FxEvent("cinematic", {kind, target, team, name, from, mid, to, facing, rootHeight, duration})`. Each client moves the anchored root locally (60 FPS) and fires poses/VFX on the same clock; `ArenaCamera` plays the shots. At the end the server sets the final CFrame and unanchors.
- **Game pause:** `cinematicUntil` / `inCinematic()`. Duels freeze (no moves, no hits, match clock stops), no pairing/filling, idle fighters stop, glove rains wait. `State.CinematicActive` + `CinematicTarget` make `FighterAnimator` freeze every other rig. The HUD is hidden and letterbox bars + a name banner are shown.
- Timings live in three places and must match: `CINEMATIC_DURATION`/`CINEMATIC_SOUNDS` (ArenaManager), the `eliteEvents`/`definitiveEvents` + `PATHS` (EntranceCinematics) and `cinematicFrame` (ArenaCamera).
- Test: dev panel → Eventos / ⚡ ACCIONES → 🎬 Entrada Élite / Definitiva (`testEntrance {kind}`), also in panel.html. `screen_capture` latency is irregular: poll `State.CinematicActive` from the Client datamodel, wait the wanted seconds, then capture.
- The camera occlusion raycast must ignore `Workspace.ArenaVFXLocal` (client VFX), or ground cracks pull the camera onto the fighter.

## Battle mode (TikTok live battles between two streamers)

- **Mode.** Setting `GameMode` = `Solo` | `Batalla`. `StarterPlayerScripts.ModeSelect` shows a start menu to the streamer (ArenaDev only) and auto-picks the saved mode after 20 s. Also switchable in the dev panel (⚔ Batalla tab) and panel.html. Each streamer runs their own game + bridge; no network sync is needed because TikTok gives both rooms the same battle points.
- **Bridge (`batalla.js`).** Tikfinity events `linkMicBattle` (start), `linkMicArmies` (points per host) and `linkMicBattlePunishFinish` (end) become game events `battleStart {id, me, rival, duration}`, `battlePoints {id, me, rival}` (running totals) and `battleEnd {id, me, rival, winner}`. Both known payload shapes are parsed (TikTok-Live-Connector 1.x `battleUsers`/`battleArmies`, and `anchorInfo`/`battleItems`/`battleGroups`). End = `battleStatus` changes, punish-finish, `battleSetting.duration` elapsed, a 6 min fallback, or `POST /battle/end`.
  - "Me" = setting `BattleMe` (@user), else the `receiverUserId` of this room's gifts, else the first host. `BattleSwap` flips sides.
  - **The real payload format is unverified.** Every battle event is also appended raw to `batallas_capturadas.jsonl` (max 5 MB), and new Tikfinity event names are logged once. Check that file after the first real battle and adjust `batalla.js`.
  - Test without a live: `POST /battle/sim {action: start|points|end, side, amount}` (fake 1.x-shaped messages through the same parser), `GET /battle/status`, panel.html card "⚔️ Modo batalla".
- **Game (`ArenaManager`, section `MODO BATALLA`).** Everything lives in the `Battle` table, because the script is close to Luau's 200-local limit (~165 top-level locals). Don't add new top-level locals there; add fields to `Battle` instead.
  - `Battle.start` clears the ring (fighters go back to the front of the lineup), spawns two champions (`BattleFighter` attribute, `busy = "battle"`; me = hero/gold, rival = villain/purple) and pauses normal pairing and filling while `Battle.current` exists.
  - Point deltas queue hits (`Battle.strike`). Damage never takes a champion below `Battle.MIN_HEALTH` (8%) before the end.
  - Power levels at `POWER_STEPS` (100/1k/5k/20k) raise `DamageMultiplier` (bigger client aura) and add Fire/Smoke instances.
  - This room's gifts during a battle are special attacks for "me" (`Battle.gift`, before `handleGift`). The attack is picked by the gift's level in the gift editor, or by coins if the gift has no role. Their points are absorbed so they don't hit twice.
  - `Battle.ended` → `Battle.runFinish`: both roots are anchored and `FxEvent("finisher", {winner, loser, from, to, loserAt, facing, rootHeight, duration, impact})` is fired. `EntranceCinematics` draws the letterbox, banner and the winner's dash (moved locally); `ArenaCamera.finisherFrame` plays the shots. At `FINISHER_IMPACT` the loser is unanchored, `SetNetworkOwner(nil)`, `knockOut`, and **every BasePart** gets a launch velocity: after unanchoring, Roblox handed it to the client and impulses on the root alone did nothing. Timings must match in those three scripts.
  - Tie: no KO. After the end, `Battle.finish` fades the champions out and normal play resumes.
- **HUD.** In Batalla mode ArenaHUD hides all its sections, its toasts, its announces during an active battle and the `ArenaHudEditor` gui. `StarterPlayerScripts.BattleHUD` (ScreenGui `ArenaBattleHUD`, DisplayOrder 11) takes over:
  - Battle bar: crests, counting points, tug bar with a clash spark, a timer ring of 40 dots (countdown if TikTok gave a duration, elapsed time otherwise), power pips, combos, a crown for the leader, and a "¡REMONTADA!" callout.
  - Guide (¿CÓMO AYUDAR?), the special-attacks list (built from the `Shared.GIFTS` levels), crowd energy, MVP (top 3 donors of this battle), event cards, the VS splash, the last-15 s banner, a 5→1 countdown and the result screen.
  - Lobby panel when there is no battle.
  - Columns switch to a compact one-phrase layout in vertical (`Guide.setCompact`, `Attacks.setCompact`).
  - It hides itself while `State.CinematicActive` or `State.BattleFinisher` is set.
  - Data: `hud("battle", Battle.payload())` (+ snapshot) and `hud("battleEvent", {kind = intro|special|gift|power|likes|crowd|follow})`.
  - Shared constants: `Shared.BATTLE` (POWER_STEPS, ATTACKS names/emojis, COIN_LEVELS, FOLLOW_HEAL).
  - The Gotham font has no "➜" glyph (it renders as a box); use "→".
- **Likes and follows in a battle.** Likes also fill `b.crowd`; every `BattleLikeGoal` likes (setting, default 300) queue the `crowd` special ("¡GOLPE DEL PÚBLICO!") for "me". A follow heals "me" by `FOLLOW_HEAL` (10%). Neither gives TikTok points, so neither changes the winner.
- To check the vertical battle HUD in a landscape Studio view, force `ArenaBattleHUD.Root` to 1080x1920 at scale `viewport.Y / 1920`, the same trick as for ArenaHUD.
- **Test commands:** `simBattleStart`, `simBattlePoints {side, amount}`, `simBattleGift {level 1–6}`, `simBattleEnd {winner?}` / `endBattle` (dev panel ⚔ Batalla tab, ⚡ ACCIONES, panel.html).
- `screen_capture` coordinates are the screenshot's (scaled); `user_mouse_input` uses GUI `AbsolutePosition` coordinates (e.g. viewport 1163×672 vs capture 1454×840).

## Constraints and gotchas

- **Place properties.** `Workspace.StreamingEnabled` must stay `false` and `Players.CharacterAutoLoads` `false`. The streamer has no character, so with streaming the client would not receive the ring or the NPCs.
- **Head replacement.** `Humanoid:ApplyDescription` replaces the NPC's `Head`. Client tags must re-bind on `ChildAdded`, which `bindHead` in ArenaHUD does.
- **Bridge token.** `Config.BRIDGE_ACCESS_TOKEN` stays `""`: the game gets the token from the bridge's `/handshake` (see "Token flow"). Never write the real token anywhere. For integration tests run the bridge on another port with a throwaway `ACCESS_TOKEN`, point `Config.BRIDGE_URL` at it temporarily, and revert it afterwards. Port 3000 is sometimes taken by another project's `node server.js` (answers 404): check before debugging "bridge offline".
- **Vertical HUD.** The vertical layout is a 1080x1920 virtual canvas scaled to the screen width, so text that looks fine at 1920 wide is small. `textBoost()` (1.3 in vertical) enlarges overhead tags, popups, icons and alerts; `DEFAULT_SCALE.V`, `styleScore` and the toast `UIScale` enlarge HUD sections. The big announce sits below the gift columns. To check a vertical layout in a landscape Studio window, set `HudLayout = Vertical` on the server, then in the client force `Root.UIScale.Scale = viewport.Y / 1920`, `Root.Size = (1080, 1920)`, anchor/position it centered and `ClipsDescendants = true`.
- **HTTP.** `HttpService` calls to `localhost` only work when playing in Studio, which is how the stream runs.
- **Highlights.** Roblox renders at most 31 Highlights at once, so team auras are only used on ring fighters.

## Testing the game through Studio MCP

- Start play, then fire commands from the **Client** datamodel:

  ```lua
  game.ReplicatedStorage.Arena.Remotes.DevCommand:FireServer("simBots", {count = 12})
  ```

  Other useful ones: `simGift {name, giftId, count}`, `simLikes`, `rain {kind}`, `setSetting {key, value}`.
- Inspect the **Server** datamodel for state.
- **`screen_capture` limits.** It does not render BillboardGuis, so overhead HP bars and damage popups never appear in captures; verify them by properties or ask the user. Captures also arrive a few seconds late, so short-lived announcements may already be gone.
- **Checking poses.** Set the NPC attribute `DebugPose` (`"guard"`, `"jab:0.17"`, `"superUpper:0.66"`, `"victory:0.8:2"`…) from the Client datamodel. To aim the camera yourself, run `RunService:UnbindFromRenderStep("ArenaCamera")` on the client and set `CurrentCamera.CFrame` (restart Play to get the director camera back). Anchor the NPC's root on the server so it holds still.
- **Particle textures.** Built-in `rbxasset://textures/particles/` files that render as particles: `sparkles_main`, `explosion01_core_main` (orange fire), `fire_main` (wispy smoke), `smoke_main` (soft tintable glow), `explosion01_shockwave_main`. `fire_sparks_main` and `forcefield_glow_main` render nothing.
- **Portrait HUD.** Set the custom device "TikTok Vertical 1080x1920" in `StudioDeviceSimulatorService` while in Edit mode, then set Portrait orientation, then play.
