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
#   • Caddy en C:\trompa-caddy: HTTPS gratis (Let's Encrypt) delante del servidor
#   • abre los puertos 80 y 443 en el firewall de Windows
#   • dos tareas programadas que arrancan solas al encender el VPS y se
#     reinician si se cierran: "Trompa Servidor" y "Trompa HTTPS"
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

# ----- Caddy (HTTPS) -----
Paso 'Caddy (HTTPS automático)'
New-Item -ItemType Directory -Force -Path $caddyDir | Out-Null
$caddyExe = Join-Path $caddyDir 'caddy.exe'
if (-not (Test-Path $caddyExe)) {
	Write-Host 'Descargando Caddy...'
	Invoke-WebRequest -UseBasicParsing 'https://caddyserver.com/api/download?os=windows&arch=amd64' -OutFile $caddyExe
}
$caddyfile = @"
{
	email $Correo
}

$Dominio {
	reverse_proxy 127.0.0.1:8080
}
"@
[IO.File]::WriteAllText((Join-Path $caddyDir 'Caddyfile'), $caddyfile, (New-Object Text.UTF8Encoding $false))

# Los puertos 80 y 443 deben estar libres (IIS u otro programa los bloquearía)
foreach ($puerto in 80, 443) {
	$ocupado = Get-NetTCPConnection -State Listen -LocalPort $puerto -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($ocupado) {
		$proceso = (Get-Process -Id $ocupado.OwningProcess -ErrorAction SilentlyContinue).ProcessName
		throw "El puerto $puerto ya lo usa '$proceso'. Si es IIS (W3SVC / System), desactívalo: Stop-Service W3SVC; Set-Service W3SVC -StartupType Disabled"
	}
}

# ----- firewall -----
Paso 'Firewall de Windows (puertos 80 y 443)'
foreach ($puerto in 80, 443) {
	$nombre = "Trompa HTTP $puerto"
	if (-not (Get-NetFirewallRule -DisplayName $nombre -ErrorAction SilentlyContinue)) {
		New-NetFirewallRule -DisplayName $nombre -Direction Inbound -Protocol TCP -LocalPort $puerto -Action Allow | Out-Null
	}
}

# ----- tareas programadas (arrancan al encender y se reinician solas) -----
Paso 'Tareas que arrancan solas'
$ajustes = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$disparador = New-ScheduledTaskTrigger -AtStartup
$script = Join-Path $app 'vps\servicio_windows.ps1'
foreach ($par in @(@('Trompa Servidor', 'servidor'), @('Trompa HTTPS', 'caddy'))) {
	$accion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Que $($par[1])"
	Register-ScheduledTask -TaskName $par[0] -Action $accion -Trigger $disparador -Settings $ajustes -Principal $principal -Force | Out-Null
	Start-ScheduledTask -TaskName $par[0]
}

# ----- comprobar -----
Paso 'Comprobando'
$okLocal = $false
for ($i = 0; $i -lt 20 -and -not $okLocal; $i++) {
	Start-Sleep -Seconds 1
	try { $okLocal = (Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:8080/salud' -TimeoutSec 3).StatusCode -eq 200 } catch {}
}
Write-Host ("Servidor en el puerto 8080: " + $(if ($okLocal) { 'OK' } else { "NO responde (mira $app\logs\servidor.log)" }))
$okHttps = $false
for ($i = 0; $i -lt 30 -and -not $okHttps; $i++) {
	Start-Sleep -Seconds 3
	try { $okHttps = (Invoke-WebRequest -UseBasicParsing "https://$Dominio/salud" -TimeoutSec 5).StatusCode -eq 200 } catch {}
}
Write-Host ("HTTPS en https://$Dominio : " + $(if ($okHttps) { 'OK' } else { "todavía no (el certificado puede tardar un par de minutos; mira $app\logs\caddy.log)" }))

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " Listo: https://$Dominio"
Write-Host " Logs:  $app\logs\servidor.log  y  $app\logs\caddy.log"
Write-Host " Clave de soporte (guárdala):"
Select-String -Path $envFile -Pattern '^ADMIN_KEY=' | ForEach-Object { Write-Host " $($_.Line)" }
Write-Host "============================================================" -ForegroundColor Green
