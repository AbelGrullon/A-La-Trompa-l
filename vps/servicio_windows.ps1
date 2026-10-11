# Mantiene vivo el servidor online (o Caddy) en Windows Server: si se cierra,
# lo vuelve a abrir a los 3 segundos. Lo lanzan las tareas programadas que crea
# instalar_windows.ps1 al encender el servidor (no hace falta abrirlo a mano).
#   -Que servidor : node online.js        (log: C:\trompa\logs\servidor.log)
#   -Que caddy    : caddy (HTTPS → 8080)   (log: C:\trompa\logs\caddy.log)
param(
	[Parameter(Mandatory = $true)]
	[ValidateSet('servidor', 'caddy')]
	[string]$Que
)

$app = 'C:\trompa'
$caddyDir = 'C:\trompa-caddy'
$logs = Join-Path $app 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$log = Join-Path $logs "$Que.log"

while ($true) {
	# el log no crece sin fin: a los 10 MB se guarda el anterior y se empieza otro
	if ((Test-Path $log) -and ((Get-Item $log).Length -gt 10MB)) {
		Move-Item -Force $log "$log.1"
	}
	Add-Content -Path $log -Encoding UTF8 -Value "$(Get-Date -Format s) arrancando $Que"
	if ($Que -eq 'servidor') {
		Set-Location $app
		# (cmd escribe el log tal cual sale de node, en UTF-8)
		cmd /c "node online.js >> `"$log`" 2>&1"
	} else {
		$env:XDG_DATA_HOME = Join-Path $caddyDir 'datos' # certificados HTTPS
		cmd /c "`"$caddyDir\caddy.exe`" run --config `"$caddyDir\Caddyfile`" --adapter caddyfile >> `"$log`" 2>&1"
	}
	Add-Content -Path $log -Encoding UTF8 -Value "$(Get-Date -Format s) $Que se detuvo (código $LASTEXITCODE). Reinicio en 3 s"
	Start-Sleep -Seconds 3
}
