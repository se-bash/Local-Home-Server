#!/bin/bash

set -e

BASE_DIR="/opt/homeserver"
MDNS_NAME="$(hostname).local"

echo "=== Verificando archivos del repositorio ==="
if [ ! -f "./docker-compose.yml" ]; then
    echo "Error: No se encuentra docker-compose.yml en este directorio."
    echo "Por favor, ejecuta este script desde la raíz del repositorio clonado."
    exit 1
fi

echo "=== 1. Optimizando repositorios (Buscando el mejor espejo para tu conexión) ==="
sudo apt-get update
sudo apt-get install -y netselect-apt wget

# Obtener la versión actual de Debian (ej. bookworm, bullseye)
source /etc/os-release

cd /tmp
echo "Analizando latencia de los servidores de Debian ($VERSION_CODENAME)"
sudo netselect-apt -n $VERSION_CODENAME || true

if [ -f /tmp/sources.list ]; then
    echo "Aplicando cambios..."
    sudo cp /etc/apt/sources.list /etc/apt/sources.list.backup
    sudo mv /tmp/sources.list /etc/apt/sources.list
    sudo apt-get update
else
    echo "Advertencia: No se pudo optimizar el repositorio. Se continuará con el predeterminado."
fi
cd - > /dev/null

echo "=== 2. Instalando dependencias del sistema ==="
sudo apt-get install -y fail2ban borgbackup ufw avahi-daemon

echo "=== 3. Configurando red mDNS ==="
sudo systemctl enable --now avahi-daemon
echo "El servidor estará accesible en tu red local como: ${MDNS_NAME}"

echo "=== 4. Configurando Fail2ban para proteger SSH ==="
cat << 'EOF' | sudo tee /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF
sudo systemctl restart fail2ban

echo "=== 5. Creando estructura de directorios y volúmenes en $BASE_DIR ==="
sudo mkdir -p ${BASE_DIR}/prometheus/data
sudo mkdir -p ${BASE_DIR}/grafana/data
sudo mkdir -p ${BASE_DIR}/homepage/config
sudo mkdir -p ${BASE_DIR}/jellyfin/config ${BASE_DIR}/jellyfin/cache ${BASE_DIR}/jellyfin/media
sudo mkdir -p ${BASE_DIR}/nextcloud/app ${BASE_DIR}/nextcloud/db
sudo mkdir -p ${BASE_DIR}/pihole/etc-pihole ${BASE_DIR}/pihole/etc-dnsmasq.d
sudo mkdir -p ${BASE_DIR}/tailscale/state
sudo mkdir -p ${BASE_DIR}/portainer/data
sudo mkdir -p ${BASE_DIR}/borgbackup/repo ${BASE_DIR}/borgbackup/cache

echo "=== 6. Copiando el archivo docker-compose.yml a la ruta del servidor ==="
sudo cp ./docker-compose.yml ${BASE_DIR}/docker-compose.yml

echo "=== 7. Asignando permisos de almacenamiento a bases de datos ==="
sudo chown -R 65534:65534 ${BASE_DIR}/prometheus
sudo chown -R 472:472 ${BASE_DIR}/grafana

echo "=== 8. Creando archivo de configuración prometheus.yml ==="
cat << 'EOF' | sudo tee ${BASE_DIR}/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
EOF

echo "=== 9. Configurando Homepage (Paneles y Accesos Directos) ==="
cat << EOF | sudo tee ${BASE_DIR}/homepage/config/services.yaml
- Dashboard & Monitoreo:
    - Grafana:
        icon: grafana.png
        href: http://${MDNS_NAME}:3001
        description: Visualización de métricas del servidor
    - Prometheus:
        icon: prometheus.png
        href: http://${MDNS_NAME}:9090
        description: Base de datos de telemetría

- Gestión & Seguridad:
    - Portainer:
        icon: portainer.png
        href: https://${MDNS_NAME}:9443
        description: Interfaz gráfica para Docker
    - Pi-hole:
        icon: pi-hole.png
        href: http://${MDNS_NAME}:8081/admin
        description: Bloqueo de publicidad y DNS local

- Medios & Almacenamiento:
    - Jellyfin:
        icon: jellyfin.png
        href: http://${MDNS_NAME}:8096
        description: Servidor de películas y música
    - Nextcloud:
        icon: nextcloud.png
        href: http://${MDNS_NAME}:8080
        description: Nube privada de archivos
EOF

echo "=== 10. Configurando Cron Job para BorgBackup (Copias Diarias a las 3:00 AM) ==="
sudo cat << 'EOF' | sudo tee /etc/cron.daily/borg-homeserver
#!/bin/bash
# Inicializar repositorio Borg si no existe
if [ ! -d "/opt/homeserver/borgbackup/repo/data" ]; then
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
    borg init --encryption=none /opt/homeserver/borgbackup/repo
fi

# Crear respaldo de la carpeta /opt/homeserver
borg create /opt/homeserver/borgbackup/repo::'backup-{now:%Y-%m-%d-%H%M}' /opt/homeserver \
    --exclude '/opt/homeserver/borgbackup' \
    --exclude '/opt/homeserver/jellyfin/media'

# Mantener los últimos 7 respaldos diarios, 4 semanales y 6 mensuales
borg prune -v --list /opt/homeserver/borgbackup/repo --keep-daily=7 --keep-weekly=4 --keep-monthly=6
EOF
sudo chmod +x /etc/cron.daily/borg-homeserver

echo "=== 11. Configurando Firewall (UFW) ==="
sudo ufw allow 22/tcp     # SSH
sudo ufw allow 3000/tcp   # Homepage
sudo ufw allow 3001/tcp   # Grafana
sudo ufw allow 8080/tcp   # Nextcloud
sudo ufw allow 8081/tcp   # Pi-hole Web Admin
sudo ufw allow 8096/tcp   # Jellyfin
sudo ufw allow 9090/tcp   # Prometheus
sudo ufw allow 9443/tcp   # Portainer HTTPS
sudo ufw allow 53/tcp     # DNS Pi-hole
sudo ufw allow 53/udp     # DNS Pi-hole
sudo ufw allow 41641/udp  # Tailscale
# Habilitar UFW sin interrupciones
sudo ufw --force enable

echo "=== ¡Despliegue Avanzado Completado! ==="
echo "Para iniciar la infraestructura de contenedores ejecuta:"
echo "  cd ${BASE_DIR} && sudo docker compose up -d"
echo ""
echo "Podrás acceder a tu panel principal desde cualquier dispositivo en la red en:"
echo "  http://${MDNS_NAME}:3000"
