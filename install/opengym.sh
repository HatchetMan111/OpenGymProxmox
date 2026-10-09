#!/usr/bin/env bash
#
# openGym Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      openGym – Self-hosted Gym & Body-Weight Tracker (Plan, Log, Stats, Passkeys)
# Upstream: https://github.com/DuarteSantos8/openGym (AGPL-3.0, kein Teil dieses Repos)
# Stack:    Docker Compose (api :3000 + web :8080 via nginx), Daten in ./data (JSON)
# Laeuft:   vollstaendig lokal in einem LXC-Container, keine Cloud noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Gast!)
# Modus:    LXC + Docker (upstream-nah: git clone + compose pull, kein Fork noetig)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenGymProxmox/main/install/opengym.sh)"
#   CTID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenGymProxmox/main/install/opengym.sh)"
#   bash opengym.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="opengym"                                   # CT-Name + Service-Name
APP_PORT="8080"                                 # Web UI (Compose: WEB_PORT -> nginx)
UPSTREAM_REPO="https://github.com/DuarteSantos8/openGym"
INSTALLER_REPO="https://github.com/HatchetMan111/OpenGymProxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/OpenGymProxmox/main/systemd/opengym-compose.service"
OPENGYM_VERSION="main"                          # Branch/Tag von Upstream (z. B. v1.3.10)

DEFAULT_CORES="2"                               # vCPU
DEFAULT_RAM="2048"                              # RAM in MB
DEFAULT_DISK="8"                                # Disk in GB (Images ~1 GB + 140 MB Media + Daten)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE=""                              # leer = auto (bevorzugt local-lvm)
DEFAULT_TEMPLATE_STORAGE="local"                # Storage fuer Container-Templates (vztmpl)
DEBIAN_TEMPLATE="debian-12-standard"            # pveam-Template-Präfix

APP_DIR="/opt/opengym"
GUEST_SERVICE="opengym-compose"

# Umgebungs-Overrides: CTID=150 CORES=2 RAM=2048 DISK=8 ./opengym.sh
CTID_ARG="${CTID:-}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  # shellcheck disable=SC2034 # Farbpalette (BOLD/CYAN fuer spaetere Meldungen reserviert)
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Stapel, Log)
# shellcheck disable=SC2154 # ec wird im Trap zugewiesen, nicht ausserhalb
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Aufrufstapel: ${FUNCNAME[*]:-main}"; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer (Docker-in-LXC, upstream-nah)

Usage:
  bash opengym.sh [OPTIONEN]
  CTID=150 bash opengym.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/main/install/opengym.sh)"

Optionen:
  --ctid ID            CT-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       Disk-Storage (Default: auto, bevorzugt local-lvm)
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --version VER        Upstream-Branch/Tag (Default: ${OPENGYM_VERSION})
  --password PW        Root-Passwort im CT (Default: zufaellig, wird einmalig angezeigt)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CTID_ARG" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="$DEFAULT_STORAGE" BRIDGE="$DEFAULT_BRIDGE"
VERSION="$OPENGYM_VERSION" ROOTPW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CTID="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --password) ROOTPW="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    _) shift;;  # Platzhalter fuer Einzeiler-Trick: ...)" _ --flags
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

CTID_EXPLICIT=0
[[ -n "$CTID_ARG" ]] && CTID_EXPLICIT=1

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }
command -v pvesm >/dev/null || { msg_error "pvesm nicht gefunden."; exit 1; }

if [[ -z "$CTID" ]]; then
  CTID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CTID"
else
  if pct status "$CTID" >/dev/null 2>&1; then
    if [[ "$CTID_EXPLICIT" == "1" ]]; then
      msg_info "CT $CTID existiert – Update-Modus (idempotent)."
    else
      FREE_ID="$(pvesh get /cluster/nextid)"
      msg_warn "CTID $CTID belegt – weiche auf freie ID $FREE_ID aus."
      CTID="$FREE_ID"
    fi
  fi
fi

if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status 2>/dev/null | grep -q '^local-lvm[[:space:]]'; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein CT-Disk-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Bridge: $BRIDGE | CT-Name: $APP | Upstream: $VERSION"

[[ "$RAM" -ge 1024 ]] || msg_warn "Unter 1024 MB wird Docker kaum laufen (gewaehlt: $RAM)."
[[ "$DISK" -ge 6 ]] || msg_warn "Unter 6 GB wird es mit Images + Media eng (gewaehlt: $DISK)."

# ---------------------------------------------------------------------------
# 2. Template sicherstellen
# ---------------------------------------------------------------------------
TEMPLATE_FILE="$(pveam list "$DEFAULT_TEMPLATE_STORAGE" 2>/dev/null | grep -oP "${DEBIAN_TEMPLATE}[^\s]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE_FILE:-}" ]]; then
  msg_info "Aktualisiere Template-Liste und lade ${DEBIAN_TEMPLATE} ..."
  pveam update
  CANDIDATE="$(pveam available 2>/dev/null | grep -oP "^(?:${DEFAULT_TEMPLATE_STORAGE}:vztmpl/)?\\K${DEBIAN_TEMPLATE}[^\\s]*\\.tar\\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
  [[ -n "${CANDIDATE:-}" ]] || { msg_error "Kein ${DEBIAN_TEMPLATE}-Template via pveam verfuegbar."; exit 1; }
  pveam download "$DEFAULT_TEMPLATE_STORAGE" "$CANDIDATE"
  TEMPLATE_FILE="$CANDIDATE"
  msg_ok "Template geladen: $TEMPLATE_FILE"
else
  msg_ok "Template vorhanden: $TEMPLATE_FILE"
fi
OSTEMPLATE="${DEFAULT_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, nur Gast provisionieren)
# ---------------------------------------------------------------------------
if pct status "$CTID" >/dev/null 2>&1; then
  msg_warn "CT $CTID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -n "$ROOTPW" ]] || ROOTPW="$(openssl rand -hex 12)"
  msg_info "Erstelle CT $CTID ($APP): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CTID" "$OSTEMPLATE" \
    --hostname "$APP" \
    --password "$ROOTPW" \
    --cores "$CORES" --memory "$RAM" --swap 512 \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --onboot 1 \
    --features "nesting=1,keyctl=1" \
    --unprivileged 1 \
    --nameserver "1.1.1.1 8.8.8.8"
  msg_ok "CT $CTID erstellt (onboot=1, nesting=1, unprivileged)."
  pct start "$CTID" \
    || { msg_error "pct start scheiterte (oft RAM/Storage voll). free -m und pvesm status pruefen."; exit 1; }
  msg_ok "CT $CTID laeuft."
fi

pct start "$CTID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Gast-IP warten
# ---------------------------------------------------------------------------
msg_info "Warte auf Gast-IP (max. 2 Min, DHCP) ..."
CT_IP=""
for i in $(seq 1 12); do
  sleep 10
  CT_IP="$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)"
  if [[ -n "${CT_IP:-}" ]]; then
    msg_ok "Gast-IP: $CT_IP"
    break
  fi
  [[ $((i % 3)) == 0 ]] && msg_info "noch keine IP nach $((i * 10))s ..."
done
if [[ -z "${CT_IP:-}" ]]; then
  msg_error "Keine Gast-IP nach 2 Min. Diagnose-Dump:"
  msg_error "--- pct status ---"; pct status "$CTID" || true
  msg_error "--- pct config ---"; pct config "$CTID" || true
  msg_error "Naechste Schritte:"
  msg_error " 1) pct enter $CTID -> ip -4 addr; systemctl status networking"
  msg_error " 2) DHCP auf $BRIDGE pruefen; ggf. statische IP: pct set $CTID --net0 name=eth0,bridge=$BRIDGE,ip=192.168.1.50/24,gw=192.168.1.1"
  msg_error " 3) Update-Modus: bash opengym.sh --ctid $CTID (CT bleibt bestehen, idempotent)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. openGym im Gast (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Provisioniere openGym im Gast (Docker + Compose + Upstream $VERSION) ..."

pct exec "$CTID" -- bash -s -- "$CT_IP" "$VERSION" <<'GUEST_EOF'
set -euo pipefail
CT_IP="$1"
UPSTREAM_VERSION="$2"
export DEBIAN_FRONTEND=noninteractive
echo "[GAST] CT-IP: $CT_IP | Upstream: $UPSTREAM_VERSION"

# apt-Lock abwarten (Erstboot)
for _ in $(seq 1 12); do
  fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
  echo "[GAST] warte auf apt-lock ..."
  sleep 10
done

apt-get update
apt-get install -y ca-certificates curl git wget gnupg lsb-release

# Docker (idempotent): offizielles Repo + Compose-Plugin
if ! command -v docker >/dev/null 2>&1; then
  echo "[GAST] Installiere Docker ..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  echo "[GAST] Docker bereits vorhanden: $(docker --version)"
fi
systemctl enable --now docker
docker compose version

# App-Code (Update: ff-only pull, sonst fresh clone der Version)
if [[ ! -d /opt/opengym/.git ]]; then
  rm -rf /opt/opengym
  git clone --depth 1 --branch "$UPSTREAM_VERSION" https://github.com/DuarteSantos8/openGym /opt/opengym
else
  git -C /opt/opengym fetch --depth 1 origin "$UPSTREAM_VERSION" || true
  git -C /opt/opengym checkout -q "$UPSTREAM_VERSION" 2>/dev/null || true
  git -C /opt/opengym pull --ff-only || echo "[GAST] WARN: git pull nicht ff-only moeglich – weiter mit lokalem Stand."
fi
test -f /opt/opengym/docker-compose.yml

# .env rendern (nur bekannte Keys; Passkeys brauchen Domain+HTTPS -> LAN-Fallback Passwort-Login)
cat > /opt/opengym/.env <<ENV_EOF
RP_ID=${CT_IP}
ORIGIN=http://${CT_IP}:8080
WEB_PORT=8080
RP_NAME=openGym
PASSWORD_LOGIN=1
TRUST_PROXY=1
ENV_EOF
echo "[GAST] .env geschrieben (RP_ID=$CT_IP, ORIGIN=http://$CT_IP:8080, PASSWORD_LOGIN=1)."

cd /opt/opengym
docker compose pull
docker compose up -d
GUEST_EOF

# systemd-Wrapper aus Installer-Repo uebernehmen (Fallback: Inline-Unit)
if pct exec "$CTID" -- curl -fsSL -o /tmp/opengym-compose.service "$SERVICE_URL"; then
  msg_ok "opengym-compose.service aus Repo uebernommen."
  pct exec "$CTID" -- mv /tmp/opengym-compose.service /etc/systemd/system/opengym-compose.service
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct exec "$CTID" -- tee /etc/systemd/system/opengym-compose.service >/dev/null <<UNIT
[Unit]
Description=openGym Compose Stack (Docker :8080)
Documentation=${UPSTREAM_REPO}
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
fi

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now "$GUEST_SERVICE"

# ---------------------------------------------------------------------------
# 6. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CTID" -- systemctl is-active "$GUEST_SERVICE" \
  || { msg_error "systemd-Service $GUEST_SERVICE ist nicht active."; pct exec "$CTID" -- systemctl status "$GUEST_SERVICE" --no-pager || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active $GUEST_SERVICE = active)."

msg_info "Warte auf Web UI (max. 5 Min, Erststart zieht Images + 140 MB Media) ..."
WEB_OK=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- curl -fs -m 10 "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
if [[ "$WEB_OK" != "1" ]]; then
  msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."
  pct exec "$CTID" -- systemctl status "$GUEST_SERVICE" --no-pager || true
  pct exec "$CTID" -- bash -c "cd $APP_DIR && docker compose ps && docker compose logs --tail=100" || true
  exit 1
fi
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

pct config "$CTID" | grep -q "onboot: 1" && msg_ok "onboot=1 gesetzt." || msg_warn "onboot nicht 1 – bitte pruefen."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : openGym – Self-hosted Gym & Body-Weight Tracker"
echo "  Upstream     : $UPSTREAM_REPO ($VERSION)"
echo "  Installer    : $INSTALLER_REPO"
echo "  CT           : $CTID (Name: $APP, onboot=1, unprivileged, nesting=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Hinweis      : Passkeys brauchen HTTPS+Domain; im LAN laeuft der"
echo "                 Passwort-Login (PASSWORD_LOGIN=1). Fuer Domain-Betrieb"
echo "                 RP_ID/ORIGIN in /opt/opengym/.env auf die Domain setzen"
echo "                 (Anleitung im README) und Stack neu starten."
if [[ -n "${ROOTPW:-}" ]]; then
echo "  Root-PW (CT) : ${ROOTPW} (nur jetzt angezeigt!)"
fi
echo "  Service      : pct enter $CTID -> systemctl status $GUEST_SERVICE"
echo "  Logs         : pct enter $CTID -> cd $APP_DIR && docker compose logs -f"
echo "  Update       : Skript erneut laufen lassen (idempotent: git pull + compose pull/up)"
echo "  Deinstall    : pct stop $CTID && pct destroy $CTID"
echo "  Reboot-Test  : pct reboot $CTID && sleep 90 && curl -fs http://${CT_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
