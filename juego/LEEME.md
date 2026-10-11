# Código del juego (copia exportada)

Esta carpeta es una **copia** de los scripts del place de Roblox "¡A la trompa!" (placeId 77774451323374), exportada para tener historial en git.

**El juego de verdad vive dentro del place en Roblox Studio.** Cambiar estos archivos NO cambia el juego: los cambios se hacen en Studio y después se vuelve a exportar esta copia.

Nombres de los archivos (convención de Rojo):

- `*.server.lua`: Script (servidor)
- `*.client.lua`: LocalScript (cliente)
- `*.lua`: ModuleScript

Las carpetas siguen la jerarquía del place: `ServerScriptService/Arena/...`, `ReplicatedStorage/Arena/...` y `StarterPlayer/StarterPlayerScripts/...`.

No se incluyen:

- los scripts de Roblox por defecto (`PlayerModule`, `RbxCharacterSounds`, `Animate`);
- las copias de seguridad de `ServerStorage`.

La luz parpadeante (`Workspace/Iluminacion`) está repetida 4 veces en el place y aquí se guarda una sola vez.
