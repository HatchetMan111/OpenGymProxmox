# openGym auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil, LXC + Docker)

> Upstream-App (kein Teil dieses Repos): `https://github.com/DuarteSantos8/openGym`
> (Self-hosted Gym & Body-Weight Tracker – Routinen planen, Workouts loggen,
> Muskel-Status sehen, Passkey-Login, AGPL-3.0)
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft per Docker Compose – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

> **Vorher:** `HatchetMan111` in den URLs unten durch deinen GitHub-User ersetzen
> (oder das Repo forken – das Script nutzt `INSTALLER_REPO`/`SERVICE_URL` oben
> im Script, ein `sed` genügt).

```bash
# 1. Installieren – das war's schon:
#    CT-ID ist immer die nächste freie, IP per DHCP,
#    Root-Passwort wird einmalig am Ende angezeigt:
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenGymProxmox/main/install/opengym.sh)"
```

Weitere Anpassungen (ID immer **nächste freie**, außer gesetzt):

```bash
CTID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OpenGymProxmox/main/install/opengym.sh)"
bash opengym.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash opengym.sh --version v1.3.10   # bestimmte Upstream-Version statt main
bash opengym.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/opengym-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / CT-Name | `opengym` |
| Zweck | Self-hosted Gym & Body-Weight Tracker – Routinen, Workout-Logging, Stats, Passkeys |
| Tech-Stack | Docker Compose: `api` (Node `node:http` `:3000`) + `web` (nginx `:8080`), Daten in `./data` (JSON) |
| GitHub-Repo (Upstream) | `https://github.com/DuarteSantos8/openGym` |
| Web UI | `http://<CT-IP>:8080` (Compose-Portmapping, `0.0.0.0`) |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk (Minimum 1 / 1024 / 6) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt (Kollision → ausweichen, explizite ID → Update-Modus) |
| Template | Debian-12-Standard (`pveam`, `debian-12-standard*.tar.*`) |
| CT-Features | `onboot: 1`, `nesting=1,keyctl=1`, unprivileged (Docker braucht Nesting) |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools (root, `pct/pvesh/pvesm`), nimmt die nächste freie CT-ID,
   erkennt Disk-Storage (bevorzugt `local-lvm`), lädt das Debian-12-Template falls nötig,
2. erstellt den CT `opengym` (`onboot: 1`, Nesting, DHCP, zufälliges Root-PW),
   startet ihn und wartet auf die Gast-IP,
3. installiert im Gast Docker + Compose-Plugin, klont/pullt Upstream nach
   `/opt/opengym`, rendert `.env` (`RP_ID`/`ORIGIN` = CT-IP, `PASSWORD_LOGIN=1`
   als LAN-Fallback), `docker compose pull + up -d` (inkl. Media-One-Shot, ~140 MB),
   schreibt `opengym-compose.service`, `systemctl enable --now` (Docker + Unit),
4. verifiziert `systemctl is-active opengym-compose` + HTTP auf `localhost:8080/`
   (Retry bis 5 Min – Erststart zieht Images/Media) und gibt die finale URL + CT-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active opengym-compose = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8080/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : openGym – Self-hosted Gym & Body-Weight Tracker
  Upstream     : https://github.com/DuarteSantos8/openGym (main)
  CT           : 100 (Name: opengym, onboot=1, unprivileged, nesting=1)
  Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Web UI       : http://192.168.1.100:8080
  ...
  Log          : /tmp/opengym-install-2026-....log
══════════════════════════════════════════════════════════
```

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 90
pct exec $CT -- systemctl is-active opengym-compose
curl -fs http://<CT-IP>:8080/ >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash opengym.sh --ctid 100            # Update: idempotent (git pull + compose pull/up + restart)
pct stop 100 && pct destroy 100       # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code + Aufrufstapel aus, Voll-Log unter `/tmp/opengym-install-*.log`.
- `bash opengym.sh --debug` für `bash -x`-Trace.
- Im Gast: `pct enter <CTID>`, dann `systemctl status opengym-compose --no-pager`,
  `journalctl -u opengym-compose -n 100`, `cd /opt/opengym && docker compose ps && docker compose logs --tail=100`.

## Hinweis: Passkeys im LAN

Passkeys sind an exakten Hostnamen + HTTPS gebunden (Browser-Regel, einzige
Ausnahme `localhost`). Über `http://<CT-IP>:8080` nutzt du daher den
**Passwort-Login** (`PASSWORD_LOGIN=1`, vom Script default gesetzt).
Für Domain-Betrieb mit HTTPS (empfohlen für Handys): Reverse-Proxy/Tunnel auf
die CT-IP `:8080`, dann im Gast in `/opt/opengym/.env` setzen:

```bash
RP_ID=gym.example.com
ORIGIN=https://gym.example.com
```

Danach `cd /opt/opengym && docker compose up -d` (Details: Upstream `docs/SELF_HOSTING.md`).

## Dateien

- `install/opengym.sh` – Proxmox-Einzeiler (Host, root, `pct`-Provision, Gast-Setup via `pct exec`).
- `systemd/opengym-compose.service` – Wrapper-Unit (`:8080`, `After=docker.service network-online.target`, `Restart` via `unless-stopped` + `RemainAfterExit`).
