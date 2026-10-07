#!/usr/bin/env bash
#
# setup.sh - bootstrap and auto-wire the arr stack. Safe to re-run at any time:
# every step checks what already exists and only adds what is missing.
#
#   1. fills in the auto-detected values in .env and generates API keys
#   2. creates the folder layout and pre-seeds qBittorrent + Bazarr
#   3. docker compose up
#   4. connects the apps to each other through their HTTP APIs
#
set -Eeuo pipefail
SELF=$(readlink -f "${BASH_SOURCE[0]}")
cd "$(dirname "$SELF")"

ENV_FILE=.env
FAILED=()

# ----------------------------------------------------------------- helpers ---
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null; then sudo "$@"
  else die "Need root for: $* (re-run as root or install sudo)"; fi
}
mk()        { mkdir -p "$@" 2>/dev/null || as_root mkdir -p "$@"; }
own()       { chown "$@" 2>/dev/null || as_root chown "$@"; }
read_file() { cat "$1" 2>/dev/null || as_root cat "$1" 2>/dev/null || true; }
put_file()  { # <src> <dest>   (installed 0600, owned by PUID:PGID)
  install -m 600 "$1" "$2" 2>/dev/null || as_root install -m 600 "$1" "$2"
  own "$PUID:$PGID" "$2"
}

set_env() { # <KEY> <value>   (only used for simple values)
  local key=$1 val=$2
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i -E "s|^${key}=.*|${key}=${val//|/\\|}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
  export "$key=$val"
}

json() { jq -n --arg v "$1" '$v'; } # JSON/YAML-safe quoted string

wait_http() { # <url> [timeout-seconds]
  local url=$1 timeout=${2:-240} waited=0
  until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
    ((waited += 3))
    ((waited >= timeout)) && { warn "Timed out waiting for $url"; return 1; }
    sleep 3
  done
}

# Runs a step in a subshell with errexit, so one failing app never aborts the
# rest; failures are collected and listed at the end.
run_step() { # <description> <function> [args...]
  local desc=$1 rc
  shift
  log "$desc"
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  if ((rc != 0)); then
    warn "FAILED: $desc"
    FAILED+=("$desc")
  fi
  return 0
}

# curl wrapper: prints the response on success; on HTTP errors shows the
# server's error message on stderr and fails.
http() {
  local out
  if out=$(curl --fail-with-body -sS "$@"); then
    printf '%s' "$out"
  else
    [[ -n $out ]] && printf '    %s\n' "$out" >&2
    return 1
  fi
}

# *arr API call: <METHOD> <url> <api-key> [json-body]
api() {
  local method=$1 url=$2 key=$3 body=${4:-}
  local args=(-X "$method" "$url" -H "X-Api-Key: $key")
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  http "${args[@]}"
}

# ------------------------------------------------------------ preparation ---
# Group membership only reaches new login sessions. If this user was added to
# the 'docker' group but the current shell predates that, restart the script
# under the group with sg(1) instead of making the user log out and back in.
docker_access() {
  docker info >/dev/null 2>&1 && return 0
  local me
  me=$(id -un)
  if ! systemctl is-active --quiet docker 2>/dev/null && [[ ! -S /var/run/docker.sock ]]; then
    die "The Docker daemon is not running (as root: systemctl enable --now docker)."
  fi
  if id -nG "$me" | grep -qw docker; then
    if [[ -z ${ARR_SG_REEXEC:-} ]] && command -v sg >/dev/null; then
      info "docker group not active in this shell yet - restarting under it"
      export ARR_SG_REEXEC=1
      exec sg docker -c "$(printf '%q' "$SELF")"
    fi
    die "Cannot talk to the Docker daemon although '$me' is in the docker group. Log out and back in, then retry."
  fi
  die "User '$me' is not in the 'docker' group. As root run:  usermod -aG docker $me   then start ./setup.sh again."
}

preflight() {
  local tool
  for tool in docker curl jq python3 openssl ip; do
    command -v "$tool" >/dev/null || die "'$tool' is missing - run ./install-docker.sh first."
  done
  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing - run ./install-docker.sh."
  docker_access
  [[ -f $ENV_FILE ]] || die "No .env found:  cp .env.example .env  and fill it in."
}

load_env() {
  set -a
  # shellcheck disable=SC1090
  . "./$ENV_FILE"
  set +a

  : "${ADMIN_USER:=admin}" "${QUALITY_PROFILE:=HD-1080p}" "${AUTH_REQUIRED:=enabled}"
  : "${METADATA_LANGUAGE:=en}" "${METADATA_COUNTRY:=US}"
  : "${VPN_SERVICE_PROVIDER:=protonvpn}" "${VPN_PORT_FORWARDING:=on}" "${VPN_INPUT_PORT:=}"
  : "${AUTO_UPDATE:=off}" "${SEED_RATIO_LIMIT:=}"
  [[ -z $SEED_RATIO_LIMIT || $SEED_RATIO_LIMIT =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "SEED_RATIO_LIMIT must be empty or a number such as 0, 1 or 1.5."

  [[ ${CONFIG_DIR:-} == /* ]] || die "CONFIG_DIR must be an absolute path."
  [[ ${DATA_DIR:-} == /* ]]   || die "DATA_DIR must be an absolute path."
  [[ -n ${ADMIN_PASSWORD:-} ]] || die "ADMIN_PASSWORD is empty in .env."
  [[ $VPN_SERVICE_PROVIDER == none || -n ${WIREGUARD_PRIVATE_KEY:-} ]] ||
    die "WIREGUARD_PRIVATE_KEY is empty in .env (or set VPN_SERVICE_PROVIDER=none to test without a VPN)."
  case $VPN_SERVICE_PROVIDER in
    none)
      warn "VPN_SERVICE_PROVIDER=none: qBittorrent runs WITHOUT a VPN - your home IP is visible to all peers." ;;
    windscribe)
      [[ -n ${WIREGUARD_ADDRESSES:-} && -n ${WIREGUARD_PRESHARED_KEY:-} ]] ||
        die "Windscribe needs WIREGUARD_ADDRESSES and WIREGUARD_PRESHARED_KEY in .env."
      [[ -z ${VPN_SERVER_COUNTRIES:-} ]] ||
        die "Windscribe selects servers by region: use VPN_SERVER_REGIONS and leave VPN_SERVER_COUNTRIES empty."
      if [[ $VPN_PORT_FORWARDING == on ]]; then
        warn "Automatic port forwarding is ProtonVPN-only - switching VPN_PORT_FORWARDING to off (use VPN_INPUT_PORT)."
        set_env VPN_PORT_FORWARDING off
      fi ;;
    protonvpn)
      [[ -z ${VPN_SERVER_REGIONS:-} ]] ||
        die "ProtonVPN selects servers by country: use VPN_SERVER_COUNTRIES and leave VPN_SERVER_REGIONS empty." ;;
    *) warn "VPN_SERVICE_PROVIDER='$VPN_SERVICE_PROVIDER' is untested with this stack." ;;
  esac
  [[ -z $VPN_INPUT_PORT || $VPN_INPUT_PORT =~ ^[0-9]+$ ]] || die "VPN_INPUT_PORT must be a single port number."

  # --- which containers run (compose profiles) --------------------------------
  local profiles=vpn
  QBIT_CONTAINER=qbittorrent
  if [[ $VPN_SERVICE_PROVIDER == none ]]; then profiles=novpn QBIT_CONTAINER=qbittorrent-novpn; fi
  [[ $AUTO_UPDATE == on ]] && profiles+=,autoupdate
  [[ ${COMPOSE_PROFILES:-} == "$profiles" ]] || set_env COMPOSE_PROFILES "$profiles"

  # --- auto-detected values -------------------------------------------------
  if [[ -z ${PUID:-} || -z ${PGID:-} ]]; then
    local user=${SUDO_USER:-$(id -un)} uid gid
    uid=$(id -u "$user"); gid=$(id -g "$user")
    if ((uid == 0)); then
      uid=1000; gid=1000
      warn "Running as root: media files will be owned by UID/GID 1000 (change PUID/PGID in .env if needed)."
    fi
    set_env PUID "$uid"; set_env PGID "$gid"
  fi
  if [[ -z ${TZ:-} ]]; then
    local tz
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ -n $tz ]] || tz=$(readlink -f /etc/localtime | sed -n 's|.*/zoneinfo/||p')
    set_env TZ "${tz:-Etc/UTC}"
  fi
  if [[ -z ${HOST_IP:-} || -z ${LAN_SUBNET:-} ]]; then
    local route dev ip cidr
    route=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
    dev=$(awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' <<<"$route")
    ip=$(awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}' <<<"$route")
    [[ -n $dev && -n $ip ]] || die "Could not detect the LAN address - set HOST_IP and LAN_SUBNET in .env."
    cidr=$(ip -o -4 addr show dev "$dev" | awk -v ip="$ip" '{split($4,a,"/"); if(a[1]==ip) print $4}' | head -n1)
    [[ -n ${HOST_IP:-} ]] || set_env HOST_IP "$ip"
    [[ -n ${LAN_SUBNET:-} ]] || set_env LAN_SUBNET \
      "$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "${cidr:-$ip/24}")"
  fi

  # --- API keys (fixed up front, injected into the containers via env) --------
  local key
  for key in RADARR_API_KEY SONARR_API_KEY PROWLARR_API_KEY BAZARR_API_KEY; do
    [[ -n ${!key:-} ]] || set_env "$key" "$(openssl rand -hex 16)"
  done

  PLEX_PREFS="$CONFIG_DIR/plex/Library/Application Support/Plex Media Server/Preferences.xml"
}

make_dirs() {
  log "Creating folders under $CONFIG_DIR and $DATA_DIR"
  local cfg=(qbittorrent/qBittorrent prowlarr radarr sonarr bazarr/config plex jellyfin/config jellyfin/cache)
  local data=(torrents torrents/movies torrents/tv torrents/incomplete media media/movies media/tv)
  local d
  mk "$CONFIG_DIR/gluetun" "$CONFIG_DIR/seerr"
  for d in "${cfg[@]}";  do mk "$CONFIG_DIR/$d"; done
  for d in "${data[@]}"; do mk "$DATA_DIR/$d";   done

  for d in qbittorrent prowlarr radarr sonarr bazarr plex jellyfin; do
    own -R "$PUID:$PGID" "$CONFIG_DIR/$d"
  done
  own -R 1000:1000 "$CONFIG_DIR/seerr" # the Seerr image always runs as UID 1000
  # not recursive on purpose: never touch ownership of media that already exists
  own "$PUID:$PGID" "$DATA_DIR"
  for d in "${data[@]}"; do own "$PUID:$PGID" "$DATA_DIR/$d"; done
}

# qBittorrent: known login instead of the random first-run password, sane paths,
# bound to the VPN interface, localhost auth bypass (for gluetun's port hook).
seed_qbittorrent() {
  local conf="$CONFIG_DIR/qbittorrent/qBittorrent/qBittorrent.conf" hash tmp
  [[ -n $(read_file "$conf") ]] && return 0
  log "Pre-seeding qBittorrent configuration"
  local net="Session\\Interface=tun0"$'\n'"Session\\InterfaceName=tun0"
  [[ -n $VPN_INPUT_PORT ]] && net+=$'\n'"Session\\Port=$VPN_INPUT_PORT"
  [[ $VPN_SERVICE_PROVIDER == none ]] && net="Session\\Port=6881"
  hash=$(QB_PW="$ADMIN_PASSWORD" python3 -c '
import base64, hashlib, os
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac("sha512", os.environ["QB_PW"].encode(), salt, 100000, dklen=64)
print(base64.b64encode(salt).decode() + ":" + base64.b64encode(dk).decode())')
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
[BitTorrent]
Session\\DefaultSavePath=/data/torrents
Session\\TempPath=/data/torrents/incomplete
Session\\TempPathEnabled=true
Session\\DisableAutoTMMByDefault=false
${net}

[LegalNotice]
Accepted=true

[Preferences]
WebUI\\Address=*
WebUI\\Port=8080
WebUI\\Username=${ADMIN_USER}
WebUI\\Password_PBKDF2="@ByteArray(${hash})"
WebUI\\LocalHostAuth=false
EOF
  put_file "$tmp" "$conf"
  rm -f "$tmp"
}

# Bazarr has no first-run API, but it merges a partial config.yaml with defaults.
seed_bazarr() {
  local conf="$CONFIG_DIR/bazarr/config/config.yaml" tmp md5
  [[ -n $(read_file "$conf") ]] && return 0
  log "Pre-seeding Bazarr configuration"
  md5=$(printf '%s' "$ADMIN_PASSWORD" | md5sum | cut -d' ' -f1)
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
auth:
  apikey: $(json "$BAZARR_API_KEY")
  type: form
  username: $(json "$ADMIN_USER")
  password: $(json "$md5")
general:
  use_radarr: true
  use_sonarr: true
radarr:
  ip: radarr
  port: 7878
  ssl: false
  apikey: $(json "$RADARR_API_KEY")
sonarr:
  ip: sonarr
  port: 8989
  ssl: false
  apikey: $(json "$SONARR_API_KEY")
EOF
  put_file "$tmp" "$conf"
  rm -f "$tmp"
}

plex_token() { read_file "$PLEX_PREFS" | sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' | head -n1; }

# Claim tokens are only valid for 4 minutes, so ask right before starting Plex
# (after the images are pulled) instead of storing one in .env.
ask_plex_claim() {
  [[ -n $(plex_token) || -n ${PLEX_CLAIM:-} ]] && return 0
  if [[ ! -t 0 ]]; then
    warn "Plex is not claimed and there is no terminal to ask for a claim token (PLEX_CLAIM=... ./setup.sh)."
    return 0
  fi
  echo
  echo "  Plex needs to be linked to your account once:"
  echo "    1. open https://plex.tv/claim and sign in"
  echo "    2. copy the token (claim-xxxxxxxx) - it expires after 4 minutes"
  read -r -p "  Paste the claim token (or press Enter to skip Plex + Seerr wiring): " PLEX_CLAIM || true
  export PLEX_CLAIM
  echo
}

start_stack() {
  log "Pulling images"
  docker compose pull --quiet
  ask_plex_claim
  # Switching VPN on/off: the other variant would keep running (and holding
  # port 8080 / the same config folder), so remove it first.
  if [[ $VPN_SERVICE_PROVIDER == none ]]; then
    docker rm -f qbittorrent gluetun >/dev/null 2>&1 || true
  else
    docker rm -f qbittorrent-novpn >/dev/null 2>&1 || true
  fi
  log "Starting containers"
  docker compose up -d --remove-orphans || die "Stack did not start. If gluetun is 'unhealthy' the VPN is not connecting:
    docker logs gluetun     (check the WIREGUARD_* / VPN_SERVER_* values, then re-run ./setup.sh)"
}

# ------------------------------------------------------------- app wiring ---
# qBittorrent network + seeding settings, (re)applied on every run so that switching the
# VPN on/off or changing VPN_INPUT_PORT takes effect. Runs inside the container
# against localhost, which skips the login.
#   VPN:    bind to tun0; fixed port only if VPN_INPUT_PORT is set (Windscribe),
#           with ProtonVPN gluetun pushes the port itself
#   no VPN: any interface, port 6881 (published by compose)
configure_qbittorrent() {
  local prefs
  wait_http "http://localhost:8080" 120
  if [[ $VPN_SERVICE_PROVIDER == none ]]; then
    prefs=$(jq -nc --argjson p "${VPN_INPUT_PORT:-6881}" \
      '{current_network_interface: "", listen_port: $p, random_port: false, upnp: false}')
  elif [[ -n $VPN_INPUT_PORT ]]; then
    prefs=$(jq -nc --argjson p "$VPN_INPUT_PORT" \
      '{current_network_interface: "tun0", listen_port: $p, random_port: false, upnp: false}')
  else
    prefs='{"current_network_interface":"tun0","random_port":false,"upnp":false}'
  fi
  # Seeding: stop (never delete - Radarr/Sonarr remove torrents themselves once
  # they are imported and stopped) when the share ratio is reached.
  #   empty = seed forever, 0 = stop as soon as the download completes
  local share='{"max_ratio_enabled": false, "max_seeding_time_enabled": false}'
  if [[ -n $SEED_RATIO_LIMIT ]]; then
    share=$(jq -nc --argjson r "$SEED_RATIO_LIMIT" '{max_ratio_enabled: true, max_ratio: $r, max_ratio_act: 0}
      + (if $r == 0 then {max_seeding_time_enabled: true, max_seeding_time: 0}
         else {max_seeding_time_enabled: false} end)')
  fi
  prefs=$(jq -c --argjson s "$share" '. + $s' <<<"$prefs")
  docker exec "$QBIT_CONTAINER" curl -fsS -o /dev/null --data-urlencode "json=$prefs" \
    http://127.0.0.1:8080/api/v2/app/setPreferences
  info "settings applied ($prefs)"
}

arr_auth() { # <api-base> <key>
  local base=$1 key=$2 cfg
  cfg=$(api GET "$base/config/host" "$key")
  cfg=$(jq --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" --arg r "$AUTH_REQUIRED" \
    '.authenticationMethod="forms" | .authenticationRequired=$r
     | .username=$u | .password=$p | .passwordConfirmation=$p' <<<"$cfg")
  api PUT "$base/config/host/$(jq -r .id <<<"$cfg")" "$key" "$cfg" >/dev/null
  info "login set to '$ADMIN_USER'"
}

# Radarr / Sonarr: login, root folder, qBittorrent as download client
configure_arr() { # <url> <key> <root-folder> <category-field> <category>
  local url=$1 key=$2 root=$3 cat_field=$4 category=$5
  local base="$url/api/v3" body
  wait_http "$url/ping"
  arr_auth "$base" "$key"

  if api GET "$base/rootfolder" "$key" | jq -e --arg p "$root" 'any(.[]; .path | rtrimstr("/") == $p)' >/dev/null; then
    info "root folder $root already present"
  else
    api POST "$base/rootfolder" "$key" "$(jq -n --arg p "$root" '{path: $p}')" >/dev/null
    info "root folder $root added"
  fi

  if api GET "$base/downloadclient" "$key" | jq -e 'any(.[]; .implementation == "QBittorrent")' >/dev/null; then
    info "qBittorrent already connected"
  else
    wait_http "http://localhost:8080" 120
    body=$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" --arg f "$cat_field" --arg c "$category" '{
      name: "qBittorrent", implementation: "QBittorrent", configContract: "QBittorrentSettings",
      protocol: "torrent", enable: true, priority: 1,
      removeCompletedDownloads: true, removeFailedDownloads: true, tags: [],
      fields: [
        {name: "host", value: "qbittorrent"}, {name: "port", value: 8080}, {name: "useSsl", value: false},
        {name: "username", value: $u}, {name: "password", value: $p}, {name: $f, value: $c}
      ]}')
    api POST "$base/downloadclient" "$key" "$body" >/dev/null
    info "qBittorrent connected (category '$category')"
  fi
}

# Prowlarr: login, FlareSolverr proxy (+tag), Radarr and Sonarr as sync targets
configure_prowlarr() {
  local url=http://localhost:9696 key=$PROWLARR_API_KEY
  local base="$url/api/v1" tag body app app_key app_url
  wait_http "$url/ping"
  arr_auth "$base" "$key"

  tag=$(api GET "$base/tag" "$key" | jq -r 'first(.[] | select(.label == "flaresolverr") | .id) // empty')
  [[ -n $tag ]] || tag=$(api POST "$base/tag" "$key" '{"label":"flaresolverr"}' | jq -r .id)

  if api GET "$base/indexerProxy" "$key" | jq -e 'any(.[]; .implementation == "FlareSolverr")' >/dev/null; then
    info "FlareSolverr proxy already present"
  else
    body=$(jq -n --argjson tag "$tag" '{
      name: "FlareSolverr", implementation: "FlareSolverr", configContract: "FlareSolverrSettings",
      tags: [$tag],
      fields: [{name: "host", value: "http://flaresolverr:8191/"}, {name: "requestTimeout", value: 60}]}')
    api POST "$base/indexerProxy" "$key" "$body" >/dev/null
    info "FlareSolverr proxy added (applies to indexers tagged 'flaresolverr')"
  fi

  for app in Radarr Sonarr; do
    if [[ $app == Radarr ]]; then app_key=$RADARR_API_KEY app_url=http://radarr:7878
    else app_key=$SONARR_API_KEY app_url=http://sonarr:8989; fi
    if api GET "$base/applications" "$key" | jq -e --arg a "$app" 'any(.[]; .implementation == $a)' >/dev/null; then
      info "$app already linked"
      continue
    fi
    wait_http "http://localhost:${app_url##*:}/ping"
    body=$(jq -n --arg a "$app" --arg k "$app_key" --arg u "$app_url" '{
      name: $a, implementation: $a, configContract: ($a + "Settings"), syncLevel: "fullSync", tags: [],
      fields: [
        {name: "prowlarrUrl", value: "http://prowlarr:9696"},
        {name: "baseUrl", value: $u}, {name: "apiKey", value: $k}
      ]}')
    api POST "$base/applications" "$key" "$body" >/dev/null
    info "$app linked (indexers sync automatically)"
  done
}

# Jellyfin: complete the first-run wizard (admin user + both libraries), then
# make sure every library picks up new files immediately.
configure_jellyfin() {
  local url=http://localhost:8096
  local client='MediaBrowser Client="arr-stack", Device="setup.sh", DeviceId="arr-stack-setup", Version="1.0"'
  wait_http "$url/System/Info/Public"

  if [[ $(curl -fsS "$url/System/Info/Public" | jq -r .StartupWizardCompleted) == true ]]; then
    info "first-run wizard already completed"
  else
    jf() { # <METHOD> <path> [json-body]
      local args=(-X "$1" "$url$2" -H 'Content-Type: application/json')
      [[ -n ${3:-} ]] && args+=(-d "$3")
      http "${args[@]}" >/dev/null
    }
    local lib='{"LibraryOptions": {"EnableRealtimeMonitor": true}}'
    jf POST /Startup/Configuration "$(jq -n --arg l "$METADATA_LANGUAGE" --arg c "$METADATA_COUNTRY" \
      '{UICulture: "en-US", MetadataCountryCode: $c, PreferredMetadataLanguage: $l}')"
    jf GET /Startup/User
    jf POST /Startup/User "$(jq -n --arg n "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Name: $n, Password: $p}')"
    jf POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fdata%2Fmedia%2Fmovies&refreshLibrary=false" "$lib"
    jf POST "/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=%2Fdata%2Fmedia%2Ftv&refreshLibrary=false" "$lib"
    jf POST /Startup/RemoteAccess '{"EnableRemoteAccess": true, "EnableAutomaticPortMapping": false}'
    jf POST /Startup/Complete
    info "admin '$ADMIN_USER' created, libraries Movies + Shows added"
  fi

  # Libraries created through the API have real-time monitoring off, so new
  # imports would only show up at the next scheduled scan. Switch it on.
  local token folders update changed=0
  token=$(http -X POST "$url/Users/AuthenticateByName" -H "Authorization: $client" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg n "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Username: $n, Pw: $p}')" 2>/dev/null |
    jq -r '.AccessToken // empty') || true
  if [[ -z $token ]]; then
    warn "Could not sign in to Jellyfin as '$ADMIN_USER' (password changed?) - enable 'real time monitoring' per library by hand."
    return 0
  fi
  jfa() { http -H "Authorization: $client, Token=\"$token\"" -H 'Content-Type: application/json' "$@"; }
  folders=$(jfa "$url/Library/VirtualFolders")
  while IFS= read -r update; do
    [[ -n $update ]] || continue
    jfa -X POST "$url/Library/VirtualFolders/LibraryOptions" -d "$update" >/dev/null
    changed=1
  done < <(jq -c '.[] | select(.LibraryOptions.EnableRealtimeMonitor != true)
                  | {Id: .ItemId, LibraryOptions: (.LibraryOptions | .EnableRealtimeMonitor = true)}' <<<"$folders")
  if ((changed)); then
    jfa -X POST "$url/Library/Refresh" >/dev/null
    info "real-time monitoring enabled, library scan started"
  else
    info "real-time monitoring already enabled"
  fi
  jfa -X POST "$url/Sessions/Logout" >/dev/null 2>&1 || true
}

# Plex: libraries + make LAN clients count as local despite bridge networking
configure_plex() {
  local url=http://localhost:32400 token="" i paths=""
  wait_http "$url/identity"
  for ((i = 0; i < 30; i++)); do
    token=$(plex_token)
    [[ -n $token ]] && break
    sleep 3
  done
  [[ -n $token ]] || { warn "Plex server is not claimed - re-run ./setup.sh with a fresh claim token."; return 1; }

  px() { http -H "X-Plex-Token: $token" -H 'Accept: application/json' "$@"; }
  enc() { jq -rn --arg v "$1" '$v | @uri'; } # strict URL encoding (%20, not +)

  # On first start the container runs a temporary, unclaimed server to process
  # the claim and then restarts as the real one, which still has to sign in to
  # plex.tv. Until that is done it refuses writes (403) or is briefly down, so
  # wait until it reports being signed in.
  local state="" sections=""
  for ((i = 0; i < 60; i++)); do
    state=$(px "$url/" 2>/dev/null | jq -r '.MediaContainer.myPlexSigninState // empty' 2>/dev/null) || state=""
    [[ $state == ok ]] && break
    sleep 3
  done
  [[ $state == ok ]] || warn "Plex has not confirmed its plex.tv sign-in (state: ${state:-unknown}) - trying anyway."

  for ((i = 0; i < 40; i++)); do
    sections=$(px "$url/library/sections" 2>/dev/null) && break
    sections=""
    sleep 3
  done
  if [[ -z $sections ]]; then
    warn "Plex rejects the owner token on GET /library/sections:"
    px "$url/library/sections" >/dev/null || true
    return 1
  fi
  paths=$(jq -r '.MediaContainer.Directory[]?.Location[]?.path' <<<"$sections")

  add_library() { # <name> <type> <agent> <scanner> <path>
    if grep -qxF "$5" <<<"$paths"; then info "library '$1' already present"; return 0; fi
    local q
    q="name=$(enc "$1")&type=$2&agent=$3&scanner=$(enc "$4")&location=$(enc "$5")"
    q+="&language=$(enc "${METADATA_LANGUAGE}-${METADATA_COUNTRY}")"
    local try
    for try in 1 2 3 4 5 6; do
      if px -X POST -H 'Content-Length: 0' "$url/library/sections?$q" >/dev/null 2>&1; then
        info "library '$1' added"
        return 0
      fi
      sleep 5
    done
    warn "Plex refused: POST /library/sections?$q"
    px -X POST -H 'Content-Length: 0' "$url/library/sections?$q" >/dev/null || true # show the error
    return 1
  }
  add_library "Movies"   movie tv.plex.agents.movie  "Plex Movie"     /data/media/movies
  add_library "TV Shows" show  tv.plex.agents.series "Plex TV Series" /data/media/tv

  px -X PUT -H 'Content-Length: 0' \
    "$url/:/prefs?customConnections=$(enc "http://${HOST_IP}:32400")&LanNetworksBandwidth=$(enc "$LAN_SUBNET")" >/dev/null \
    || warn "Could not set Plex network preferences (Settings -> Network -> LAN Networks / Custom server access URLs)."

  # Pick up new files right away (off by default) plus an hourly safety-net scan
  if px -X PUT -H 'Content-Length: 0' \
    "$url/:/prefs?FSEventLibraryUpdatesEnabled=1&FSEventLibraryPartialScanEnabled=1&ScheduledLibraryUpdatesEnabled=1&ScheduledLibraryUpdateInterval=3600" >/dev/null; then
    info "automatic library scanning enabled"
  else
    warn "Could not enable automatic scanning (Plex -> Settings -> Library -> 'Scan my library automatically')."
  fi
}

# Seerr: sign in with the Plex owner token (becomes admin), attach Plex,
# Radarr and Sonarr, then mark the setup wizard as done.
configure_seerr() {
  local url=http://localhost:5055 token jar libs="" prof body
  wait_http "$url/api/v1/status"
  if [[ $(curl -fsS "$url/api/v1/settings/public" | jq -r .initialized) == true ]]; then
    info "already set up"
    return 0
  fi
  token=$(plex_token)
  [[ -n $token ]] || { warn "Plex is not claimed yet, so Seerr cannot sign in."; return 1; }

  jar=$(mktemp)
  # shellcheck disable=SC2064  # expand now: $jar is local, the trap fires later
  trap "rm -f '$jar'" EXIT     # subshell-local (see run_step)
  sr() { http -b "$jar" -c "$jar" -H 'Content-Type: application/json' "$@"; }

  sr -X POST "$url/api/v1/auth/plex" -d "$(jq -n --arg t "$token" '{authToken: $t}')" >/dev/null
  info "signed in with your Plex account (admin)"

  # Seerr validates the connection; give Plex time if it is still restarting.
  local try plex_cfg='{"ip": "plex", "port": 32400, "useSsl": false}'
  for try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sr -X POST "$url/api/v1/settings/plex" -d "$plex_cfg" >/dev/null 2>&1 && break
    if ((try == 12)); then
      sr -X POST "$url/api/v1/settings/plex" -d "$plex_cfg" >/dev/null # show the error and fail
    fi
    sleep 5
  done
  # Current Seerr: POST .../library/sync, then PUT .../library/{id}.
  # Older builds (Overseerr API): GET ...?sync=true, then GET ...?enable=ids.
  local lib
  if libs=$(sr -X POST "$url/api/v1/settings/plex/library/sync" 2>/dev/null); then
    libs=$(jq -r '.[].id' <<<"$libs")
    for lib in $libs; do
      sr -X PUT "$url/api/v1/settings/plex/library/$lib" -d '{"enabled": true}' >/dev/null
    done
  else
    libs=$(sr "$url/api/v1/settings/plex/library?sync=true" | jq -r '[.[].id] | join(",")')
    [[ -z $libs ]] || sr "$url/api/v1/settings/plex/library?enable=$libs" >/dev/null
  fi
  if [[ -n $libs ]]; then
    info "Plex connected, libraries enabled"
  else
    warn "Plex connected but it has no libraries yet (enable them later in Seerr -> Settings -> Plex)."
  fi

  if [[ $(sr "$url/api/v1/settings/radarr" | jq length) == 0 ]]; then
    prof=$(api GET http://localhost:7878/api/v3/qualityprofile "$RADARR_API_KEY" |
      jq -c --arg n "$QUALITY_PROFILE" '(map(select(.name == $n))[0] // .[0]) | {id, name}')
    body=$(jq -n --argjson p "$prof" --arg k "$RADARR_API_KEY" '{
      name: "Radarr", hostname: "radarr", port: 7878, apiKey: $k, useSsl: false, baseUrl: "",
      activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/movies",
      minimumAvailability: "released", tags: [], is4k: false, isDefault: true,
      syncEnabled: true, preventSearch: false}')
    sr -X POST "$url/api/v1/settings/radarr" -d "$body" >/dev/null
    info "Radarr connected (profile: $(jq -r .name <<<"$prof"))"
  fi

  if [[ $(sr "$url/api/v1/settings/sonarr" | jq length) == 0 ]]; then
    prof=$(api GET http://localhost:8989/api/v3/qualityprofile "$SONARR_API_KEY" |
      jq -c --arg n "$QUALITY_PROFILE" '(map(select(.name == $n))[0] // .[0]) | {id, name}')
    body=$(jq -n --argjson p "$prof" --arg k "$SONARR_API_KEY" '{
      name: "Sonarr", hostname: "sonarr", port: 8989, apiKey: $k, useSsl: false, baseUrl: "",
      activeProfileId: $p.id, activeProfileName: $p.name, activeDirectory: "/data/media/tv",
      activeAnimeProfileId: $p.id, activeAnimeProfileName: $p.name, activeAnimeDirectory: "/data/media/tv",
      seriesType: "standard", animeSeriesType: "anime", tags: [], animeTags: [],
      is4k: false, isDefault: true, enableSeasonFolders: true,
      syncEnabled: true, preventSearch: false}')
    sr -X POST "$url/api/v1/settings/sonarr" -d "$body" >/dev/null
    info "Sonarr connected (profile: $(jq -r .name <<<"$prof"))"
  fi

  sr -X POST "$url/api/v1/settings/initialize" >/dev/null
  info "setup wizard completed"
}

summary() {
  local h=$HOST_IP
  cat <<EOF

────────────────────────────────────────────────────────────────────────
  Seerr        http://$h:5055      sign in with Plex
  Plex         http://$h:32400/web
  Jellyfin     http://$h:8096      $ADMIN_USER / (ADMIN_PASSWORD)
  Radarr       http://$h:7878      "
  Sonarr       http://$h:8989      "
  Prowlarr     http://$h:9696      "
  Bazarr       http://$h:6767      "
  qBittorrent  http://$h:8080      "
────────────────────────────────────────────────────────────────────────
  Left for you:
   1. Prowlarr -> Indexers -> Add. They sync to Radarr/Sonarr on their own.
      Give Cloudflare-protected ones the tag "flaresolverr".
   2. Bazarr -> Settings -> Languages (create a profile, set it as default)
      and Settings -> Providers.
EOF
  if [[ $VPN_SERVICE_PROVIDER == none ]]; then
    warn "No VPN: torrents use your home IP. Set VPN_SERVICE_PROVIDER in .env and re-run to change that."
  else
    echo "  Check the VPN:   docker exec gluetun wget -qO- https://ipinfo.io"
  fi
  if ((${#FAILED[@]})); then
    echo
    warn "Some steps did not complete (fix the cause, then just run ./setup.sh again):"
    printf '      - %s\n' "${FAILED[@]}" >&2
    exit 1
  fi
}

# -------------------------------------------------------------------- main ---
preflight
load_env
make_dirs
seed_qbittorrent
seed_bazarr
start_stack

run_step "qBittorrent" configure_qbittorrent
run_step "Radarr"   configure_arr http://localhost:7878 "$RADARR_API_KEY" /data/media/movies movieCategory movies
run_step "Sonarr"   configure_arr http://localhost:8989 "$SONARR_API_KEY" /data/media/tv     tvCategory    tv
run_step "Prowlarr" configure_prowlarr
run_step "Jellyfin" configure_jellyfin
run_step "Plex"     configure_plex
run_step "Seerr"    configure_seerr
summary
