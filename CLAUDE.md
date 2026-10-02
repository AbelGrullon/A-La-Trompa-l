# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"¡A la trompa!" is an automatic boxing arena for TikTok lives. Viewers never touch Roblox. The game works **only with gifts, likes and follows** (the TikTok chat and shares are deliberately ignored since 2026-10-01). It turns those into fighters, named after their TikTok name, with an avatar picked by hashing the name. The fighters battle on their own while the streamer captures the Roblox window.

The project has two halves:

1. **This folder:** a Node "bridge" (`server.js` + `panel.html`). It reads the live from **Tikfinity Desktop**'s local WebSocket (`ws://127.0.0.1:21213`) and exposes the events over HTTP.
2. **The Roblox place** "A la trompa!" (placeId 77774451323374). **All game code lives only inside the place in Roblox Studio.** There are no `.lua` source files here, and Rojo is not used even though the plugin is installed. Read and edit it with the Roblox Studio MCP tools (`script_read`, `multi_edit`, `execute_luau`, `start_stop_play`, `get_console_output`, `screen_capture`). Changes only persist once the user saves or publishes the place in Studio.

All comments, logs and UI text are in Spanish. Keep it that way.

## Commands

```bash
npm install
npm start            # node server.js → http://localhost:3000/panel (INICIAR_BRIDGE.bat does the same)
npm run token        # change the saved token (CAMBIAR_TOKEN.bat)
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
Tikfinity WS → server.js handlers → events[] queue
   → Roblox Bridge module polls GET /events/pull every 1 s
   → ArenaManager.handleEvent (gift | like | follow | viewers | admin)
   → server state + HudEvent / FxEvent remotes → ArenaHUD / ArenaCamera on the client
```

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
- the `ADMIN_ACTIONS` whitelist in `server.js`
- a button in `DevPanel`
- a button in `panel.html`

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
