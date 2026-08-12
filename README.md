# Home Server

Este repositorio contiene un script de automatización (`setup.sh`) y la infraestructura como código (`docker-compose.yml`) para desplegar un servidor casero (Home Server) avanzado, seguro y completamente funcional en **Debian**.

El script prepara el sistema operativo, optimiza la conexión, configura la seguridad básica y levanta un ecosistema de contenedores Docker preconfigurados para interactuar entre sí.

## 🚀 ¿Qué incluye?

### 🛠️ Sistema y Red
* **Optimización de Repositorios:** Busca automáticamente el espejo (mirror) de Debian con menor latencia para tu conexión.
* **Resolución mDNS:** Configura Avahi para que puedas acceder a tu servidor usando un dominio local (ej. `http://tu-servidor.local`), sin depender de IPs estáticas fijas.
* **Firewall (UFW) y Fail2ban:** Protege los puertos esenciales y bloquea automáticamente intentos de fuerza bruta por SSH.
* **Respaldos Automáticos:** Tarea programada (Cron) con **BorgBackup** que realiza copias de seguridad diarias (con retención semanal y mensual).

### 🐳 Ecosistema de Contenedores (Docker)
1. **Homepage:** Un portal central (Dashboard) dinámico que agrupa los accesos a todos tus servicios.
2. **Portainer y Watchtower:** Interfaz gráfica para gestionar contenedores y sistema de actualizaciones automáticas de imágenes.
3. **Seguridad Docker:** Usa `docker-socket-proxy` para aislar el socket de Docker y aumentar la seguridad.
4. **Monitoreo:** **Prometheus** (recolección de métricas), **Node Exporter** (estadísticas del sistema) y **Grafana** (paneles visuales).
5. **Nextcloud + MariaDB:** Tu propia nube privada de almacenamiento, sincronización y contactos.
6. **Jellyfin:** Servidor multimedia para organizar y transmitir tus películas, series y música.
7. **Pi-hole:** Bloqueador de publicidad a nivel de red y servidor DNS local.
8. **Tailscale:** VPN Mesh de configuración cero (Zero-config) para acceder a tu servidor de forma segura desde cualquier lugar del mundo.

## ⚙️ Requisitos
* Una computadora o placa (como Raspberry Pi) con **Debian** (o derivados) recién instalado.
* Conexión a internet.
* Acceso de superusuario (`sudo`).

## 📥 Instalación

