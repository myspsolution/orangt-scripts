#!/usr/bin/env bash

# 04-install-php-npm-postgresql-ufw-ipv4-swap-v4.sh
# Install PHP, Node.js, database clients, and supporting web-server tools.
# Revised: 2026-10-28 10-28-26
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 04-install-php-npm-postgresql-ufw-ipv4-swap-v4.sh
# Privileged commands run directly as root or through authorized sudo.
# APT retries and HTTPS mirror fallback; IPv4 UFW ports 22, 80, and 443.
# Create and persist a 4 GB /swapfile only when needed.

if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Error: run this script with bash, not another shell.' >&2
  exit 1
fi

if shopt -oq posix; then
  printf '%s\n' 'Error: run this script with bash, not sh or Bash POSIX mode.' >&2
  exit 1
fi

set -Eeuo pipefail

readonly RED="\033[1;41;37m"
readonly YLW="\033[1;33m"
readonly STD="\033[0m"
readonly BLD="\033[1;97m"

readonly LINUX_DISTRO_CHECK="ubuntu"
readonly LINUX_VERSION_CHECK="26.04"
readonly PHP_VERSION="8.5"
readonly NODE_VERSION="24"
readonly PGSQL_VERSION="18"
readonly SWAP_FILE="/swapfile"
readonly SWAP_SIZE="4G"
readonly PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
readonly PHP_FPM_COMMAND="/usr/sbin/php-fpm${PHP_VERSION}"
readonly NGINX_USER="www-data"
readonly CONFIG_FILE="/etc/orangt.conf"
readonly PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"
readonly PHP_FPM_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
readonly PHP_FPM_WWW_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
readonly FILE_NGINX_CONF="/etc/nginx/nginx.conf"
readonly URL_BASE="https://raw.githubusercontent.com/myspsolution/orangt-templates/refs/heads/main"
readonly REPLACE_FILE_PHP_FPM_WWW_CONF="${URL_BASE}/php/www.${PHP_VERSION}.conf"
readonly REPLACE_FILE_PHP_INI="${URL_BASE}/php/php.${PHP_VERSION}.ini"
readonly REPLACE_FILE_NGINX_CONF="${URL_BASE}/nginx/nginx.conf"
readonly FILE_LOG_ROTATE_NGINX="/etc/logrotate.d/nginx"
readonly FILE_LOG_ROTATE_PHP_FPM="/etc/logrotate.d/php${PHP_VERSION}-fpm"
readonly FILE_LOG_ROTATE_FIREWALL="/etc/logrotate.d/ufw"
readonly FILE_LOG_ROTATE_SUPERVISOR="/etc/logrotate.d/supervisor"
readonly REPLACE_FILE_LOG_ROTATE_NGINX="${URL_BASE}/logrotate/logrotate-nginx"
readonly REPLACE_FILE_LOG_ROTATE_PHP_FPM="${URL_BASE}/logrotate/logrotate-php${PHP_VERSION}-fpm"
readonly REPLACE_FILE_LOG_ROTATE_FIREWALL="${URL_BASE}/logrotate/logrotate-ufw"
readonly REPLACE_FILE_LOG_ROTATE_SUPERVISOR="${URL_BASE}/logrotate/logrotate-supervisor"
readonly LARAVEL_TOOL_SCRIPT="https://cdn.bitzen19.com/script/install_laravel_tools.sh"
readonly DHPARAM_FILE="/etc/ssl/dhparams-2048.pem"
readonly REQUIRED=(
  nano
  util-linux # Provides runuser.
  curl
  wget
  zip
  unzip
  xz-utils
  git
  ufw
  nginx
  acl
  logrotate
  openssl
  python3
  lsb-release
  gnupg
  ca-certificates
  software-properties-common
  fail2ban
  tmpreaper
  finger
  poppler-utils
  pdftk-java
  certbot
  python3-certbot-nginx
  supervisor
)
readonly PHP_PACKAGES=(
  "php${PHP_VERSION}-common"
  "php${PHP_VERSION}-cli"
  "php${PHP_VERSION}-fpm"
  "php${PHP_VERSION}-curl"
  "php${PHP_VERSION}-zip"
  "php${PHP_VERSION}-mbstring"
  "php${PHP_VERSION}-xml"
  "php${PHP_VERSION}-bcmath"
  "php${PHP_VERSION}-gd"
  "php${PHP_VERSION}-intl"
  "php${PHP_VERSION}-pgsql"
  "php${PHP_VERSION}-mysql"
  "php${PHP_VERSION}-dev"
  "php${PHP_VERSION}-mcrypt"
  php-pear
)

# Defaults; supported ORANGT settings may be overridden by /etc/orangt.conf.
ORANGT_USER="orangt"
ORANGT_DIR="/var/www/html"
ORANGT_NGINX_LOG_DIR="/var/log/nginx"
APT_MAX_ATTEMPTS="${APT_MAX_ATTEMPTS:-3}"
APT_RETRY_DELAY="${APT_RETRY_DELAY:-5}"
APT_FALLBACK_APPLIED=0
TEMP_FILES=()
TEMP_DIRS=()
declare -A STAGED_RESOURCES=()
INSTALL_NODE=0
NODE_ARCH=""
NODE_ARCHIVE=""
NODE_ARCHIVE_STAGE=""
NODE_DOWNLOAD_BASE=""
NODE_FULL_VERSION=""
NODE_SHASUM_STAGE=""
NGINX_ERRORS_STAGE=""
NGINX_SNIPPETS_STAGE=""
SUDO=()

# Color only human-facing terminal output; leave redirected output plain.
message() {
  local message_kind="$1"
  local message_text="$2"
  local message_color="$BLD"
  local message_reset="$STD"
  local message_label=""
  local message_end=$'\n'
  local message_fd=1

  case "$message_kind" in
    error)
      message_color="$RED"
      message_label='ERROR:'
      message_text=" $message_text"
      message_fd=2
      ;;
    warning)
      message_color="$YLW"
      message_label='WARNING:'
      message_text=" $message_text"
      message_fd=2
      ;;
    prompt)
      message_label="$message_text"
      message_text=""
      message_end=' '
      message_fd=2
      ;;
    info)
      message_label="$message_text"
      message_text=""
      ;;
  esac

  if [[ ! -t "$message_fd" || "${TERM:-dumb}" == 'dumb' || -n "${NO_COLOR:-}" ]]; then
    message_color=""
    message_reset=""
  fi

  printf '%b%s%b%s%s' "$message_color" "$message_label" "$message_reset" "$message_text" "$message_end" >&"$message_fd"
}

info() {
  message info "$*"
}

warn() {
  message warning "$*"
}

error() {
  message error "$*"
}

configure_privilege() {
  local sudo_bin

  if (( EUID == 0 )); then
    SUDO=()
    return
  fi

  sudo_bin=$(type -P sudo || true)
  [[ -n "$sudo_bin" ]] || {
    error 'This installer requires root access or an authorized sudo account.'
    printf '%s\n' 'Start an authorized session, then run: bash 04-install-php-npm-postgresql-ufw-ipv4-swap-v4.sh' >&2
    exit 1
  }

  if [[ -t 0 && -t 2 ]]; then
    if ! "$sudo_bin" -v; then
      error 'Sudo authentication was cancelled or failed. No changes were made.'
      exit 1
    fi
    SUDO=("$sudo_bin")
  else
    if ! "$sudo_bin" -n -v 2>/dev/null; then
      error 'Noninteractive sudo authentication is unavailable. No changes were made.'
      exit 1
    fi
    SUDO=("$sudo_bin" -n)
  fi

}

require_sudo_command() {
  local command_name="$1"
  local command_path
  shift

  (( EUID != 0 )) || return
  command_path=$(type -P "$command_name" || true)
  [[ -n "$command_path" ]] || {
    error "Required command is unavailable: ${command_name}"
    exit 1
  }
  if ! "${SUDO[@]}" -l -- "$command_path" "$@" >/dev/null 2>&1; then
    error "Sudo is not authorized for the required command: ${command_path} $*"
    exit 1
  fi
}

preflight_privileged_commands() {
  require_sudo_command timedatectl set-timezone Asia/Jakarta
  if [[ ! -e "$SWAP_FILE" ]]; then
    require_sudo_command fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
  fi
  require_sudo_command ufw --force reset
  require_sudo_command ufw default deny incoming
  require_sudo_command ufw default allow outgoing
  require_sudo_command ufw allow 22/tcp comment 'SSH IPv4'
  require_sudo_command systemctl enable ufw nginx "$PHP_FPM_SERVICE" supervisor
  require_sudo_command chown -R root:root /usr/share/nginx/html/sps
  require_sudo_command chown -R root:root /etc/nginx/snippets/sps
}

preflight_bootstrap_commands() {
  require_sudo_command env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 update --error-on=any
  require_sudo_command env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 install -y --no-install-recommends \
    ca-certificates curl git python3 xz-utils ufw
}

cleanup() {
  local path

  for path in "${TEMP_FILES[@]:-}"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
  for path in "${TEMP_DIRS[@]:-}"; do
    [[ -n "$path" ]] && rm -rf -- "$path"
  done
}

download_to_stage() {
  local url="$1"
  local destination

  destination=$(mktemp)
  TEMP_FILES+=("$destination")
  if ! curl -fsSL --connect-timeout 10 --max-time 120 \
    "$url" -o "$destination"; then
    error "Cannot download required resource: ${url%%\?*}"
    exit 1
  fi
  [[ -s "$destination" ]] || {
    error "Downloaded resource is empty: ${url%%\?*}"
    exit 1
  }
  STAGED_RESOURCES["$url"]="$destination"
}

stage_git_repository() {
  local url="$1"
  local destination="$2"

  if ! GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --exit-code \
    "$url" HEAD >/dev/null 2>&1; then
    error "Cannot access required Git repository: ${url}"
    exit 1
  fi
  git clone --depth 1 "$url" "$destination"
  [[ -d "$destination/.git" ]] || {
    error "Staged Git repository is incomplete: ${url}"
    exit 1
  }
}

apt_update_strict() {
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    update --error-on=any
}

verify_apt_error_mode() {
  if ! apt-get update --error-on=any --print-uris >/dev/null 2>&1; then
    error 'This apt-get version cannot make partial repository refresh failures fatal.'
    exit 1
  fi
}

stage_remote_resources() {
  local installed_node_major=""
  local url

  for url in \
    "$REPLACE_FILE_PHP_FPM_WWW_CONF" \
    "$REPLACE_FILE_PHP_INI" \
    "$REPLACE_FILE_NGINX_CONF" \
    "$REPLACE_FILE_LOG_ROTATE_NGINX" \
    "$REPLACE_FILE_LOG_ROTATE_PHP_FPM" \
    "$REPLACE_FILE_LOG_ROTATE_FIREWALL" \
    "$REPLACE_FILE_LOG_ROTATE_SUPERVISOR" \
    'https://composer.github.io/installer.sig' \
    'https://getcomposer.org/installer' \
    "$LARAVEL_TOOL_SCRIPT"; do
    download_to_stage "$url"
  done

  if (( INSTALL_NODE )) && command -v node >/dev/null 2>&1; then
    installed_node_major=$(node -p 'process.versions.node.split(".")[0]' || true)
  fi
  if (( INSTALL_NODE )) && [[ "$installed_node_major" != "$NODE_VERSION" ]]; then
    download_to_stage 'https://nodejs.org/dist/index.json'
    case "$(dpkg --print-architecture)" in
      amd64)
        NODE_ARCH="x64"
        ;;
      arm64)
        NODE_ARCH="arm64"
        ;;
      *)
        error "Unsupported architecture for this Node.js installer: $(dpkg --print-architecture)"
        exit 1
        ;;
    esac

    NODE_FULL_VERSION=$(python3 - "$NODE_VERSION" \
      "${STAGED_RESOURCES['https://nodejs.org/dist/index.json']}" <<'PYNODE'
import json
import sys

major = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as stream:
    releases = json.load(stream)

for release in releases:
    if release["version"].startswith(f"v{major}."):
        print(release["version"])
        break
else:
    raise SystemExit(f"No Node.js v{major}.x release found")
PYNODE
    )
    NODE_ARCHIVE="node-${NODE_FULL_VERSION}-linux-${NODE_ARCH}.tar.xz"
    NODE_DOWNLOAD_BASE="https://nodejs.org/dist/${NODE_FULL_VERSION}"
    download_to_stage "${NODE_DOWNLOAD_BASE}/${NODE_ARCHIVE}"
    download_to_stage "${NODE_DOWNLOAD_BASE}/SHASUMS256.txt"
    NODE_ARCHIVE_STAGE="${STAGED_RESOURCES["${NODE_DOWNLOAD_BASE}/${NODE_ARCHIVE}"]}"
    NODE_SHASUM_STAGE="${STAGED_RESOURCES["${NODE_DOWNLOAD_BASE}/SHASUMS256.txt"]}"

    grep -F "  ${NODE_ARCHIVE}" "$NODE_SHASUM_STAGE" | \
      sed "s#  ${NODE_ARCHIVE}\$#  ${NODE_ARCHIVE_STAGE}#" | sha256sum -c -
  fi

  NGINX_ERRORS_STAGE=$(mktemp -d)
  NGINX_SNIPPETS_STAGE=$(mktemp -d)
  TEMP_DIRS+=("$NGINX_ERRORS_STAGE" "$NGINX_SNIPPETS_STAGE")
  stage_git_repository \
    https://github.com/myspsolution/nginx-custom-error-pages.git \
    "$NGINX_ERRORS_STAGE"
  stage_git_repository \
    https://github.com/myspsolution/nginx-custom-snippets.git \
    "$NGINX_SNIPPETS_STAGE"
}

# Print prompts separately so read preserves spaces and backslashes.
read_input() {
  local input_prompt="$1"
  local input_target="$2"

  message prompt "$input_prompt"
  if ! IFS= read -r "$input_target"; then
    printf '\n' >&2
    warn 'Input cancelled.'
    return 2
  fi
}

trim_space() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# From bash-script-formatting assets/functions/text.bash and prompts.bash.
trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

confirm() {
  local question="$1"
  local default="${2:-y}"
  local choices answer

  case "$default" in
    y)
      choices='Y/n'
      ;;
    n)
      choices='y/N'
      ;;
    none)
      choices='y/n'
      ;;
    *)
      error 'Confirmation default must be y, n, or none.'
      return 2
      ;;
  esac

  while true; do
    message prompt "$question [$choices]:"
    if ! IFS= read -r answer; then
      printf '\n%s\n' 'Input cancelled.' >&2
      return 2
    fi

    answer=$(trim "$answer")
    answer="${answer:-$default}"

    case "$answer" in
      [Yy]|[Yy][Ee][Ss])
        return 0
        ;;
      [Nn]|[Nn][Oo])
        return 1
        ;;
      *)
        warn 'Please enter y or n.'
        ;;
    esac
  done
}

apply_ubuntu_mirror_fallback() {
  local source_file
  local changed=0
  local -a source_files=(
    /etc/apt/sources.list
    /etc/apt/sources.list.d/ubuntu.sources
  )

  printf '\n'
  printf '%s\n' "Switching Ubuntu archive URLs to official HTTPS mirrors..."

  for source_file in "${source_files[@]}"; do
    [[ -f "$source_file" ]] || continue

    if [[ ! -f "${source_file}.before-orangt-mirror-fallback" ]]; then
      "${SUDO[@]}" cp -a \
        "$source_file" \
        "${source_file}.before-orangt-mirror-fallback"
    fi

    # Replace country archive mirrors such as id.archive.ubuntu.com with the
    # official HTTPS archive. Keep ports.ubuntu.com unchanged for architectures
    # that use the Ubuntu ports repository.
    if grep -Eq \
      'https?://([[:alpha:]]{2}\.)?archive\.ubuntu\.com/ubuntu|http://security\.ubuntu\.com/ubuntu' \
      "$source_file"; then
      "${SUDO[@]}" sed -Ei \
        -e 's#https?://([[:alpha:]]{2}\.)?archive\.ubuntu\.com/ubuntu#https://archive.ubuntu.com/ubuntu#g' \
        -e 's#http://security\.ubuntu\.com/ubuntu#https://security.ubuntu.com/ubuntu#g' \
        "$source_file"
      changed=1
    fi
  done

  if (( changed == 0 )); then
    printf '%s\n' "No country-specific Ubuntu archive URL was found to replace."
  fi

  # Remove only partial downloads and partial package indexes. Complete cached
  # packages and existing source configuration are preserved.
  "${SUDO[@]}" rm -rf \
    /var/lib/apt/lists/partial/* \
    /var/cache/apt/archives/partial/*

  APT_FALLBACK_APPLIED=1
}

apt_run_raw() {
  if [[ "${1:-}" == 'update' ]]; then
    shift
    "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
      apt-get \
      -o Acquire::Retries=3 \
      -o Acquire::http::Timeout=30 \
      -o Acquire::https::Timeout=30 \
      update --error-on=any "$@"
    return
  fi

  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive \
    apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    "$@"
}

apt_run() {
  local attempt

  for (( attempt=1; attempt<=APT_MAX_ATTEMPTS; attempt++ )); do
    printf '\n'
    printf '%s\n' "APT attempt ${attempt}/${APT_MAX_ATTEMPTS}: apt-get $*"

    if apt_run_raw "$@"; then
      return 0
    fi

    warn "APT operation failed on attempt ${attempt}."

    if (( APT_FALLBACK_APPLIED == 0 )); then
      apply_ubuntu_mirror_fallback

      printf '%s\n' "Refreshing package lists using the fallback mirror..."
      if ! apt_run_raw update; then
        warn "APT metadata refresh also failed; the operation will still be retried."
      fi
    fi

    if (( attempt < APT_MAX_ATTEMPTS )); then
      printf '%s\n' "Retrying in ${APT_RETRY_DELAY} seconds..."
      sleep "$APT_RETRY_DELAY"
    fi
  done

  printf '\n'
  error "APT operation failed after ${APT_MAX_ATTEMPTS} attempts:"
  printf '  apt-get' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  error "The script is stopping to avoid continuing with missing packages."
  return 1
}

replace_and_backup_file_with_url() {
  local targetfile="$1"
  local url="$2"
  local staged_file owner group perms

  if [[ ! -e "$targetfile" ]]; then
    error "target file does not exist: ${targetfile}"
    return 1
  fi

  staged_file="${STAGED_RESOURCES[$url]:-}"
  [[ -n "$staged_file" && -s "$staged_file" ]] || {
    error "Required staged resource is unavailable: ${url}"
    return 1
  }

  owner="$(stat -c '%u' "$targetfile")"
  group="$(stat -c '%g' "$targetfile")"
  perms="$(stat -c '%a' "$targetfile")"

  if [[ ! -e "${targetfile}.original" ]]; then
    "${SUDO[@]}" cp -a "$targetfile" "${targetfile}.original"
  fi

  # Install atomically only after the download succeeds.
  "${SUDO[@]}" install -o "$owner" -g "$group" -m "$perms" "$staged_file" "$targetfile"
}

replace_file_with_url() {
  local targetfile="$1"
  local url="$2"
  local staged_file

  staged_file="${STAGED_RESOURCES[$url]:-}"
  [[ -n "$staged_file" && -s "$staged_file" ]] || {
    error "Required staged resource is unavailable: ${url}"
    return 1
  }

  "${SUDO[@]}" install -o root -g root -m 0644 "$staged_file" "$targetfile"
}

sync_git_repository() {
  local url="$1"
  local targetdir="$2"
  local staged_dir="$3"

  [[ -d "$staged_dir/.git" ]] || {
    error "Staged Git repository is unavailable: ${url}"
    return 1
  }
  info "Installing staged Git repository: ${targetdir}"
  "${SUDO[@]}" rm -rf -- "$targetdir"
  "${SUDO[@]}" cp -a -- "$staged_dir" "$targetdir"
  "${SUDO[@]}" chown -R root:root "$targetdir"
}

install_composer() {
  local installer expected actual

  installer="${STAGED_RESOURCES['https://getcomposer.org/installer']}"
  expected=$(<"${STAGED_RESOURCES['https://composer.github.io/installer.sig']}")
  actual="$(php -r "echo hash_file('sha384', '${installer}');")"

  if [[ "$expected" != "$actual" ]]; then
    error "Composer installer checksum verification failed."
    return 1
  fi

  "${SUDO[@]}" php "$installer" \
    --install-dir=/usr/local/bin \
    --filename=composer \
    --quiet

}

# ---------------- Starting script ----------------

trap cleanup EXIT
trap 'error "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# Read only the supported settings from /etc/orangt.conf.
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    key="$(printf '%s' "${key:-}" | trim_space)"
    value="$(printf '%s' "${value:-}" | trim_space)"

    [[ -z "$key" || "$key" == \#* ]] && continue

    # Remove one matching pair of surrounding quotes.
    if [[ "$value" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    case "$key" in
      ORANGT_USER|ORANGT_DIR|ORANGT_NGINX_LOG_DIR)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        warn "Ignoring unsupported setting in ${CONFIG_FILE}: ${key}"
        ;;
    esac
  done < "$CONFIG_FILE"
fi

export ORANGT_USER ORANGT_DIR ORANGT_NGINX_LOG_DIR

CURRENT_USER="$(id -un)"
if (( EUID == 0 )); then
  id "$ORANGT_USER" >/dev/null 2>&1 || {
    error "Configured application user does not exist: ${ORANGT_USER}"
    exit 1
  }
  CURRENT_GROUP="$(id -gn "$ORANGT_USER")"
else
  CURRENT_GROUP="$(id -gn "$CURRENT_USER")"
fi

# ---------------- Preliminary checking/validation ----------------

if (( EUID != 0 )) && [[ "$CURRENT_USER" != "$ORANGT_USER" ]]; then
  printf '\n'
  error "Please run this installation script as user: ${ORANGT_USER}"
  printf '%s\n' "Current user: ${CURRENT_USER}" >&2
  printf '\n'
  exit 1
fi

configure_privilege

if ! command -v spstool >/dev/null 2>&1; then
  printf '\n'
  error "Please install spstool before running this installation."
  printf '\n'
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  error "Cannot read /etc/os-release."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
OS_INFO="${PRETTY_NAME:-Unknown Linux}"

if [[ "${ID:-}" != "$LINUX_DISTRO_CHECK" ]]; then
  printf '\n'
  error "This installation script must be run on ${LINUX_DISTRO_CHECK} only."
  printf '%s\n' "Detected OS: ${OS_INFO}" >&2
  printf '\n'
  exit 1
fi

if [[ "${VERSION_ID:-}" != "$LINUX_VERSION_CHECK" ]]; then
  printf '\n'
  error "This installation script must be run on Ubuntu ${LINUX_VERSION_CHECK} only."
  printf '%s\n' "Detected OS: ${OS_INFO}" >&2
  printf '%s\n' "Installation is aborted." >&2
  printf '\n'
  exit 1
fi

command -v apt-get >/dev/null 2>&1 || {
  error 'The required apt-get command is unavailable.'
  exit 1
}
command -v timeout >/dev/null 2>&1 || {
  error 'The required timeout command is unavailable.'
  exit 1
}
if confirm "Do you want to install node ${NODE_VERSION} ? It is mandatory for orangt V5"; then
  INSTALL_NODE=1
else
  CONFIRM_STATUS=$?
  if (( CONFIRM_STATUS != 1 )); then
    exit "$CONFIRM_STATUS"
  fi
fi

verify_apt_error_mode
preflight_bootstrap_commands
apt_update_strict
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get \
  -o Acquire::Retries=3 \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30 \
  install -y --no-install-recommends ca-certificates curl git python3 xz-utils ufw
preflight_privileged_commands
stage_remote_resources

info "Setting timezone to Asia/Jakarta..."
"${SUDO[@]}" timedatectl set-timezone Asia/Jakarta

# ---------------- Swap configuration ----------------

info "Checking swap configuration..."

if [[ ! -e "$SWAP_FILE" ]]; then
  info "Creating ${SWAP_SIZE} swap file: ${SWAP_FILE}"

  if ! "${SUDO[@]}" fallocate -l "$SWAP_SIZE" "$SWAP_FILE"; then
    warn "fallocate failed; creating the swap file with dd instead..."
    "${SUDO[@]}" dd if=/dev/zero of="$SWAP_FILE" bs=1M count=4096 status=progress
  fi

  "${SUDO[@]}" chmod 600 "$SWAP_FILE"
  "${SUDO[@]}" mkswap "$SWAP_FILE"
else
  printf '%s\n' "Swap file already exists: ${SWAP_FILE}"
  "${SUDO[@]}" chmod 600 "$SWAP_FILE"
fi

# Activate /swapfile only when it is not already active.
if ! swapon --show=NAME --noheadings |
  awk '{$1=$1};1' |
  grep -Fxq "$SWAP_FILE"; then
  info "Activating swap file: ${SWAP_FILE}"
  "${SUDO[@]}" swapon "$SWAP_FILE"
else
  printf '%s\n' "Swap file is already active: ${SWAP_FILE}"
fi

# Back up fstab only once, before adding the persistent swap entry.
if [[ ! -f /etc/fstab.before-orangt-swap ]]; then
  "${SUDO[@]}" cp -a /etc/fstab /etc/fstab.before-orangt-swap
fi

if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]+none[[:space:]]+swap[[:space:]]+sw([[:space:]]+0[[:space:]]+0)?[[:space:]]*$' /etc/fstab; then
  printf '%s\n' '/swapfile none swap sw 0 0' |
    "${SUDO[@]}" tee -a /etc/fstab >/dev/null
fi

# Use a dedicated sysctl file so repeated runs do not duplicate settings.
"${SUDO[@]}" tee /etc/sysctl.d/99-orangt-swap.conf >/dev/null <<'EOF'
# Settings for swap
vm.swappiness=15
vm.vfs_cache_pressure=50
EOF

"${SUDO[@]}" sysctl --system >/dev/null

info "Current swap status:"
swapon --show
free -h

# ---------------- Package installation ----------------

printf '%s\n' "Everything starts from the current user's home: ${HOME}"
cd "$HOME"

info "Updating Ubuntu repositories..."
apt_run update

# Enable Ubuntu Universe, required by several packages below.
apt_run install -y software-properties-common
"${SUDO[@]}" add-apt-repository -y universe
apt_run update

info "Installing required system packages..."

apt_run install -y "${REQUIRED[@]}"

# Install MySQL client only when the mysql command is unavailable.
if ! command -v mysql >/dev/null 2>&1; then
  printf '\n'
  info "Installing MySQL client..."
  apt_run install -y mysql-client
else
  printf '\n'
  printf '%s\n' "MySQL client is already installed:"
  mysql --version
fi

# Ubuntu 26.04 already provides PostgreSQL client 18; no PGDG repository is needed.
printf '\n'
info "Installing PostgreSQL client ${PGSQL_VERSION}..."
apt_run install -y "postgresql-client-${PGSQL_VERSION}"

printf '\n'
info "Installing PHP ${PHP_VERSION} and modules..."

apt_run install -y "${PHP_PACKAGES[@]}"

for required_file in \
  "$PHP_CLI_INI" \
  "$PHP_FPM_INI" \
  "$PHP_FPM_WWW_CONF" \
  "$FILE_NGINX_CONF"; do
  if [[ ! -f "$required_file" ]]; then
    error "Required configuration file was not found: ${required_file}"
    exit 1
  fi
done

if [[ ! -x "$PHP_FPM_COMMAND" ]]; then
  error "PHP-FPM executable was not found: ${PHP_FPM_COMMAND}"
  exit 1
fi

# Make PHP 8.5 the default CLI when alternatives are available.
if update-alternatives --list php 2>/dev/null | grep -Fxq "/usr/bin/php${PHP_VERSION}"; then
  "${SUDO[@]}" update-alternatives --set php "/usr/bin/php${PHP_VERSION}"
fi

ACTUAL_PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')"
if [[ "$ACTUAL_PHP_VERSION" != "$PHP_VERSION" ]]; then
  error "The default php command is PHP ${ACTUAL_PHP_VERSION}, expected ${PHP_VERSION}."
  exit 1
fi

# ---------------- Nginx support repositories ----------------

"${SUDO[@]}" mkdir -p /usr/share/nginx/html /etc/nginx/snippets

sync_git_repository \
  https://github.com/myspsolution/nginx-custom-error-pages.git \
  /usr/share/nginx/html/sps \
  "$NGINX_ERRORS_STAGE"

sync_git_repository \
  https://github.com/myspsolution/nginx-custom-snippets.git \
  /etc/nginx/snippets/sps \
  "$NGINX_SNIPPETS_STAGE"

# ---------------- Firewall ----------------

# Configure UFW for IPv4 only. This prevents UFW from generating IPv6 rules.
info "Configuring UFW for IPv4 only..."

if grep -Eq '^[[:space:]]*IPV6=' /etc/default/ufw; then
  "${SUDO[@]}" sed -Ei 's/^[[:space:]]*IPV6=.*/IPV6=no/' /etc/default/ufw
else
  printf '%s\n' 'IPV6=no' | "${SUDO[@]}" tee -a /etc/default/ufw >/dev/null
fi

# Reset existing UFW rules so only SSH, HTTP, and HTTPS remain allowed.
# Port 22 is added before UFW is enabled to avoid locking out an SSH session.
printf '%s\n' "Resetting UFW rules..."
"${SUDO[@]}" ufw --force disable || true
"${SUDO[@]}" ufw --force reset

"${SUDO[@]}" ufw default deny incoming
"${SUDO[@]}" ufw default allow outgoing

"${SUDO[@]}" ufw allow 22/tcp comment 'SSH IPv4'
"${SUDO[@]}" ufw allow 80/tcp comment 'HTTP IPv4'
"${SUDO[@]}" ufw allow 443/tcp comment 'HTTPS IPv4'

"${SUDO[@]}" ufw --force enable
"${SUDO[@]}" ufw reload

info "Current UFW status:"
"${SUDO[@]}" ufw status verbose

# ---------------- PHP, Nginx, and logrotate configuration ----------------

info "Backing up and replacing PHP and Nginx configuration files..."

replace_and_backup_file_with_url "$PHP_CLI_INI" "$REPLACE_FILE_PHP_INI"
replace_and_backup_file_with_url "$PHP_FPM_INI" "$REPLACE_FILE_PHP_INI"
replace_and_backup_file_with_url "$PHP_FPM_WWW_CONF" "$REPLACE_FILE_PHP_FPM_WWW_CONF"
replace_and_backup_file_with_url "$FILE_NGINX_CONF" "$REPLACE_FILE_NGINX_CONF"

# The downloaded FPM pool template defaults to user/group orangt. Adjust it to
# the actual configured user and primary group.
"${SUDO[@]}" sed -i -E \
  -e "s|^user[[:space:]]*=.*|user = ${ORANGT_USER}|" \
  -e "s|^group[[:space:]]*=.*|group = ${CURRENT_GROUP}|" \
  "$PHP_FPM_WWW_CONF"

# The downloaded Nginx and logrotate templates use /var/log/nginx. Apply the
# configured path when a different log directory is selected.
"${SUDO[@]}" mkdir -p "$ORANGT_NGINX_LOG_DIR"
if [[ "$ORANGT_NGINX_LOG_DIR" != "/var/log/nginx" ]]; then
  "${SUDO[@]}" sed -i "s|/var/log/nginx|${ORANGT_NGINX_LOG_DIR}|g" "$FILE_NGINX_CONF"
fi

printf '%s\n' "Adding ${NGINX_USER} to application group ${CURRENT_GROUP}..."
"${SUDO[@]}" usermod -aG "$CURRENT_GROUP" "$NGINX_USER"

# Prepare the application directory without deleting existing applications.
"${SUDO[@]}" mkdir -p "$ORANGT_DIR"
"${SUDO[@]}" chown "$ORANGT_USER:$CURRENT_GROUP" "$ORANGT_DIR"

# Remove only Ubuntu's default site, not every existing virtual host.
"${SUDO[@]}" rm -f /etc/nginx/sites-enabled/default
"${SUDO[@]}" rm -f /etc/nginx/sites-available/default

if [[ ! -s "$DHPARAM_FILE" ]]; then
  info "Creating ${DHPARAM_FILE}..."
  "${SUDO[@]}" openssl dhparam -out "$DHPARAM_FILE" 2048
else
  printf '%s\n' "DH parameters already exist: ${DHPARAM_FILE}"
fi

# Give the application user read access to current and future service logs.
"${SUDO[@]}" mkdir -p "$ORANGT_NGINX_LOG_DIR" /var/log/supervisor
"${SUDO[@]}" setfacl -R -m "u:${ORANGT_USER}:rX" "$ORANGT_NGINX_LOG_DIR"
"${SUDO[@]}" setfacl -m "d:u:${ORANGT_USER}:rX" "$ORANGT_NGINX_LOG_DIR"
"${SUDO[@]}" setfacl -R -m "u:${ORANGT_USER}:rX" /var/log/supervisor
"${SUDO[@]}" setfacl -m "d:u:${ORANGT_USER}:rX" /var/log/supervisor

info "Installing logrotate configurations..."
replace_file_with_url "$FILE_LOG_ROTATE_NGINX" "$REPLACE_FILE_LOG_ROTATE_NGINX"
replace_file_with_url "$FILE_LOG_ROTATE_PHP_FPM" "$REPLACE_FILE_LOG_ROTATE_PHP_FPM"
replace_file_with_url "$FILE_LOG_ROTATE_FIREWALL" "$REPLACE_FILE_LOG_ROTATE_FIREWALL"
replace_file_with_url "$FILE_LOG_ROTATE_SUPERVISOR" "$REPLACE_FILE_LOG_ROTATE_SUPERVISOR"

if [[ "$ORANGT_NGINX_LOG_DIR" != "/var/log/nginx" ]]; then
  "${SUDO[@]}" sed -i "s|/var/log/nginx|${ORANGT_NGINX_LOG_DIR}|g" "$FILE_LOG_ROTATE_NGINX"
fi

# Test new configurations before restarting running services.
info "Testing PHP-FPM, Nginx, and logrotate configuration..."
"${SUDO[@]}" "$PHP_FPM_COMMAND" -t
"${SUDO[@]}" nginx -t
"${SUDO[@]}" logrotate --debug /etc/logrotate.conf >/dev/null

# Start or restart services only after configuration tests succeed.
info "Enabling and restarting services..."
"${SUDO[@]}" systemctl enable ufw nginx "$PHP_FPM_SERVICE" supervisor
"${SUDO[@]}" systemctl restart "$PHP_FPM_SERVICE"
"${SUDO[@]}" systemctl restart nginx
"${SUDO[@]}" systemctl restart supervisor

# ---------------- Composer ----------------

info "Installing Composer..."
install_composer

# ---------------- Node.js ----------------

if (( INSTALL_NODE )); then
  # Ubuntu 26.04 provides Node.js 22, while this script requires Node.js 24.
  # Install the official Node.js binary under /usr/local instead of using a
  # third-party APT repository that does not yet list Ubuntu 26.04 as supported.
  INSTALLED_NODE_MAJOR=""
  if command -v node >/dev/null 2>&1; then
    INSTALLED_NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  fi

  if [[ "$INSTALLED_NODE_MAJOR" != "$NODE_VERSION" ]]; then
    info "Installing the latest official Node.js ${NODE_VERSION}.x release..."

    "${SUDO[@]}" tar -xJf "$NODE_ARCHIVE_STAGE" \
      -C /usr/local \
      --strip-components=1
    hash -r
  else
    printf '%s\n' "Node.js ${NODE_VERSION}.x is already installed."
  fi

  ACTUAL_NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  if [[ "$ACTUAL_NODE_MAJOR" != "$NODE_VERSION" ]]; then
    error "Installed Node.js major version is ${ACTUAL_NODE_MAJOR}; expected ${NODE_VERSION}."
    exit 1
  fi
else
  printf '%s\n' "Skipping Node.js installation."
fi

# ---------------- Laravel tools ----------------

info "Downloading and installing Laravel tools..."
LARAVEL_TOOL_TEMP="${STAGED_RESOURCES[$LARAVEL_TOOL_SCRIPT]}"
bash -n "$LARAVEL_TOOL_TEMP"
bash "$LARAVEL_TOOL_TEMP"

# ---------------- Final verification ----------------

printf '\n'
printf '%s\n' "Installed PHP version:"
php -v

printf '\n'
printf '%s\n' "Installed PHP modules:"
php -m

printf '\n'
printf '%s\n' "MySQL-related PHP modules:"
php -m | grep -Ei 'mysqli|mysqlnd|pdo_mysql' || true

printf '\n'
printf '%s\n' "PostgreSQL-related PHP modules:"
php -m | grep -Ei 'pgsql|pdo_pgsql' || true

printf '\n'
printf '%s\n' "Database clients:"
mysql --version
psql --version

printf '\n'
printf '%s\n' "Composer:"
composer --version
if (( INSTALL_NODE )); then
  printf '%s\n' "Node.js and npm:"
  node --version
  npm --version
fi

printf '\n'
printf '%s\n' "Service status:"
for service in ufw nginx "$PHP_FPM_SERVICE" supervisor; do
  if systemctl is-active --quiet "$service"; then
    printf '%s\n' "  ${service}: active"
  else
    error "  ${service}: FAILED"
    systemctl --no-pager --full status "$service" || true
    exit 1
  fi
done

printf '\n'
info "PHP and supported components installation is finished."

if [[ -t 0 ]]; then
  read_input 'Press [Enter] to display updated system information:' REPLY || exit 1
fi

info "spstool sysinfo"
printf '\n'
spstool sysinfo
