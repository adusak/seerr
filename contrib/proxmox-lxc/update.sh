#!/usr/bin/env bash
#
# Update script for a Seerr installation that is built from a git branch in a
# Proxmox LXC (layout of the community-scripts Seerr container: code in
# /opt/seerr, settings in /etc/seerr/seerr.conf, systemd service "seerr").
#
# Use it in place of the community-scripts "update" command, which replaces
# /opt/seerr with the official release:
#
#   install -m 755 /opt/seerr/contrib/proxmox-lxc/update.sh /usr/bin/update
#
# The new version is built in a separate directory while the service keeps
# running. The service is stopped only when the build is complete, so a failed
# build does not change the installation. After a successful update, this
# script replaces /usr/bin/update with the version from the new code.
#
# Options:
#   --force   Rebuild even when the installation is already up to date.
#
# Environment variables:
#   SEERR_DIR      Installation directory (default: /opt/seerr)
#   SEERR_BRANCH   Branch to install (default: main)
#   SEERR_SERVICE  systemd service name (default: seerr)
#   SEERR_CONF     Environment file of the service (default: /etc/seerr/seerr.conf)
#   SEERR_UPDATE_BIN  Path of the update command (default: /usr/bin/update)

set -Eeuo pipefail

SEERR_DIR="${SEERR_DIR:-/opt/seerr}"
SEERR_BRANCH="${SEERR_BRANCH:-main}"
SEERR_SERVICE="${SEERR_SERVICE:-seerr}"
SEERR_CONF="${SEERR_CONF:-/etc/seerr/seerr.conf}"
SEERR_UPDATE_BIN="${SEERR_UPDATE_BIN:-/usr/bin/update}"
STAGE_DIR="${SEERR_DIR}.new"
PREV_DIR="${SEERR_DIR}.prev"
SELF_PATH="contrib/proxmox-lxc/update.sh"
MIN_FREE_KB=$((3 * 1024 * 1024))

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

info() { echo -e "\e[1;34m==>\e[0m $*"; }
ok() { echo -e "\e[1;32m==>\e[0m $*"; }
die() {
  echo -e "\e[1;31m==> ERROR:\e[0m $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -d "$SEERR_DIR/.git" ]] || die "$SEERR_DIR is not a git clone."

conf_value() {
  [[ -f "$SEERR_CONF" ]] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$SEERR_CONF" | tail -n1 | tr -d "\"'"
}

# --- Find the target commit -------------------------------------------------

cd "$SEERR_DIR"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  git status --short --untracked-files=no
  die "$SEERR_DIR has local changes. Commit or discard them first."
fi

info "Fetching branch '$SEERR_BRANCH'"
git fetch --quiet origin "$SEERR_BRANCH"
current="$(git rev-parse HEAD)"
target="$(git rev-parse FETCH_HEAD)"
current_branch="$(git symbolic-ref --quiet --short HEAD || true)"

if [[ $FORCE -eq 0 && "$current" == "$target" && "$current_branch" == "$SEERR_BRANCH" && -f dist/index.js ]]; then
  ok "Seerr is already up to date ($(git log -1 --format='%h %s' HEAD))."
  exit 0
fi

info "Updating from $(git log -1 --format='%h' "$current") to $(git log -1 --format='%h %s' "$target")"

avail_kb="$(df --output=avail -k "$(dirname "$SEERR_DIR")" | tail -n1 | tr -d ' ')"
if ((avail_kb < MIN_FREE_KB)); then
  die "Not enough free disk space: $((avail_kb / 1024)) MB available, 3072 MB necessary for the build."
fi

# --- Build in a separate directory -------------------------------------------

info "Preparing build directory $STAGE_DIR"
rm -rf "$STAGE_DIR"
git clone --quiet --no-checkout "$SEERR_DIR" "$STAGE_DIR"
cd "$STAGE_DIR"
git remote set-url origin "$(git -C "$SEERR_DIR" remote get-url origin)"
git checkout --quiet -B "$SEERR_BRANCH" "$target"
git fetch --quiet origin "$SEERR_BRANCH"
git branch --quiet --set-upstream-to="origin/$SEERR_BRANCH"

info "Checking Node.js version"
node_range="$(sed -n 's/.*"node": *"\^\{0,1\}\([0-9.]*\)".*/\1/p' package.json | head -n1)"
# shellcheck disable=SC2016 # JavaScript template string, not shell
node -e '
  const [want, have] = [process.argv[1], process.versions.node].map((v) => v.split(".").map(Number));
  const ok = have[0] === want[0] && (have[1] > want[1] || (have[1] === want[1] && have[2] >= (want[2] || 0)));
  if (!ok) { console.error(`Node.js ^${process.argv[1]} is necessary, but ${process.versions.node} is installed.`); process.exit(1); }
' "$node_range" || die "Install a supported Node.js version (for example: apt update && apt install -y nodejs) and try again."

pnpm_version="$(sed -n 's/.*"packageManager": *"pnpm@\([^"]*\)".*/\1/p' package.json)"
if [[ -n "$pnpm_version" && "$(pnpm -v 2>/dev/null || true)" != "$pnpm_version" ]]; then
  info "Installing pnpm $pnpm_version"
  npm install --global --silent "pnpm@$pnpm_version"
fi

info "Installing dependencies (Patience)"
export CYPRESS_INSTALL_BINARY=0 HUSKY=0
pnpm install --frozen-lockfile --reporter=append-only >/tmp/seerr-update-install.log 2>&1 ||
  die "Dependency installation failed. Log: /tmp/seerr-update-install.log. The installed version was not changed."

info "Building Seerr (Patience)"
NODE_OPTIONS="--max-old-space-size=3072" pnpm build >/tmp/seerr-update-build.log 2>&1 ||
  die "Build failed. Log: /tmp/seerr-update-build.log. The installed version was not changed."
ok "Build complete"

# --- Swap the installation ----------------------------------------------------

info "Stopping $SEERR_SERVICE"
systemctl stop "$SEERR_SERVICE"

rm -rf "$PREV_DIR"
mv "$SEERR_DIR" "$PREV_DIR"
mv "$STAGE_DIR" "$SEERR_DIR"

# Keep the data directory when it is inside the installation directory
config_dir="$(conf_value CONFIG_DIRECTORY)"
if [[ -z "$config_dir" || "$config_dir" == "config" || "$config_dir" == "$SEERR_DIR/config" ]]; then
  rm -rf "$SEERR_DIR/config"
  mv "$PREV_DIR/config" "$SEERR_DIR/config"
fi

info "Starting $SEERR_SERVICE"
systemctl start "$SEERR_SERVICE"

port="$(conf_value PORT)"
port="${port:-5055}"
info "Waiting for Seerr on port $port (database migrations can take some time)"
started=0
for _ in $(seq 1 120); do
  if curl -fsS --noproxy '*' --max-time 5 "http://127.0.0.1:${port}/api/v1/status" >/dev/null 2>&1; then
    started=1
    break
  fi
  if ! systemctl is-active --quiet "$SEERR_SERVICE"; then
    break
  fi
  sleep 5
done

if [[ $started -ne 1 ]]; then
  journalctl -u "$SEERR_SERVICE" -n 50 --no-pager || true
  die "Seerr did not start. The previous code is in $PREV_DIR, but the database can already be migrated. Restore your LXC snapshot to go back."
fi

rm -rf "$PREV_DIR"

if [[ -f "$SEERR_DIR/$SELF_PATH" ]]; then
  # Replace with a new file, so that this running script is not changed
  install -m 755 "$SEERR_DIR/$SELF_PATH" "$SEERR_UPDATE_BIN.new"
  mv -f "$SEERR_UPDATE_BIN.new" "$SEERR_UPDATE_BIN"
fi

ok "Updated Seerr to $(git -C "$SEERR_DIR" log -1 --format='%h %s')"
