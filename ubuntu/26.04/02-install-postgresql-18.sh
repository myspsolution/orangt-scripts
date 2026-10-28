#!/usr/bin/env bash

# 02-install-postgresql-18-ubuntu-26.04-maxconn300-ssd-ufw-only-ip-filter.sh
# PostgreSQL 18 installer for Ubuntu Server 26.04 LTS (Resolute).
# Revised: 2026-09-09 22-21-30
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 02-install-postgresql-18-ubuntu-26.04-maxconn300-ssd-ufw-only-ip-filter.sh
# Designed for a fresh server and the configured orangt application user.
# Privileged commands run directly as root or through authorized sudo.

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

readonly SCRIPT_NAME="${0##*/}"
readonly DB_VERSION="18"
readonly DB_PORT="5432"
readonly REQUIRED_UBUNTU_VERSION="26.04"
readonly REQUIRED_UBUNTU_CODENAME="resolute"
readonly DEFAULT_TIMEZONE="Asia/Jakarta"
readonly CONFIG_FILE="/etc/orangt.conf"
readonly PGDG_KEY_URL="https://www.postgresql.org/media/keys/ACCC4CF8.asc"
readonly PGDG_REPO_URL="https://apt.postgresql.org/pub/repos/apt"
readonly SLOW_QUERY_THRESHOLD="2s"

TMP_FILES=()
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
POSTGRES_PASSWORD=""
PG_HBA_CONF=""
POSTGRESQL_CONF=""
TUNING_CONF=""
HBA_BACKUP=""
CONF_BACKUP=""
CONFIG_WAS_CHANGED=0
ENV_NEEDS_WRITE=0
PGDG_KEY_STAGE=""
SSH_PORT="22"
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

confirm_yes_no() {
  local question="$1"
  local answer

  while true; do
    # Preserve the original explicit-answer requirement: Enter is not yes.
    read_input "$question [y/n]:" answer || exit 1
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"

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

die() {
  error "$*"
  exit 1
}

configure_privilege() {
  local sudo_bin

  if (( EUID == 0 )); then
    SUDO=()
    command -v runuser >/dev/null 2>&1 || die 'Root execution requires runuser for PostgreSQL account commands.'
    return
  fi

  sudo_bin=$(type -P sudo || true)
  [[ -n "$sudo_bin" ]] || die "This installer requires root access or an authorized sudo account. Run: bash ${SCRIPT_NAME}"

  if [[ -t 0 && -t 2 ]]; then
    "$sudo_bin" -v || die 'Sudo authentication was cancelled or failed. No changes were made.'
    SUDO=("$sudo_bin")
  else
    "$sudo_bin" -n -v 2>/dev/null || die 'Noninteractive sudo authentication is unavailable. No changes were made.'
    SUDO=("$sudo_bin" -n)
  fi

}

require_sudo_command() {
  local command_name="$1"
  local command_path
  shift

  (( EUID != 0 )) || return
  command_path=$(type -P "$command_name" || true)
  [[ -n "$command_path" ]] || die "Required command is unavailable: ${command_name}"
  "${SUDO[@]}" -l -- "$command_path" "$@" >/dev/null 2>&1 || \
    die "Sudo is not authorized for the required command: ${command_path} $*"
}

preflight_privileged_commands() {
  require_sudo_command env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 update --error-on=any
  require_sudo_command timedatectl set-timezone "$TIMEZONE"
  require_sudo_command install -d -o root -g root -m 0755 \
    /usr/share/postgresql-common/pgdg
  require_sudo_command install -o root -g root -m 0644 "$PGDG_KEY_STAGE" \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  require_sudo_command install -o root -g root -m 0644 "$PGDG_SOURCE_TMP" \
    /etc/apt/sources.list.d/pgdg.sources
  require_sudo_command systemctl enable postgresql
  require_sudo_command ufw default deny incoming
  require_sudo_command ufw default allow outgoing
  require_sudo_command ufw allow "${SSH_PORT:-22}/tcp" comment SSH
  if (( REMOTE_DATABASE )); then
    require_sudo_command ufw allow from "$ALLOW_REMOTE_IP" to any port "$DB_PORT" \
      proto tcp comment 'PostgreSQL allowed source'
  fi
  require_sudo_command ufw --force disable
  require_sudo_command ufw --force enable
  require_sudo_command ufw reload
}

apt_update_strict() {
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    update --error-on=any
}

verify_apt_error_mode() {
  apt-get update --error-on=any --print-uris >/dev/null 2>&1 || \
    die 'This apt-get version cannot make partial repository refresh failures fatal.'
}

stage_pgdg_key() {
  PGDG_KEY_STAGE=$(mktemp)
  TMP_FILES+=("$PGDG_KEY_STAGE")

  if ! curl -fsSL --connect-timeout 10 --max-time 30 \
    "$PGDG_KEY_URL" -o "$PGDG_KEY_STAGE"; then
    die "Cannot download the PostgreSQL signing key from ${PGDG_KEY_URL}."
  fi
  grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----$' "$PGDG_KEY_STAGE" || \
    die 'The downloaded PostgreSQL signing key is not valid ASCII-armored PGP data.'
}

detect_ssh_port() {
  local detected_ssh_port=""

  [[ -x /usr/sbin/sshd ]] || return
  if (( EUID != 0 )); then
    "${SUDO[@]}" -l -- /usr/sbin/sshd -T >/dev/null 2>&1 || \
      die 'Sudo is not authorized to inspect the effective SSH server port.'
  fi
  detected_ssh_port=$("${SUDO[@]}" /usr/sbin/sshd -T 2>/dev/null | \
    awk '$1=="port" {print $2; exit}' || true)
  if [[ "$detected_ssh_port" =~ ^[0-9]+$ ]]; then
    SSH_PORT="$detected_ssh_port"
  fi
}

preflight_installation() {
  command -v apt-get >/dev/null 2>&1 || die 'The required apt-get command is unavailable.'
  command -v dpkg >/dev/null 2>&1 || die 'The required dpkg command is unavailable.'
  verify_apt_error_mode

  configure_privilege
  require_sudo_command env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 update --error-on=any
  require_sudo_command env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 install -y --no-install-recommends \
    ca-certificates curl
  apt_update_strict
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    install -y --no-install-recommends ca-certificates curl

  stage_pgdg_key
  if ! curl -fsSL --connect-timeout 10 --max-time 30 --range 0-0 \
    "$PGDG_REPO_URL/dists/${VERSION_CODENAME}-pgdg/Release" >/dev/null 2>&1; then
    die "Cannot access the PostgreSQL repository release for ${VERSION_CODENAME}-pgdg."
  fi
  require_sudo_command env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 install -y --no-install-recommends \
    postgresql-common ufw
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 install -y --no-install-recommends \
    postgresql-common ufw
  detect_ssh_port
}

run_as_user() {
  local target_user="$1"
  shift

  if [[ $(id -un) == "$target_user" ]]; then
    command "$@"
  elif (( EUID == 0 )); then
    command runuser -u "$target_user" -- "$@"
  else
    "${SUDO[@]}" -u "$target_user" -- "$@"
  fi
}

cleanup() {
  local file
  for file in "${TMP_FILES[@]:-}"; do
    [[ -n "$file" ]] && rm -f -- "$file" 2>/dev/null || true
  done
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  local failed_command="$3"

  error "Installation failed at line ${line_no} (exit code ${exit_code})."
  printf 'Failed command: %s\n' "$failed_command" >&2

  if command -v systemctl >/dev/null 2>&1 && [[ -n "${PG_HBA_CONF:-}" ]]; then
    printf '\nPostgreSQL status and recent logs may help:\n' >&2
    printf '  sudo systemctl status postgresql@%s-main --no-pager -l\n' "$DB_VERSION" >&2
    printf '  sudo journalctl -u postgresql@%s-main -n 100 --no-pager\n' "$DB_VERSION" >&2
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_simple_config_value() {
  local key="$1"
  local file="$2"
  local line value

  [[ -r "$file" ]] || return 1
  line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n 1 || true)
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  value="$(trim "$value")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

valid_ipv4() {
  local ip="$1"
  local IFS='.'
  local -a octets=()
  local octet

  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

secure_random_index() {
  local maximum="$1"
  local number
  number=$(od -An -N4 -tu4 /dev/urandom)
  number="${number//[[:space:]]/}"
  printf '%s' "$((number % maximum))"
}

random_chars() {
  local alphabet="$1"
  local length="$2"
  local result=""
  local index

  while ((${#result} < length)); do
    index=$(secure_random_index "${#alphabet}")
    result+="${alphabet:index:1}"
  done
  printf '%s' "$result"
}

shuffle_string() {
  local input="$1"
  local -a chars=()
  local i j tmp result=""

  for ((i = 0; i < ${#input}; i++)); do
    chars+=("${input:i:1}")
  done

  for ((i = ${#chars[@]} - 1; i > 0; i--)); do
    j=$(secure_random_index "$((i + 1))")
    tmp="${chars[i]}"
    chars[i]="${chars[j]}"
    chars[j]="$tmp"
  done

  for tmp in "${chars[@]}"; do
    result+="$tmp"
  done
  printf '%s' "$result"
}

generate_password() {
  # Deliberately excludes quotes, backslashes, spaces, backticks, semicolons,
  # and colons so the result is safe in SQL literals and Laravel .env quotes.
  local lower='abcdefghijkmnopqrstuvwxyz'
  local upper='ABCDEFGHJKLMNPQRSTUVWXYZ'
  local digits='23456789'
  local special='!@#$%^&*_-+=?'
  local all="${lower}${upper}${digits}${special}"
  local password

  password="$(random_chars "$lower" 2)"
  password+="$(random_chars "$upper" 2)"
  password+="$(random_chars "$digits" 2)"
  password+="$(random_chars "$special" 2)"
  password+="$(random_chars "$all" 32)"
  shuffle_string "$password"
}

generate_db_user() {
  printf 'user_%s' "$(random_chars 'abcdefghijklmnopqrstuvwxyz23456789' 18)"
}

primary_ipv4() {
  local detected=""
  detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)
  if ! valid_ipv4 "$detected"; then
    detected=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 1 || true)
  fi
  valid_ipv4 "$detected" || return 1
  printf '%s' "$detected"
}

# Prompt functions return only the selected value on stdout.
prompt_client_code() {
  local value

  while true; do
    read_input 'Enter project client code (3-12 lowercase alphanumeric characters):' value || exit 1
    if [[ ! "$value" =~ ^[a-z0-9]{3,12}$ ]]; then
      warn 'Invalid client code. Example: myclient'
      continue
    fi
    if confirm_yes_no "Use client code '$value'?"; then
      printf '%s' "$value"
      return 0
    fi
  done
}

prompt_environment() {
  local choice selected

  while true; do
    printf '\nChoose the server environment:\n\n' >&2
    printf '%s\n' \
      '  1) dev                  (web application + database)' \
      '  2) dev-database         (database server only)' \
      '  3) production           (web application + database)' \
      '  4) production-database  (database server only)' >&2
    read_input 'Choose an option [1-4]:' choice || exit 1

    case "$choice" in
      1)
        selected='dev'
        ;;
      2)
        selected='dev-database'
        ;;
      3)
        selected='production'
        ;;
      4)
        selected='production-database'
        ;;
      *)
        warn 'Please choose 1, 2, 3, or 4.'
        continue
        ;;
    esac

    if confirm_yes_no "Use environment '$selected'?"; then
      printf '%s' "$selected"
      return 0
    fi
  done
}

prompt_remote_ip() {
  local local_ip="$1"
  local value

  while true; do
    printf '\nEnter the exact IPv4 address of the remote web application server.\n' >&2
    printf 'Local database IP: %s\n' "$local_ip" >&2
    read_input 'Enter allowed application IPv4 address:' value || exit 1

    if ! valid_ipv4 "$value" || [[ "$value" == "$local_ip" || "$value" == '127.0.0.1' ]]; then
      warn 'Enter a valid, different IPv4 address.'
      continue
    fi

    if confirm_yes_no "Allow ${value}/32 to PostgreSQL?"; then
      printf '%s' "$value"
      return 0
    fi
  done
}

set_ufw_ipv6_disabled() {
  local tmp
  tmp=$(mktemp)
  TMP_FILES+=("$tmp")

  cat /etc/default/ufw > "$tmp"
  if grep -qE '^[[:space:]]*IPV6=' "$tmp"; then
    sed -E 's/^[[:space:]]*IPV6=.*/IPV6=no/' "$tmp" > "${tmp}.new"
    mv "${tmp}.new" "$tmp"
  else
    printf '\nIPV6=no\n' >> "$tmp"
  fi
  "${SUDO[@]}" install -o root -g root -m 0644 "$tmp" /etc/default/ufw
}

restore_postgresql_config() {
  set +e
  if [[ -n "$HBA_BACKUP" && -f "$HBA_BACKUP" ]]; then
    "${SUDO[@]}" cp -a "$HBA_BACKUP" "$PG_HBA_CONF"
  fi
  if [[ -n "$CONF_BACKUP" && -f "$CONF_BACKUP" ]]; then
    "${SUDO[@]}" cp -a "$CONF_BACKUP" "$POSTGRESQL_CONF"
  fi
  if [[ -n "$TUNING_CONF" ]]; then
    "${SUDO[@]}" rm -f "$TUNING_CONF"
  fi
  "${SUDO[@]}" systemctl restart "postgresql@${DB_VERSION}-main" >/dev/null 2>&1 || true
  set -e
}

# ---------------- Starting script ----------------

trap cleanup EXIT
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
IFS=$'\n\t'
umask 077

# ---------------- Preliminary validation ----------------

ORANGT_USER="${ORANGT_USER:-$(read_simple_config_value ORANGT_USER "$CONFIG_FILE" || true)}"
ORANGT_USER="${ORANGT_USER:-orangt}"
[[ "$ORANGT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid ORANGT_USER value: $ORANGT_USER"
id "$ORANGT_USER" >/dev/null 2>&1 || die "Configured application user does not exist: $ORANGT_USER"
if (( EUID != 0 )) && [[ $(id -un) != "$ORANGT_USER" ]]; then
  die "This script must be run as root or user '$ORANGT_USER'."
fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == 'ubuntu' ]] || die "Ubuntu is required. Detected: ${PRETTY_NAME:-unknown OS}"
[[ "${VERSION_ID:-}" == "$REQUIRED_UBUNTU_VERSION" ]] || die "Ubuntu ${REQUIRED_UBUNTU_VERSION} is required. Detected: ${PRETTY_NAME:-unknown version}"
[[ "${VERSION_CODENAME:-}" == "$REQUIRED_UBUNTU_CODENAME" ]] || die "Ubuntu codename '$REQUIRED_UBUNTU_CODENAME' is required. Detected: ${VERSION_CODENAME:-unknown}"

ARCHITECTURE=$(dpkg --print-architecture)
case "$ARCHITECTURE" in
  amd64|arm64|ppc64el)
    ;;
  *)
    die "Unsupported architecture for this installer: $ARCHITECTURE"
    ;;
esac

EXISTING_PG_PATH=$(find /etc/postgresql /var/lib/postgresql -mindepth 1 -maxdepth 3 -print -quit 2>/dev/null || true)
if command -v psql >/dev/null 2>&1 || [[ -n "$EXISTING_PG_PATH" ]]; then
  die 'A PostgreSQL installation or cluster already exists. This installer is intentionally for a fresh server only.'
fi

TIMEZONE="${TIMEZONE:-$DEFAULT_TIMEZONE}"
[[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"

CLIENT_CODE="${CLIENT_CODE:-}"
if [[ -z "$CLIENT_CODE" ]]; then
  [[ -t 0 ]] || die 'CLIENT_CODE is required when running non-interactively.'
  CLIENT_CODE=$(prompt_client_code)
fi
[[ "$CLIENT_CODE" =~ ^[a-z0-9]{3,12}$ ]] || die 'CLIENT_CODE must be 3-12 lowercase alphanumeric characters.'

ENV_FILE="/home/${ORANGT_USER}/server.env"
SERVER_ENVIRONMENT="${SERVER_ENVIRONMENT:-}"
if [[ -z "$SERVER_ENVIRONMENT" && -r "$ENV_FILE" ]]; then
  SERVER_ENVIRONMENT=$(read_simple_config_value SERVER_ENVIRONMENT "$ENV_FILE" || true)
fi

SELECTED_ENV=""
if [[ "$SERVER_ENVIRONMENT" == "${CLIENT_CODE}-"* ]]; then
  SELECTED_ENV="${SERVER_ENVIRONMENT#${CLIENT_CODE}-}"
fi
case "$SELECTED_ENV" in
  dev|dev-database|production|production-database)
    ;;
  *)
    SELECTED_ENV="${SELECTED_ENV_OVERRIDE:-}"
    if [[ -z "$SELECTED_ENV" ]]; then
      [[ -t 0 ]] || die 'SELECTED_ENV_OVERRIDE is required when running non-interactively.'
      SELECTED_ENV=$(prompt_environment)
    fi
    case "$SELECTED_ENV" in
      dev|dev-database|production|production-database)
        ;;
      *)
        die 'Environment must be dev, dev-database, production, or production-database.'
        ;;
    esac
    SERVER_ENVIRONMENT="${CLIENT_CODE}-${SELECTED_ENV}"
    ENV_NEEDS_WRITE=1
    ;;
esac
SERVER_ENVIRONMENT="${CLIENT_CODE}-${SELECTED_ENV}"

LOCAL_IP=$(primary_ipv4) || die 'Unable to determine the primary IPv4 address.'
REMOTE_DATABASE=0
ALLOW_REMOTE_IP=""
if [[ "$SELECTED_ENV" == *-database ]]; then
  REMOTE_DATABASE=1
  ALLOW_REMOTE_IP="${ALLOW_REMOTE_IP:-}"
  if [[ -z "$ALLOW_REMOTE_IP" ]]; then
    [[ -t 0 ]] || die 'ALLOW_REMOTE_IP is required for a remote database server.'
    ALLOW_REMOTE_IP=$(prompt_remote_ip "$LOCAL_IP")
  fi
  valid_ipv4 "$ALLOW_REMOTE_IP" || die 'ALLOW_REMOTE_IP is not a valid IPv4 address.'
  [[ "$ALLOW_REMOTE_IP" != "$LOCAL_IP" && "$ALLOW_REMOTE_IP" != '127.0.0.1' ]] || die 'ALLOW_REMOTE_IP must differ from the database server IP.'
fi

HOST_NAME=$(hostname -f 2>/dev/null || hostname)
CPU_CORES=$(nproc)
RAM_TOTAL_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
(( RAM_TOTAL_MB >= 1024 )) || die 'At least 1 GB RAM is required.'
STORAGE_PROFILE='ssd'

if [[ "$SELECTED_ENV" == *-database ]]; then
  SHARED_BUFFER_PERCENT=25
  CACHE_PERCENT=75
else
  SHARED_BUFFER_PERCENT=20
  CACHE_PERCENT=60
fi

SHARED_BUFFERS_MB=$((RAM_TOTAL_MB * SHARED_BUFFER_PERCENT / 100))
(( SHARED_BUFFERS_MB < 128 )) && SHARED_BUFFERS_MB=128
EFFECTIVE_CACHE_MB=$((RAM_TOTAL_MB * CACHE_PERCENT / 100))
MAINTENANCE_WORK_MEM_MB=$((RAM_TOTAL_MB / 16))
(( MAINTENANCE_WORK_MEM_MB < 64 )) && MAINTENANCE_WORK_MEM_MB=64
(( MAINTENANCE_WORK_MEM_MB > 2048 )) && MAINTENANCE_WORK_MEM_MB=2048
AUTOVACUUM_WORK_MEM_MB=$((MAINTENANCE_WORK_MEM_MB / 2))
(( AUTOVACUUM_WORK_MEM_MB < 64 )) && AUTOVACUUM_WORK_MEM_MB=64
(( AUTOVACUUM_WORK_MEM_MB > 1024 )) && AUTOVACUUM_WORK_MEM_MB=1024

# Fixed PostgreSQL connection limit requested for this deployment.
# Keep this value consistent with PgBouncer/application pool sizing.
MAX_CONNECTIONS=300

WORK_MEM_AVAILABLE_MB=$((RAM_TOTAL_MB - SHARED_BUFFERS_MB - 1024))
(( WORK_MEM_AVAILABLE_MB < 512 )) && WORK_MEM_AVAILABLE_MB=512
WORK_MEM_MB=$((WORK_MEM_AVAILABLE_MB / (MAX_CONNECTIONS * 3)))
(( WORK_MEM_MB < 4 )) && WORK_MEM_MB=4
(( WORK_MEM_MB > 64 )) && WORK_MEM_MB=64

MAX_WORKER_PROCESSES=$CPU_CORES
(( MAX_WORKER_PROCESSES < 8 )) && MAX_WORKER_PROCESSES=8
MAX_PARALLEL_WORKERS=$CPU_CORES
(( MAX_PARALLEL_WORKERS < 2 )) && MAX_PARALLEL_WORKERS=2
MAX_PARALLEL_WORKERS_PER_GATHER=$((CPU_CORES / 2))
(( MAX_PARALLEL_WORKERS_PER_GATHER < 1 )) && MAX_PARALLEL_WORKERS_PER_GATHER=1
(( MAX_PARALLEL_WORKERS_PER_GATHER > 4 )) && MAX_PARALLEL_WORKERS_PER_GATHER=4
MAX_PARALLEL_MAINTENANCE_WORKERS=$MAX_PARALLEL_WORKERS_PER_GATHER
(( MAX_PARALLEL_MAINTENANCE_WORKERS < 2 )) && MAX_PARALLEL_MAINTENANCE_WORKERS=2

AUTOVACUUM_MAX_WORKERS=$((CPU_CORES / 2))
(( AUTOVACUUM_MAX_WORKERS < 3 )) && AUTOVACUUM_MAX_WORKERS=3
(( AUTOVACUUM_MAX_WORKERS > 6 )) && AUTOVACUUM_MAX_WORKERS=6

# SSD-optimized planner and I/O settings are always used.
RANDOM_PAGE_COST='1.1'
EFFECTIVE_IO_CONCURRENCY=200
MAINTENANCE_IO_CONCURRENCY=100

if (( RAM_TOTAL_MB < 8192 )); then
  MIN_WAL_SIZE='512MB'
  MAX_WAL_SIZE='2GB'
elif (( RAM_TOTAL_MB < 32768 )); then
  MIN_WAL_SIZE='1GB'
  MAX_WAL_SIZE='4GB'
else
  MIN_WAL_SIZE='2GB'
  MAX_WAL_SIZE='8GB'
fi

if [[ "$SELECTED_ENV" == *dev* ]]; then
  DB_NAME="db_${CLIENT_CODE}_dev"
else
  DB_NAME="db_${CLIENT_CODE}_prod"
fi
DB_USER=$(generate_db_user)
DB_PASSWORD=$(generate_password)
POSTGRES_PASSWORD=$(generate_password)

printf '\n'
info 'Installation profile'
printf '  OS                   : %s\n' "$PRETTY_NAME"
printf '  PostgreSQL           : %s\n' "$DB_VERSION"
printf '  Environment          : %s\n' "$SERVER_ENVIRONMENT"
printf '  CPU cores            : %s\n' "$CPU_CORES"
printf '  RAM                  : %s MB\n' "$RAM_TOTAL_MB"
printf '  Storage profile      : %s\n' "$STORAGE_PROFILE"
printf '  Max connections      : %s\n' "$MAX_CONNECTIONS"
printf '  Shared buffers       : %s MB\n' "$SHARED_BUFFERS_MB"
printf '  Work memory          : %s MB per operation\n' "$WORK_MEM_MB"
printf '  Slow-query threshold : %s\n' "$SLOW_QUERY_THRESHOLD"
if (( REMOTE_DATABASE )); then
  printf '  UFW PostgreSQL IP    : %s/32\n' "$ALLOW_REMOTE_IP"
else
  printf '  Network exposure     : localhost only\n'
fi

if [[ -t 0 ]]; then
  read_input 'Press [Enter] to install PostgreSQL 18, or Ctrl+C to cancel:' REPLY || exit 1
fi

PGDG_SOURCE_TMP=$(mktemp)
TMP_FILES+=("$PGDG_SOURCE_TMP")
preflight_installation
preflight_privileged_commands

info "Setting timezone to $TIMEZONE ..."
"${SUDO[@]}" timedatectl set-timezone "$TIMEZONE"

if (( ENV_NEEDS_WRITE )); then
  printf 'SERVER_ENVIRONMENT=%s\n' "$SERVER_ENVIRONMENT" > "$ENV_FILE"
  "${SUDO[@]}" chown "$ORANGT_USER:$(id -gn "$ORANGT_USER")" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
fi

# ------------------------------ Packages ------------------------------

info 'Configuring the official PostgreSQL PGDG repository ...'
"${SUDO[@]}" install -d -o root -g root -m 0755 /usr/share/postgresql-common/pgdg
"${SUDO[@]}" install -o root -g root -m 0644 "$PGDG_KEY_STAGE" \
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
"${SUDO[@]}" chmod 0644 /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

cat > "$PGDG_SOURCE_TMP" <<EOF
Types: deb
URIs: $PGDG_REPO_URL
Suites: ${VERSION_CODENAME}-pgdg
Architectures: $ARCHITECTURE
Components: main
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
EOF
"${SUDO[@]}" install -o root -g root -m 0644 "$PGDG_SOURCE_TMP" /etc/apt/sources.list.d/pgdg.sources

apt_update_strict
APT_CANDIDATE=$(apt-cache policy "postgresql-${DB_VERSION}" | awk '/Candidate:/ {print $2; exit}' || true)
[[ -n "$APT_CANDIDATE" && "$APT_CANDIDATE" != '(none)' ]] || die "postgresql-${DB_VERSION} is not available from the configured repository."

info "Installing PostgreSQL ${DB_VERSION} ..."
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
  apt-get install -y --no-install-recommends "postgresql-${DB_VERSION}" "postgresql-client-${DB_VERSION}"

"${SUDO[@]}" systemctl enable postgresql >/dev/null
if ! "${SUDO[@]}" systemctl start "postgresql@${DB_VERSION}-main"; then
  "${SUDO[@]}" pg_ctlcluster "$DB_VERSION" main start
fi

PG_CLUSTER_ROW=$(pg_lsclusters --no-header | awk -v v="$DB_VERSION" '$1==v && $2=="main" {print; exit}' || true)
[[ -n "$PG_CLUSTER_ROW" ]] || die "PostgreSQL ${DB_VERSION} main cluster was not created."

PG_HBA_CONF="/etc/postgresql/${DB_VERSION}/main/pg_hba.conf"
POSTGRESQL_CONF="/etc/postgresql/${DB_VERSION}/main/postgresql.conf"
TUNING_CONF="/etc/postgresql/${DB_VERSION}/main/conf.d/99-orangt.conf"
DATA_DIR="/var/lib/postgresql/${DB_VERSION}/main"
PG_BIN="/usr/lib/postgresql/${DB_VERSION}/bin"

[[ -f "$PG_HBA_CONF" && -f "$POSTGRESQL_CONF" && -d "$DATA_DIR" ]] || die 'Expected PostgreSQL cluster files are missing.'

# ------------------------------ Roles and database ------------------------------

info 'Creating the application role and database ...'
run_as_user postgres "$PG_BIN/psql" --no-psqlrc --set=ON_ERROR_STOP=1 -d postgres <<SQL
SET password_encryption = 'scram-sha-256';
CREATE ROLE "$DB_USER"
  LOGIN
  NOSUPERUSER
  NOCREATEDB
  NOCREATEROLE
  NOINHERIT
  NOREPLICATION
  PASSWORD '$DB_PASSWORD';
ALTER ROLE postgres PASSWORD '$POSTGRES_PASSWORD';
CREATE DATABASE "$DB_NAME"
  OWNER "$DB_USER"
  TEMPLATE template0
  ENCODING 'UTF8'
  LOCALE_PROVIDER builtin
  BUILTIN_LOCALE 'C.UTF-8';
\connect "$DB_NAME"
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT ALL ON SCHEMA public TO "$DB_USER";
SQL

# ------------------------------ PostgreSQL configuration ------------------------------

BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)
HBA_BACKUP="${PG_HBA_CONF}.before-orangt-${BACKUP_STAMP}"
CONF_BACKUP="${POSTGRESQL_CONF}.before-orangt-${BACKUP_STAMP}"
"${SUDO[@]}" cp -a "$PG_HBA_CONF" "$HBA_BACKUP"
"${SUDO[@]}" cp -a "$POSTGRESQL_CONF" "$CONF_BACKUP"
"${SUDO[@]}" install -d -o postgres -g postgres -m 0750 "$(dirname "$TUNING_CONF")"

if (( REMOTE_DATABASE )); then
  LISTEN_ADDRESSES="127.0.0.1,${LOCAL_IP}"
  DB_HOST="$LOCAL_IP"
  DB_SSLMODE='require'
else
  LISTEN_ADDRESSES='127.0.0.1'
  DB_HOST='127.0.0.1'
  DB_SSLMODE='prefer'
fi

TUNING_TMP=$(mktemp)
TMP_FILES+=("$TUNING_TMP")
cat > "$TUNING_TMP" <<EOF
# Managed by $SCRIPT_NAME on $(date --iso-8601=seconds)
# Workload profile: general-purpose Laravel/PostgreSQL OLTP starting values.

# Connections and security
listen_addresses = '$LISTEN_ADDRESSES'
port = $DB_PORT
max_connections = $MAX_CONNECTIONS
superuser_reserved_connections = 5
password_encryption = 'scram-sha-256'
ssl = on
ssl_min_protocol_version = 'TLSv1.2'

# Memory
shared_buffers = '${SHARED_BUFFERS_MB}MB'
effective_cache_size = '${EFFECTIVE_CACHE_MB}MB'
work_mem = '${WORK_MEM_MB}MB'
maintenance_work_mem = '${MAINTENANCE_WORK_MEM_MB}MB'
autovacuum_work_mem = '${AUTOVACUUM_WORK_MEM_MB}MB'
huge_pages = try

# Planner and I/O
random_page_cost = $RANDOM_PAGE_COST
effective_io_concurrency = $EFFECTIVE_IO_CONCURRENCY
maintenance_io_concurrency = $MAINTENANCE_IO_CONCURRENCY

# WAL and checkpoints: durability remains fully enabled
fsync = on
full_page_writes = on
synchronous_commit = on
wal_compression = on
checkpoint_timeout = '15min'
checkpoint_completion_target = 0.9
min_wal_size = '$MIN_WAL_SIZE'
max_wal_size = '$MAX_WAL_SIZE'

# Parallelism
max_worker_processes = $MAX_WORKER_PROCESSES
max_parallel_workers = $MAX_PARALLEL_WORKERS
max_parallel_workers_per_gather = $MAX_PARALLEL_WORKERS_PER_GATHER
max_parallel_maintenance_workers = $MAX_PARALLEL_MAINTENANCE_WORKERS

# Autovacuum
track_counts = on
autovacuum = on
autovacuum_max_workers = $AUTOVACUUM_MAX_WORKERS
autovacuum_naptime = '30s'
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

# Diagnostics and slow-query logging
track_io_timing = on
track_wal_io_timing = on
compute_query_id = auto
log_min_duration_statement = '$SLOW_QUERY_THRESHOLD'
log_lock_waits = on
log_checkpoints = on
log_connections = 'authorization'
log_disconnections = on
log_temp_files = '10MB'
log_autovacuum_min_duration = '1s'
log_line_prefix = '%m [%p] %q%u@%d %r '

# Session safety
timezone = '$TIMEZONE'
log_timezone = '$TIMEZONE'
idle_in_transaction_session_timeout = '5min'
EOF
"${SUDO[@]}" install -o postgres -g postgres -m 0640 "$TUNING_TMP" "$TUNING_CONF"

# Ubuntu's postgresql.conf normally already includes conf.d. Add it only if absent.
if ! "${SUDO[@]}" grep -Eq "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf\.d'" "$POSTGRESQL_CONF"; then
  printf "\ninclude_dir = 'conf.d'\n" | "${SUDO[@]}" tee -a "$POSTGRESQL_CONF" >/dev/null
fi

HBA_TMP=$(mktemp)
TMP_FILES+=("$HBA_TMP")
cat > "$HBA_TMP" <<EOF
# Managed by $SCRIPT_NAME on $(date --iso-8601=seconds)
# TYPE      DATABASE        USER             ADDRESS                 METHOD

# Local operating-system administration for the postgres account.
local       all             postgres                                 peer

# Other Unix-socket users must authenticate with SCRAM.
local       all             all                                      scram-sha-256

# Password access for the postgres superuser is localhost-only.
host        postgres        postgres         127.0.0.1/32            scram-sha-256

# Application access from this server over loopback.
host        $DB_NAME        $DB_USER         127.0.0.1/32            scram-sha-256

# Permit encrypted password authentication from any IPv4 source.
# Source-IP restriction is enforced only by UFW, not by pg_hba.conf.
hostssl     all             all              0.0.0.0/0               scram-sha-256

# Do not permit unencrypted remote TCP connections.
host        all             all              0.0.0.0/0               reject
host        all             all              ::/0                    reject
EOF
"${SUDO[@]}" install -o postgres -g postgres -m 0640 "$HBA_TMP" "$PG_HBA_CONF"
CONFIG_WAS_CHANGED=1

info 'Validating PostgreSQL configuration before restart ...'
if ! run_as_user postgres "$PG_BIN/postgres" -D "$DATA_DIR" \
  -C max_connections -c "config_file=$POSTGRESQL_CONF" >/dev/null; then
  restore_postgresql_config
  die 'postgresql.conf validation failed. Original configuration was restored.'
fi

HBA_ERROR_COUNT=$(run_as_user postgres "$PG_BIN/psql" --no-psqlrc -Atqc \
  "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;" postgres)
if [[ "$HBA_ERROR_COUNT" != '0' ]]; then
  run_as_user postgres "$PG_BIN/psql" --no-psqlrc -P pager=off -c \
    "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;" postgres || true
  restore_postgresql_config
  die 'pg_hba.conf validation failed. Original configuration was restored.'
fi

if ! "${SUDO[@]}" systemctl restart "postgresql@${DB_VERSION}-main"; then
  restore_postgresql_config
  die 'PostgreSQL could not restart with the new configuration. Original configuration was restored.'
fi

systemctl is-active --quiet "postgresql@${DB_VERSION}-main" || die 'PostgreSQL service is not active after restart.'
run_as_user postgres "$PG_BIN/psql" --no-psqlrc -Atqc 'SELECT 1;' postgres | grep -qx '1' || die 'Local PostgreSQL administrator test failed.'
PGPASSWORD="$DB_PASSWORD" "$PG_BIN/psql" --no-psqlrc \
  "host=127.0.0.1 port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=$DB_SSLMODE connect_timeout=5" \
  -Atqc 'SELECT current_database(), current_user;' >/dev/null || die 'Application credential test failed.'

# ------------------------------ Firewall ------------------------------

info 'Configuring UFW without IPv6 rules ...'
set_ufw_ipv6_disabled

"${SUDO[@]}" ufw default deny incoming
"${SUDO[@]}" ufw default allow outgoing
"${SUDO[@]}" ufw allow "${SSH_PORT}/tcp" comment 'SSH'
if (( REMOTE_DATABASE )); then
  "${SUDO[@]}" ufw allow from "$ALLOW_REMOTE_IP" to any port "$DB_PORT" proto tcp comment 'PostgreSQL allowed source'
fi
"${SUDO[@]}" ufw --force disable >/dev/null 2>&1 || true
"${SUDO[@]}" ufw --force enable
"${SUDO[@]}" ufw reload

# ------------------------------ Credentials and final checks ------------------------------

INSTALLED_VERSION=$("$PG_BIN/psql" --version)
ACTIVE_LISTEN=$(run_as_user postgres "$PG_BIN/psql" --no-psqlrc -Atqc "SHOW listen_addresses;" postgres)
ACTIVE_MAX_CONNECTIONS=$(run_as_user postgres "$PG_BIN/psql" --no-psqlrc -Atqc "SHOW max_connections;" postgres)
ACTIVE_PASSWORD_ENCRYPTION=$(run_as_user postgres "$PG_BIN/psql" --no-psqlrc -Atqc "SHOW password_encryption;" postgres)
ACTIVE_SLOW_QUERY=$(run_as_user postgres "$PG_BIN/psql" --no-psqlrc -Atqc "SHOW log_min_duration_statement;" postgres)

CREDENTIALS_DIR="/home/${ORANGT_USER}/.orangt-credentials"
CREDENTIALS_FILE="${CREDENTIALS_DIR}/postgresql-${CLIENT_CODE}-${SELECTED_ENV}.txt"
"${SUDO[@]}" install -d -o "$ORANGT_USER" -g "$(id -gn "$ORANGT_USER")" -m 0700 "$CREDENTIALS_DIR"
cat > "$CREDENTIALS_FILE" <<EOF
DATABASE LOGIN INFORMATION
==========================
Generated             : $(date --iso-8601=seconds)
Client code           : $CLIENT_CODE
Database environment  : $SERVER_ENVIRONMENT
Hostname              : $HOST_NAME
Database server IPv4  : $LOCAL_IP
PostgreSQL            : $INSTALLED_VERSION
Port                  : $DB_PORT
Storage profile       : $STORAGE_PROFILE
Max connections       : $ACTIVE_MAX_CONNECTIONS
Slow-query threshold  : $ACTIVE_SLOW_QUERY

POSTGRESQL SUPERUSER (LOCALHOST TCP ONLY)
----------------------------------------
Host                  : 127.0.0.1
Database              : postgres
Username              : postgres
Password              : $POSTGRES_PASSWORD

WEB APPLICATION DATABASE CONFIG (.env)
--------------------------------------
DB_CONNECTION=pgsql
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD='$DB_PASSWORD'
DB_SSLMODE=$DB_SSLMODE

ADMIN LOGIN EXAMPLE
-------------------
psql -h 127.0.0.1 -p $DB_PORT -U postgres -d postgres

APPLICATION LOGIN EXAMPLE
-------------------------
psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME
EOF
chmod 0600 "$CREDENTIALS_FILE"
"${SUDO[@]}" chown "$ORANGT_USER:$(id -gn "$ORANGT_USER")" "$CREDENTIALS_FILE"

info 'PostgreSQL installation completed successfully.'
printf '  Installed version       : %s\n' "$INSTALLED_VERSION"
printf '  Service                 : active\n'
printf '  Listen addresses        : %s\n' "$ACTIVE_LISTEN"
printf '  Max connections         : %s\n' "$ACTIVE_MAX_CONNECTIONS"
printf '  Password encryption     : %s\n' "$ACTIVE_PASSWORD_ENCRYPTION"
printf '  Slow-query threshold    : %s\n' "$ACTIVE_SLOW_QUERY"
printf '  PostgreSQL config       : %s\n' "$TUNING_CONF"
printf '  Client authentication   : %s\n' "$PG_HBA_CONF"
printf '  PostgreSQL logs         : /var/log/postgresql/postgresql-%s-main.log\n' "$DB_VERSION"
printf '  Credentials file        : %s (mode 600)\n' "$CREDENTIALS_FILE"
printf '\n'
"${SUDO[@]}" ufw status verbose

info 'DATABASE LOGIN INFORMATION'
cat "$CREDENTIALS_FILE"
warn 'Protect the credentials file and copy it to your secure password manager.'
