#!/usr/bin/env bash
set -uo pipefail

BASE="/opt/homeserver"
CONFIG_DIR="/etc/homeserver"
RESULTADOS="${RESULTADOS:-$PWD/resultados_tesis}"
HS_ENV_FILE="${HS_ENV_FILE:-$BASE/.env}"
HS_BORG_PASS_FILE="${HS_BORG_PASS_FILE:-/root/.config/homeserver/borg-passphrase}"
HS_TELEGRAM_FILE="${HS_TELEGRAM_FILE:-$CONFIG_DIR/telegram.env}"
HS_CRED_FILE="${HS_CRED_FILE:-/root/homeserver-credenciales.txt}"
MODE="${1:-estado}"
PREFIJO_SUF=""
INDICE=""

ayuda() {
    printf '%s\n' \
        "Uso: sudo bash recolectar_evidencias.sh <modo> [argumentos]" \
        "" \
        "Modos disponibles:" \
        "  estado [etiqueta]                 Recopila el estado actual del servidor." \
        "  reposo [segundos=600]             Muestrea el servidor en reposo." \
        "  carga [segundos=600]              Muestrea el servidor durante una carga." \
        "  tiempo <etiqueta> -- <comando...> Mide y registra la duración de un comando." \
        "  sha256 <etiqueta> <archivo>       Calcula y registra una huella SHA-256." \
        "  persistencia antes|despues        Captura y compara la persistencia." \
        "  sanear <archivo>                 Crea una copia sin ANSI ni secretos." \
        "  resumen                          Genera tablas y plantillas Markdown." \
        "  ayuda                             Muestra esta ayuda." \
        "" \
        "RESULTADOS y PREFIJO son variables opcionales."
}

if (( EUID != 0 )); then
    printf '%s\n' "ERROR: ejecute este recolector como root: sudo bash recolectar_evidencias.sh <modo>." >&2
    exit 1
fi

case "$MODE" in
    ayuda|-h|--help)
        ayuda
        exit 0
        ;;
    estado|reposo|carga|tiempo|sha256|persistencia|sanear|resumen)
        ;;
    *)
        ayuda >&2
        exit 2
        ;;
esac

if [[ -n ${PREFIJO:-} ]]; then
    PREFIJO_SUF="$PREFIJO"
    [[ $PREFIJO_SUF == _* ]] || PREFIJO_SUF="_$PREFIJO_SUF"
    PREFIJO_SUF=${PREFIJO_SUF//[^A-Za-z0-9._-]/_}
fi

if ! mkdir -p "$RESULTADOS"; then
    printf 'ERROR: no se pudo crear el directorio de resultados: %s\n' "$RESULTADOS" >&2
    exit 1
fi
INDICE="$RESULTADOS/INDICE.txt"

redactor() {
    python3 -c '
import os
import re
import shlex
import sys
from pathlib import Path

ansi = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
token = re.compile(r"\b\d{6,12}:[A-Za-z0-9_-]{30,}\b")
tailscale = re.compile(r"tskey-[A-Za-z0-9-]+")
labels = re.compile(
    r"(contraseña|password|passwd|passphrase|token|clave)(\s*[:=]\s*|\s+)\S+",
    re.IGNORECASE,
)
secret_values = set()

def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except (OSError, TypeError):
        return ""

def parse_assignments(path, selected=None):
    for line in read_text(path).splitlines():
        item = line.strip()
        if not item or item.startswith("#"):
            continue
        if item.startswith("export "):
            item = item[7:].lstrip()
        if "=" not in item:
            continue
        name, value = item.split("=", 1)
        name = name.strip()
        if selected is not None and name not in selected:
            continue
        value = value.strip()
        try:
            pieces = shlex.split(value, comments=False, posix=True)
            value = pieces[0] if pieces else ""
        except ValueError:
            value = value.strip(chr(34) + chr(39) + "\t ")
        yield name, value

env_path, pass_path, telegram_path, credential_path = sys.argv[1:5]
for name, value in parse_assignments(env_path):
    if re.search(r"PASSWORD|PASSPHRASE|KEY|TOKEN|SECRET", name, re.IGNORECASE) and len(value) >= 6:
        secret_values.add(value)

passphrase = read_text(pass_path).strip()
if len(passphrase) >= 6:
    secret_values.add(passphrase)
for name, value in parse_assignments(telegram_path, {"TELEGRAM_BOT_TOKEN"}):
    if len(value) >= 6:
        secret_values.add(value)

credentials = read_text(credential_path)
for match in re.finditer(
    r"(?:contraseña|password|passwd|passphrase|token|clave)\s*[:=]\s*([^\s,;]+)",
    credentials,
    re.IGNORECASE,
):
    value = match.group(1).rstrip(".")
    if len(value) >= 6:
        secret_values.add(value)

data = ansi.sub("", sys.stdin.read()).replace("\r", "")
for value in sorted(secret_values, key=len, reverse=True):
    data = data.replace(value, "***")
data = token.sub("***", data)
data = tailscale.sub("***", data)
data = labels.sub(lambda match: match.group(1) + match.group(2) + "***", data)
sys.stdout.write(data)
' "$HS_ENV_FILE" "$HS_BORG_PASS_FILE" "$HS_TELEGRAM_FILE" "$HS_CRED_FILE"
}

redactar_archivo() {
    local archivo="$1" temporal
    [[ -f $archivo ]] || return 0
    temporal=$(mktemp "$RESULTADOS/.redaccion.XXXXXX") || return 1
    redactor <"$archivo" >"$temporal"
    local codigo=$?
    if (( codigo == 0 )); then
        mv -f -- "$temporal" "$archivo"
    else
        rm -f -- "$temporal"
        return "$codigo"
    fi
}

cabecera_texto() {
    local archivo="$1" comando="$2"
    mkdir -p "$(dirname "$archivo")"
    {
        printf '# Fecha: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf '# Host: %s\n' "$(hostname 2>/dev/null || printf 'desconocido')"
        printf '# Comando: %s\n' "$comando"
    } | redactor >"$archivo"
}

registrar_indice() {
    local archivo="$1" descripcion="$2" relativo
    relativo=${archivo#"$RESULTADOS"/}
    printf '%s | %s\n' "$relativo" "$descripcion" | redactor >>"$INDICE"
}

registrar_salida() {
    local archivo="$1" comando="$2" descripcion="$3" salida="$4" codigo="$5"
    cabecera_texto "$archivo" "$comando"
    if [[ -z $salida ]]; then
        if (( codigo != 0 )); then
            salida="NO DISPONIBLE: el comando terminó con código $codigo"
        else
            salida="(sin salida)"
        fi
    elif (( codigo != 0 )); then
        salida+=$'\n'"NO DISPONIBLE: el comando terminó con código $codigo"
    fi
    printf '%s\n' "$salida" | redactor >>"$archivo"
    registrar_indice "$archivo" "$descripcion"
}

registrar_texto() {
    local archivo="$1" comando="$2" descripcion="$3" salida codigo
    salida=$(bash -c "$comando" 2>&1)
    codigo=$?
    registrar_salida "$archivo" "$comando" "$descripcion" "$salida" "$codigo"
}

registrar_csv_indice() {
    local archivo="$1" descripcion="$2"
    redactar_archivo "$archivo"
    registrar_indice "$archivo" "$descripcion"
}

iniciar_indice() {
    if [[ ! -f $INDICE ]]; then
        cabecera_texto "$INDICE" "recolectar_evidencias.sh $MODE"
    fi
}

finalizar() {
    if [[ -f $INDICE ]]; then
        printf '%s\n' "INDICE.txt | Índice acumulado de todos los artefactos de evidencia." | redactor >>"$INDICE"
    fi
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]] && id "$SUDO_USER" >/dev/null 2>&1; then
        local grupo
        grupo=$(id -gn "$SUDO_USER" 2>/dev/null || printf '%s' "$SUDO_USER")
        chown -R "$SUDO_USER:$grupo" "$RESULTADOS" 2>/dev/null || true
    fi
}

trap finalizar EXIT
iniciar_indice

etiqueta_segura() {
    local valor="${1:-}"
    valor=${valor//[^A-Za-z0-9._-]/_}
    [[ -n $valor ]] || valor="estado"
    printf '%s' "$valor"
}

archivo_csv_nuevo() {
    local archivo="$1" encabezado="$2"
    mkdir -p "$(dirname "$archivo")"
    printf '%s\n' "$encabezado" | redactor >"$archivo"
}

crear_http_csv() {
    local archivo="$1" tipo="$2"
    python3 - "$archivo" "$tipo" <<'PY'
import csv
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
kind = sys.argv[2]
endpoints = [
    ("homepage", "http://127.0.0.1:3000/", False),
    ("nextcloud", "http://127.0.0.1:8080/status.php", False),
    ("beszel", "http://127.0.0.1:8090/api/health", False),
    ("jellyfin", "http://127.0.0.1:8096/health", False),
    ("adguardhome", "http://127.0.0.1:8081/", False),
    ("portainer", "https://127.0.0.1:9443/api/system/status", True),
]
with path.open("w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(["servicio", "url", "http_code", "time_total_s"])
    for service, url, insecure in endpoints:
        command = ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code},%{time_total}", "--max-time", "5"]
        if insecure:
            command.append("-k")
        command.append(url)
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=7)
            value = result.stdout.strip()
            code, elapsed = value.split(",", 1) if "," in value else ("000", "NA")
        except (FileNotFoundError, subprocess.TimeoutExpired):
            code, elapsed = "000", "NA"
        if kind == "carga":
            writer.writerow([service, url, code, elapsed])
        else:
            writer.writerow([service, url, code, elapsed])
PY
    redactar_archivo "$archivo"
}

crear_capacidades_csv() {
    local archivo="$1" ids
    local -a id_array=()
    archivo_csv_nuevo "$archivo" "container,user,privileged,cap_add,cap_drop,security_opt,network_mode,networks,readonly_rootfs,restart_policy"
    if ! command -v docker >/dev/null 2>&1; then
        printf '"%s",,,,,,,,,\n' "NO DISPONIBLE: docker no está instalado" >>"$archivo"
        redactar_archivo "$archivo"
        return
    fi
    ids=$(docker ps -aq 2>/dev/null)
    if [[ -z $ids ]]; then
        printf '%s\n' '"NO DISPONIBLE: no hay contenedores inspeccionables",,,,,,,,,' >>"$archivo"
        redactar_archivo "$archivo"
        return
    fi
    read -r -a id_array <<<"$ids"
    docker inspect "${id_array[@]}" 2>/dev/null | python3 -c '
import csv
import json
import sys

try:
    containers = json.load(sys.stdin)
except Exception:
    containers = []
writer = csv.writer(sys.stdout)
for item in containers:
    config = item.get("Config") or {}
    host = item.get("HostConfig") or {}
    networks = sorted((item.get("NetworkSettings") or {}).get("Networks", {}).keys())
    restart = host.get("RestartPolicy") or {}
    restart_name = restart.get("Name", "")
    restart_retries = restart.get("MaxRetries", "")
    writer.writerow([
        (item.get("Name") or "").lstrip("/"),
        config.get("User", ""),
        host.get("Privileged", False),
        ";".join(host.get("CapAdd") or []),
        ";".join(host.get("CapDrop") or []),
        ";".join(host.get("SecurityOpt") or []),
        host.get("NetworkMode", ""),
        ";".join(networks),
        host.get("ReadonlyRootfs", False),
        f"{restart_name}:{restart_retries}",
    ])
' >>"$archivo"
    if [[ $(wc -l <"$archivo") -le 1 ]]; then
        printf '%s\n' '"NO DISPONIBLE: docker inspect no devolvió datos",,,,,,,,,' >>"$archivo"
    fi
    redactar_archivo "$archivo"
}

estado_servidor() {
    local etiqueta="${1:-estado}" nombre dir comando salida codigo
    nombre="$(etiqueta_segura "$etiqueta")$PREFIJO_SUF"
    dir="$RESULTADOS/$nombre"
    mkdir -p "$dir"

    comando='cat /etc/os-release; uname -a; lscpu; free -m; swapon --show; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL; df -h; uptime'
    registrar_texto "$dir/sistema.txt" "$comando" "Sistema operativo, procesador, memoria, discos, espacio y tiempo activo."

    comando='if command -v docker >/dev/null 2>&1; then docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; docker compose -f /opt/homeserver/docker-compose.yml ps -a; docker volume ls; docker network ls; ids=$(docker ps -aq); if [ -n "$ids" ]; then docker inspect --format "{{.Name}} {{json .Mounts}}" $ids; else echo "NO DISPONIBLE: no hay contenedores para inspeccionar"; fi; else echo "NO DISPONIBLE: docker no está instalado"; fi'
    registrar_texto "$dir/contenedores.txt" "$comando" "Contenedores, composición, volúmenes, redes y montajes."

    crear_capacidades_csv "$dir/capacidades.csv"
    registrar_indice "$dir/capacidades.csv" "Capacidades y aislamiento configurado para cada contenedor."

    comando='if command -v ss >/dev/null 2>&1; then ss -tulnp; else echo "NO DISPONIBLE: ss no está instalado"; fi'
    registrar_texto "$dir/puertos.txt" "$comando" "Sockets TCP y UDP en escucha."

    crear_http_csv "$dir/http_endpoints.csv" "estado"
    registrar_csv_indice "$dir/http_endpoints.csv" "Código HTTP y duración de respuesta de los seis servicios."

    salida=$(python3 - <<'PY'
import socket
import struct

nombre = "example.com"
identificador = 0x4A31
pregunta = b"".join(bytes([len(parte)]) + parte.encode("ascii") for parte in nombre.split(".")) + b"\0"
paquete = struct.pack("!HHHHHH", identificador, 0x0100, 1, 0, 0, 0) + pregunta + struct.pack("!HH", 1, 1)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(3)
try:
    sock.sendto(paquete, ("127.0.0.1", 53))
    respuesta, _ = sock.recvfrom(4096)
except (OSError, TimeoutError) as error:
    print(f"NO DISPONIBLE: la consulta DNS no respondió ({type(error).__name__})")
    raise SystemExit(1)
finally:
    sock.close()
if len(respuesta) < 12:
    raise SystemExit("NO DISPONIBLE: respuesta DNS truncada")
flags, respuestas = struct.unpack_from("!HH", respuesta, 2)[0], struct.unpack_from("!H", respuesta, 6)[0]
rcode = flags & 0x000F
offset = 12
for _ in range(1):
    while offset < len(respuesta) and respuesta[offset] != 0:
        if respuesta[offset] & 0xC0 == 0xC0:
            offset += 2
            break
        offset += respuesta[offset] + 1
    else:
        offset += 1
    if offset < len(respuesta) and respuesta[offset - 1] == 0:
        offset += 4
    else:
        offset += 4
direcciones = []
for _ in range(respuestas):
    if offset + 10 > len(respuesta):
        break
    if respuesta[offset] & 0xC0 == 0xC0:
        offset += 2
    else:
        while offset < len(respuesta) and respuesta[offset] != 0:
            offset += respuesta[offset] + 1
        offset += 1
    if offset + 10 > len(respuesta):
        break
    tipo, clase, ttl, longitud = struct.unpack_from("!HHIH", respuesta, offset)
    offset += 10
    datos = respuesta[offset:offset + longitud]
    offset += longitud
    if tipo == 1 and clase == 1 and longitud == 4:
        direcciones.append(socket.inet_ntoa(datos))
print(f"servidor=127.0.0.1:53 nombre={nombre} rcode={rcode} respuestas={respuestas} A={','.join(direcciones) or 'ninguna'}")
PY
    )
    codigo=$?
    registrar_salida "$dir/dns_adguard.txt" "python3 (consulta DNS A UDP a 127.0.0.1:53 para example.com)" "Resultado DNS de AdGuard Home." "$salida" "$codigo"

    comando='echo "Desde el host:"; for ruta in /_ping /version /containers/json /secrets /volumes; do printf "%s " "$ruta"; curl -sS -o /dev/null -w "%{http_code}\n" --max-time 5 "http://127.0.0.1:2375$ruta" 2>/dev/null || echo "NO DISPONIBLE"; done; echo "Desde homepage:"; if docker inspect homepage >/dev/null 2>&1; then docker exec homepage wget -qO- -T 5 http://docker-socket-proxy:2375/version 2>&1 || echo "NO DISPONIBLE: acceso de homepage"; else echo "NO DISPONIBLE: contenedor homepage"; fi; echo "Desde jellyfin:"; if docker inspect jellyfin >/dev/null 2>&1; then docker exec jellyfin curl -s --max-time 5 http://docker-socket-proxy:2375/version 2>&1 || echo "NO DISPONIBLE: acceso no esperado de jellyfin"; else echo "NO DISPONIBLE: contenedor jellyfin"; fi; echo "Bind del proxy:"; if command -v ss >/dev/null 2>&1; then ss -ltn | grep -E "127\.0\.0\.1:2375|:2375" || echo "NO DISPONIBLE: sin listener 2375"; else echo "NO DISPONIBLE: ss no está instalado"; fi'
    registrar_texto "$dir/socket_proxy.txt" "$comando" "Acceso permitido y denegado al proxy desde el host y contenedores."

    comando='echo "Nota: el código conecta MariaDB a homeserver_default; no se implementa aislamiento de MariaDB."; for contenedor in jellyfin adguardhome; do echo "Contenedor: $contenedor"; if ! docker inspect "$contenedor" >/dev/null 2>&1; then echo "NO DISPONIBLE: contenedor ausente"; elif [ "$contenedor" = jellyfin ]; then if docker exec jellyfin bash -c '\''timeout 3 bash -c "</dev/tcp/nextcloud-db/3306"'\'' >/dev/null 2>&1; then echo "ALCANZABLE"; else echo "NO ALCANZABLE (o bash/timeout no disponibles)"; fi; else if docker exec adguardhome sh -c '\''command -v nc >/dev/null 2>&1 && nc -z -w 3 nextcloud-db 3306'\'' >/dev/null 2>&1; then echo "ALCANZABLE"; else echo "NO ALCANZABLE (o nc no disponible)"; fi; fi; done'
    registrar_texto "$dir/aislamiento_mariadb.txt" "$comando" "Prueba observacional de conectividad TCP a MariaDB; no implica aislamiento."

    comando='if command -v ufw >/dev/null 2>&1; then ufw status verbose; ufw status numbered; else echo "NO DISPONIBLE: ufw no está instalado"; fi; if command -v iptables >/dev/null 2>&1; then iptables -S DOCKER-USER; iptables -L DOCKER-USER -v -n --line-numbers; else echo "NO DISPONIBLE: iptables no está instalado"; fi'
    registrar_texto "$dir/firewall.txt" "$comando" "Estado de UFW y reglas de DOCKER-USER."

    comando='if command -v fail2ban-client >/dev/null 2>&1; then fail2ban-client status; fail2ban-client status sshd; else echo "NO DISPONIBLE: fail2ban-client no está instalado"; fi; if command -v journalctl >/dev/null 2>&1; then journalctl -u fail2ban -n 50 --no-pager; else echo "NO DISPONIBLE: journalctl no está instalado"; fi'
    registrar_texto "$dir/fail2ban.txt" "$comando" "Estado del servicio y del jail sshd de Fail2ban."

    comando='echo "Resolución homeserver.local:"; getent ahosts homeserver.local 2>&1 || echo "NO DISPONIBLE: no se resolvió homeserver.local"; echo "Avahi:"; if command -v systemctl >/dev/null 2>&1; then systemctl is-active avahi-daemon 2>&1 || echo "NO DISPONIBLE: avahi-daemon no está activo"; hostnamectl 2>&1 || true; else echo "NO DISPONIBLE: systemctl no está disponible"; fi'
    registrar_texto "$dir/mdns.txt" "$comando" "Resolución mDNS y estado de Avahi."

    comando='for unidad in homeserver-alertas.service homeserver-alertas.timer homeserver-bot.service homeserver-arranque.service fail2ban.service docker.service avahi-daemon.service cron.service unattended-upgrades.service; do if command -v systemctl >/dev/null 2>&1; then echo "===== $unidad ====="; systemctl status --no-pager "$unidad" 2>&1 || echo "NO DISPONIBLE: unidad ausente o inactiva"; else echo "NO DISPONIBLE: systemctl no está disponible"; break; fi; done; echo "===== temporizadores homeserver ====="; systemctl list-timers "homeserver*" --all --no-pager 2>&1 || echo "NO DISPONIBLE: temporizadores"; echo "===== cron ====="; cat /etc/cron.d/homeserver 2>&1 || echo "NO DISPONIBLE: /etc/cron.d/homeserver"; echo "===== regla udev ====="; cat /etc/udev/rules.d/99-homeserver-disco.rules 2>&1 || echo "NO DISPONIBLE: regla udev"; echo "===== discos.conf ====="; cat /etc/homeserver/discos.conf 2>&1 || echo "NO DISPONIBLE: discos.conf"; echo "===== discos pendientes ====="; if [ -d /var/lib/homeserver/discos ]; then find /var/lib/homeserver/discos -maxdepth 1 -type f -name "*.pending" -print -exec cat {} \;; else echo "NO DISPONIBLE: directorio de discos"; fi; echo "===== estado de alertas ====="; if [ -d /var/lib/homeserver/alertas ]; then find /var/lib/homeserver/alertas -maxdepth 2 -type f -print -exec cat {} \;; else echo "NO DISPONIBLE: directorio de alertas"; fi; echo "===== último respaldo ====="; if [ -r /var/lib/homeserver/ultimo-respaldo ]; then fecha=$(cat /var/lib/homeserver/ultimo-respaldo); date -d "@$fecha" --iso-8601=seconds 2>&1 || printf "%s\n" "$fecha"; else echo "NO DISPONIBLE: marca de último respaldo"; fi; echo "===== notificaciones ====="; journalctl -t homeserver-notificar -n 50 --no-pager 2>&1 || echo "NO DISPONIBLE: journal de notificaciones"'
    registrar_texto "$dir/servicios.txt" "$comando" "Unidades, temporizadores, tareas cron, reglas udev, discos y alertas."

    comando='echo "===== configuración de red de homeserver ====="; cat /etc/homeserver/homeserver.conf 2>&1 || echo "NO DISPONIBLE: homeserver.conf"; echo "===== direcciones ====="; ip -4 addr 2>&1 || echo "NO DISPONIBLE: ip"; echo "===== rutas ====="; ip route 2>&1 || echo "NO DISPONIBLE: ip route"; echo "===== gestores de red ====="; if command -v nmcli >/dev/null 2>&1; then nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION device show 2>&1; else echo "NetworkManager: NO DISPONIBLE"; fi; if [ -f /etc/network/interfaces ]; then cat /etc/network/interfaces; else echo "ifupdown: NO DISPONIBLE"; fi; if compgen -G "/etc/netplan/*.yaml" >/dev/null; then cat /etc/netplan/*.yaml; else echo "netplan: NO DISPONIBLE"; fi; if command -v networkctl >/dev/null 2>&1; then networkctl list --no-pager 2>&1; else echo "systemd-networkd: NO DISPONIBLE"; fi'
    registrar_texto "$dir/red.txt" "$comando" "Configuración y estado de interfaces, rutas y gestor de red."

    comando='echo "===== estado de Tailscale ====="; if docker inspect tailscale >/dev/null 2>&1; then docker exec tailscale tailscale status 2>&1 || echo "NO DISPONIBLE: Tailscale requiere inicio de sesión o no responde"; else echo "NO DISPONIBLE: contenedor tailscale"; fi; echo "===== UDP 41641 ====="; if command -v ss >/dev/null 2>&1; then ss -ulnp | grep 41641 || echo "NO DISPONIBLE: no se observa UDP 41641"; else echo "NO DISPONIBLE: ss no está instalado"; fi'
    registrar_texto "$dir/tailscale.txt" "$comando" "Estado de Tailscale y escucha UDP en el puerto 41641."

    comando='repo=/opt/homeserver/backups/borg; motivo="repositorio local"; if grep -Fq "|respaldos|" /etc/homeserver/discos.conf 2>/dev/null && mountpoint -q /mnt/respaldos; then repo=/mnt/respaldos/borg; motivo="disco RESPALDOS asignado y montado"; fi; printf "Repositorio: %s\nMotivo: %s\n" "$repo" "$motivo"; if ! command -v borg >/dev/null 2>&1; then echo "NO DISPONIBLE: borg no está instalado"; else export BORG_PASSCOMMAND="cat /root/.config/homeserver/borg-passphrase" BORG_RELOCATED_REPO_ACCESS_IS_OK=yes; if [ "$repo" = /opt/homeserver/backups/borg ]; then export BORG_CACHE_DIR=/root/.config/homeserver/borg-local-cache BORG_SECURITY_DIR=/root/.config/homeserver/borg-local-security; fi; borg info "$repo" 2>&1 || echo "NO DISPONIBLE: borg info"; borg list "$repo" 2>&1 || echo "NO DISPONIBLE: borg list"; borg info --last 1 "$repo" 2>&1 || echo "NO DISPONIBLE: borg info --last 1"; fi; echo "===== últimas líneas del registro ====="; if [ -r /var/log/homeserver-respaldo.log ]; then tail -n 60 /var/log/homeserver-respaldo.log; else echo "NO DISPONIBLE: /var/log/homeserver-respaldo.log"; fi'
    registrar_texto "$dir/borg.txt" "$comando" "Repositorio Borg seleccionado, información, archivos y registro reciente."

    printf 'Estado recopilado en: %s\n' "$dir"
}

hash_ruta() {
    local ruta="$1"
    if [[ -f $ruta ]]; then
        sha256sum "$ruta" 2>/dev/null | awk '{print $1}'
    else
        printf 'NO DISPONIBLE'
    fi
}

capturar_huellas_persistencia() {
    local accion="$1" archivo="$RESULTADOS/persistencia/$accion.sha256"
    local marcador="/opt/homeserver/nextcloud/app/data/admin/files/tesis_persistencia.txt"
    local etiqueta ruta huella
    archivo_csv_nuevo "$archivo" "elemento,ruta,sha256"

    local -a etiquetas=(
        "marcador_nextcloud"
        "docker_compose"
        "adguard_config"
        "nextcloud_config"
        "homepage_settings"
        "homepage_services"
        "homepage_widgets"
        "homepage_docker"
        "homepage_bookmarks"
    )
    local -a rutas=(
        "$marcador"
        "/opt/homeserver/docker-compose.yml"
        "/opt/homeserver/adguard/conf/AdGuardHome.yaml"
        "/opt/homeserver/nextcloud/app/config/config.php"
        "/opt/homeserver/homepage/config/settings.yaml"
        "/opt/homeserver/homepage/config/services.yaml"
        "/opt/homeserver/homepage/config/widgets.yaml"
        "/opt/homeserver/homepage/config/docker.yaml"
        "/opt/homeserver/homepage/config/bookmarks.yaml"
    )
    local indice
    for indice in "${!etiquetas[@]}"; do
        etiqueta="${etiquetas[$indice]}"
        ruta="${rutas[$indice]}"
        huella=$(hash_ruta "$ruta")
        printf '"%s","%s","%s"\n' "$etiqueta" "$ruta" "$huella" >>"$archivo"
    done

    if command -v docker >/dev/null 2>&1; then
        local volumenes contenedores
        volumenes=$(docker volume ls -q 2>/dev/null | sort)
        contenedores=$(docker ps -a --format '{{.Names}}|{{.Image}}' 2>/dev/null | sort)
        huella=$(printf '%s' "$volumenes" | sha256sum | awk '{print $1}')
        printf '"docker_volumes","docker volume ls -q","%s"\n' "$huella" >>"$archivo"
        huella=$(printf '%s' "$contenedores" | sha256sum | awk '{print $1}')
        printf '"containers_name_image","docker ps -a --format Names|Image","%s"\n' "$huella" >>"$archivo"
    else
        printf '%s\n' '"docker_volumes","docker volume ls -q","NO DISPONIBLE"' \
            '"containers_name_image","docker ps -a --format Names|Image","NO DISPONIBLE"' >>"$archivo"
    fi
    redactar_archivo "$archivo"
    registrar_indice "$archivo" "Huellas SHA-256 de archivos persistentes e inventario de Docker ($accion)."
}

persistencia() {
    local accion="${1:-}" dir="$RESULTADOS/persistencia" archivo comando marcador
    mkdir -p "$dir"
    if [[ $accion != antes && $accion != despues ]]; then
        printf '%s\n' "Uso: persistencia antes|despues" >&2
        return 2
    fi

    marcador="/opt/homeserver/nextcloud/app/data/admin/files/tesis_persistencia.txt"
    archivo="$dir/$accion.txt"
    if [[ $accion == antes ]]; then
        comando='marcador=/opt/homeserver/nextcloud/app/data/admin/files/tesis_persistencia.txt; if [ ! -e "$marcador" ]; then if [ -d "$(dirname "$marcador")" ]; then printf "Marcador de persistencia creado: %s\n" "$(date --iso-8601=seconds)" >"$marcador" && chown 33:33 "$marcador" && docker exec -u www-data nextcloud php occ files:scan --path=admin/files; else echo "NO DISPONIBLE: directorio de datos de Nextcloud ausente; no se creó el marcador"; fi; fi; echo "===== marcador ====="; if [ -f "$marcador" ]; then sha256sum "$marcador"; else echo "NO DISPONIBLE: marcador"; fi; echo "===== arranque ====="; uptime; cat /proc/sys/kernel/random/boot_id 2>&1 || echo "NO DISPONIBLE: boot_id"; echo "===== volúmenes ====="; docker volume ls 2>&1 || echo "NO DISPONIBLE: docker volume ls"; echo "===== contenedores e imágenes ====="; docker ps -a --format "{{.Names}}|{{.Image}}" 2>&1 || echo "NO DISPONIBLE: docker ps"; echo "===== archivos de configuración ====="; sha256sum /opt/homeserver/docker-compose.yml /opt/homeserver/adguard/conf/AdGuardHome.yaml /opt/homeserver/nextcloud/app/config/config.php /opt/homeserver/homepage/config/settings.yaml /opt/homeserver/homepage/config/services.yaml /opt/homeserver/homepage/config/widgets.yaml /opt/homeserver/homepage/config/docker.yaml /opt/homeserver/homepage/config/bookmarks.yaml 2>&1 || true'
    else
        comando='marcador=/opt/homeserver/nextcloud/app/data/admin/files/tesis_persistencia.txt; echo "===== marcador ====="; if [ -f "$marcador" ]; then sha256sum "$marcador"; else echo "NO DISPONIBLE: marcador"; fi; echo "===== arranque ====="; uptime; cat /proc/sys/kernel/random/boot_id 2>&1 || echo "NO DISPONIBLE: boot_id"; echo "===== volúmenes ====="; docker volume ls 2>&1 || echo "NO DISPONIBLE: docker volume ls"; echo "===== contenedores e imágenes ====="; docker ps -a --format "{{.Names}}|{{.Image}}" 2>&1 || echo "NO DISPONIBLE: docker ps"; echo "===== archivos de configuración ====="; sha256sum /opt/homeserver/docker-compose.yml /opt/homeserver/adguard/conf/AdGuardHome.yaml /opt/homeserver/nextcloud/app/config/config.php /opt/homeserver/homepage/config/settings.yaml /opt/homeserver/homepage/config/services.yaml /opt/homeserver/homepage/config/widgets.yaml /opt/homeserver/homepage/config/docker.yaml /opt/homeserver/homepage/config/bookmarks.yaml 2>&1 || true'
    fi
    registrar_texto "$archivo" "$comando" "Estado y archivos de persistencia ($accion)."
    capturar_huellas_persistencia "$accion"

    if [[ $accion == despues ]]; then
        local comparacion="$dir/comparacion.txt" salida codigo
        salida=$(python3 - "$dir/antes.sha256" "$dir/despues.sha256" <<'PY'
import csv
import sys
from pathlib import Path

antes_path, despues_path = map(Path, sys.argv[1:])
if not antes_path.is_file():
    print("NO DISPONIBLE: falta persistencia/antes.sha256")
    print("Resultado general: FALLIDO")
    raise SystemExit(1)

def leer(path):
    with path.open(newline="", encoding="utf-8") as stream:
        return {row["elemento"]: row["sha256"] for row in csv.DictReader(stream)}

antes = leer(antes_path)
despues = leer(despues_path)
fallos = []
for elemento in sorted(set(antes) | set(despues)):
    valor_antes = antes.get(elemento, "NO DISPONIBLE")
    valor_despues = despues.get(elemento, "NO DISPONIBLE")
    igual = valor_antes == valor_despues and not valor_antes.startswith("NO DISPONIBLE")
    estado = "IGUAL" if igual else "DIFERENTE"
    print(f"{elemento}: {estado} (antes={valor_antes}; despues={valor_despues})")
    if not igual:
        fallos.append(elemento)
resultado = "APROBADO" if not fallos else "FALLIDO"
print(f"Resultado general: {resultado}")
if fallos:
    raise SystemExit(1)
PY
        )
        codigo=$?
        registrar_salida "$comparacion" "python3 (comparar persistencia/antes.sha256 y persistencia/despues.sha256)" "Comparación de hashes e inventario antes y después." "$salida" "$codigo"
    fi
    printf 'Captura de persistencia completada: %s\n' "$accion"
}

leer_cpu() {
    awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9; exit}' /proc/stat
}

leer_memoria() {
    awk '
        /^MemTotal:/ {total=$2}
        /^MemAvailable:/ {disponible=$2}
        /^SwapTotal:/ {swap_total=$2}
        /^SwapFree:/ {swap_libre=$2}
        END {
            usado=total-disponible
            swap_usado=swap_total-swap_libre
            printf "%.2f %.2f %.2f %.2f %.2f\n", total/1024, usado/1024, disponible/1024, (total ? usado*100/total : 0), swap_usado/1024
        }' /proc/meminfo
}

cpu_porcentajes() {
    local anterior="$1" actual="$2"
    awk -v p="$anterior" -v c="$actual" '
        BEGIN {
            split(p,a," "); split(c,b," ")
            du=b[1]-a[1]; dn=b[2]-a[2]; ds=b[3]-a[3]; di=b[4]-a[4]
            dw=b[5]-a[5]; dq=b[6]-a[6]; dh=b[7]-a[7]; dt=b[8]-a[8]
            total=du+dn+ds+di+dw+dq+dh+dt
            if (total <= 0) {print "0.00 0.00 0.00 0.00 100.00"; exit}
            usuario=(du+dn)*100/total
            sistema=(ds+dq+dh)*100/total
            espera=dw*100/total
            inactivo=di*100/total
            usado=usuario+sistema+(dt*100/total)
            printf "%.2f %.2f %.2f %.2f %.2f\n", usado, usuario, sistema, espera, inactivo
        }'
}

convertir_docker_stats() {
    local fecha="$1" datos="$2"
    printf '%s\n' "$datos" | python3 -c '
import csv
import re
import sys

fecha = sys.argv[1]
def mb(texto):
    match = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]+)\s*", texto)
    if not match:
        return ""
    valor = float(match.group(1))
    unidad = match.group(2)
    factores = {"B": 1e-6, "kB": 1e-3, "KB": 1e-3, "KiB": 0.001024,
                "MB": 1.0, "MiB": 1.048576, "GB": 1000.0, "GiB": 1073.741824}
    return f"{valor * factores.get(unidad, 1.0):.3f}"

writer = csv.writer(sys.stdout)
for fila in csv.reader(sys.stdin):
    if not fila:
        continue
    fila += [""] * (6 - len(fila))
    nombre, cpu, memoria, porcentaje, red, bloque = fila[:6]
    usada = memoria.split("/", 1)[0]
    cpu = cpu.strip().rstrip("%") or "0"
    porcentaje = porcentaje.strip().rstrip("%")
    writer.writerow([fecha, nombre, cpu, mb(usada), porcentaje, red, bloque])
' "$fecha"
}

docker_stats_una_vez() {
    local destino="$1" marca datos
    command -v docker >/dev/null 2>&1 || return 0
    datos=$(timeout 8 docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}' 2>/dev/null)
    [[ -n $datos ]] || return 0
    marca=$(date --iso-8601=seconds 2>/dev/null || date)
    convertir_docker_stats "$marca" "$datos" >>"$destino"
}

docker_stats_loop() {
    local destino="$1" duracion="$2" inicio=$SECONDS restante
    while (( SECONDS - inicio < duracion )); do
        docker_stats_una_vez "$destino"
        restante=$((duracion - (SECONDS - inicio)))
        if (( restante > 30 )); then
            sleep 30
        elif (( restante > 0 )); then
            sleep "$restante"
        fi
    done
}

sondear_http_csv() {
    local destino="$1" marca servicio url codigo tiempo insecure
    marca=$(date --iso-8601=seconds 2>/dev/null || date)
    while IFS=',' read -r servicio url insecure; do
        [[ -n $servicio ]] || continue
        local -a args=(curl -sS -o /dev/null -w '%{http_code},%{time_total}' --max-time 2)
        [[ $insecure == si ]] && args+=(-k)
        args+=("$url")
        local salida
        salida=$("${args[@]}" 2>/dev/null)
        if [[ $salida == *,* ]]; then
            codigo=${salida%%,*}
            tiempo=${salida#*,}
        else
            codigo="000"
            tiempo="NA"
        fi
        printf '%s,%s,%s,%s\n' "$marca" "$servicio" "$codigo" "$tiempo" >>"$destino"
    done <<'EOF'
homepage,http://127.0.0.1:3000/,no
nextcloud,http://127.0.0.1:8080/status.php,no
beszel,http://127.0.0.1:8090/api/health,no
jellyfin,http://127.0.0.1:8096/health,no
adguardhome,http://127.0.0.1:8081/,no
portainer,https://127.0.0.1:9443/api/system/status,si
EOF
}

http_stats_loop() {
    local destino="$1" duracion="$2" inicio=$SECONDS proximo ahora espera
    proximo=$SECONDS
    while (( SECONDS - inicio < duracion )); do
        sondear_http_csv "$destino"
        proximo=$((proximo + 15))
        ahora=$SECONDS
        espera=$((proximo - ahora))
        (( espera > 0 )) && sleep "$espera"
    done
}

muestrear_metricas() {
    local modo="$1" duracion="$2" sufijo="$PREFIJO_SUF"
    local metricas="$RESULTADOS/metricas_${modo}${sufijo}.csv"
    local contenedores="$RESULTADOS/metricas_${modo}${sufijo}_contenedores.csv"
    local vmstat="$RESULTADOS/vmstat_${modo}${sufijo}.txt"
    local free_file="$RESULTADOS/free_${modo}${sufijo}.txt"
    local contenedores_estado="$RESULTADOS/metricas_${modo}${sufijo}_contenedores_estado.txt"
    local respuesta="$RESULTADOS/tiempos_respuesta_carga${sufijo}.csv"
    local cuenta=$(((duracion + 4) / 5))
    local anterior actual porcentajes memoria carga total
    local inicio=$SECONDS indice instante esperado transcurrido carga_pct usuario_pct sistema_pct iowait_pct inactivo_pct
    local vm_raw stats_pid http_pid vm_pid

    archivo_csv_nuevo "$metricas" "timestamp,cpu_used_pct,cpu_user_pct,cpu_system_pct,cpu_iowait_pct,cpu_idle_pct,mem_total_mb,mem_used_mb,mem_available_mb,mem_used_pct,swap_used_mb,load1"
    archivo_csv_nuevo "$contenedores" "timestamp,container,cpu_pct,mem_used_mb,mem_pct,net_io,block_io"

    cabecera_texto "$free_file" "free -m (antes y después del muestreo)"
    carga=$(free -m 2>&1)
    if [[ -z $carga ]]; then carga="NO DISPONIBLE: free no está instalado"; fi
    printf 'Antes:\n%s\n' "$carga" | redactor >>"$free_file"

    cabecera_texto "$vmstat" "vmstat -t 5 $cuenta"
    vm_raw=$(mktemp "$RESULTADOS/.vmstat.XXXXXX") || vm_raw=""
    if [[ -n $vm_raw ]]; then
        (
            if command -v vmstat >/dev/null 2>&1; then
                timeout "$((duracion + 12))" vmstat -t 5 "$cuenta"
            else
                printf '%s\n' "NO DISPONIBLE: vmstat no está instalado"
            fi
        ) >"$vm_raw" 2>&1 &
        vm_pid=$!
    else
        vm_pid=""
    fi

    local stats_raw="$contenedores"
    docker_stats_loop "$stats_raw" "$duracion" &
    stats_pid=$!
    if [[ $modo == carga ]]; then
        archivo_csv_nuevo "$respuesta" "timestamp,servicio,http_code,time_total_s"
        http_stats_loop "$respuesta" "$duracion" &
        http_pid=$!
    else
        http_pid=""
    fi

    inicio=$SECONDS
    anterior=$(leer_cpu)
    for ((indice=1; indice<=cuenta; indice++)); do
        esperado=$((inicio + indice * 5))
        transcurrido=$((esperado - SECONDS))
        if (( transcurrido > 0 )); then
            sleep "$transcurrido"
        fi
        actual=$(leer_cpu)
        porcentajes=$(cpu_porcentajes "$anterior" "$actual")
        read -r carga_pct usuario_pct sistema_pct iowait_pct inactivo_pct <<<"$porcentajes"
        memoria=$(leer_memoria)
        read -r total usado disponible usado_pct swap_usado <<<"$memoria"
        transcurrido=$((SECONDS - inicio))
        instante=$(date --iso-8601=seconds 2>/dev/null || date)
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$instante" "$carga_pct" "$usuario_pct" "$sistema_pct" "$iowait_pct" "$inactivo_pct" \
            "$total" "$usado" "$disponible" "$usado_pct" "$swap_usado" "$(awk '{print $1}' /proc/loadavg)" >>"$metricas"
        anterior="$actual"
        printf 'Progreso: %s/%s segundos (%s)\n' "$transcurrido" "$duracion" "$modo"
    done

    if [[ -n $vm_pid ]]; then wait "$vm_pid" || true; fi
    wait "$stats_pid" || true
    if [[ -n $http_pid ]]; then wait "$http_pid" || true; fi

    if [[ -n $vm_raw && -f $vm_raw ]]; then
        redactor <"$vm_raw" >>"$vmstat"
        rm -f -- "$vm_raw"
    else
        printf '%s\n' "NO DISPONIBLE: no se pudo iniciar vmstat" | redactor >>"$vmstat"
    fi

    carga=$(free -m 2>&1)
    if [[ -z $carga ]]; then carga="NO DISPONIBLE: free no está instalado"; fi
    printf 'Después:\n%s\n' "$carga" | redactor >>"$free_file"
    registrar_indice "$metricas" "Métricas del sistema cada cinco segundos durante $modo."
    registrar_indice "$contenedores" "Métricas de Docker cada treinta segundos durante $modo, memoria en MB decimales."
    registrar_indice "$vmstat" "Salida de vmstat -t 5 para $modo."
    registrar_indice "$free_file" "Memoria libre antes y después de $modo."
    if command -v docker >/dev/null 2>&1 && [[ $(wc -l <"$contenedores") -gt 1 ]]; then
        registrar_salida "$contenedores_estado" "docker stats --no-stream (cada 30 segundos)" \
            "Disponibilidad de docker stats durante $modo." "docker stats produjo datos durante el muestreo." 0
    else
        local motivo_docker="NO DISPONIBLE: docker stats no devolvió contenedores o el daemon no responde"
        command -v docker >/dev/null 2>&1 || motivo_docker="NO DISPONIBLE: docker no está instalado"
        registrar_salida "$contenedores_estado" "docker stats --no-stream (cada 30 segundos)" \
            "Disponibilidad de docker stats durante $modo." "$motivo_docker" 0
    fi
    if [[ $modo == carga ]]; then
        registrar_csv_indice "$respuesta" "Sondeos de los seis servicios cada quince segundos durante carga."
    fi
    redactar_archivo "$metricas"
    redactar_archivo "$contenedores"
    redactar_archivo "$vmstat"
    redactar_archivo "$free_file"
    printf 'Muestreo terminado: %s\n' "$metricas"
}

medir_comando() {
    local etiqueta="${1:-}" archivo_entrada comando inicio fin duracion codigo tmp csv
    if [[ -z $etiqueta ]]; then
        printf '%s\n' "Uso: tiempo <etiqueta> -- <comando...>" >&2
        return 2
    fi
    shift
    if [[ $# -lt 2 || $1 != -- ]]; then
        printf '%s\n' "Uso: tiempo <etiqueta> -- <comando...>" >&2
        return 2
    fi
    shift
    if (( $# == 0 )); then
        printf '%s\n' "ERROR: falta el comando que se medirá." >&2
        return 2
    fi
    etiqueta=$(etiqueta_segura "$etiqueta")
    archivo_entrada="$RESULTADOS/tiempos/$etiqueta$PREFIJO_SUF.txt"
    mkdir -p "$(dirname "$archivo_entrada")"
    printf -v comando '%q ' "$@"
    comando=${comando% }
    cabecera_texto "$archivo_entrada" "$comando"

    tmp=$(mktemp "$RESULTADOS/.tiempo.XXXXXX") || return 1
    inicio=$(date +%s.%N)
    local inicio_iso
    inicio_iso=$(date --iso-8601=seconds 2>/dev/null || date)
    "$@" >"$tmp" 2>&1
    codigo=$?
    fin=$(date +%s.%N)
    local fin_iso
    fin_iso=$(date --iso-8601=seconds 2>/dev/null || date)
    duracion=$(awk -v comienzo="$inicio" -v final="$fin" 'BEGIN {printf "%.2f", final-comienzo}')
    redactor <"$tmp" | tee -a "$archivo_entrada"
    rm -f -- "$tmp"

    csv="$RESULTADOS/tiempos.csv"
    if [[ ! -f $csv ]]; then
        archivo_csv_nuevo "$csv" "etiqueta,inicio_iso,fin_iso,duracion_s,codigo_salida"
    fi
    python3 - "$csv" "$etiqueta" "$inicio_iso" "$fin_iso" "$duracion" "$codigo" <<'PY'
import csv
import sys
with open(sys.argv[1], "a", newline="", encoding="utf-8") as stream:
    csv.writer(stream).writerow(sys.argv[2:])
PY
    redactar_archivo "$csv"
    registrar_indice "$archivo_entrada" "Salida saneada y duración de la prueba $etiqueta."
    registrar_indice "$csv" "Duraciones y códigos de salida de comandos medidos."
    printf 'Duración: %s s; código de salida: %s\n' "$duracion" "$codigo"
    return "$codigo"
}

registrar_sha256() {
    local etiqueta="${1:-}" ruta="${2:-}" huella fecha archivo salida codigo
    if [[ -z $etiqueta || -z $ruta ]]; then
        printf '%s\n' "Uso: sha256 <etiqueta> <archivo>" >&2
        return 2
    fi
    archivo="$RESULTADOS/sha256.csv"
    if [[ ! -f $archivo ]]; then
        archivo_csv_nuevo "$archivo" "etiqueta,fecha,archivo,sha256"
    fi
    fecha=$(date --iso-8601=seconds 2>/dev/null || date)
    if [[ -f $ruta ]]; then
        huella=$(sha256sum "$ruta" 2>/dev/null | awk '{print $1}')
        codigo=0
    else
        huella="NO DISPONIBLE"
        codigo=1
    fi
    salida=$(python3 - "$archivo" "$etiqueta" "$fecha" "$ruta" "$huella" <<'PY'
import csv
import sys
with open(sys.argv[1], "a", newline="", encoding="utf-8") as stream:
    csv.writer(stream).writerow(sys.argv[2:])
print(",".join(sys.argv[2:]))
PY
    )
    printf '%s\n' "$salida" | redactor
    redactar_archivo "$archivo"
    registrar_indice "$archivo" "Huellas SHA-256 solicitadas por etiqueta."
    (( codigo == 0 )) || return "$codigo"
}

saneador() {
    local origen="${1:-}" base nombre salida contenido codigo
    if [[ -z $origen ]]; then
        printf '%s\n' "Uso: sanear <archivo>" >&2
        return 2
    fi
    base=$(basename -- "$origen")
    nombre=${base%.*}
    salida="$RESULTADOS/${nombre}${PREFIJO_SUF}.limpio.txt"
    if [[ -f $origen ]]; then
        contenido=$(redactor <"$origen")
        codigo=$?
    else
        contenido="NO DISPONIBLE: no existe el archivo indicado: $origen"
        codigo=1
    fi
    registrar_salida "$salida" "sanear $origen" "Copia saneada del archivo $base." "$contenido" "$codigo"
    printf 'Archivo saneado: %s\n' "$salida"
}

generar_resumen() {
    python3 - "$RESULTADOS" <<'PY'
import csv
import math
import re
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
command = "recolectar_evidencias.sh resumen"
header = f"# Fecha: __FECHA__\n# Host: __HOST__\n# Comando: {command}\n"

def fecha():
    import datetime
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")

def cabecera_markdown(path, title, body):
    texto = header.replace("__FECHA__", fecha()).replace("__HOST__", __import__("socket").gethostname())
    path.write_text(texto + title + "\n\n" + body.rstrip() + "\n", encoding="utf-8")

def leer_csv(path):
    try:
        with path.open(newline="", encoding="utf-8") as stream:
            return list(csv.DictReader(stream))
    except (OSError, csv.Error):
        return []

def numero(valor):
    try:
        return float(valor)
    except (TypeError, ValueError):
        return None

def media(valores):
    return statistics.mean(valores) if valores else None

def maximo(valores):
    return max(valores) if valores else None

def fmt(valor, digitos=2):
    return f"{valor:.{digitos}f}" if valor is not None else "n/a"

metricas_files = sorted(p for p in root.rglob("metricas_*.csv") if not p.name.endswith("_contenedores.csv"))
recursos = []
datos_energia = {"reposo": [], "carga": []}
for path in metricas_files:
    escenario = path.stem.removeprefix("metricas_")
    filas = leer_csv(path)
    valores = {}
    for campo in ("cpu_used_pct", "mem_used_mb", "mem_used_pct", "swap_used_mb", "load1"):
        valores[campo] = [v for row in filas if (v := numero(row.get(campo))) is not None]
    recursos.append({
        "escenario": escenario,
        "cpu_media": media(valores["cpu_used_pct"]),
        "cpu_max": maximo(valores["cpu_used_pct"]),
        "mem_media": media(valores["mem_used_mb"]),
        "mem_pct_media": media(valores["mem_used_pct"]),
        "swap_max": maximo(valores["swap_used_mb"]),
        "load_media": media(valores["load1"]),
        "n": len(filas),
    })
    if escenario.startswith("reposo"):
        datos_energia["reposo"].extend(valores["cpu_used_pct"])
    if escenario.startswith("carga"):
        datos_energia["carga"].extend(valores["cpu_used_pct"])

tabla = ["| Escenario | CPU media % | CPU máx. % | RAM media MB | RAM media % | Swap máx. MB | Carga media | n |",
         "|---|---:|---:|---:|---:|---:|---:|---:|"]
for fila in recursos:
    tabla.append("| {escenario} | {cpu_media} | {cpu_max} | {mem_media} | {mem_pct_media} | {swap_max} | {load_media} | {n} |".format(
        escenario=fila["escenario"], cpu_media=fmt(fila["cpu_media"]), cpu_max=fmt(fila["cpu_max"]),
        mem_media=fmt(fila["mem_media"]), mem_pct_media=fmt(fila["mem_pct_media"]),
        swap_max=fmt(fila["swap_max"]), load_media=fmt(fila["load_media"]), n=fila["n"]))
if not recursos:
    tabla.append("| NO DISPONIBLE | n/a | n/a | n/a | n/a | n/a | n/a | 0 |")
cabecera_markdown(root / "tabla_recursos.md", "# Tabla de recursos", "\n".join(tabla))

contenedor_files = sorted(root.rglob("metricas_*_contenedores.csv"))
grupos = {}
for path in contenedor_files:
    escenario = path.stem.removeprefix("metricas_").removesuffix("_contenedores")
    for row in leer_csv(path):
        nombre = row.get("container", "")
        if not nombre:
            continue
        llave = (escenario, nombre)
        grupo = grupos.setdefault(llave, {"cpu": [], "ram": []})
        cpu = numero(row.get("cpu_pct"))
        ram = numero(row.get("mem_used_mb"))
        if cpu is not None:
            grupo["cpu"].append(cpu)
        if ram is not None:
            grupo["ram"].append(ram)
tabla = ["| Escenario | Contenedor | CPU media % | CPU máx. % | RAM media MB | RAM máx. MB | n |",
         "|---|---|---:|---:|---:|---:|---:|"]
for (escenario, nombre), grupo in sorted(grupos.items()):
    tabla.append(f"| {escenario} | {nombre} | {fmt(media(grupo['cpu']))} | {fmt(maximo(grupo['cpu']))} | {fmt(media(grupo['ram']))} | {fmt(maximo(grupo['ram']))} | {max(len(grupo['cpu']), len(grupo['ram']))} |")
if not grupos:
    tabla.append("| NO DISPONIBLE | — | n/a | n/a | n/a | n/a | 0 |")
cabecera_markdown(root / "tabla_contenedores.md", "# Tabla de contenedores", "\n".join(tabla))

tiempos = {}
for path in sorted(root.rglob("http_endpoints*.csv")) + sorted(root.rglob("tiempos_respuesta_carga*.csv")):
    for row in leer_csv(path):
        servicio = row.get("servicio", "")
        if not servicio:
            continue
        valor = numero(row.get("time_total_s"))
        if valor is None:
            continue
        estado = row.get("http_code", "")
        entrada = tiempos.setdefault(servicio, {"valores": [], "ok": 0})
        entrada["valores"].append(valor)
        if estado[:1] in ("2", "3"):
            entrada["ok"] += 1

def percentil(valores, p):
    if not valores:
        return None
    ordenados = sorted(valores)
    posicion = (len(ordenados) - 1) * p
    inferior = math.floor(posicion)
    superior = math.ceil(posicion)
    if inferior == superior:
        return ordenados[inferior]
    return ordenados[inferior] * (superior - posicion) + ordenados[superior] * (posicion - inferior)

tabla = ["| Servicio | n | HTTP 2xx/3xx | Media ms | p95 ms | Máx. ms |",
         "|---|---:|---:|---:|---:|---:|"]
for servicio, datos in sorted(tiempos.items()):
    valores = datos["valores"]
    tabla.append(f"| {servicio} | {len(valores)} | {datos['ok']} | {fmt(media(valores)*1000)} | {fmt(percentil(valores, .95)*1000)} | {fmt(maximo(valores)*1000)} |")
if not tiempos:
    tabla.append("| NO DISPONIBLE | 0 | 0 | n/a | n/a | n/a |")
cabecera_markdown(root / "tabla_tiempos_respuesta.md", "# Tabla de tiempos de respuesta", "\n".join(tabla))

tiempos_path = root / "tiempos.csv"
filas_tiempos = leer_csv(tiempos_path) if tiempos_path.exists() else []
repetidos = {}
for row in filas_tiempos:
    etiqueta = row.get("etiqueta", "")
    base = re.sub(r"_\d+$", "", etiqueta)
    item = repetidos.setdefault(base, {"duraciones": [], "codigos": []})
    valor = numero(row.get("duracion_s"))
    try:
        exitoso = int(row.get("codigo_salida", "")) == 0
    except ValueError:
        exitoso = False
    item["codigos"].append(exitoso)
    if exitoso and valor is not None:
        item["duraciones"].append(valor)

repeat_csv = root / "repetibilidad.csv"
with repeat_csv.open("w", newline="", encoding="utf-8") as stream:
    writer = csv.writer(stream)
    writer.writerow(["etiqueta", "n", "valores_s", "media_s", "desviacion_estandar_s", "exito_pct"])
    for etiqueta, item in sorted(repetidos.items()):
        valores = item["duraciones"]
        desviacion = statistics.stdev(valores) if len(valores) >= 2 else "n/a (n<2)"
        exito = 100 * sum(item["codigos"]) / len(item["codigos"]) if item["codigos"] else 0
        writer.writerow([etiqueta, len(valores), ";".join(f"{v:.2f}" for v in valores),
                         f"{media(valores):.2f}" if valores else "",
                         f"{desviacion:.2f}" if isinstance(desviacion, (float, int)) else desviacion,
                         f"{exito:.0f}"])

tabla = ["| Etiqueta | n exitosos | Valores exitosos (s) | Media (s) | Desviación estándar muestral (s) | Éxito |",
         "|---|---:|---|---:|---:|---:|"]
for etiqueta, item in sorted(repetidos.items()):
    valores = item["duraciones"]
    desviacion = statistics.stdev(valores) if len(valores) >= 2 else None
    exito = 100 * sum(item["codigos"]) / len(item["codigos"]) if item["codigos"] else 0
    tabla.append(f"| {etiqueta} | {len(valores)} | {', '.join(f'{v:.2f}' for v in valores)} | {fmt(media(valores))} | {fmt(desviacion) if desviacion is not None else 'n/a (n<2)'} | {exito:.0f} % |")
if not repetidos:
    tabla.append("| NO DISPONIBLE | 0 | — | n/a | n/a (n<2) | 0 % |")
cabecera_markdown(root / "repetibilidad.md", "# Repetibilidad", "\n".join(tabla))

resposo = datos_energia["reposo"]
carga = datos_energia["carga"]
energia_lines = ["**ESTIMACIÓN: modelo energético; no es una medición con vatímetro.**", ""]
if not resposo or not carga:
    energia_lines.append("NO DISPONIBLE: se requieren muestras de reposo y carga.")
else:
    u_r = statistics.mean(resposo) / 100
    u_c = statistics.mean(carga) / 100
    u_p = max(carga) / 100
    resto = 35.0
    energia_lines.extend([
        "Modelo: P_cpu = TDP · (0,30 + 0,70 · u); resto del equipo = 35 W; kWh/mes = W · 24 · 30 / 1000.",
        f"Utilización: reposo media {u_r*100:.1f} %, carga media {u_c*100:.1f} %, pico de carga {u_p*100:.1f} %.",
        "",
        "| Escenario | u (%) | TDP 65 W: CPU W | TDP 65 W: equipo W | kWh/mes 65 W | TDP 95 W: CPU W | TDP 95 W: equipo W | kWh/mes 95 W |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for nombre, utilizacion in (("Reposo", u_r), ("Carga media", u_c), ("Carga pico", u_p)):
        valores = [nombre, f"{utilizacion*100:.1f}"]
        for tdp in (65, 95):
            cpu = tdp * (0.30 + 0.70 * utilizacion)
            equipo = cpu + resto
            valores.extend((f"{cpu:.1f}", f"{equipo:.1f}", f"{equipo*24*30/1000:.1f}"))
        energia_lines.append("| " + " | ".join(valores) + " |")
    perfil = 0.9 * u_r + 0.1 * u_c
    energia_lines.extend(["", f"Perfil típico supuesto (90 % reposo, 10 % carga): utilización media {perfil*100:.1f} %."])
    for tdp in (65, 95):
        potencia = tdp * (0.30 + 0.70 * perfil) + resto
        energia_lines.append(f"- TDP {tdp} W: {potencia:.1f} W → {potencia*24*30/1000:.1f} kWh/mes → {potencia*24*365/1000:.0f} kWh/año.")
    respuestas = []
    for path in sorted(root.rglob("tiempos_respuesta_carga*.csv")):
        respuestas.extend(leer_csv(path))
    if respuestas:
        correctos = sum(1 for row in respuestas if row.get("http_code", "")[:1] in ("2", "3"))
        energia_lines.extend(["", f"Disponibilidad HTTP observada durante carga: {correctos}/{len(respuestas)} sondeos correctos ({100*correctos/len(respuestas):.2f} %)."])
cabecera_markdown(root / "consumo_energetico_estimado.md", "# Consumo energético estimado", "\n".join(energia_lines))

matriz = [
    ("F1-01", "Instalación desatendida desde entrada cerrada", "Instalar con stdin cerrado y registrar duración", "01_despliegue_integracion/log_instalacion_debian13.txt"),
    ("F1-02", "Servicios, puertos y salud de interfaces", "Recopilar contenedores, puertos, HTTP y DNS", "01_despliegue_integracion/docker_ps_y_puertos.txt"),
    ("F1-03", "Persistencia tras reinicio", "Comparar hashes antes y después del reinicio", "01_despliegue_integracion/persistencia_reinicio.txt"),
    ("F1-04", "Interfaces autenticadas", "Capturar Homepage, Portainer, Nextcloud, Jellyfin y AdGuard", "01_despliegue_integracion/*.png"),
    ("F2-01", "Línea base de reposo", "Muestrear CPU, memoria, swap, carga y contenedores", "02_rendimiento_hardware_legacy/metricas_reposo.csv"),
    ("F2-02", "Carga de servicios", "Transcodificar, cargar Nextcloud y sondear HTTP", "02_rendimiento_hardware_legacy/metricas_carga.csv"),
    ("F2-03", "Sobrecarga de controles de seguridad", "Comparar carga con y sin seguridad", "02_rendimiento_hardware_legacy/metricas_carga_sin_seguridad.csv"),
    ("F3-01", "Proxy de socket y capacidades mínimas", "Probar endpoints permitidos/denegados e inspeccionar contenedores", "03_seguridad_y_red/auditoria_socket_y_capacidades.txt"),
    ("F3-02", "Reglas de firewall y exposición LAN", "Inspeccionar UFW, DOCKER-USER y escaneos", "03_seguridad_y_red/reglas_ufw_iptables_nmap.txt"),
    ("F3-03", "Bloqueo de intentos SSH", "Provocar fallos controlados y verificar Fail2ban", "03_seguridad_y_red/prueba_fail2ban.txt"),
    ("F3-04", "Resolución mDNS", "Resolver homeserver.local desde servidor y cliente", "03_seguridad_y_red/aislamiento_red_y_mdns.txt"),
    ("F3-05", "Rollback de IP estática", "Medir pérdida, disparo del rollback y restauración", "03_seguridad_y_red/prueba_rollback_ip_90s.txt"),
    ("F3-06", "Alcance de aislamiento de MariaDB", "Documentar conectividad observada y alcance", "03_seguridad_y_red/aislamiento_red_y_mdns.txt"),
    ("F4-01", "Hotplug y selección de discos", "Asignar discos y conservar/formatear según confirmación", "04_respaldo_restauracion_monitoreo/logs_udev_y_borg_tiempos.txt"),
    ("F4-02", "Respaldos Borg y retención", "Crear incrementales, consultar cifrado y aplicar poda", "04_respaldo_restauracion_monitoreo/logs_udev_y_borg_tiempos.txt"),
    ("F4-03", "Integridad y restauración", "Comparar SHA-256 antes y después de extraer datos", "04_respaldo_restauracion_monitoreo/verificacion_integridad_sha256.txt"),
    ("F4-04", "Alertas y recuperación", "Verificar notificación, deduplicación y resolución", "04_respaldo_restauracion_monitoreo/simulacion_alertas_telegram.txt"),
]
lineas = ["| ID | Requisito | Prueba | Evidencia (archivo/captura) | Resultado APROBADO/FALLIDO | Observación |",
          "|---|---|---|---|---|---|"]
for id_, requisito, prueba, evidencia in matriz:
    lineas.append(f"| {id_} | {requisito} | {prueba} | {evidencia} |  |  |")
cabecera_markdown(root / "plantilla_matriz_trazabilidad.md", "# Plantilla de matriz de trazabilidad", "\n".join(lineas))

repetibilidad = [
    "| Prueba | Intento 1 | Intento 2 | Intento 3 | Media | σ | Éxito |",
    "|---|---:|---:|---:|---:|---:|---:|",
    "| Despliegue |  |  |  |  |  |  |",
    "| Rollback IP |  |  |  |  |  |  |",
    "| Respaldo incremental |  |  |  |  |  |  |",
]
cabecera_markdown(root / "plantilla_repetibilidad_n3.md", "# Plantilla de repetibilidad N=3", "\n".join(repetibilidad))
PY
    local archivo
    for archivo in "$RESULTADOS"/tabla_recursos.md "$RESULTADOS"/tabla_contenedores.md \
        "$RESULTADOS"/tabla_tiempos_respuesta.md "$RESULTADOS"/repetibilidad.md \
        "$RESULTADOS"/repetibilidad.csv "$RESULTADOS"/consumo_energetico_estimado.md \
        "$RESULTADOS"/plantilla_matriz_trazabilidad.md "$RESULTADOS"/plantilla_repetibilidad_n3.md; do
        [[ -f $archivo ]] || continue
        redactar_archivo "$archivo"
        registrar_indice "$archivo" "Tabla, estimación o plantilla generada por el modo resumen."
    done
    printf 'Resumen generado en: %s\n' "$RESULTADOS"
}

case "$MODE" in
    estado)
        estado_servidor "${2:-estado}"
        codigo=$?
        ;;
    reposo|carga)
        duracion="${2:-600}"
        if [[ ! $duracion =~ ^[0-9]+$ ]] || (( duracion < 1 )); then
            printf '%s\n' "ERROR: los segundos deben ser un entero mayor que cero." >&2
            codigo=2
        else
            muestrear_metricas "$MODE" "$duracion"
            codigo=$?
        fi
        ;;
    tiempo)
        shift
        medir_comando "$@"
        codigo=$?
        ;;
    sha256)
        shift
        registrar_sha256 "$@"
        codigo=$?
        ;;
    persistencia)
        shift
        persistencia "${1:-}"
        codigo=$?
        ;;
    sanear)
        shift
        saneador "${1:-}"
        codigo=$?
        ;;
    resumen)
        generar_resumen
        codigo=$?
        ;;
    *)
        ayuda >&2
        codigo=2
        ;;
esac

exit "$codigo"
