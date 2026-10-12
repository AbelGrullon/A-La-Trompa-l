# ¡A la trompa! ONLINE — guía de instalación

Con el modo online los streamers **no instalan nada**: solo Tikfinity y un enlace.

**Para el streamer:**

1. Abre **Tikfinity** y lo conecta a su directo.
2. Entra en `https://TU-DOMINIO`, escribe su **@usuario de TikTok** y una contraseña. La primera vez se crea la cuenta.
3. Pulsa **▶ ABRIR EL JUEGO**. El juego de Roblox se conecta solo.
4. Deja esa pestaña del navegador abierta durante el directo: es la que lleva los regalos, likes y batallas de su Tikfinity al juego.

Si entra al juego por otro camino, el juego le pide su @usuario y el **código de 6 cifras** que sale en el panel. La siguiente vez lo recuerda.

**Cómo funciona por dentro:** la página del panel corre en el PC del streamer, junto a Tikfinity. Lee Tikfinity (que solo atiende a programas de ese mismo PC) y reenvía los eventos al servidor del VPS. El juego, publicado en Roblox, le pide los eventos a ese servidor.

---

## 1. El VPS (Contabo)

- Con el plan más pequeño (Cloud VPS S) sobra.
- Sistema: **Ubuntu 22.04 o 24.04**.
- Apunta la **IP** y la **contraseña de root** que te dan.

## 2. El dominio

Roblox y los navegadores necesitan **HTTPS**, así que hace falta un nombre, no solo la IP.

- **Si tienes dominio:** crea un registro **A**, por ejemplo `trompa.tudominio.com`, apuntando a la IP del VPS.
- **Gratis:** en [duckdns.org](https://www.duckdns.org) creas `algo.duckdns.org` y le pones la IP del VPS.

Espera unos minutos a que el nombre funcione. Para comprobarlo: `ping trompa.tudominio.com` debe responder la IP del VPS.

## 3. Subir el proyecto e instalar

Desde PowerShell en tu PC, en la carpeta `proyecto TIKTOK`:

```powershell
scp -r "A La Trompa" root@IP_DEL_VPS:/root/trompa
```

Luego entra al VPS y ejecuta el instalador:

```bash
ssh root@IP_DEL_VPS
bash /root/trompa/vps/instalar.sh trompa.tudominio.com tu@correo.com
```

El instalador hace todo:

- instala Node.js, nginx con HTTPS (Let's Encrypt) y el firewall;
- crea el servicio `trompa`, que arranca solo y se reinicia si falla.

Al terminar muestra la **clave de soporte** (`ADMIN_KEY`): guárdala.

Para comprobar que funciona: abre `https://trompa.tudominio.com` y debe salir la pantalla **CONECTAR**.

## 3 (bis). Si tu VPS es Windows Server

En vez de los pasos de Ubuntu del punto 3, usa `vps\instalar_windows.ps1`. Instala:

- **Node.js**;
- **Caddy**, que pone el HTTPS gratis automáticamente;
- las reglas del firewall de Windows;
- dos tareas programadas que arrancan todo al encender el servidor y lo reinician si se cierra.

**1. En tu PC**, empaqueta la carpeta en un zip en el Escritorio (sin tus archivos privados):

```powershell
$esc = [Environment]::GetFolderPath('Desktop'); $tmp = Join-Path $env:TEMP 'trompa_paquete\A La Trompa'; robocopy "$esc\proyecto TIKTOK\A La Trompa" $tmp /E /XD node_modules .git juego backup_original datos_online /XF .env settings.json *.jsonl /NFL /NDL /NJH /NJS; Compress-Archive -Path $tmp -DestinationPath "$esc\trompa.zip" -Force
```

**2. Conéctate al VPS** con *Conexión a Escritorio remoto* (`mstsc`), con la IP y el usuario/contraseña de Contabo.

**3. Pasa el zip.** Copia `trompa.zip` en tu PC y pégalo en el Escritorio del VPS (Ctrl+C / Ctrl+V funciona a través del escritorio remoto). Después, en el VPS: clic derecho → *Extraer todo…*

**4. Instala.** En el VPS abre **PowerShell como administrador** (clic derecho → *Ejecutar como administrador*) y lanza el instalador. Cambia la ruta si lo extrajiste en otro sitio:

```powershell
powershell -ExecutionPolicy Bypass -File "$([Environment]::GetFolderPath('Desktop'))\trompa\A La Trompa\vps\instalar_windows.ps1" -Dominio alatrompa.duckdns.org -Correo tu@correo.com
```

Al terminar dice si el servidor y el HTTPS responden, y muestra la **ADMIN_KEY** (guárdala).

**Si el VPS ya tiene otra web con Caddy** (por ejemplo `vensacatelo.com`), el instalador no pone un segundo Caddy, sino que **añade el dominio del juego al Caddy que ya tienes**:

- antes hace una copia de seguridad de tu Caddyfile (`Caddyfile.antes-trompa-FECHA`);
- valida la configuración nueva;
- comprueba que sigan todas las webs que Caddy sirve ahora;
- y la recarga sin cortar tu web.

Si algo no cuadra, deja tu Caddyfile como estaba y te dice qué añadir a mano. Si el puerto 8080 lo usa tu otra web, el juego usa otro puerto libre (18080…).

**Si el instalador dice que el puerto 80 está ocupado por IIS**, desactívalo y vuelve a lanzar el instalador:

```powershell
Stop-Service W3SVC; Set-Service W3SVC -StartupType Disabled
```

**Día a día en Windows Server:**

- Logs: `C:\trompa\logs\servidor.log` y `C:\trompa\logs\caddy.log`.
- Reiniciar: en el *Programador de tareas*, tareas **Trompa Servidor** y **Trompa HTTPS**. O reinicia el VPS.
- Actualizar: copia el zip nuevo, extráelo y vuelve a lanzar el instalador. Las cuentas de los streamers (`C:\trompa\datos_online`) no se tocan.
- La clave de soporte está en `C:\trompa\online.env`.

## 4. El juego en Roblox Studio

1. En `ServerScriptService → Arena → Config` pon tu dirección:
   ```lua
   ONLINE_URL = "https://trompa.tudominio.com",
   ```
   Si la dejas vacía (`""`), el juego sigue usando el bridge local de tu PC, como hasta ahora.
2. En **Game Settings → Security**, activa **Allow HTTP Requests**.
3. Si quieres probar en Studio que recuerda el enlace, activa también **Enable Studio Access to API Services**.
4. **Un streamer por servidor:** en el Creator Dashboard (o Game Settings → Places), pon **Max Players = 1**. Así cada streamer tiene su propia arena.
5. **Publica** el juego y hazlo **público**: el botón "Abrir el juego" lo abre por su número (`PLACE_ID`).

Si el número del juego cambia, ponlo en `online.env` del VPS (`PLACE_ID=...`) y reinicia con `systemctl restart trompa`.

## 5. Día a día

- **Ver lo que pasa:** `journalctl -u trompa -f`
- **Actualizar** después de cambiar archivos: vuelve a subir la carpeta con `scp` y ejecuta otra vez `bash /root/trompa/vps/instalar.sh trompa.tudominio.com tu@correo.com`. Las cuentas y ajustes de los streamers no se tocan.
- **Alguien olvidó su contraseña:** borra su cuenta y que entre de nuevo con una contraseña nueva. Perderá sus ajustes.
  ```bash
  curl -X POST https://trompa.tudominio.com/soporte/borrar \
    -H "x-admin-key: TU_ADMIN_KEY" -H "Content-Type: application/json" \
    -d '{"user":"nombre_de_usuario"}'
  ```
- **Batallas reales:** lo que Tikfinity manda de cada batalla se guarda en `/opt/trompa/datos_online/canales/<usuario>/batallas_capturadas.jsonl`. Sirve para ajustar el lector de batallas si algo no cuadra.

## Avisos

- La primera vez, **Chrome puede pedir permiso** para "acceder a dispositivos de tu red local". Hay que pulsar **Permitir**: es para leer Tikfinity en el propio PC.
- El panel avisa si el streamer intenta cerrar la pestaña en pleno directo.
- Si abre el panel en dos pestañas, la nueva sustituye a la vieja.
- **Código nuevo** (botón en el panel): el código y el enlace anteriores dejan de valer, y el juego vuelve a pedir conectarse.
- En el juego publicado, los nombres de TikTok pasan por el **filtro de texto de Roblox** antes de mostrarse.
