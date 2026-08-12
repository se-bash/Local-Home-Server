#!/bin/bash
# ==============================================================================
# Script de Configuración Avanzada para Debian Home Server
# ==============================================================================

set -e

# Asegurar que el script se ejecuta como root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Por favor, ejecuta este script como root (escribe 'su -' para cambiar a root)."
    exit 1
fi

echo "=== 0. Instalando 'sudo' y configurando administradores ==="
apt-get update
apt-get install -y sudo

echo "------------------------------------------------------"
echo "Usuarios normales detectados en el sistema:"
ls -1 /home 2>/dev/null || echo "(Ningún usuario normal detectado en /home)"
echo "------------------------------------------------------"
read -p "¿A qué usuario deseas darle permisos de sudo? (Escribe el nombre o deja en blanco para omitir): " NUEVO_ADMIN

if [ -n "$NUEVO_ADMIN" ]; then
    if id "$NUEVO_ADMIN" >/dev/null 2>&1; then
        usermod -aG sudo "$NUEVO_ADMIN"
        echo "Usuario '$NUEVO_ADMIN' agregado al grupo 'sudo' exitosamente."
        echo "   (El usuario deberá cerrar sesión y volver a entrar para que los permisos apliquen)."
    else
        echo "El usuario '$NUEVO_ADMIN' no existe en el sistema. Continuando sin asignar sudo."
    fi
fi
echo ""
sleep 2

BASE_DIR="/opt/homeserver"
MDNS_NAME="$(hostname).local"

echo "=== Verificando archivos del repositorio ==="
if [ ! -f "./docker-compose.yml" ]; then
    echo "Error: No se encuentra docker-compose.yml en este directorio."
    echo "Por favor, ejecuta este script desde la raíz del repositorio clonado."
    exit 1
fi
echo "Archivo docker-compose.yml encontrado."
echo ""
sleep 2

echo "=== 1. Optimizando repositorios (Buscando el mejor espejo para tu conexión) ==="
apt-get install -y netselect-apt wget
source /etc/os-release

cd /tmp
echo "Analizando latencia de los servidores de Debian ($VERSION_CODENAME)..."
netselect-apt -n $VERSION_CODENAME || true

if [ -f /tmp/sources.list ]; then
    echo "Aplicando cambios al repositorio..."
    cp /etc/apt/sources.list /etc/apt/sources.list.backup
    mv /tmp/sources.list /etc/apt/sources.list
    apt-get update
else
    echo "Advertencia: No se pudo optimizar el repositorio. Se continuará con el predeterminado."
fi
cd - > /dev/null
echo ""
sleep 2

echo "=== 2. Instalando dependencias del sistema ==="
apt-get install -y fail2ban borgbackup ufw avahi-daemon
echo ""
sleep 2

echo "=== 3. Instalando Docker Oficial ==="
# Eliminar versiones antiguas o conflictivas
apt-get remove -y docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc || true

# Agregar clave GPG oficial de Docker
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Agregar el repositorio a las fuentes de Apt
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update
# Instalar los paquetes reales de Docker
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Iniciar y habilitar el servicio de Docker
systemctl enable --now docker
systemctl status docker --no-pager | head -n 5
echo ""
sleep 2

echo "=== 4. Configurando red mDNS ==="
systemctl enable --now avahi-daemon
echo "El servidor estará accesible en tu red local como: ${MDNS_NAME}"
echo ""
sleep 2

echo "=== 5. Configurando Fail2ban para proteger SSH ==="
cat << 'EOF' | tee /etc/fail2ban/jail.local > /dev/null
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl restart fail2ban
echo ""
sleep 2

echo "=== 6. Creando estructura de directorios y volúmenes en $BASE_DIR ==="
mkdir -p ${BASE_DIR}/prometheus/data
mkdir -p ${BASE_DIR}/grafana/data
mkdir -p ${BASE_DIR}/homepage/config
mkdir -p ${BASE_DIR}/jellyfin/config ${BASE_DIR}/jellyfin/cache ${BASE_DIR}/jellyfin/media
mkdir -p ${BASE_DIR}/nextcloud/app ${BASE_DIR}/nextcloud/db
mkdir -p ${BASE_DIR}/pihole/etc-pihole ${BASE_DIR}/pihole/etc-dnsmasq.d
mkdir -p ${BASE_DIR}/tailscale/state
mkdir -p ${BASE_DIR}/portainer/data
mkdir -p ${BASE_DIR}/borgbackup/repo ${BASE_DIR}/borgbackup/cache
echo ""
sleep 2

echo "=== 7. Copiando el archivo docker-compose.yml a la ruta del servidor ==="
cp ./docker-compose.yml ${BASE_DIR}/docker-compose.yml
echo ""
sleep 2

echo "=== 8. Asignando permisos de almacenamiento a bases de datos ==="
chown -R 65534:65534 ${BASE_DIR}/prometheus
chown -R 472:472 ${BASE_DIR}/grafana
echo ""
sleep 2

echo "=== 9. Creando archivo de configuración prometheus.yml ==="
cat << 'EOF' | tee ${BASE_DIR}/prometheus/prometheus.yml > /dev/null
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
echo ""
sleep 2

echo "=== 10. Configurando Homepage (Paneles y Accesos Directos) ==="
cat << EOF | tee ${BASE_DIR}/homepage/config/services.yaml > /dev/null
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
echo ""
sleep 2

echo "=== 11. Configurando Cron Job para BorgBackup (Copias Diarias a las 3:00 AM) ==="
cat << 'EOF' | tee /etc/cron.daily/borg-homeserver > /dev/null
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
chmod +x /etc/cron.daily/borg-homeserver
echo ""
sleep 2

echo "=== 12. Configurando Firewall (UFW) ==="
ufw allow 22/tcp     # SSH
ufw allow 3000/tcp   # Homepage
ufw allow 3001/tcp   # Grafana
ufw allow 8080/tcp   # Nextcloud
ufw allow 8081/tcp   # Pi-hole Web Admin
ufw allow 8096/tcp   # Jellyfin
ufw allow 9090/tcp   # Prometheus
ufw allow 9443/tcp   # Portainer HTTPS
ufw allow 53/tcp     # DNS Pi-hole
ufw allow 53/udp     # DNS Pi-hole
ufw allow 41641/udp  # Tailscale
# Habilitar UFW sin interrupciones
ufw --force enable
echo ""
sleep 2

echo "========================================================="
echo "=== ¡Despliegue Completado con Éxito! ==="
echo "========================================================="
echo ""
echo "Para iniciar la infraestructura de contenedores ejecuta:"
echo "  cd ${BASE_DIR} && docker compose up -d"
echo ""
echo "Podrás acceder a tu panel principal desde cualquier dispositivo en la red en:"
echo "  http://${MDNS_NAME}:3000"
echo ""
