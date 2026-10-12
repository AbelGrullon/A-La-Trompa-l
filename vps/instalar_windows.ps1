# Instala (o actualiza) ¡A la trompa! ONLINE en un VPS con Windows Server.
#
# Uso: PowerShell COMO ADMINISTRADOR, en el VPS, con la carpeta "A La Trompa"
# ya copiada (por ejemplo al Escritorio):
#   powershell -ExecutionPolicy Bypass -File "C:\Users\Administrator\Desktop\A La Trompa\vps\instalar_windows.ps1" -Dominio alatrompa.duckdns.org -Correo tu@correo.com
#
# Hace todo:
#   • Node.js 20 (si no está)
#   • copia la app a C:\trompa (las cuentas de los streamers en datos_online\ y
#     online.env no se tocan al actualizar)
#   • HTTPS gratis (Let's Encrypt) con Caddy. Si este VPS YA tiene un Caddy
#     (por ejemplo, el de otra web), le añade el dominio del juego con copia
#     de seguridad, validación y recarga sin cortar la otra web. Si no, instala
#     uno propio en C:\trompa-caddy y abre los puertos 80 y 443.
#   • si el puerto 8080 está ocupado por otro programa, usa uno libre (18080…)
#   • tareas programadas que arrancan solas al encender el VPS y se reinician
#     si se cierran: "Trompa Servidor" (y "Trompa HTTPS" si el Caddy es propio)
# Se puede volver a ejecutar para actualizar.
param(
	[Parameter(Mandatory = $true)][string]$Dominio,
	[Parameter(Mandatory = $true)][string]$Correo
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue' # (las descargas van mucho más rápido sin barra)

$app = 'C:\trompa'
$caddyDir = 'C:\trompa-caddy'
$origen = Split-Path -Parent $PSScriptRoot

function Paso($texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
	throw 'Abre PowerShell como Administrador (clic derecho → Ejecutar como administrador) y vuelve a lanzarlo.'
}
if (-not (Test-Path (Join-Path $origen 'online.js'))) {
	throw "No encuentro online.js en $origen. Lanza este script desde la carpeta vps de 'A La Trompa'."
}

# ----- Node.js -----
Paso 'Node.js'
function Refrescar-Path {
	$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}
Refrescar-Path
$nodeOk = $false
if (Get-Command node -ErrorAction SilentlyContinue) {
	$version = [int]((node -v).TrimStart('v').Split('.')[0])
	$nodeOk = $version -ge 18
}
if (-not $nodeOk) {
	$sumas = (Invoke-WebRequest -UseBasicParsing 'https://nodejs.org/dist/latest-v20.x/SHASUMS256.txt').Content
	$msi = ([regex]::Match($sumas, 'node-v[\d.]+-x64\.msi')).Value
	if (-not $msi) { throw 'No se encontró el instalador de Node.js' }
	$destino = Join-Path $env:TEMP $msi
	Write-Host "Descargando $msi..."
	Invoke-WebRequest -UseBasicParsing "https://nodejs.org/dist/latest-v20.x/$msi" -OutFile $destino
	Start-Process msiexec.exe -Wait -ArgumentList "/i `"$destino`" /qn /norestart"
	Refrescar-Path
}
Write-Host "Node $(node -v)"

# ----- parar lo que esté corriendo (al actualizar) -----
Paso 'Parando la versión anterior (si había)'
foreach ($tarea in 'Trompa Servidor', 'Trompa HTTPS') {
	if (Get-ScheduledTask -TaskName $tarea -ErrorAction SilentlyContinue) {
		Stop-ScheduledTask -TaskName $tarea -ErrorAction SilentlyContinue
	}
}
Get-CimInstance Win32_Process | Where-Object {
	($_.Name -eq 'node.exe' -and $_.CommandLine -like '*online.js*') -or
	($_.Name -eq 'caddy.exe' -and $_.ExecutablePath -like "$caddyDir*") -or
	($_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*servicio_windows.ps1*')
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# ----- archivos -----
Paso "Copiando la app a $app"
New-Item -ItemType Directory -Force -Path $app | Out-Null
robocopy $origen $app /MIR /NFL /NDL /NJH /NJS /NP `
	/XD node_modules .git datos_online logs juego backup_original `
	/XF online.env .env settings.json *.jsonl | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy falló (código $LASTEXITCODE)" }
Push-Location $app
try {
	cmd /c 'npm ci --omit=dev || npm install --omit=dev'
	if ($LASTEXITCODE -ne 0) { throw 'npm install falló' }
} finally {
	Pop-Location
}
$envFile = Join-Path $app 'online.env'
if (-not (Test-Path $envFile)) {
	$bytes = New-Object byte[] 24
	[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
	$clave = -join ($bytes | ForEach-Object { $_.ToString('x2') })
	$texto = (Get-Content -Raw (Join-Path $app 'online.env.example')) -replace '(?m)^ADMIN_KEY=.*$', "ADMIN_KEY=$clave"
	[IO.File]::WriteAllText($envFile, $texto, (New-Object Text.UTF8Encoding $false))
}
New-Item -ItemType Directory -Force -Path (Join-Path $app 'datos_online'), (Join-Path $app 'logs') | Out-Null

# ----- puerto interno del servidor -----
# (si 8080 ya lo usa otra cosa de este VPS, por ejemplo otra web, se busca uno libre)
Paso 'Puerto interno'
$lineaPuerto = Select-String -Path $envFile -Pattern '^PORT=(\d+)' | Select-Object -First 1
$puertoApp = if ($lineaPuerto) { [int]$lineaPuerto.Matches[0].Groups[1].Value } else { 8080 }
if (Get-NetTCPConnection -State Listen -LocalPort $puertoApp -ErrorAction SilentlyContinue) {
	$libre = 18080..18150 | Where-Object { -not (Get-NetTCPConnection -State Listen -LocalPort $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
	if (-not $libre) { throw 'No hay ningún puerto libre entre 18080 y 18150' }
	Write-Host "El puerto $puertoApp ya lo usa otro programa de este VPS: uso el $libre"
	$puertoApp = $libre
	$texto = Get-Content -Raw $envFile
	$texto = if ($texto -match '(?m)^PORT=') { $texto -replace '(?m)^PORT=.*$', "PORT=$puertoApp" } else { "PORT=$puertoApp`r`n" + $texto }
	[IO.File]::WriteAllText($envFile, $texto, (New-Object Text.UTF8Encoding $false))
}
Write-Host "Servidor en 127.0.0.1:$puertoApp"

# ----- HTTPS (Caddy) -----
# Si este VPS ya tiene un Caddy sirviendo otra web, se le AÑADE el dominio del
# juego (con copia de seguridad, validación y recarga sin cortar la otra web).
# Si no hay nada en los puertos 80/443, se instala un Caddy propio.
Paso 'HTTPS (Caddy)'
$bloque = "$Dominio {`r`n`treverse_proxy 127.0.0.1:$puertoApp`r`n}"
$ocupante = $null
foreach ($puerto in 443, 80) {
	$conexion = Get-NetTCPConnection -State Listen -LocalPort $puerto -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($conexion) {
		$ocupante = Get-CimInstance Win32_Process -Filter "ProcessId=$($conexion.OwningProcess)"
		break
	}
}

function Caddy-Cmd($exe, $argumentos) {
	# (cmd devuelve el texto tal cual; PowerShell 5.1 trataría lo que Caddy escribe en stderr como error)
	$salida = cmd /c "`"$exe`" $argumentos 2>&1"
	return @{ codigo = $LASTEXITCODE; texto = ($salida | Out-String) }
}

$caddyPropio = $true
$integradoEn = $null
if ($ocupante) {
	if ($ocupante.Name -ne 'caddy.exe') {
		throw "Los puertos web (80/443) los usa '$($ocupante.Name)'. Si es IIS (System), desactívalo: Stop-Service W3SVC; Set-Service W3SVC -StartupType Disabled. Si es otro programa, avísame."
	}
	$caddyPropio = $false
	$exeAjeno = $ocupante.ExecutablePath
	Write-Host "Este VPS ya tiene Caddy ($exeAjeno): le añado $Dominio sin tocar lo demás."
	# su archivo de configuración: el --config de su línea de comandos, o el Caddyfile junto al programa
	$config = $null
	$m = [regex]::Match([string]$ocupante.CommandLine, '--config(?:\s+|=)("([^"]+)"|(\S+))')
	if ($m.Success) { $config = if ($m.Groups[2].Value) { $m.Groups[2].Value } else { $m.Groups[3].Value } }
	if ($config -and -not [IO.Path]::IsPathRooted($config)) { $config = Join-Path (Split-Path $exeAjeno) $config }
	if (-not $config -or -not (Test-Path $config)) {
		$junto = Join-Path (Split-Path $exeAjeno) 'Caddyfile'
		if (Test-Path $junto) { $config = $junto } else { $config = $null }
	}
	if (-not $config) {
		Write-Warning "No encontré el archivo de configuración de tu Caddy. Añádele esto a mano y recárgalo:`n$bloque"
	} elseif ([IO.Path]::GetExtension($config) -eq '.json') {
		Write-Warning "Tu Caddy usa configuración JSON ($config). Añade a mano un sitio para $Dominio que haga reverse_proxy a 127.0.0.1:$puertoApp."
	} else {
		$contenido = Get-Content -Raw $config
		if ($contenido -match [regex]::Escape($Dominio)) {
			# ya estaba (una instalación anterior): se actualiza el puerto por si cambió
			$nuevo = [regex]::Replace($contenido, '(?s)(' + [regex]::Escape($Dominio) + '\s*\{\s*reverse_proxy\s+127\.0\.0\.1:)\d+', '${1}' + $puertoApp)
		} else {
			$nuevo = $contenido.TrimEnd() + "`r`n`r`n# ¡A la trompa! (servidor online del juego, añadido por instalar_windows.ps1)`r`n$bloque`r`n"
		}
		if ($nuevo -ne $contenido) {
			$copia = "$config.antes-trompa-$(Get-Date -Format yyyyMMdd-HHmmss)"
			Copy-Item $config $copia
			[IO.File]::WriteAllText($config, $nuevo, (New-Object Text.UTF8Encoding $false))
			$validacion = Caddy-Cmd $exeAjeno "validate --config `"$config`" --adapter caddyfile"
			if ($validacion.codigo -ne 0) {
				Copy-Item $copia $config -Force
				throw "La configuración nueva de Caddy no es válida: dejé tu Caddyfile como estaba.`n$($validacion.texto)"
			}
			# Seguridad: el archivo nuevo debe seguir teniendo TODAS las webs que tu Caddy
			# sirve ahora mismo (por si el Caddyfile encontrado no fuera el que está usando)
			$vivo = $null
			try { $vivo = (Invoke-WebRequest -UseBasicParsing 'http://localhost:2019/config/' -TimeoutSec 5).Content } catch {}
			if (-not $vivo) {
				Copy-Item $copia $config -Force
				throw "No pude hablar con tu Caddy (su API en localhost:2019). No toqué nada. Añade esto a mano a tu Caddyfile y reinicia tu Caddy:`n$bloque"
			}
			$adaptado = Caddy-Cmd $exeAjeno "adapt --config `"$config`" --adapter caddyfile"
			$hostsDe = {
				param($json)
				[regex]::Matches([string]$json, '"host"\s*:\s*\[([^\]]*)\]') | ForEach-Object {
					[regex]::Matches($_.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.ToLower() }
				} | Sort-Object -Unique
			}
			$faltan = @(& $hostsDe $vivo | Where-Object { $_ -notin @(& $hostsDe $adaptado.texto) })
			if ($faltan.Count -gt 0) {
				Copy-Item $copia $config -Force
				throw "El Caddyfile que encontré ($config) no parece ser el que usa tu Caddy ahora (faltarían: $($faltan -join ', ')). No toqué nada. Dime dónde está tu Caddyfile o añade esto a mano:`n$bloque"
			}
			$recarga = Caddy-Cmd $exeAjeno "reload --config `"$config`" --adapter caddyfile"
			if ($recarga.codigo -ne 0) {
				Copy-Item $copia $config -Force
				throw "Caddy no aceptó la recarga: dejé tu Caddyfile como estaba (tu web sigue igual).`n$($recarga.texto)"
			}
			Write-Host "Listo: $Dominio añadido a $config (copia de antes: $copia)"
		} else {
			Write-Host "Tu Caddy ya tenía $Dominio apuntando al puerto $puertoApp"
		}
		$integradoEn = $config
	}
	# (el Caddy propio no hace falta: se quita si se había descargado)
	if (Get-ScheduledTask -TaskName 'Trompa HTTPS' -ErrorAction SilentlyContinue) {
		Unregister-ScheduledTask -TaskName 'Trompa HTTPS' -Confirm:$false
	}
	Remove-Item -Recurse -Force $caddyDir -ErrorAction SilentlyContinue
} else {
	New-Item -ItemType Directory -Force -Path $caddyDir | Out-Null
	$caddyExe = Join-Path $caddyDir 'caddy.exe'
	if (-not (Test-Path $caddyExe)) {
		Write-Host 'Descargando Caddy...'
		Invoke-WebRequest -UseBasicParsing 'https://caddyserver.com/api/download?os=windows&arch=amd64' -OutFile $caddyExe
	}
	$version = Caddy-Cmd $caddyExe 'version'
	if ($version.codigo -ne 0) {
		Remove-Item -Force $caddyExe -ErrorAction SilentlyContinue
		throw 'La descarga de Caddy salió mal. Vuelve a lanzar el instalador.'
	}
	Write-Host "Caddy propio: $($version.texto.Trim())"
	$caddyfile = "{`r`n`temail $Correo`r`n}`r`n`r`n$bloque`r`n"
	[IO.File]::WriteAllText((Join-Path $caddyDir 'Caddyfile'), $caddyfile, (New-Object Text.UTF8Encoding $false))

	Paso 'Firewall de Windows (puertos 80 y 443)'
	foreach ($puerto in 80, 443) {
		$nombre = "Trompa HTTP $puerto"
		if (-not (Get-NetFirewallRule -DisplayName $nombre -ErrorAction SilentlyContinue)) {
			New-NetFirewallRule -DisplayName $nombre -Direction Inbound -Protocol TCP -LocalPort $puerto -Action Allow | Out-Null
		}
	}
}

# ----- tareas programadas (arrancan al encender y se reinician solas) -----
Paso 'Tareas que arrancan solas'
$ajustes = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$disparador = New-ScheduledTaskTrigger -AtStartup
$script = Join-Path $app 'vps\servicio_windows.ps1'
$tareas = @(, @('Trompa Servidor', 'servidor'))
if ($caddyPropio) { $tareas += , @('Trompa HTTPS', 'caddy') }
foreach ($par in $tareas) {
	$accion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Que $($par[1])"
	Register-ScheduledTask -TaskName $par[0] -Action $accion -Trigger $disparador -Settings $ajustes -Principal $principal -Force | Out-Null
	Start-ScheduledTask -TaskName $par[0]
}

# ----- comprobar -----
Paso 'Comprobando'
$okLocal = $false
for ($i = 0; $i -lt 20 -and -not $okLocal; $i++) {
	Start-Sleep -Seconds 1
	try { $okLocal = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$puertoApp/salud" -TimeoutSec 3).StatusCode -eq 200 } catch {}
}
Write-Host ("Servidor en el puerto ${puertoApp}: " + $(if ($okLocal) { 'OK' } else { "NO responde (mira $app\logs\servidor.log)" }))
$okHttps = $false
for ($i = 0; $i -lt 30 -and -not $okHttps; $i++) {
	Start-Sleep -Seconds 3
	try { $okHttps = (Invoke-WebRequest -UseBasicParsing "https://$Dominio/salud" -TimeoutSec 5).StatusCode -eq 200 } catch {}
}
$dondeMirar = if ($caddyPropio) { "$app\logs\caddy.log" } else { 'el log de tu Caddy' }
Write-Host ("HTTPS en https://$Dominio : " + $(if ($okHttps) { 'OK' } else { "todavía no (el certificado puede tardar un par de minutos; mira $dondeMirar). ¿$Dominio apunta a la IP de este VPS?" }))

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " Listo: https://$Dominio"
Write-Host " Log del servidor: $app\logs\servidor.log"
if ($integradoEn) { Write-Host " HTTPS: tu Caddy de siempre ($integradoEn)" }
Write-Host " Clave de soporte (guárdala):"
Select-String -Path $envFile -Pattern '^ADMIN_KEY=' | ForEach-Object { Write-Host " $($_.Line)" }
Write-Host "============================================================" -ForegroundColor Green
