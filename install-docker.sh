#!/usr/bin/env bash
#
# install-docker.sh - Docker Engine + compose plugin from Docker's official apt
# repository, plus the few tools setup.sh needs. Debian 12/13. Run as root.
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null || { echo "Run this as root (su -)." >&2; exit 1; }
  exec sudo bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq python3 openssl iproute2

# Debian's own Docker packages own the same files as Docker's official ones
# (dpkg: "trying to overwrite ... docker-compose") - remove them first.
# Images, containers and volumes are kept.
conflicts=()
for pkg in docker.io docker-doc docker-compose docker-buildx docker-cli podman-docker containerd runc; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok' && conflicts+=("$pkg")
done
if ((${#conflicts[@]})); then
  echo "Removing conflicting distro packages: ${conflicts[*]}"
  apt-get remove -y "${conflicts[@]}"
fi
apt-get -f install -y # repair a previously interrupted run

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck disable=SC1091
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
cat > /etc/apt/sources.list.d/docker.sources <<SRC
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Let a regular user run docker without sudo. Work out who that is:
#   1. ./install-docker.sh <username>      explicit
#   2. sudo ./install-docker.sh            the user who called sudo
#   3. su -  then  ./install-docker.sh     the user who logged in (logname)
#   4. the owner of this folder, or the only regular account on the system
script_dir=$(dirname "$(readlink -f "$0")")
user=${1:-${SUDO_USER:-}}
[[ -n $user && $user != root ]] || user=$(logname 2>/dev/null || true)
[[ -n $user && $user != root ]] || user=$(stat -c %U "$script_dir" 2>/dev/null || true)
if [[ -z $user || $user == root || $user == UNKNOWN ]]; then
  mapfile -t humans < <(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1}')
  user=""
  ((${#humans[@]} == 1)) && user=${humans[0]}
fi

if [[ -n $user && $user != root ]] && id "$user" >/dev/null 2>&1; then
  usermod -aG docker "$user"
  echo
  echo "User '$user' may now use Docker. ./setup.sh picks this up by itself;"
  echo "for plain 'docker' commands log out and back in once (or run: newgrp docker)."
else
  echo
  echo "Could not tell which user should run the stack. Add yours with:"
  echo "    usermod -aG docker <username>"
fi
echo

docker --version
docker compose version
