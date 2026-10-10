#!/usr/bin/env bash
# Instala (o actualiza) ¡A la trompa! ONLINE en un VPS con Ubuntu (Contabo, etc.).
#
# Uso, como root, con la carpeta "A La Trompa" ya subida al VPS:
#   sudo bash vps/instalar.sh trompa.tudominio.com tu@correo.com
#
# Hace todo: Node.js, el servicio (arranca solo y se reinicia si falla), nginx
# con HTTPS (Let's Encrypt) y WebSocket, y el firewall. Se puede volver a
# ejecutar para actualizar: copia los archivos nuevos y reinicia el servicio
# (los canales de los streamers, en datos_online/, no se tocan).
set -euo pipefail

DOMINIO="${1:?Falta el dominio. Uso: sudo bash vps/instalar.sh trompa.tudominio.com tu@correo.com}"
CORREO="${2:?Falta el correo (lo pide el certificado HTTPS)}"
APP_DIR=/opt/trompa
ORIGEN="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
	echo "Ejecútalo como root (sudo)." >&2
	exit 1
fi

echo "==> Paquetes: Node.js 20, nginx, certbot y firewall"
apt-get update
apt-get install -y curl ca-certificates gnupg nginx certbot python3-certbot-nginx ufw rsync openssl
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 18 ]; then
	curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
	apt-get install -y nodejs
fi

echo "==> Archivos en $APP_DIR"
id trompa >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin trompa
mkdir -p "$APP_DIR"
rsync -a --delete \
	--exclude node_modules --exclude .git --exclude datos_online --exclude online.env \
	--exclude .env --exclude settings.json --exclude '*.jsonl' --exclude backup_original \
	"$ORIGEN"/ "$APP_DIR"/
cd "$APP_DIR"
npm ci --omit=dev || npm install --omit=dev
if [ ! -f online.env ]; then
	cp online.env.example online.env
	sed -i "s/^ADMIN_KEY=.*/ADMIN_KEY=$(openssl rand -hex 24)/" online.env
fi
mkdir -p datos_online
chown -R trompa:trompa "$APP_DIR"
chmod 600 online.env

echo "==> Servicio trompa (systemd)"
cat > /etc/systemd/system/trompa.service <<SERVICIO
[Unit]
Description=A la trompa ONLINE (servidor de eventos de TikTok para Roblox)
After=network.target

[Service]
User=trompa
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/env node $APP_DIR/online.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SERVICIO
systemctl daemon-reload
systemctl enable trompa
systemctl restart trompa

echo "==> nginx (HTTPS + WebSocket del panel)"
if [ ! -f /etc/letsencrypt/live/$DOMINIO/fullchain.pem ]; then
	cat > /etc/nginx/sites-available/trompa <<NGINX
server {
	listen 80;
	server_name $DOMINIO;
	client_max_body_size 1m;

	location / {
		proxy_pass http://127.0.0.1:8080;
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto \$scheme;
		proxy_read_timeout 3600s;
		proxy_send_timeout 3600s;
	}
}
NGINX
	ln -sf /etc/nginx/sites-available/trompa /etc/nginx/sites-enabled/trompa
	rm -f /etc/nginx/sites-enabled/default
	nginx -t
	systemctl reload nginx
fi

echo "==> Firewall (SSH + web)"
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "==> Certificado HTTPS (Let's Encrypt)"
if [ ! -f /etc/letsencrypt/live/$DOMINIO/fullchain.pem ]; then
	certbot --nginx -d "$DOMINIO" -m "$CORREO" --agree-tos --non-interactive --redirect
else
	echo "(ya existe: se renueva solo)"
fi

sleep 1
echo
echo "============================================================"
echo " Listo: https://$DOMINIO"
echo " Comprueba:  curl https://$DOMINIO/salud"
echo " Ver el log: journalctl -u trompa -f"
echo " Clave de soporte (guárdala):"
grep '^ADMIN_KEY=' "$APP_DIR/online.env"
echo "============================================================"
