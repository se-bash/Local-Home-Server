#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE=/var/log/homeserver-setup.log
STEP="preparación inicial"
BASE_DIR=/opt/homeserver
CONFIG_DIR=/etc/homeserver
ENV_FILE=$BASE_DIR/.env
TELEGRAM_FILE=$CONFIG_DIR/telegram.env
DISKS_FILE=$CONFIG_DIR/discos.conf
declare -A DISK_ID=()
declare -A DISK_CHOICE=()
declare -A DISK_MODE=()
declare -A DISK_NAMES=()

if [[ $EUID -ne 0 ]]; then
    printf 'Error: Ejecuta el instalador como root: sudo bash setup_server.sh\n' >&2
    exit 1
fi
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

fallo() {
    local codigo=$?
    printf 'Error durante el paso «%s» (código %s). Consulta %s.\n' "$STEP" "$codigo" "$LOG_FILE" >&2
    exit "$codigo"
}
trap fallo ERR

paso() {
    STEP=$1
    printf '\n[%s] %s\n' "$2" "$1"
}

fatal() {
    printf 'Error durante el paso «%s»: %s\n' "$STEP" "$*" >&2
    exit 1
}

generar_secreto() {
    openssl rand -hex 24
}

escribir_env() {
    local clave=$1 valor=$2
    sed -i "/^${clave}=/d" "$ENV_FILE"
    printf '%s="%s"\n' "$clave" "$valor" >>"$ENV_FILE"
}

leer_env() {
    local clave=$1
    sed -n "s/^${clave}=//p" "$ENV_FILE" | tail -n 1
}

guardar_telegram() {
    local token=$1 chat=$2 api=$3
    install -d -m 0755 "$CONFIG_DIR"
    {
        printf 'TELEGRAM_BOT_TOKEN=%q\n' "$token"
        printf 'TELEGRAM_CHAT_ID=%q\n' "$chat"
        printf 'TELEGRAM_API=%q\n' "$api"
    } >"$TELEGRAM_FILE"
    chmod 600 "$TELEGRAM_FILE"
}

verificar_telegram() {
    local token=$1 api=$2 username actual
    username=$(python3 - "$api" "$token" <<'PY'
import json
import sys
import urllib.request

api, token = sys.argv[1].rstrip("/"), sys.argv[2]
with urllib.request.urlopen(f"{api}/bot{token}/getMe", timeout=15) as response:
    result = json.load(response)
if not result.get("ok") or not result.get("result", {}).get("username"):
    raise SystemExit("El token de Telegram no es válido.")
print(result["result"]["username"])
PY
)
    [[ -n "$username" ]] || fatal "El token de Telegram no es válido."
    printf 'Abre Telegram, busca @%s y envía /start\n' "$username"
    printf 'Esperando el primer mensaje durante un máximo de 3 minutos...\n'
    actual=$(python3 - "$api" "$token" <<'PY'
import json
import sys
import time
import urllib.parse
import urllib.request

api, token = sys.argv[1].rstrip("/"), sys.argv[2]
deadline = time.monotonic() + 180
while time.monotonic() < deadline:
    query = urllib.parse.urlencode({"timeout": 50, "offset": 0})
    try:
        with urllib.request.urlopen(f"{api}/bot{token}/getUpdates?{query}", timeout=60) as response:
            updates = json.load(response).get("result", [])
    except Exception:
        time.sleep(1)
        continue
    mensaje = next((update for update in updates if update.get("message", {}).get("chat", {}).get("id") is not None), None)
    if mensaje is None:
        continue
    chat = mensaje["message"]["chat"]["id"]
    offset = int(mensaje["update_id"]) + 1
    query = urllib.parse.urlencode({"offset": offset, "timeout": 0})
    with urllib.request.urlopen(f"{api}/bot{token}/getUpdates?{query}", timeout=15):
        pass
    solicitud = urllib.request.Request(
        f"{api}/bot{token}/sendMessage",
        data=json.dumps({"chat_id": chat, "text": "Conectado a homeserver"}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(solicitud, timeout=15):
        pass
    print(chat)
    break
else:
    raise SystemExit("No se recibió un mensaje de Telegram en 3 minutos.")
PY
    ) || true
    if [[ -z $actual ]]; then
        printf 'No se recibió /start; se continúa sin Telegram (puedes volver a ejecutar el script para configurarlo)\n'
        return 1
    fi
    TELEGRAM_BOT_TOKEN=$token
    TELEGRAM_CHAT_ID=$actual
    guardar_telegram "$token" "$actual" "$api"
}

load_existing_settings() {
    if [[ -r $CONFIG_DIR/homeserver.conf ]]; then
        # Archivo creado por este instalador y protegido contra escritura de otros usuarios.
        # shellcheck source=/dev/null
        source "$CONFIG_DIR/homeserver.conf"
    fi
    if [[ -r $ENV_FILE ]]; then
        BESZEL_KEY_ANTIGUA=$(sed -n 's/^BESZEL_KEY=//p' "$ENV_FILE")
        if [[ $BESZEL_KEY_ANTIGUA == *" "* && $BESZEL_KEY_ANTIGUA != \"* ]]; then
            sed -i '/^BESZEL_KEY=/d' "$ENV_FILE"
            printf 'BESZEL_KEY="%s"\n' "$BESZEL_KEY_ANTIGUA" >>"$ENV_FILE"
        fi
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
    fi
    if [[ -r $TELEGRAM_FILE ]]; then
        # shellcheck source=/dev/null
        source "$TELEGRAM_FILE"
    fi
}

disco_protegido() {
    local candidato=$1 origen destino
    for destino in / /boot; do
        origen=$(findmnt -rn -o SOURCE -T "$destino" 2>/dev/null | sed 's/\[.*$//')
        [[ -b $origen ]] || continue
        lsblk -s -nrpo NAME "$origen" 2>/dev/null | grep -Fxq "$candidato" && return 0
    done
    while IFS= read -r origen; do
        [[ -b $origen ]] || continue
        lsblk -s -nrpo NAME "$origen" 2>/dev/null | grep -Fxq "$candidato" && return 0
    done < <(swapon --noheadings --raw --show=NAME 2>/dev/null)
    for origen in /dev/md* /dev/dm-* /dev/mapper/*; do
        [[ -b $origen ]] || continue
        lsblk -s -nrpo NAME "$origen" 2>/dev/null | grep -Fxq "$candidato" && return 0
    done
    return 1
}

detect_disks_for_questions() {
    local disk kname size model serial wwn long_id id fs mounts
    while IFS= read -r disk; do
        [[ -b $disk ]] || continue
        kname=$(basename "$disk")
        [[ $kname =~ ^(loop|ram|zram|sr|md|dm-) ]] && continue
        disco_protegido "$disk" && continue
        size=$(blockdev --getsize64 "$disk" 2>/dev/null || printf 0)
        ((size >= 1073741824)) || continue
        mounts=$(lsblk -nrpo MOUNTPOINT "$disk" | sed '/^$/d')
        [[ -z $mounts ]] || continue
        serial=$(lsblk -dn -o SERIAL "$disk" | xargs)
        wwn=$(lsblk -dn -o WWN "$disk" | xargs)
        long_id=${wwn:-${serial:-$(basename "$(find /dev/disk/by-id -maxdepth 1 -type l -lname "../../$kname" -print -quit 2>/dev/null || printf '%s' "$kname")")}}
        long_id=$(tr -cd '[:alnum:]_.-' <<<"$long_id")
        [[ -n $long_id ]] || long_id=$kname
        [[ -f $DISKS_FILE ]] && grep -q "^${long_id}|" "$DISKS_FILE" && continue
        id=$(printf '%s' "$long_id" | sha1sum | cut -c1-10)
        model=$(lsblk -dn -o MODEL "$disk" | xargs)
        model=${model:-Disco $kname}
        fs=$(lsblk -nrpo FSTYPE "$disk" | sed '/^$/d' | head -n 1 || true)
        if lsblk -nrpo TYPE "$disk" | grep -qx part; then
            fs=$(lsblk -nrpo FSTYPE "$disk" | sed '/^$/d' | head -n 1 || true)
        fi
        DISK_ID[$kname]=$id
        DISK_CHOICE[$kname]=""
        DISK_NAMES[$kname]="$model|$size|${fs:-vacío}"
        printf '%s|%s|%s|%s|%s|%s\n' "$id" "$long_id" "$kname" "$model" "$size" "${fs:-}" >"/run/homeserver-${kname}.disk"
    done < <(lsblk -dnpo NAME,TYPE | awk '$2 == "disk" {print $1}')
}

preguntar_opciones() {
    local token api ts kname id model bytes fs eleccion borrar
    token=${TELEGRAM_BOT_TOKEN:-}
    api=${TELEGRAM_API:-https://api.telegram.org}
    if [[ -z ${TELEGRAM_BOT_TOKEN:-} && -z ${TELEGRAM_BOT_CONFIGURED:-} && -t 0 ]]; then
        read -r -s -p 'Token del bot de Telegram (opcional; Enter para omitir): ' token
        printf '\n'
    fi
    if [[ -n $token && -z ${TELEGRAM_CHAT_ID:-} ]]; then
        if ! verificar_telegram "$token" "$api"; then
            token=""
            unset TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
        fi
    elif [[ -n $token && -n ${TELEGRAM_CHAT_ID:-} ]]; then
        guardar_telegram "$token" "$TELEGRAM_CHAT_ID" "$api"
    elif [[ -z $token && -n ${TELEGRAM_CHAT_ID:-} ]]; then
        token=${TELEGRAM_BOT_TOKEN:-}
    fi
    if [[ -n $token ]]; then
        TELEGRAM_BOT_CONFIGURED=si
        TELEGRAM_API=$api
    fi
    ts=${TS_AUTHKEY:-${TS_AUTHKEY_EXISTENTE:-}}
    if [[ -z $ts && -t 0 ]]; then
        read -r -p 'Clave de autenticación de Tailscale (opcional; Enter para omitir): ' ts
    fi
    [[ -z $ts ]] || TS_AUTHKEY=$ts
    detect_disks_for_questions
    for kname in "${!DISK_ID[@]}"; do
        id=${DISK_ID[$kname]}
        IFS='|' read -r model bytes fs <<<"${DISK_NAMES[$kname]}"
        varname="HS_DISK_${kname}"
        eleccion=${!varname:-}
        if [[ -z $eleccion && -t 0 ]]; then
            printf '¿Para qué usar %s %s? [1] Respaldos [2] Almacenamiento [3] Ignorar: ' "$model" "$(numfmt --to=iec --suffix=B "$bytes")"
            read -r eleccion
        fi
        case ${eleccion,,} in
            1|respaldos) DISK_CHOICE[$kname]=respaldos ;;
            2|almacenamiento) DISK_CHOICE[$kname]=almacenamiento ;;
            3|ignorar|ignore) DISK_CHOICE[$kname]=ignorar ;;
            *) continue ;;
        esac
        if [[ -n $fs && ${DISK_CHOICE[$kname]} != ignorar ]]; then
            format_var="HS_DISK_FORMAT_${kname}"
            borrar=${!format_var:-}
            if [[ -z $borrar && -t 0 ]]; then
                read -r -p '[1] Usar sin borrar [2] Formatear: ' borrar
            fi
            if [[ $borrar == 2 || $borrar == formatear ]]; then
                if [[ -t 0 ]]; then
                    read -r -p "Escribe BORRAR para confirmar el formateo de $model: " borrar
                else
                    confirm_var="HS_DISK_CONFIRM_${kname}"
                    borrar=${!confirm_var:-}
                fi
                [[ $borrar == BORRAR ]] || fatal "No se confirmó el formateo de $kname."
                DISK_MODE[$kname]=formatear
            else
                DISK_MODE[$kname]=usar
            fi
        else
            DISK_MODE[$kname]=formatear
        fi
    done
}

preflight() {
    [[ $EUID -eq 0 ]] || fatal "Ejecuta el instalador como root: sudo bash setup_server.sh"
    [[ -r /etc/os-release ]] || fatal "No se pudo identificar la distribución."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ ${ID:-} == debian ]] || fatal "Este instalador solo admite Debian 12 (bookworm) y Debian 13 (trixie)."
    case ${VERSION_ID:-} in
        12|13) ;;
        *) fatal "Versión no admitida: Debian ${VERSION_ID:-desconocida}. Se requiere Debian 12 o 13." ;;
    esac
    [[ $(dpkg --print-architecture) == amd64 || $(dpkg --print-architecture) == arm64 ]] || fatal "Arquitectura no admitida: $(dpkg --print-architecture)."
    df -Pk / | awk 'NR == 2 {exit ($4 < 10485760)}' || fatal "Se requieren al menos 10 GB libres en /."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --max-time 12 https://deb.debian.org >/dev/null || fatal "No hay conexión a Internet con deb.debian.org."
    else
        python3 -c 'import urllib.request; urllib.request.urlopen("https://deb.debian.org", timeout=12)' || fatal "No hay conexión a Internet con deb.debian.org."
    fi
}

load_existing_settings
preflight
if [[ -f /etc/apt/sources.list ]]; then
    sed -i '/^[[:space:]]*deb[[:space:]]\+cdrom:/s/^/# Instalador homeserver: deshabilitado: /' /etc/apt/sources.list
fi
apt-get -o DPkg::Lock::Timeout=600 update -qq
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y curl ca-certificates python3 jq openssl
umask 077
install -d -m 0755 "$BASE_DIR" "$CONFIG_DIR" /var/lib/homeserver/discos /var/lib/homeserver/alertas
touch "$DISKS_FILE"
touch /var/log/homeserver-setup.log
chmod 600 "$DISKS_FILE"
TELEGRAM_API=${TELEGRAM_API:-${TELEGRAM_API_SAVED:-https://api.telegram.org}}

paso 'Respondiendo las preguntas iniciales' '1/14'
preguntar_opciones

TZ_HOST=$(timedatectl show -p Timezone --value 2>/dev/null || true)
TZ_HOST=${TZ_HOST:-America/Guayaquil}

paso 'Preparando ajustes seguros y credenciales' '2/14'
if [[ ! -f $ENV_FILE ]]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi
for clave in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD NEXTCLOUD_ADMIN_PASSWORD JELLYFIN_ADMIN_PASSWORD BESZEL_ADMIN_PASSWORD PORTAINER_PASSWORD ADGUARD_ADMIN_PASSWORD BORG_PASSPHRASE; do
    [[ -n $(leer_env "$clave") ]] || escribir_env "$clave" "$(generar_secreto)"
done
escribir_env TZ_HOST "$TZ_HOST"
[[ -n $(leer_env BESZEL_TOKEN) ]] || escribir_env BESZEL_TOKEN "$(generar_secreto)"
if [[ -n ${TS_AUTHKEY:-} ]]; then
    escribir_env TS_AUTHKEY "$TS_AUTHKEY"
fi
if [[ -n ${TELEGRAM_BOT_TOKEN:-} ]]; then
    escribir_env TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
fi
if [[ -n ${TELEGRAM_API:-} ]]; then
    escribir_env TELEGRAM_API "$TELEGRAM_API"
fi
chmod 600 "$ENV_FILE"
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

paso 'Actualizando Debian e instalando paquetes' '3/14'
if [[ -f /etc/apt/sources.list ]]; then
    sed -i '/^[[:space:]]*deb[[:space:]]\+cdrom:/s/^/# Instalador homeserver: deshabilitado: /' /etc/apt/sources.list
fi
if [[ -d /etc/apt/sources.list.d ]]; then
    while IFS= read -r archivo; do
        sed -i '/^[[:space:]]*deb[[:space:]]\+cdrom:/s/^/# Instalador homeserver: deshabilitado: /' "$archivo"
    done < <(find /etc/apt/sources.list.d -type f \( -name '*.list' -o -name '*.sources' \))
fi
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y sudo curl ca-certificates gnupg fail2ban python3-systemd ufw nftables avahi-daemon libnss-mdns borgbackup unattended-upgrades apache2-utils jq parted e2fsprogs ntfs-3g exfatprogs smartmontools openssl util-linux rsync cron iputils-ping
dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl enable --now unattended-upgrades
systemctl enable --now cron

paso 'Detectando y agregando al usuario administrador' '4/14'
HS_USER=${SUDO_USER:-}
if [[ -z $HS_USER || $HS_USER == root ]] || ! id "$HS_USER" >/dev/null 2>&1; then
    HS_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1; exit}' /etc/passwd)
fi
if [[ -n $HS_USER ]] && id "$HS_USER" >/dev/null 2>&1; then
    usermod -aG sudo,docker "$HS_USER" 2>/dev/null || usermod -aG sudo "$HS_USER"
fi
printf 'HS_USER=%q\n' "$HS_USER" >"$CONFIG_DIR/user.conf"
chmod 600 "$CONFIG_DIR/user.conf"

paso 'Configurando Docker desde el repositorio oficial' '5/14'
apt-get -o DPkg::Lock::Timeout=600 remove -y docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc || true
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
if [[ ! -f /etc/docker/daemon.json ]] || ! jq -e '."log-opts"' /etc/docker/daemon.json >/dev/null 2>&1; then
    install -d -m 0755 /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        jq '. + {"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' /etc/docker/daemon.json >/etc/docker/daemon.json.new
        mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    else
        printf '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}\n' >/etc/docker/daemon.json
    fi
    systemctl restart docker
fi
usermod -aG docker "$HS_USER" 2>/dev/null || true

paso 'Fijando nombre del servidor y acceso local' '6/14'
hostnamectl set-hostname homeserver
if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i -E 's/^[[:space:]]*127\.0\.1\.1[[:space:]].*/127.0.1.1 homeserver/' /etc/hosts
else
    printf '127.0.1.1 homeserver\n' >>/etc/hosts
fi
systemctl enable --now avahi-daemon

paso 'Configurando la dirección IP fija actual' '7/14'
SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
LAN_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
GATEWAY=$(ip -4 route show default | awk 'NR==1 {print $3}')
PREFIX=$(ip -o -4 addr show dev "$LAN_IFACE" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[2]; exit}')
LAN_CIDR=$(python3 - "$SERVER_IP" "$PREFIX" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(f"{sys.argv[1]}/{sys.argv[2]}").network)
PY
)
TZ_HOST=$(timedatectl show -p Timezone --value 2>/dev/null || true)
TZ_HOST=${TZ_HOST:-America/Guayaquil}
SERVER_STATIC=0
if command -v nmcli >/dev/null 2>&1 && nmcli -t -f STATE general 2>/dev/null | grep -q connected; then
    NM_CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v dev="$LAN_IFACE" '$2==dev {print $1; exit}')
    if [[ -n $NM_CON ]]; then
        if [[ $(nmcli -g ipv4.method con show "$NM_CON") == manual ]]; then
            SERVER_STATIC=1
        else
            NETWORK_SNAPSHOT=/var/lib/homeserver/red-red
            mkdir -p "$NETWORK_SNAPSHOT"
            cp -a /etc/NetworkManager/system-connections "$NETWORK_SNAPSHOT/" 2>/dev/null || true
            printf '#!/bin/bash\ncp -a "%s/system-connections/." /etc/NetworkManager/system-connections/ 2>/dev/null || true\nnmcli con reload\nnmcli con up %q || true\n' \
                "$NETWORK_SNAPSHOT" "$NM_CON" >/usr/local/sbin/homeserver-ip-rollback
            chmod 700 /usr/local/sbin/homeserver-ip-rollback
            systemd-run --on-active=90s --unit=homeserver-ip-rollback /usr/local/sbin/homeserver-ip-rollback
            nmcli con mod "$NM_CON" ipv4.method manual ipv4.addresses "$SERVER_IP/$PREFIX" ipv4.gateway "$GATEWAY" ipv4.dns '1.1.1.1 9.9.9.9'
            SERVER_STATIC=1
            nmcli con up "$NM_CON" || true
            NETWORK_APPLY=nmcli
        fi
    fi
elif compgen -G '/etc/netplan/*.yaml' >/dev/null; then
    if ! grep -Rqs 'dhcp4:[[:space:]]*false' /etc/netplan; then
        NETPLAN_KIND=ethernets
        [[ ! -d /sys/class/net/$LAN_IFACE/wireless ]] || NETPLAN_KIND=wifis
        NETWORK_SNAPSHOT=/var/lib/homeserver/red-red
        mkdir -p "$NETWORK_SNAPSHOT"
        cp -a /etc/netplan "$NETWORK_SNAPSHOT/"
        cat >/usr/local/sbin/homeserver-ip-rollback <<EOF
#!/bin/bash
rm -f /etc/netplan/90-homeserver.yaml
cp -a "$NETWORK_SNAPSHOT/netplan/." /etc/netplan/
netplan apply || true
EOF
        cat >/etc/netplan/90-homeserver.yaml <<EOF
network:
  version: 2
  $NETPLAN_KIND:
    $LAN_IFACE:
      dhcp4: false
      addresses: [$SERVER_IP/$PREFIX]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [1.1.1.1, 9.9.9.9]
EOF
        chmod 700 /usr/local/sbin/homeserver-ip-rollback
        systemd-run --on-active=90s --unit=homeserver-ip-rollback /usr/local/sbin/homeserver-ip-rollback
        netplan apply || true
        NETWORK_APPLY='netplan apply'
    else
        SERVER_STATIC=1
    fi
elif [[ -f /etc/network/interfaces ]] && grep -RqsE "iface[[:space:]]+${LAN_IFACE}[[:space:]]+inet[[:space:]]+dhcp" /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null; then
    NETWORK_SNAPSHOT=/var/lib/homeserver/red-red
    mkdir -p "$NETWORK_SNAPSHOT"
    cp -a /etc/network/interfaces "$NETWORK_SNAPSHOT/"
    [[ ! -d /etc/network/interfaces.d ]] || cp -a /etc/network/interfaces.d "$NETWORK_SNAPSHOT/"
    cat >/usr/local/sbin/homeserver-ip-rollback <<EOF
#!/bin/bash
cp -a "$NETWORK_SNAPSHOT/interfaces" /etc/network/interfaces
if [ -d "$NETWORK_SNAPSHOT/interfaces.d" ]; then cp -a "$NETWORK_SNAPSHOT/interfaces.d/." /etc/network/interfaces.d/; fi
systemctl restart networking || true
EOF
    chmod 700 /usr/local/sbin/homeserver-ip-rollback
    systemd-run --on-active=90s --unit=homeserver-ip-rollback /usr/local/sbin/homeserver-ip-rollback
    python3 - "$LAN_IFACE" "$SERVER_IP" "$PREFIX" "$GATEWAY" <<'PY'
from pathlib import Path
import re, sys
iface, address, prefix, gateway = sys.argv[1:]
files = [Path("/etc/network/interfaces"), *Path("/etc/network/interfaces.d").glob("*")]
for path in files:
    if not path.is_file():
        continue
    text = path.read_text()
    pattern = re.compile(r"(?ms)^(iface\s+" + re.escape(iface) + r"\s+inet\s+)dhcp(.*?)(?=^iface\s|\Z)")
    def replace(match):
        body = re.sub(r"(?m)^\s*(?:address|gateway|dns-nameservers)\s+.*\n?", "", match.group(2))
        return match.group(1) + "static" + body + f"\n    address {address}/{prefix}\n    gateway {gateway}\n    dns-nameservers 1.1.1.1 9.9.9.9\n"
    path.write_text(pattern.sub(replace, text))
PY
    NETWORK_APPLY='systemctl restart networking'
    systemctl restart networking || true
elif [[ -f /etc/network/interfaces ]] && grep -RqsE "iface[[:space:]]+${LAN_IFACE}[[:space:]]+inet[[:space:]]+static" /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null; then
    SERVER_STATIC=1
elif systemctl is-active --quiet systemd-networkd && ! compgen -G '/etc/netplan/*.yaml' >/dev/null; then
    NETWORKD_STATIC=0
    for archivo in /etc/systemd/network/*.network; do
        [[ -f $archivo ]] || continue
        if grep -Eq "^[[:space:]]*Name=$LAN_IFACE([[:space:]]|$)" "$archivo" &&
            grep -qE '^[[:space:]]*Address=' "$archivo"; then
            NETWORKD_STATIC=1
            break
        fi
    done
    if [[ $NETWORKD_STATIC == 1 ]]; then
        SERVER_STATIC=1
    else
    NETWORK_SNAPSHOT=/var/lib/homeserver/red-red
    mkdir -p "$NETWORK_SNAPSHOT"
    cp -a /etc/systemd/network "$NETWORK_SNAPSHOT/" 2>/dev/null || true
    cat >/usr/local/sbin/homeserver-ip-rollback <<EOF
#!/bin/bash
rm -f /etc/systemd/network/10-homeserver.network
cp -a "$NETWORK_SNAPSHOT/network/." /etc/systemd/network/ 2>/dev/null || true
systemctl restart systemd-networkd || true
EOF
    chmod 700 /usr/local/sbin/homeserver-ip-rollback
    systemd-run --on-active=90s --unit=homeserver-ip-rollback /usr/local/sbin/homeserver-ip-rollback
    cat >/etc/systemd/network/10-homeserver.network <<EOF
[Match]
Name=$LAN_IFACE

[Network]
DHCP=no
Address=$SERVER_IP/$PREFIX
Gateway=$GATEWAY
DNS=1.1.1.1
DNS=9.9.9.9
EOF
    systemctl restart systemd-networkd || true
    NETWORK_APPLY='systemctl restart systemd-networkd'
    fi
else
    printf 'No se detectó un gestor compatible para fijar la IP; se conserva DHCP.\n'
    SERVER_STATIC=0
fi
if [[ -n ${NETWORK_APPLY:-} ]]; then
    red_validada=false
    for ((i=0; i<60; i++)); do
        if ip -4 -o addr show dev "$LAN_IFACE" | awk -v address="$SERVER_IP/$PREFIX" '$4 == address {found=1} END {exit !found}' &&
            ip -4 route show default dev "$LAN_IFACE" | awk -v gateway="$GATEWAY" '$1 == "default" && $2 == "via" && $3 == gateway {found=1} END {exit !found}' &&
            curl -fsS --max-time 10 -o /dev/null https://deb.debian.org; then
            red_validada=true
            break
        fi
        sleep 1
    done
    if [[ $red_validada == true ]]; then
        systemctl stop homeserver-ip-rollback.timer 2>/dev/null || true
        SERVER_STATIC=1
    else
        printf 'Validación de red fallida para %s; direcciones actuales:\n' "$LAN_IFACE" >&2
        ip -4 -o addr show dev "$LAN_IFACE" >&2 || true
        printf 'Rutas predeterminadas actuales:\n' >&2
        ip -4 route show default >&2 || true
        curl -sS --max-time 10 -o /dev/null -w 'Respuesta HTTP de https://deb.debian.org: %{http_code}\n' \
            https://deb.debian.org >&2 || true
        /usr/local/sbin/homeserver-ip-rollback || true
        systemctl stop homeserver-ip-rollback.timer 2>/dev/null || true
        SERVER_STATIC=0
        printf 'No se pudo validar la red; se restauró la configuración anterior y se conserva DHCP.\n'
    fi
fi
printf 'LAN_IFACE=%q\nSERVER_IP=%q\nLAN_CIDR=%q\nGATEWAY=%q\nBACKUP_TARGET=%q\nTELEGRAM_CONFIGURED=%q\nSERVER_STATIC=%q\nTZ_HOST=%q\n' \
    "$LAN_IFACE" "$SERVER_IP" "$LAN_CIDR" "$GATEWAY" "${BACKUP_TARGET:-$BASE_DIR/backups/borg}" "${TELEGRAM_BOT_CONFIGURED:-no}" "$SERVER_STATIC" "$TZ_HOST" >"$CONFIG_DIR/homeserver.conf"
chmod 600 "$CONFIG_DIR/homeserver.conf"
escribir_env SERVER_IP "$SERVER_IP"
escribir_env LAN_CIDR "$LAN_CIDR"
escribir_env GATEWAY "$GATEWAY"
escribir_env TZ_HOST "$TZ_HOST"
[[ -n $(leer_env BESZEL_KEY) ]] || escribir_env BESZEL_KEY ""

paso 'Configurando seguridad, firewall y servicios del sistema' '8/14'
cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
banaction = nftables-multiport
action = %(action_)s
         homeserver-notificar[name=%(__name__)s]

[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
EOF
cat >/etc/fail2ban/action.d/homeserver-notificar.conf <<'EOF'
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/bin/homeserver-notificar "Fail2ban bloqueó <ip> en <name>"
actionunban =
EOF

paso 'Generando ayudantes para notificaciones, discos, copias y alertas' '9/14'
cat >/usr/local/bin/homeserver-notificar <<'EOF'
#!/usr/bin/env bash
set -u
texto=${1:-}
markup=${2:-}
if [[ -r /etc/homeserver/telegram.env ]]; then
    # shellcheck source=/dev/null
    source /etc/homeserver/telegram.env
fi
if [[ -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ]]; then
    logger -t homeserver-notificar -- "$texto"
    exit 0
fi
args=(--data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "text=$texto")
[[ -z $markup ]] || args+=(--data-urlencode "reply_markup=$markup")
curl -fsS --max-time 20 "$TELEGRAM_API/bot${TELEGRAM_BOT_TOKEN}/sendMessage" "${args[@]}" >/dev/null || logger -t homeserver-notificar -- "No se pudo enviar una notificación de Telegram."
EOF

cat >/usr/local/bin/homeserver-disco <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=/opt/homeserver
PEND=/var/lib/homeserver/discos
CONF=/etc/homeserver/discos.conf
CONFIG=/etc/homeserver/homeserver.conf
ENVF=/opt/homeserver/.env
mkdir -p "$PEND" /mnt/respaldos /mnt/almacenamiento
touch "$CONF"
chmod 600 "$CONF"
# shellcheck source=/dev/null
[[ ! -r $CONFIG ]] || source "$CONFIG"
# shellcheck source=/dev/null
[[ ! -r $ENVF ]] || { set -a; source "$ENVF"; set +a; }
# shellcheck source=/dev/null
[[ ! -r /etc/homeserver/telegram.env ]] || source /etc/homeserver/telegram.env

sanear() {
    tr '[:upper:] ' '[:lower:]_' <<<"$1" | tr -cd '[:alnum:]_.-'
}

id_disco_largo() {
    local dev=$1 serial wwn link
    serial=$(lsblk -dn -o SERIAL "$dev" | xargs)
    wwn=$(lsblk -dn -o WWN "$dev" | xargs)
    link=$(find /dev/disk/by-id -maxdepth 1 -type l -lname "../../$(basename "$dev")" -print -quit 2>/dev/null || true)
    sanear "${wwn:-${serial:-${link##*/}}}"
}

id_disco() {
    printf '%s' "$(id_disco_largo "$1")" | sha1sum | cut -c1-10
}

notificar() {
    /usr/local/bin/homeserver-notificar "$1" "${2:-}"
}

registrar_pendiente() {
    local kname=$1 disk=/dev/$1 id id_largo size model fs origen destino
    [[ -b $disk ]] || exit 0
    [[ $kname =~ ^(loop|ram|zram|sr|md|dm-) ]] && exit 0
    for destino in / /boot; do
        origen=$(findmnt -rn -o SOURCE -T "$destino" 2>/dev/null || true)
        [[ -b $origen ]] || continue
        lsblk -s -nrpo NAME "$origen" 2>/dev/null | grep -Fxq "$disk" && exit 0
    done
    while IFS= read -r origen; do
        [[ -b $origen ]] || continue
        lsblk -s -nrpo NAME "$origen" 2>/dev/null | grep -Fxq "$disk" && exit 0
    done < <(swapon --noheadings --raw --show=NAME 2>/dev/null)
    for origen in /dev/md* /dev/dm-* /dev/mapper/*; do
        [[ -b $origen ]] || continue
        lsblk -s -nrpo NAME "$origen" 2>/dev/null | grep -Fxq "$disk" && exit 0
    done
    size=$(blockdev --getsize64 "$disk")
    ((size >= 1073741824)) || exit 0
    [[ -z $(lsblk -nrpo MOUNTPOINT "$disk" | sed '/^$/d') ]] || exit 0
    id_largo=$(id_disco_largo "$disk")
    [[ -n $id_largo ]] || id_largo=$kname
    grep -q "^${id_largo}|" "$CONF" && exit 0
    id=$(printf '%s' "$id_largo" | sha1sum | cut -c1-10)
    model=$(lsblk -dn -o MODEL "$disk" | xargs)
    model=${model:-Disco $kname}
    fs=$(lsblk -nrpo FSTYPE "$disk" | sed '/^$/d' | head -n 1 || true)
    printf 'kname=%q\nmodelo=%q\ntamano=%q\nfs=%q\ndisk_id_largo=%q\n' "$kname" "$model" "$size" "$fs" "$id_largo" >"$PEND/$id.pending"
    if [[ -n ${TELEGRAM_BOT_TOKEN:-} ]]; then
        keyboard='{"inline_keyboard":[[{"text":"Respaldos","callback_data":"respaldos:'"$id"'"},
{"text":"Almacenamiento","callback_data":"almacenamiento:'"$id"'"},
{"text":"Ignorar","callback_data":"ignorar:'"$id"'"}]]}'
        notificar "Disco nuevo detectado: $model $(numfmt --to=iec --suffix=B "$size") (${fs:-vacío}). ¿Para qué lo quieres usar?" "$keyboard"
    else
        install -d -m 0755 /etc/update-motd.d
        cat >/etc/update-motd.d/99-homeserver <<'MOTD'
#!/bin/sh
echo "Hay discos pendientes de configurar. Ejecuta: sudo homeserver-disco"
MOTD
        chmod 755 /etc/update-motd.d/99-homeserver
    fi
}

menu_pendiente() {
    local pending_id=$1 file model size fs fslabel modelo='' tamano=''
    file=$PEND/$pending_id.pending
    [[ -r $file ]] || { echo "No existe el disco pendiente $pending_id" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$file"
    model=$modelo
    size=$tamano
    fslabel=${fs:-vacío}
    if [[ -z ${TELEGRAM_BOT_TOKEN:-} ]]; then
        printf '%s (%s, %s): ejecutar homeserver-disco aplicar %s respaldos|almacenamiento [formatear]\n' "$model" "$(numfmt --to=iec --suffix=B "$size")" "$fslabel" "$pending_id"
        return
    fi
    notificar "Disco nuevo detectado: $model $(numfmt --to=iec --suffix=B "$size") (${fs:-vacío}). ¿Para qué lo quieres usar?"
}

aplicar() {
    local pending_id=$1 tipo=$2 accion=${3:-} file kname='' model fs='' modelo='' tamano='' dev uuid label mnt nombre part fs_part mount_opts disk_id_largo='' id=''
    file=$PEND/$pending_id.pending
    [[ -r $file ]] || { echo "No existe el disco pendiente $pending_id" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$file"
    disk_id_largo=${disk_id_largo:-${id:-$pending_id}}
    # shellcheck source=/dev/null
    [[ ! -r /etc/homeserver/user.conf ]] || source /etc/homeserver/user.conf
    model=$modelo
    dev=/dev/$kname
    [[ $tipo == respaldos || $tipo == almacenamiento ]] || { echo "Destino no válido." >&2; return 1; }
    if [[ -n $fs && $accion != formatear ]]; then
        part=$(lsblk -b -nrpo NAME,FSTYPE,SIZE "$dev" | awk '$2 != "" {print $1, $3}' | sort -k2,2nr | awk 'NR==1 {print $1}')
        [[ -n $part ]] || { echo "No se encontró una partición con sistema de archivos." >&2; return 1; }
        fs_part=$(blkid -s TYPE -o value "$part")
        case $fs_part in ext4|xfs|btrfs|ntfs|exfat|vfat) ;; *) echo "Sistema de archivos no admitido: $fs_part" >&2; return 1 ;; esac
    else
        if [[ -n $fs && $accion != formatear ]]; then
            echo "Este disco contiene datos. Indica formatear solo después de confirmar BORRAR." >&2
            return 1
        fi
        if [[ -n $fs && $accion == formatear ]]; then
            if [[ ${CONFIRMAR:-} != BORRAR ]]; then
                [[ -t 0 ]] || { echo "Confirma el formateo con CONFIRMAR=BORRAR." >&2; return 1; }
                read -r -p "Esto borra todo el contenido de $model. Escribe BORRAR para continuar: " CONFIRMAR
                [[ $CONFIRMAR == BORRAR ]] || { echo "No se confirmó el formateo." >&2; return 1; }
            fi
        fi
        wipefs -a "$dev"
        parted -s "$dev" mklabel gpt mkpart primary ext4 1MiB 100%
        partprobe "$dev"
        udevadm settle
        part=$(lsblk -nrpo NAME "$dev" | awk 'NR==2 {print $1}')
        label=hs-$tipo
        [[ $tipo != almacenamiento ]] || label=hs-almacenamiento
        mkfs.ext4 -F -L "$label" "$part"
        fs_part=ext4
    fi
    uuid=$(blkid -s UUID -o value "$part")
    mount_opts=nofail,x-systemd.device-timeout=10s
    case $fs_part in
        ntfs|exfat|vfat) mount_opts=uid=33,gid=33,umask=002,nofail,x-systemd.device-timeout=10s ;;
    esac
    if [[ $tipo == respaldos ]]; then
        nombre=respaldos
        mnt=/mnt/respaldos
    else
        nombre=$(sanear "${fs:+$(blkid -s LABEL -o value "$part")}")
        [[ -n $nombre ]] || nombre=$(sanear "$model")
        [[ -n $nombre ]] || nombre="disco-$kname"
        local base=$nombre n=1
        while [[ -e /mnt/almacenamiento/$nombre ]] && ! grep -q "UUID=$uuid" /etc/fstab; do
            nombre="${base}-$n"
            n=$((n + 1))
        done
        mnt=/mnt/almacenamiento/$nombre
    fi
    install -d -m 0775 "$mnt"
    if ! grep -q "UUID=$uuid" /etc/fstab; then
        printf 'UUID=%s %s %s %s 0 2\n' "$uuid" "$mnt" "$fs_part" "$mount_opts" >>/etc/fstab
    fi
    mount "$mnt" || mount -a
    printf '%s|%s|%s|%s|%s|%s\n' "$disk_id_largo" "$kname" "$tipo" "$mnt" "$uuid" "$nombre" >>"$CONF"
    rm -f "$file"
    if [[ $tipo == almacenamiento ]]; then
        for directorio in Peliculas Series Musica Archivos .beszel; do
            if [[ $fs_part == ntfs || $fs_part == exfat || $fs_part == vfat ]]; then
                mkdir -p "$mnt/$directorio"
            elif [[ -n ${HS_USER:-} ]]; then
                install -d -m 2775 -o "$HS_USER" -g www-data "$mnt/$directorio"
            else
                install -d -m 2775 -o www-data -g www-data "$mnt/$directorio"
            fi
        done
        actualizar_montajes "$nombre" "$mnt"
    else
        mkdir -p "$mnt/.beszel"
        [[ $fs_part == ntfs || $fs_part == exfat || $fs_part == vfat ]] || chown root:root "$mnt"
        export BORG_PASSCOMMAND='cat /root/.config/homeserver/borg-passphrase'
        export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
        if [[ -d $BASE/backups/borg ]]; then
            if borg info "$BASE/backups/borg" >/dev/null 2>&1; then
                if [[ -e $mnt/borg ]]; then
                    notificar "Ya existe un repositorio de Borg en $mnt/borg; se conservaron ambos repositorios."
                else
                    rsync -a "$BASE/backups/borg/" "$mnt/borg/"
                    borg info "$mnt/borg" >/dev/null
                    rm -rf "$BASE/backups/borg"
                    mkdir -p "$BASE/backups"
                fi
            fi
        fi
        sed -i "s|^BACKUP_TARGET=.*|BACKUP_TARGET=/mnt/respaldos/borg|" "$CONFIG"
        notificar "Respaldos ahora en disco externo"
    fi
    [[ ! -x /usr/local/bin/homeserver-compose ]] || /usr/local/bin/homeserver-compose
    if docker inspect beszel-agent >/dev/null 2>&1; then
        docker compose -f "$BASE/docker-compose.yml" up -d --force-recreate beszel-agent homepage
    fi
    if [[ $tipo == respaldos ]]; then
        notificar "Disco $model configurado como Respaldos en $mnt"
    else
        notificar "Disco $model configurado como Almacenamiento en $mnt"
    fi
    echo "Disco configurado en $mnt"
}

actualizar_montajes() {
    local nombre=$1 mnt=$2
    [[ ! -x /usr/local/bin/homeserver-compose ]] || /usr/local/bin/homeserver-compose
    if docker inspect beszel-agent >/dev/null 2>&1; then
        docker compose -f "$BASE/docker-compose.yml" up -d --force-recreate beszel-agent homepage
    fi
    if [[ -x /usr/local/bin/homeserver-jellyfin ]]; then
        /usr/local/bin/homeserver-jellyfin agregar "$nombre" "/mnt/almacenamiento/$nombre" || true
    fi
    if docker exec nextcloud php occ status >/dev/null 2>&1; then
        docker exec -u www-data nextcloud php occ app:enable files_external || true
        docker exec -u www-data nextcloud php occ files_external:create "$nombre" local null::null -c datadir="$mnt/Archivos" || true
    fi
}

ignorar() {
    local pending_id=$1 file disk_id_largo='' id=''
    file=$PEND/$pending_id.pending
    [[ -r $file ]] || { echo "No existe el disco pendiente $pending_id" >&2; return 1; }
    # shellcheck source=/dev/null
    source "$file"
    disk_id_largo=${disk_id_largo:-${id:-$pending_id}}
    printf '%s|%s|ignorar|-|-|-\n' "$disk_id_largo" "$kname" >>"$CONF"
    rm -f "$file"
    notificar "Disco ignorado"
    echo "Disco ignorado."
}

case ${1:-} in
    detectar) registrar_pendiente "${2:?Falta el nombre del disco}" ;;
    aplicar) aplicar "${2:?Falta el identificador}" "${3:?Falta el destino}" "${4:-}" ;;
    ignorar) ignorar "${2:?Falta el identificador}" ;;
    callback)
        accion=${2:?Falta la acción}
        case $accion in
            respaldos|almacenamiento)
                pending_id=${3:?Falta el identificador}
                file=$PEND/$pending_id.pending
                [[ -r $file ]] || exit 0
                # shellcheck source=/dev/null
                source "$file"
                if [[ -n $fs ]]; then
                    keyboard='{"inline_keyboard":[[{"text":"Usar sin borrar","callback_data":"usar:'"$accion"':'"$pending_id"'"},
{"text":"Formatear","callback_data":"formatear:'"$accion"':'"$pending_id"'"}]]}'
                    notificar "El disco $modelo contiene datos ($fs). ¿Cómo continuar?" "$keyboard"
                else
                    aplicar "$pending_id" "$accion" formatear
                fi
                ;;
            ignorar) ignorar "${3:?Falta el identificador}" ;;
            usar)
                destino=${3:?Falta el destino}
                pending_id=${4:?Falta el identificador}
                aplicar "$pending_id" "$destino" usar
                ;;
            formatear)
                destino=${3:?Falta el destino}
                pending_id=${4:?Falta el identificador}
                keyboard='{"inline_keyboard":[[{"text":"Sí, borrar","callback_data":"borrar:'"${3:?Falta el destino}"':'"$pending_id"'"},
{"text":"Cancelar","callback_data":"cancelar:'"${3:?Falta el destino}"':'"$pending_id"'"}]]}'
                notificar "Esto BORRA todo el contenido del disco. ¿Confirmar?" "$keyboard"
                ;;
            borrar)
                destino=${3:?Falta el destino}
                pending_id=${4:?Falta el identificador}
                export CONFIRMAR=BORRAR
                file=$PEND/$pending_id.pending
                [[ -r $file ]] || exit 0
                # shellcheck source=/dev/null
                source "$file"
                aplicar "$pending_id" "$destino" formatear
                ;;
            cancelar) notificar "Se canceló la operación con el disco." ;;
            *) exit 1 ;;
        esac
        ;;
    *)
        shopt -s nullglob
        files=("$PEND"/*.pending)
        if ((${#files[@]} == 0)); then
            echo "No hay discos pendientes."
            exit 0
        fi
        for file in "${files[@]}"; do
            pending_id=${file##*/}
            pending_id=${pending_id%.pending}
            menu_pendiente "$pending_id"
            if [[ -t 0 ]]; then
                read -r -p 'Destino [1] Respaldos [2] Almacenamiento [3] Ignorar: ' opcion
                case $opcion in
                    1) destino=respaldos ;;
                    2) destino=almacenamiento ;;
                    3) ignorar "$pending_id"; continue ;;
                    *) continue ;;
                esac
                # shellcheck source=/dev/null
                source "$file"
                formato=""
                if [[ -n $fs ]]; then
                    read -r -p '[1] Usar sin borrar [2] Formatear: ' formato
                    if [[ $formato == 2 ]]; then
                        read -r -p 'Escribe BORRAR para confirmar: ' confirma
                        [[ $confirma == BORRAR ]] || continue
                        export CONFIRMAR=BORRAR
                        formato=formatear
                    else
                        formato=usar
                    fi
                else
                    formato=formatear
                    export CONFIRMAR=BORRAR
                fi
                aplicar "$pending_id" "$destino" "$formato"
            fi
        done
        ;;
esac
EOF

cat >/usr/local/bin/homeserver-respaldo <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
BASE=/opt/homeserver
LOG=/var/log/homeserver-respaldo.log
LOCK=/run/lock/homeserver-respaldo.lock
fallo() {
    local codigo=$?
    /usr/local/bin/homeserver-notificar "Falló el respaldo del servidor: $(tail -n 25 "$LOG" 2>/dev/null | tr '\n' ' ')" || true
    exit "$codigo"
}
trap fallo ERR
exec 9>"$LOCK"
flock -n 9 || exit 0
exec > >(tee -a "$LOG") 2>&1
# shellcheck source=/dev/null
[[ ! -r /etc/homeserver/homeserver.conf ]] || source /etc/homeserver/homeserver.conf
# shellcheck source=/dev/null
[[ ! -r $BASE/.env ]] || { set -a; source "$BASE/.env"; set +a; }
export SERVER_IP LAN_CIDR TZ_HOST
# shellcheck source=/dev/null
[[ ! -r /etc/homeserver/telegram.env ]] || source /etc/homeserver/telegram.env

repo=$BASE/backups/borg
if grep -q '|respaldos|' /etc/homeserver/discos.conf 2>/dev/null; then
    if mountpoint -q /mnt/respaldos; then
        repo=/mnt/respaldos/borg
    else
        /usr/local/bin/homeserver-notificar "Disco de respaldos desconectado"
        echo "El disco externo no está montado; se usará el repositorio local."
    fi
fi
install -d -m 0700 "$(dirname "$repo")"
if [[ -z ${BORG_PASSPHRASE_FILE:-} ]]; then
    install -d -m 0700 /root/.config/homeserver
    printf '%s' "${BORG_PASSPHRASE:?Falta la frase de Borg}" >/root/.config/homeserver/borg-passphrase
    chmod 600 /root/.config/homeserver/borg-passphrase
    BORG_PASSPHRASE_FILE=/root/.config/homeserver/borg-passphrase
fi
unset BORG_PASSPHRASE
export BORG_REPO=$repo
export BORG_PASSCOMMAND="cat $BORG_PASSPHRASE_FILE"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
if [[ $repo == "$BASE/backups/borg" ]]; then
    BORG_CACHE_DIR=/root/.config/homeserver/borg-local-cache
    BORG_SECURITY_DIR=/root/.config/homeserver/borg-local-security
    install -d -m 0700 "$BORG_CACHE_DIR" "$BORG_SECURITY_DIR"
    export BORG_CACHE_DIR BORG_SECURITY_DIR
fi
if ! borg info "$repo" >/dev/null 2>&1; then
    borg init --encryption=repokey-blake2 "$repo"
fi
if [[ ! -f /root/homeserver-borg-key.txt ]]; then
    borg key export "$repo" /root/homeserver-borg-key.txt
    chmod 600 /root/homeserver-borg-key.txt
fi
mkdir -p "$BASE/nextcloud/db-dump"
if docker exec -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" nextcloud-db mariadb-dump --single-transaction -u root nextcloud >"$BASE/nextcloud/db-dump/nextcloud.sql"; then
    chmod 600 "$BASE/nextcloud/db-dump/nextcloud.sql"
else
    echo "No se pudo exportar la base de datos de Nextcloud." >&2
    false
fi
archive="homeserver-$(date +%F-%H%M)"
borg create --stats "$repo::$archive" "$BASE" \
    --exclude "$BASE/backups" \
    --exclude "$BASE/jellyfin/media" \
    --exclude "$BASE/jellyfin/cache" \
    --exclude "$BASE/nextcloud/db"
borg prune -v --list "$repo" --keep-daily 7 --keep-weekly 4 --keep-monthly 6
borg compact "$repo"
size=$(borg info --json "$repo::$archive" | jq -r '.archives[0].stats.compressed_size // 0')
/usr/local/bin/homeserver-notificar "Respaldo correcto: $archive; tamaño comprimido: $(numfmt --to=iec "$size"); repositorio: $repo"
if [[ $repo == "$BASE/backups/borg" ]]; then
    advertencia="Los respaldos están en el mismo disco del sistema: si el disco falla se pierden. Conecta otro disco o copia /opt/homeserver/backups a otro lugar."
    echo "$advertencia"
    /usr/local/bin/homeserver-notificar "$advertencia"
fi
date +%s >/var/lib/homeserver/ultimo-respaldo
EOF

cat >/usr/local/bin/homeserver-alertas <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE=/var/lib/homeserver/alertas
mkdir -p "$STATE"
avisar() {
    local key=$1 problem=$2 resolved=${3:-}
    if [[ -n $problem ]]; then
        if [[ ! -f $STATE/$key || $(<"$STATE/$key") != problema ]]; then
            /usr/local/bin/homeserver-notificar "$problem"
            printf problema >"$STATE/$key"
        fi
    elif [[ -f $STATE/$key ]] && [[ $(<"$STATE/$key") == problema ]]; then
        /usr/local/bin/homeserver-notificar "${resolved:-Resuelto: $key}"
        printf resuelto >"$STATE/$key"
    fi
}
while read -r target; do
    [[ -n $target ]] || continue
    usage=$(df -P "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    if [[ -n $usage && $usage -gt 85 ]]; then
        avisar "disco-$(echo "$target" | tr / _)" "Uso de disco superior al 85 %: $target ($usage %)" "Resuelto: uso de disco en $target volvió a $usage %"
    else
        avisar "disco-$(echo "$target" | tr / _)" "" "Resuelto: uso de disco en $target volvió a $usage %"
    fi
done < <(findmnt -rn -o TARGET | awk '$1=="/" || $1=="/mnt/respaldos" || $1 ~ /^\/mnt\/almacenamiento\// {print $1}')
mem=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {if (t>0) print int((t-a)*100/t); else print 0}' /proc/meminfo)
if ((mem > 90)); then
    avisar memoria "Uso de memoria superior al 90 %: ${mem} %"
else
    avisar memoria "" "Resuelto: memoria"
fi
read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
total=$((user + nice + system + idle + iowait + irq + softirq + steal))
busy=$((total - idle - iowait))
if [[ -r $STATE/cpu-counters ]]; then
    read -r old_total old_busy <"$STATE/cpu-counters"
    delta_total=$((total - old_total))
    delta_busy=$((busy - old_busy))
    cpu=0
    ((delta_total > 0)) && cpu=$((100 * delta_busy / delta_total))
    if ((cpu > 90)); then
        count=$(cat "$STATE/cpu-high" 2>/dev/null || printf 0)
        count=$((count + 1))
        printf '%s' "$count" >"$STATE/cpu-high"
        ((count < 2)) || avisar cpu "Uso de CPU superior al 90 % en dos mediciones: ${cpu} %"
    else
        rm -f "$STATE/cpu-high"
        avisar cpu "" "Resuelto: uso de CPU"
    fi
fi
printf '%s %s\n' "$total" "$busy" >"$STATE/cpu-counters"
servicios_malos=$(docker compose -f /opt/homeserver/docker-compose.yml ps -a --format json 2>/dev/null |
    jq -r 'select((.State // "") != "running" or ((.Health // "") != "" and .Health != "healthy")) | (.Service // .Name)' |
    paste -sd ', ' -)
if [[ -n $servicios_malos ]]; then
    avisar contenedores "Servicios detenidos o no saludables: $servicios_malos"
else
    avisar contenedores "" "Resuelto: todos los servicios están en ejecución y saludables"
fi
if grep -q '|respaldos|' /etc/homeserver/discos.conf 2>/dev/null && ! mountpoint -q /mnt/respaldos; then
    avisar respaldo-disco "Disco de respaldos desconectado"
else
    avisar respaldo-disco "" "Resuelto: el disco de respaldos está conectado"
fi
ultimo=$(cat /var/lib/homeserver/ultimo-respaldo 2>/dev/null || printf 0)
if (( $(date +%s) - ultimo > 93600 )); then
    avisar respaldo-antiguo "El último respaldo exitoso tiene más de 26 horas."
else
    avisar respaldo-antiguo "" "Resuelto: el respaldo tiene menos de 26 horas"
fi
EOF

cat >/usr/local/bin/homeserver-bot <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source /etc/homeserver/telegram.env
OFFSET_FILE=/var/lib/homeserver/bot.offset
mkdir -p /var/lib/homeserver
offset=$(cat "$OFFSET_FILE" 2>/dev/null || printf 0)
while true; do
    respuesta=$(curl -fsS --max-time 65 "$TELEGRAM_API/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=50&offset=${offset}" || true)
    if [[ -z $respuesta ]]; then
        sleep 2
        continue
    fi
    while IFS= read -r update; do
        [[ -n $update ]] || continue
        update_id=$(jq -r '.update_id' <<<"$update")
        offset=$((update_id + 1))
        printf '%s' "$offset" >"$OFFSET_FILE"
        chat=$(jq -r '.message.chat.id // .callback_query.message.chat.id // empty' <<<"$update")
        [[ $chat == "$TELEGRAM_CHAT_ID" ]] || continue
        callback=$(jq -r '.callback_query.data // empty' <<<"$update")
        if [[ -n $callback ]]; then
            callback_id=$(jq -r '.callback_query.id' <<<"$update")
            curl -fsS "$TELEGRAM_API/bot${TELEGRAM_BOT_TOKEN}/answerCallbackQuery" --data-urlencode "callback_query_id=$callback_id" >/dev/null || true
            message_id=$(jq -r '.callback_query.message.message_id // empty' <<<"$update")
            [[ -z $message_id ]] || curl -fsS "$TELEGRAM_API/bot${TELEGRAM_BOT_TOKEN}/editMessageReplyMarkup" --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" --data-urlencode "message_id=$message_id" --data-urlencode 'reply_markup={"inline_keyboard":[]}' >/dev/null || true
            IFS=: read -r action destino id <<<"$callback"
            callback_log=$(mktemp)
            if ! /usr/local/bin/homeserver-disco callback "$action" "$destino" "$id" 2>"$callback_log"; then
                last_error=$(tail -n 1 "$callback_log")
                /usr/local/bin/homeserver-notificar "No se pudo configurar el disco: ${last_error:-error desconocido}"
            fi
            rm -f "$callback_log"
            continue
        fi
        comando=$(jq -r '.message.text // empty' <<<"$update")
        case ${comando%%@*} in
            /ayuda)
                /usr/local/bin/homeserver-notificar "Comandos: /estado muestra el estado del servidor; /ayuda muestra esta ayuda."
                ;;
            /estado)
                cpu=$(awk 'NR==1 {print $1}' /proc/loadavg)
                ram=$(free -h | awk '/Mem:/ {print $3 " de " $2}')
                disco=$(df -h / | awk 'NR==2 {print $3 " de " $2 " (" $5 ")"}')
                contenedores=$(docker compose -f /opt/homeserver/docker-compose.yml ps --format '{{.Name}}: {{.State}}' | tr '\n' '; ')
                if [[ -r /var/lib/homeserver/ultimo-respaldo ]]; then
                    respaldo=$(date -d "@$(cat /var/lib/homeserver/ultimo-respaldo)" '+%F %T' 2>/dev/null || printf 'sin respaldo')
                else
                    respaldo='sin respaldo'
                fi
                /usr/local/bin/homeserver-notificar "Estado: carga $cpu; RAM $ram; disco raíz $disco; contenedores $contenedores; último respaldo $respaldo."
                ;;
        esac
    done < <(jq -c '.result[]?' <<<"$respuesta")
done
EOF

cat >/usr/local/bin/homeserver-jellyfin <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source /opt/homeserver/.env
BASE=http://127.0.0.1:8096
jf_auth() {
    printf 'Authorization: MediaBrowser Client="homeserver", Device="Servidor", DeviceId="homeserver", Version="1.0", Token="%s"' "$1"
}
if [[ ${1:-} == agregar ]]; then
    nombre=$2
    ruta=$3
    token=${JELLYFIN_API_KEY:-}
    [[ -n $token ]] || exit 0
    for pair in "Películas|/mnt/almacenamiento/$nombre/Peliculas" "Series|/mnt/almacenamiento/$nombre/Series" "Música|/mnt/almacenamiento/$nombre/Musica"; do
        IFS='|' read -r titulo path <<<"$pair"
        [[ $path == "$ruta/"* ]] || continue
        curl --retry 10 --retry-delay 3 -fsS -X POST "$BASE/Library/VirtualFolders/Paths?name=$(jq -rn --arg v "$titulo" '$v|@uri')" \
            -H "$(jf_auth "$token")" -H 'Content-Type: application/json' \
            -d "$(jq -n --arg name "$titulo" --arg path "$path" '{Name:$name,Path:$path}')" >/dev/null || true
    done
    exit 0
fi
EOF

cat >/usr/local/bin/homeserver-api-setup <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=/opt/homeserver
# shellcheck source=/dev/null
source "$BASE/.env"
# shellcheck source=/dev/null
source /etc/homeserver/homeserver.conf

esperar_http() {
    local url=$1 intentos=${2:-120} n
    for ((n=0; n<intentos; n++)); do
        curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo "No respondió el servicio: $url" >&2
    return 1
}

escribir_env() {
    local clave=$1 valor=$2
    sed -i "/^${clave}=/d" "$BASE/.env"
    printf '%s="%s"\n' "$clave" "$valor" >>"$BASE/.env"
}

configurar_beszel() {
    esperar_http http://127.0.0.1:8090/api/health 180
    token=$(curl -fsS -X POST http://127.0.0.1:8090/api/collections/users/auth-with-password \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg identity admin@homeserver.local --arg password "$BESZEL_ADMIN_PASSWORD" '{identity:$identity,password:$password}')" | jq -r '.token')
    [[ -n $token && $token != null ]] || { echo "No se pudo autenticar en Beszel." >&2; return 1; }
    if [[ -z ${BESZEL_KEY:-} ]]; then
        BESZEL_KEY=$(curl -fsS http://127.0.0.1:8090/api/beszel/info -H "Authorization: $token" | jq -r '.key')
        [[ -n $BESZEL_KEY && $BESZEL_KEY != null ]] || { echo "Beszel no devolvió su clave pública." >&2; return 1; }
        curl -fsS -X POST http://127.0.0.1:8090/api/beszel/universal-token \
            -H "Authorization: $token" -H 'Content-Type: application/json' \
            -d "$(jq -n --arg tok "$BESZEL_TOKEN" '{enable:1,permanent:1,token:$tok}')" >/dev/null
        escribir_env BESZEL_KEY "$BESZEL_KEY"
        chmod 600 "$BASE/.env"
        docker compose -f "$BASE/docker-compose.yml" up -d beszel-agent
    fi
    for ((i=0; i<90; i++)); do
        records=$(curl -fsS http://127.0.0.1:8090/api/collections/systems/records -H "Authorization: $token" || true)
        if jq -e '.items[]? | select(.name == "homeserver" and (.status == "up" or .status == true))' <<<"$records" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "El agente Beszel no apareció en estado activo." >&2
    return 1
}

configurar_jellyfin() {
    local info='' wizard_completed='' startup_status='' public_users='' ready=false i
    for ((i=0; i<360; i++)); do
        info=$(curl -sS --max-time 5 http://127.0.0.1:8096/System/Info/Public 2>/dev/null || true)
        wizard_completed=$(jq -r '.StartupWizardCompleted // empty' <<<"$info" 2>/dev/null || true)
        if [[ $wizard_completed == true ]]; then
            if public_users=$(curl --retry 10 --retry-delay 3 -fsS --max-time 10 http://127.0.0.1:8096/Users/Public 2>/dev/null) &&
                jq -e 'type == "array"' <<<"$public_users" >/dev/null; then
                ready=true
                break
            fi
        else
            startup_status=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code} %{content_type}' \
                http://127.0.0.1:8096/Startup/Configuration 2>/dev/null || true)
            if [[ $startup_status == "200 application/json"* ]]; then
                ready=true
                break
            fi
        fi
        sleep 1
    done
    [[ $ready == true ]] || { echo "Jellyfin no terminó de iniciar dentro del tiempo esperado." >&2; return 1; }
    jf_curl() { curl --retry 10 --retry-delay 3 "$@"; }
    jf_auth() {
        printf 'Authorization: MediaBrowser Client="homeserver", Device="Servidor", DeviceId="homeserver", Version="1.0", Token="%s"' "$1"
    }
    if [[ -z ${JELLYFIN_API_KEY:-} ]]; then
        if [[ $wizard_completed != true ]]; then
            jf_curl -fsS -X GET http://127.0.0.1:8096/Startup/User >/dev/null
            jf_curl -fsS -X POST http://127.0.0.1:8096/Startup/Configuration \
                -H 'Content-Type: application/json' \
                -d '{"ServerName":"homeserver","UICulture":"es","MetadataCountryCode":"EC","PreferredMetadataLanguage":"es"}' >/dev/null
            jf_curl -fsS -X POST http://127.0.0.1:8096/Startup/User -H 'Content-Type: application/json' \
                -d "$(jq -n --arg name admin --arg pw "$JELLYFIN_ADMIN_PASSWORD" '{Name:$name,Password:$pw}')" >/dev/null
            jf_curl -fsS -X POST http://127.0.0.1:8096/Startup/RemoteAccess -H 'Content-Type: application/json' \
                -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
            jf_curl -fsS -X POST http://127.0.0.1:8096/Startup/Complete >/dev/null
        fi
        AUTH='Authorization: MediaBrowser Client="homeserver", Device="Servidor", DeviceId="homeserver", Version="1.0"'
        if ! auth=$(jf_curl -fsS -X POST http://127.0.0.1:8096/Users/AuthenticateByName \
            -H "$AUTH" -H 'Content-Type: application/json' \
            -d "$(jq -n --arg username admin --arg pw "$JELLYFIN_ADMIN_PASSWORD" '{Username:$username, Pw:$pw}')"); then
            if [[ $wizard_completed == true ]]; then
                echo "El asistente de Jellyfin ya terminó, pero la contraseña guardada no permite iniciar sesión. Revisa JELLYFIN_ADMIN_PASSWORD en $BASE/.env y la cuenta de Jellyfin." >&2
            else
                echo "No se pudo autenticar en Jellyfin después de configurar la cuenta de administrador." >&2
            fi
            return 1
        fi
        session=$(jq -r '.AccessToken' <<<"$auth")
        [[ -n $session && $session != null ]] || { echo "No se pudo autenticar en Jellyfin." >&2; return 1; }
        session_auth=$(jf_auth "$session")
        jf_curl -fsS -X POST 'http://127.0.0.1:8096/Auth/Keys?app=homeserver' \
            -H "$session_auth" >/dev/null
        keys=$(jf_curl -fsS http://127.0.0.1:8096/Auth/Keys -H "$session_auth")
        JELLYFIN_API_KEY=$(jq -r '.Items[] | select(.AppName=="homeserver") | .AccessToken' <<<"$keys" | head -n 1)
        [[ -n $JELLYFIN_API_KEY ]] || { echo "No se pudo crear la clave API de Jellyfin." >&2; return 1; }
        sed -i '/^JELLYFIN_API_KEY=/d' "$BASE/.env"
        printf 'JELLYFIN_API_KEY=%s\n' "$JELLYFIN_API_KEY" >>"$BASE/.env"
        chmod 600 "$BASE/.env"
    fi
    auth_header=$(jf_auth "$JELLYFIN_API_KEY")
    for item in 'Películas|movies|/media/Peliculas' 'Series|tvshows|/media/Series' 'Música|music|/media/Musica'; do
        IFS='|' read -r name collection path <<<"$item"
        if ! jf_curl -fsS http://127.0.0.1:8096/Library/VirtualFolders -H "$auth_header" | jq -e --arg name "$name" '.[]? | select(.Name==$name)' >/dev/null; then
            jf_curl -fsS -X POST "http://127.0.0.1:8096/Library/VirtualFolders?name=$(jq -rn --arg v "$name" '$v|@uri')&collectionType=$collection&refreshLibrary=true" \
                -H "$auth_header" -H 'Content-Type: application/json' \
                -d "$(jq -n --arg name "$name" --arg collection "$collection" --arg path "$path" '{Name:$name,CollectionType:$collection,Paths:[$path]}')" >/dev/null || true
        fi
    done
    folders=$(jf_curl -fsS http://127.0.0.1:8096/Library/VirtualFolders -H "$auth_header")
    for name in 'Películas' 'Series' 'Música'; do
        jq -e --arg name "$name" '.[]? | select(.Name==$name)' <<<"$folders" >/dev/null ||
            { echo "No se pudo crear la biblioteca de Jellyfin: $name." >&2; return 1; }
    done
}

configurar_nextcloud() {
    esperar_http http://127.0.0.1:8080/status.php 240
    docker exec -u www-data nextcloud php occ background:cron || true
    tailscale_ip=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -n 1 || true)
    if [[ -n $tailscale_ip ]]; then
        docker exec -u www-data nextcloud php occ config:system:set trusted_domains 4 --value="$tailscale_ip"
    fi
}

configurar_beszel
configurar_jellyfin
configurar_nextcloud
EOF

chmod 755 /usr/local/bin/homeserver-{notificar,disco,respaldo,alertas,bot,jellyfin,api-setup}

paso 'Generando la configuración del panel y servicios' '10/14'
cat >/usr/local/bin/homeserver-compose <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE=/opt/homeserver
DISKS=/etc/homeserver/discos.conf
# shellcheck source=/dev/null
[[ ! -r /etc/homeserver/homeserver.conf ]] || source /etc/homeserver/homeserver.conf
# shellcheck source=/dev/null
[[ ! -r $BASE/.env ]] || { set -a; source "$BASE/.env"; set +a; }
touch "$DISKS"
mkdir -p "$BASE/homepage/config"
cat >"$BASE/docker-compose.yml" <<'COMPOSE'
services:
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: docker-socket-proxy
    restart: unless-stopped
    environment:
      CONTAINERS: "1"
      IMAGES: "1"
      NETWORKS: "1"
      INFO: "1"
      VERSION: "1"
      EVENTS: "1"
      PING: "1"
      POST: "1"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - 127.0.0.1:2375:2375
    networks:
      - socket_proxy
  watchtower:
    image: nickfedor/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: ${TZ_HOST:-America/Guayaquil}
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_NOTIFICATION_URL: ${WATCHTOWER_NOTIFICATION_URL:-}
      DOCKER_HOST: tcp://docker-socket-proxy:2375
    networks:
      - socket_proxy
      - default
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    ports:
      - 3000:3000
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "*"
      DOCKER_HOST: tcp://docker-socket-proxy:2375
    volumes:
      - ./homepage/config:/app/config
      - type: bind
        source: /mnt
        target: /mnt
        read_only: true
        bind:
          propagation: rslave
    networks:
      - socket_proxy
      - default
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    restart: unless-stopped
    ports:
      - 8090:8090
    environment:
      APP_URL: http://homeserver.local:8090
      USER_EMAIL: admin@homeserver.local
      USER_PASSWORD: ${BESZEL_ADMIN_PASSWORD}
      TZ: ${TZ_HOST:-America/Guayaquil}
    volumes:
      - ./beszel/data:/beszel_data
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      HUB_URL: http://localhost:8090
      KEY: ${BESZEL_KEY:-}
      TOKEN: ${BESZEL_TOKEN}
      DOCKER_HOST: tcp://127.0.0.1:2375
      TZ: ${TZ_HOST:-America/Guayaquil}
    volumes:
      - ./beszel/agent:/var/lib/beszel-agent
  nextcloud-db:
    image: mariadb:10.11
    container_name: nextcloud-db
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW
    volumes:
      - ./nextcloud/db:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      TZ: ${TZ_HOST:-America/Guayaquil}
  nextcloud:
    image: nextcloud:production
    container_name: nextcloud
    restart: unless-stopped
    depends_on:
      - nextcloud-db
    ports:
      - 8080:80
    environment:
      MYSQL_HOST: nextcloud-db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: homeserver.local ${SERVER_IP} homeserver localhost
      TZ: ${TZ_HOST:-America/Guayaquil}
    volumes:
      - ./nextcloud/app:/var/www/html
      - type: bind
        source: /mnt/almacenamiento
        target: /mnt/almacenamiento
        bind:
          propagation: rslave
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - 8096:8096
    environment:
      TZ: ${TZ_HOST:-America/Guayaquil}
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - ./jellyfin/media:/media
      - type: bind
        source: /mnt/almacenamiento
        target: /mnt/almacenamiento
        bind:
          propagation: rslave
  adguardhome:
    image: adguard/adguardhome:latest
    container_name: adguardhome
    restart: unless-stopped
    ports:
      - 53:53/tcp
      - 53:53/udp
      - 8081:80/tcp
    environment:
      TZ: ${TZ_HOST:-America/Guayaquil}
    volumes:
      - ./adguard/work:/opt/adguardhome/work
      - ./adguard/conf:/opt/adguardhome/conf
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    command: --admin-password-file /run/secrets/admin_password
    ports:
      - 9443:9443
    volumes:
      - ./portainer/data:/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./portainer/admin_password:/run/secrets/admin_password:ro
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      TS_STATE_DIR: /var/lib/tailscale
      TS_HOSTNAME: homeserver
      TS_AUTHKEY: ${TS_AUTHKEY:-}
      TS_ROUTES: ${LAN_CIDR}
      TS_USERSPACE: "false"
      TZ: ${TZ_HOST:-America/Guayaquil}
    volumes:
      - ./tailscale/state:/var/lib/tailscale
networks:
  default:
    name: homeserver_default
  socket_proxy:
    name: socket_proxy
    internal: true
COMPOSE
python3 - "$BASE/docker-compose.yml" "$BASE/homepage/config/widgets.yaml" "$DISKS" <<'PY'
from pathlib import Path
import sys

compose_path, widgets_path, disks_path = map(Path, sys.argv[1:])
assignments = []
for line in disks_path.read_text().splitlines():
    fields = line.split("|")
    if len(fields) < 6:
        continue
    _, _, kind, mount, _, name = fields[:6]
    if kind in {"respaldos", "almacenamiento"} and mount.startswith("/mnt/"):
        assignments.append((mount, name))
        (Path(mount) / ".beszel").mkdir(parents=True, exist_ok=True)

widgets = """- resources:
    cpu: true
    memory: true
    disk: /
"""
for mount, _ in assignments:
    widgets += f"- resources:\n    disk: {mount}\n"
widgets += """- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
"""
widgets_path.write_text(widgets)

if not compose_path.exists():
    raise SystemExit(0)
text = compose_path.read_text()
start = text.index("  beszel-agent:\n")
end = text.index("\n  nextcloud-db:\n", start)
agent = text[start:end]
agent = agent.replace("""      - type: bind
        source: /mnt
        target: /extra-filesystems
        read_only: true
        bind:
          propagation: rslave
""", "")
lines = agent.splitlines(keepends=True)
lines = [line for line in lines if not (line.startswith("      - /mnt/") and "/.beszel:/extra-filesystems/" in line)]
agent = "".join(lines)
mounts = "".join(f"      - {mount}/.beszel:/extra-filesystems/{name}:ro\n" for mount, name in assignments)
agent = agent.replace("      - ./beszel/agent:/var/lib/beszel-agent\n", "")
volume_anchor = "    volumes:\n"
if volume_anchor not in agent:
    raise SystemExit("No se encontró la sección de volúmenes del agente Beszel en Compose.")
agent = agent.replace(volume_anchor, volume_anchor + "      - ./beszel/agent:/var/lib/beszel-agent\n" + mounts, 1)
compose_path.write_text(text[:start] + agent + text[end:])
PY
chmod 600 "$BASE/docker-compose.yml"
EOF
chmod 755 /usr/local/bin/homeserver-compose
install -d -m 0755 "$BASE_DIR"/{homepage/config,jellyfin/{config,cache,media/{Peliculas,Series,Musica}},nextcloud/{app,db,db-dump},beszel/{data,agent},portainer/data,adguard/{conf,work},tailscale/state,backups} /mnt/respaldos /mnt/almacenamiento
chown -R 1000:1000 "$BASE_DIR/jellyfin/config" "$BASE_DIR/jellyfin/cache" "$BASE_DIR/beszel/data" "$BASE_DIR/beszel/agent"
install -d -m 0700 /root/.config/homeserver
if [[ ! -f /root/.config/homeserver/borg-passphrase ]]; then
    printf '%s' "$BORG_PASSPHRASE" >/root/.config/homeserver/borg-passphrase
    chmod 600 /root/.config/homeserver/borg-passphrase
fi
printf '%s' "$PORTAINER_PASSWORD" >"$BASE_DIR/portainer/admin_password"
chmod 600 "$BASE_DIR/portainer/admin_password"
ADGUARD_HASH=$(htpasswd -nbB admin "$ADGUARD_ADMIN_PASSWORD" | cut -d: -f2)
if [[ ! -f $BASE_DIR/adguard/conf/AdGuardHome.yaml ]]; then
    cat >"$BASE_DIR/adguard/conf/AdGuardHome.yaml" <<EOF
http:
  address: 0.0.0.0:80
  session_ttl: 720h
users:
  - name: admin
    password: "$ADGUARD_HASH"
auth_attempts: 5
block_auth_min: 15
language: es
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.quad9.net/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 9.9.9.9
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  protection_enabled: true
  blocking_mode: default
  edns_client_subnet:
    enabled: false
filtering:
  filtering_enabled: true
  protection_enabled: true
  safe_browsing_enabled: false
  parental_enabled: false
  safe_search:
    enabled: false
  blocked_response_ttl: 10
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/SpanishFilter/sections/adservers.txt
    name: Filtro español de AdGuard
    id: 2001
schema_version: 29
EOF
    chmod 600 "$BASE_DIR/adguard/conf/AdGuardHome.yaml"
fi
cat >"$BASE_DIR/homepage/config/settings.yaml" <<EOF
title: Homeserver
language: es
target: _blank
background:
  color: slate
layout:
  Servicios:
    style: row
    columns: 4
EOF
cat >"$BASE_DIR/homepage/config/services.yaml" <<EOF
- Servicios:
    - Beszel:
        icon: beszel.png
        href: http://$SERVER_IP:8090
        description: Estado y métricas del servidor
        server: docker-proxy
        container: beszel
    - Nextcloud:
        icon: nextcloud.png
        href: http://$SERVER_IP:8080
        description: Archivos personales
        server: docker-proxy
        container: nextcloud
    - Jellyfin:
        icon: jellyfin.png
        href: http://$SERVER_IP:8096
        description: Películas, series y música
        server: docker-proxy
        container: jellyfin
    - AdGuard Home:
        icon: adguard-home.png
        href: http://$SERVER_IP:8081
        description: Filtrado DNS
        server: docker-proxy
        container: adguardhome
    - Portainer:
        icon: portainer.png
        href: https://$SERVER_IP:9443
        description: Administración de contenedores
        server: docker-proxy
        container: portainer
    - Homepage:
        icon: homepage.png
        href: http://$SERVER_IP:3000
        description: Panel de servicios
        server: docker-proxy
        container: homepage
EOF
cat >"$BASE_DIR/homepage/config/widgets.yaml" <<'EOF'
- resources:
    cpu: true
    memory: true
    disk: /
- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
EOF
cat >"$BASE_DIR/homepage/config/docker.yaml" <<'EOF'
docker-proxy:
  host: docker-socket-proxy
  port: 2375
EOF
cat >"$BASE_DIR/homepage/config/bookmarks.yaml" <<'EOF'
[]
EOF
chmod 644 "$BASE_DIR/homepage/config/"*.yaml

paso 'Preparando montaje de discos y archivos de inicio' '11/14'
cat >/etc/udev/rules.d/99-homeserver-disco.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", RUN+="/usr/bin/systemd-run --no-block /usr/local/bin/homeserver-disco detectar %k"
EOF
udevadm control --reload-rules
for kname in "${!DISK_ID[@]}"; do
    id=${DISK_ID[$kname]}
    if [[ -z ${DISK_CHOICE[$kname]} ]]; then
        /usr/local/bin/homeserver-disco detectar "$kname"
        continue
    fi
    file=/run/homeserver-${kname}.disk
    [[ -f $file ]] || continue
    IFS='|' read -r disk_id long_id disk_kname model bytes fs <"$file"
    printf 'kname=%q\nmodelo=%q\ntamano=%q\nfs=%q\ndisk_id_largo=%q\n' "$disk_kname" "$model" "$bytes" "$fs" "$long_id" >"/var/lib/homeserver/discos/$disk_id.pending"
    case ${DISK_CHOICE[$kname]} in
        respaldos|almacenamiento)
            if [[ ${DISK_MODE[$kname]:-} == formatear ]]; then
                export CONFIRMAR=BORRAR
                /usr/local/bin/homeserver-disco aplicar "$id" "${DISK_CHOICE[$kname]}" formatear
            else
                /usr/local/bin/homeserver-disco aplicar "$id" "${DISK_CHOICE[$kname]}" usar
            fi
            ;;
        ignorar) /usr/local/bin/homeserver-disco ignorar "$id" ;;
    esac
done

paso 'Generando e iniciando el stack de servicios' '12/14'
if [[ -e /etc/systemd/resolved.conf ]] && ss -lntup 2>/dev/null | grep -qE '(:53[[:space:]]|:53$)' && systemctl is-active --quiet systemd-resolved; then
    sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    grep -q '^DNSStubListener=' /etc/systemd/resolved.conf || printf 'DNSStubListener=no\n' >>/etc/systemd/resolved.conf
    systemctl restart systemd-resolved
    if [[ $(readlink -f /etc/resolv.conf 2>/dev/null || true) == /run/systemd/resolve/stub-resolv.conf ]]; then
        ln -sfnT /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
fi

if [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} && $TELEGRAM_BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
    WATCHTOWER_NOTIFICATION_URL="telegram://${TELEGRAM_BOT_TOKEN}@telegram?chats=${TELEGRAM_CHAT_ID}"
else
    WATCHTOWER_NOTIFICATION_URL=""
    if [[ -n ${TELEGRAM_BOT_TOKEN:-} ]]; then
        echo "El token de Telegram no tiene el formato esperado; Watchtower iniciará sin notificaciones."
    fi
fi
escribir_env WATCHTOWER_NOTIFICATION_URL "$WATCHTOWER_NOTIFICATION_URL"
export WATCHTOWER_NOTIFICATION_URL
chmod 600 "$ENV_FILE"
/usr/local/bin/homeserver-compose
chmod 600 "$BASE_DIR/docker-compose.yml"
PULL_LOG=$(mktemp)
IMAGENES_DESCARGADAS=no
for intento in 1 2 3 4 5; do
    if docker compose -f "$BASE_DIR/docker-compose.yml" pull 2>&1 | tee "$PULL_LOG"; then
        IMAGENES_DESCARGADAS=si
        break
    fi
    if grep -Eqi '429|too many requests|502 bad gateway' "$PULL_LOG"; then
        printf 'Docker Hub limitó temporalmente las descargas (HTTP 429/502). Reintento %s de 5.\n' "$intento"
    else
        printf 'No se pudieron descargar todas las imágenes. Reintento %s de 5.\n' "$intento"
    fi
    if [[ $intento -lt 5 ]]; then
        demora=$((30 * 2 ** (intento - 1)))
        printf 'Se volverá a intentar en %s segundos.\n' "$demora"
        sleep "$demora"
    fi
done
rm -f "$PULL_LOG"
[[ $IMAGENES_DESCARGADAS == si ]] || fatal 'No se pudieron descargar las imágenes de Docker después de cinco intentos.'
if [[ ! -f /etc/sysctl.d/99-homeserver.conf ]]; then
    printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-homeserver.conf
fi
sysctl --system >/dev/null
docker compose -f "$BASE_DIR/docker-compose.yml" up -d tailscale
docker compose -f "$BASE_DIR/docker-compose.yml" up -d docker-socket-proxy beszel
for ((i=0; i<120; i++)); do
    curl -fsS http://127.0.0.1:8090/api/health >/dev/null 2>&1 && break
    sleep 2
done
docker compose -f "$BASE_DIR/docker-compose.yml" up -d
if docker logs homepage 2>&1 | grep -Eqi 'host.*not allowed|invalid host'; then
    python3 - "$BASE_DIR/docker-compose.yml" "$SERVER_IP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
text = text.replace('HOMEPAGE_ALLOWED_HOSTS: "*"', f'HOMEPAGE_ALLOWED_HOSTS: "homeserver.local:3000,{sys.argv[2]}:3000,homeserver:3000,localhost:3000"')
p.write_text(text)
PY
    docker compose -f "$BASE_DIR/docker-compose.yml" up -d homepage
fi

paso 'Automatizando primeros inicios y comprobando interfaces' '13/14'
/usr/local/bin/homeserver-api-setup
while IFS='|' read -r id kname tipo mnt _ nombre; do
    [[ $tipo == almacenamiento ]] || continue
    /usr/local/bin/homeserver-jellyfin agregar "$nombre" "$mnt" || true
    docker exec -u www-data nextcloud php occ app:enable files_external || true
    docker exec -u www-data nextcloud php occ files_external:create "$nombre" local null::null -c datadir="$mnt/Archivos" || true
done <"$DISKS_FILE"
for url in http://127.0.0.1:3000 http://127.0.0.1:8080 http://127.0.0.1:8090 http://127.0.0.1:8096 http://127.0.0.1:8081 https://127.0.0.1:9443; do
    for ((i=0; i<120; i++)); do
        curl -kfsS --max-time 3 "$url" >/dev/null 2>&1 && break
        sleep 2
    done
    curl -kfsS --max-time 5 "$url" >/dev/null
done
if [[ -z ${JELLYFIN_API_KEY:-} ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

paso 'Activando protección, avisos, cron y firewall' '14/14'
cat >/etc/cron.d/homeserver <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root /usr/local/bin/homeserver-respaldo
*/5 * * * * root docker exec -u www-data nextcloud php -f /var/www/html/cron.php
EOF
chmod 644 /etc/cron.d/homeserver
cat >/etc/systemd/system/homeserver-alertas.service <<'EOF'
[Unit]
Description=Revisión de alertas del homeserver
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/homeserver-alertas
EOF
cat >/etc/systemd/system/homeserver-alertas.timer <<'EOF'
[Unit]
Description=Revisión periódica de alertas del homeserver

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=homeserver-alertas.service

[Install]
WantedBy=timers.target
EOF
cat >/etc/systemd/system/homeserver-bot.service <<'EOF'
[Unit]
Description=Bot de Telegram del homeserver
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/homeserver-bot
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/homeserver-arranque.service <<'EOF'
[Unit]
Description=Aviso de arranque del homeserver
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'IP=$(ip -4 route get 1.1.1.1 | awk "{for(i=1;i<=NF;i++) if(\\$i==\\"src\\"){print \\$(i+1); exit}}"); /usr/local/bin/homeserver-notificar "Servidor reiniciado. IP: $IP"'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl stop fail2ban 2>/dev/null || true
systemctl reset-failed fail2ban 2>/dev/null || true
systemctl enable fail2ban
systemctl start fail2ban
fail2ban_ready=false
for ((i=0; i<30; i++)); do
    if fail2ban-client ping >/dev/null 2>&1; then
        fail2ban_ready=true
        break
    fi
    sleep 1
done
[[ $fail2ban_ready == true ]] || { echo "Fail2ban no inició dentro del tiempo esperado." >&2; systemctl status fail2ban --no-pager >&2 || true; exit 1; }
fail2ban-client status sshd

ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_CIDR" to any port 22 proto tcp
ufw allow from "$LAN_CIDR" to any port 53 proto tcp
ufw allow from "$LAN_CIDR" to any port 53 proto udp
ufw allow in on tailscale0
ufw allow 41641/udp
python3 - "$LAN_CIDR" "$LAN_IFACE" <<'PY'
from pathlib import Path
import sys

path = Path("/etc/ufw/after.rules")
begin = "# HOMESERVER: DOCKER-USER BEGIN"
end = "# HOMESERVER: DOCKER-USER END"
text = path.read_text()
lines = text.splitlines(keepends=True)
start = next((i for i, line in enumerate(lines) if line.rstrip("\n") == begin), None)
if start is not None:
    stop = next((i for i in range(start + 1, len(lines)) if lines[i].rstrip("\n") == end), None)
    if stop is None:
        stop = next((i for i in range(start + 1, len(lines)) if lines[i].strip() == "COMMIT"), start)
    del lines[start:stop + 1]
else:
    legacy = next((i for i, line in enumerate(lines) if "HOMESERVER: cadena DOCKER-USER" in line), None)
    if legacy is not None:
        stop = next((i for i in range(legacy + 1, len(lines)) if lines[i].strip() == "COMMIT"), legacy)
        del lines[legacy:stop + 1]
commit = max(i for i, line in enumerate(lines) if line.strip() == "COMMIT")
block = f"""\
{begin}
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A DOCKER-USER -s {sys.argv[1]} -j RETURN
-A DOCKER-USER -s 100.64.0.0/10 -j RETURN
-A DOCKER-USER -s 172.16.0.0/12 -j RETURN
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -s 192.168.0.0/16 -j RETURN
-A DOCKER-USER -i {sys.argv[2]} -j DROP
-A DOCKER-USER -j RETURN
{end}
"""
lines[commit:commit] = [block]
path.write_text("".join(lines))
PY
ufw --force enable
systemctl enable homeserver-alertas.timer homeserver-arranque.service
systemctl restart homeserver-alertas.timer
if [[ -f $TELEGRAM_FILE ]]; then
    systemctl enable --now homeserver-bot.service
fi
cat >/root/homeserver-credenciales.txt <<EOF
Credenciales del servidor homeserver
Panel Homepage: http://homeserver.local:3000 (también http://$SERVER_IP:3000)
Nextcloud: http://homeserver.local:8080 — usuario admin — contraseña: $NEXTCLOUD_ADMIN_PASSWORD
Jellyfin: http://homeserver.local:8096 — usuario admin — contraseña: $JELLYFIN_ADMIN_PASSWORD
Beszel: http://homeserver.local:8090 — usuario admin@homeserver.local — contraseña: $BESZEL_ADMIN_PASSWORD
Portainer: https://homeserver.local:9443 — usuario admin — contraseña: $PORTAINER_PASSWORD
AdGuard Home: http://homeserver.local:8081 — usuario admin — contraseña: $ADGUARD_ADMIN_PASSWORD
MariaDB de Nextcloud: usuario nextcloud — contraseña: $MYSQL_PASSWORD; usuario root — contraseña: $MYSQL_ROOT_PASSWORD
Clave de Borg: frase en /root/.config/homeserver/borg-passphrase; clave exportada en /root/homeserver-borg-key.txt
Variables y otros secretos: $ENV_FILE
EOF
if [[ -n ${TELEGRAM_BOT_TOKEN:-} ]]; then
    printf 'Bot de Telegram: token en %s/telegram.env\n' "$CONFIG_DIR" >>/root/homeserver-credenciales.txt
fi
if [[ -n ${TS_AUTHKEY:-} ]]; then
    printf 'Tailscale: clave de autenticación guardada en %s\n' "$ENV_FILE" >>/root/homeserver-credenciales.txt
fi
chmod 600 /root/homeserver-credenciales.txt
if [[ -z ${TS_AUTHKEY:-} ]]; then
    TS_URL=$(docker logs tailscale 2>&1 | grep -Eo 'https://login\.tailscale\.com/[A-Za-z0-9/?=_-]+' | tail -n 1 || true)
else
    TS_URL=""
fi
printf '\nServidor listo.\n'
printf 'Homepage: http://homeserver.local:3000 y http://%s:3000\n' "$SERVER_IP"
printf 'Nextcloud: http://homeserver.local:8080 | Jellyfin: http://homeserver.local:8096\n'
printf 'Beszel: http://homeserver.local:8090 | AdGuard: http://homeserver.local:8081 | Portainer: https://homeserver.local:9443\n'
printf 'Credenciales: /root/homeserver-credenciales.txt\n'
printf 'Configura el DNS del router para usar %s como servidor DNS.\n' "$SERVER_IP"
printf 'Reserva en el router la dirección DHCP %s para este servidor.\n' "$SERVER_IP"
printf '\nContenido de /root/homeserver-credenciales.txt:\n'
cat /root/homeserver-credenciales.txt
[[ -z $TS_URL ]] || printf 'Inicia sesión en Tailscale: %s\n' "$TS_URL"
if ! grep -q '|respaldos|' "$DISKS_FILE" 2>/dev/null; then
    printf 'Los respaldos están en el mismo disco del sistema: si el disco falla se pierden. Conecta otro disco o copia /opt/homeserver/backups a otro lugar.\n'
fi
if [[ -n ${TELEGRAM_BOT_TOKEN:-} && -n ${TELEGRAM_CHAT_ID:-} ]]; then
    /usr/local/bin/homeserver-notificar "Servidor listo. Panel: http://homeserver.local:3000; Nextcloud: http://homeserver.local:8080; Jellyfin: http://homeserver.local:8096"
fi
