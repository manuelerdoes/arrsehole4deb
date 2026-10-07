# arrsehole4deb

A self-configuring *arr media stack for Debian 13, run with Docker Compose.
You edit one file (`.env`), run one script, and the apps come up already
connected to each other.

| App | Port | Purpose |
|---|---|---|
| Seerr | 5055 | Browse and request movies/shows |
| Plex | 32400 | Media server |
| Jellyfin | 8096 | Open-source media server |
| Radarr | 7878 | Movies |
| Sonarr | 8989 | TV shows |
| Prowlarr | 9696 | Indexer manager |
| Bazarr | 6767 | Subtitles |
| qBittorrent | 8080 | Downloads, routed through the VPN |
| Gluetun | - | VPN container (ProtonVPN or Windscribe, WireGuard) |
| FlareSolverr | - | Cloudflare solver for Prowlarr |
| Caddy | 80/443 | Optional HTTPS reverse proxy for Jellyfin + Seerr |
| Watchtower | - | Optional nightly image updates (`AUTO_UPDATE=on`) |

## Install

```bash
git clone https://github.com/<you>/arrsehole4deb.git && cd arrsehole4deb
sudo ./install-docker.sh        # Docker from Docker's apt repo; skip if installed
cp .env.example .env && nano .env
./setup.sh
```

In `.env` you set the two folders (`CONFIG_DIR`, `DATA_DIR`), one admin
password and the VPN details. Everything else is detected or generated.
`setup.sh` asks once for a Plex claim token (https://plex.tv/claim, valid for
four minutes). Sign in there with the Plex account that should own the server;
Seerr's admin is that same account.

`setup.sh` is safe to re-run. It only adds what is missing and re-applies the
settings from `.env`, so changing a value and running it again is how you
reconfigure the stack.

## What setup.sh wires up

- Radarr/Sonarr: login, root folders, qBittorrent as download client
- Prowlarr: login, Radarr + Sonarr as sync targets, FlareSolverr proxy for
  indexers tagged `flaresolverr`
- qBittorrent: login, paths, VPN interface binding, incoming port, seed limit
- Bazarr: login, Radarr + Sonarr connections
- Jellyfin: first-run wizard, admin user, libraries with real-time monitoring
- Plex: claim, libraries, automatic scanning, LAN settings
- Seerr: Plex sign-in as admin, Plex + Radarr + Sonarr attached

## Left to do by hand

1. Prowlarr: add your indexers.
2. Bazarr: create a language profile and add subtitle providers.

## Settings worth knowing

| `.env` key | Meaning |
|---|---|
| `VPN_SERVICE_PROVIDER` | `protonvpn`, `windscribe`, or `none` (testing only: no VPN, your IP is visible to peers) |
| `VPN_PORT_FORWARDING` | `on` for ProtonVPN's automatic port forwarding (paid plan, NAT-PMP key) |
| `VPN_INPUT_PORT` | Static forwarded port, e.g. a Windscribe ephemeral port |
| `JELLYFIN_DOMAIN`, `SEERR_DOMAIN` | Publish these two apps over HTTPS (see below) |
| `SEED_RATIO_LIMIT` | `0` stops seeding when a download completes, empty seeds forever |
| `QUALITY_PROFILE` | Profile Seerr requests with |
| `AUTO_UPDATE` | `on` runs Watchtower |

## Remote access

Set `JELLYFIN_DOMAIN` and/or `SEERR_DOMAIN` in `.env` and re-run `./setup.sh`.
A Caddy container then serves those names over HTTPS with Let's Encrypt
certificates and forwards to the two apps; nothing else is exposed.

Requirements: DNS A records for the names pointing at your public IP, and TCP
ports 80 and 443 forwarded from your router to this server. Use strong
passwords for every Jellyfin account, and do not forward any other port.

## Folder layout

```
$DATA_DIR/torrents/{movies,tv,incomplete}   downloads
$DATA_DIR/media/{movies,tv}                 library (hardlinked on import)
$CONFIG_DIR/<app>                           app configuration
```

Keep `DATA_DIR` on a single filesystem so imports are instant hardlinks.

## Troubleshooting

- `docker logs gluetun` if the stack will not start: the VPN is not connecting.
- `docker exec gluetun wget -qO- https://ipinfo.io` shows the VPN exit IP.
- A failed step is listed at the end of `setup.sh`; fix the cause and re-run.
