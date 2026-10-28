#!/usr/bin/env bash

# 02-install-mariadb-server-ubuntu-26.04-v7.sh
# Interactive MariaDB installer for Ubuntu Server 26.04 LTS (Resolute).
# Revised: 2026-09-09 22-21-30
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 02-install-mariadb-server-ubuntu-26.04-v7.sh
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

readonly REQUIRED_OS_ID="ubuntu"
readonly REQUIRED_OS_VERSION="26.04"
readonly EXPECTED_MARIADB_SERIES="11.8"
readonly DB_PORT="3306"
readonly SSH_PORT="22"
readonly SLOW_QUERY_TIME_SECONDS="2.0"
readonly SLOW_QUERY_MIN_ROWS="0"
readonly SLOW_LOG_FILE="/var/log/mysql/mariadb-slow.log"
readonly SLOW_LOG_ROTATE_COUNT="7"
readonly MAX_CONNECTIONS_TARGET="300"
readonly FORCE_STORAGE_PROFILE="ssd"
readonly TARGET_TIMEZONE="Asia/Jakarta"
readonly GENERATED_PASSWORD_LENGTH="40"

# yes: rebuild UFW so this server exposes only the ports required by its role.
# no : preserve existing UFW rules and only add the required rules.
readonly RESET_UFW_RULES="yes"

TEMP_FILES=()
ROOT_TEMP_FILES=()
DB_PASSWORD_ROOT=""
DB_PASSWORD=""
ROOT_CLIENT_FILE=""
ENV_NEEDS_WRITE=0
SUDO_BIN=""
SUDO_OPTIONS=()

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

fatal() {
  error "$*"
  exit 1
}

configure_privilege() {
  if (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 || fatal 'Root execution requires runuser for MariaDB account checks.'
    return
  fi

  SUDO_BIN=$(type -P sudo || true)
  [[ -n "$SUDO_BIN" ]] || fatal 'This installer requires root access or an authorized sudo account. Run: bash 02-install-mariadb-server-ubuntu-26.04-v7.sh'

  if [[ -t 0 && -t 2 ]]; then
    "$SUDO_BIN" -v || fatal 'Sudo authentication was cancelled or failed. No changes were made.'
  else
    SUDO_OPTIONS=(-n)
    "$SUDO_BIN" -n -v 2>/dev/null || fatal 'Noninteractive sudo authentication is unavailable. No changes were made.'
  fi

}

require_sudo_command() {
  local command_name="$1"
  local command_path
  shift

  (( EUID != 0 )) || return
  command_path=$(type -P "$command_name" || true)
  [[ -n "$command_path" ]] || fatal "Required command is unavailable: ${command_name}"
  "$SUDO_BIN" "${SUDO_OPTIONS[@]}" -l -- "$command_path" "$@" >/dev/null 2>&1 || \
    fatal "Sudo is not authorized for the required command: ${command_path} $*"
}

preflight_privileged_commands() {
  require_sudo_command timedatectl set-timezone "$TARGET_TIMEZONE"
  require_sudo_command systemctl enable --now mariadb
  require_sudo_command ufw --force reset
  require_sudo_command ufw default deny incoming
  require_sudo_command ufw default allow outgoing
  require_sudo_command ufw allow "${SSH_PORT}/tcp" comment SSH
  if [[ "$SERVER_ENVIRONMENT" == *-database ]]; then
    local remote_ip
    for remote_ip in "${REMOTE_APP_IPS[@]}"; do
      require_sudo_command ufw allow from "$remote_ip" to any port "$DB_PORT" \
        proto tcp comment 'MariaDB application access'
    done
  else
    require_sudo_command ufw allow 80/tcp comment HTTP
    require_sudo_command ufw allow 443/tcp comment HTTPS
  fi
  require_sudo_command ufw --force enable
  require_sudo_command ufw reload
}

preflight_bootstrap_commands() {
  require_sudo_command env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 update --error-on=any
  require_sudo_command env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates iproute2 logrotate openssl perl procps ufw software-properties-common
}

apt_update_strict() {
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=3 \
    -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 \
    update --error-on=any
}

verify_apt_error_mode() {
  apt-get update --error-on=any --print-uris >/dev/null 2>&1 || \
    fatal 'This apt-get version cannot make partial repository refresh failures fatal.'
}

preflight_installation() {
  command -v apt-get >/dev/null 2>&1 || fatal 'The required apt-get command is unavailable.'
  command -v apt-cache >/dev/null 2>&1 || fatal 'The required apt-cache command is unavailable.'
  verify_apt_error_mode
  configure_privilege
  preflight_bootstrap_commands
  info 'Installing local repository and service prerequisites...'
  apt_update_strict
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates iproute2 logrotate openssl perl procps ufw software-properties-common
  preflight_privileged_commands
}

# Route command-level elevation through the selected mode. Existing -n flags
# are normalized so interactive callers can authenticate again if necessary.
sudo() {
  local -a arguments=("$@")
  local target_user

  if [[ "${arguments[0]:-}" == '-n' ]]; then
    arguments=("${arguments[@]:1}")
  fi

  if (( EUID == 0 )); then
    if [[ "${arguments[0]:-}" == '-u' ]]; then
      target_user="${arguments[1]}"
      arguments=("${arguments[@]:2}")
      command runuser -u "$target_user" -- "${arguments[@]}"
    else
      command "${arguments[@]}"
    fi
  else
    command "$SUDO_BIN" "${SUDO_OPTIONS[@]}" "${arguments[@]}"
  fi
}

cleanup() {
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "$file" && -e "$file" ]] || continue
    if command -v shred >/dev/null 2>&1; then
      shred -u "$file" 2>/dev/null || rm -f "$file"
    else
      rm -f "$file"
    fi
  done

  for file in "${ROOT_TEMP_FILES[@]:-}"; do
    [[ -n "$file" ]] || continue
    sudo -n rm -f -- "$file" 2>/dev/null || true
  done

  DB_PASSWORD_ROOT=""
  DB_PASSWORD=""
  ROOT_CLIENT_FILE=""
}

on_error() {
  local exit_code=$?
  local line_no=$1
  local command_text=${2:-unknown}

  error "Installation failed at line ${line_no} (exit code ${exit_code})."
  printf 'Failed command: %s\n' "$command_text" >&2
  printf 'MariaDB status and recent logs may help:\n' >&2
  printf '  sudo systemctl status mariadb --no-pager -l\n' >&2
  printf '  sudo journalctl -u mariadb -n 100 --no-pager\n\n' >&2
  exit "$exit_code"
}

random_uint32() {
  local value
  value=$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')
  [[ "$value" =~ ^[0-9]+$ ]] || fatal "Unable to obtain secure random data from /dev/urandom."
  printf '%s' "$value"
}

random_char_from() {
  local charset=$1
  local random_value
  random_value=$(random_uint32)
  printf '%s' "${charset:$((random_value % ${#charset})):1}"
}

generate_secure_password() {
  local length=${1:-40}
  local lowercase='abcdefghijkmnopqrstuvwxyz'
  local uppercase='ABCDEFGHJKLMNPQRSTUVWXYZ'
  local digits='23456789'
  # Excludes quotes, backslash, whitespace, #, ;, $, and backticks so the
  # password remains safe in SQL literals, MariaDB option files, and .env.
  local symbols='!@%^*_-+:.?,'
  local all_chars="${lowercase}${uppercase}${digits}${symbols}"
  local password chars=()
  local i j random_value tmp
  local IFS=

  (( length >= 16 )) || fatal "Generated password length must be at least 16 characters."

  # Guarantee at least one character from every required class.
  password="$(random_char_from "$lowercase")"
  password+="$(random_char_from "$uppercase")"
  password+="$(random_char_from "$digits")"
  password+="$(random_char_from "$symbols")"

  while (( ${#password} < length )); do
    password+="$(random_char_from "$all_chars")"
  done

  # Fisher-Yates shuffle so the guaranteed characters are not in fixed positions.
  for ((i = 0; i < ${#password}; i++)); do
    chars+=("${password:i:1}")
  done
  for ((i = ${#chars[@]} - 1; i > 0; i--)); do
    random_value=$(random_uint32)
    j=$((random_value % (i + 1)))
    tmp=${chars[i]}
    chars[i]=${chars[j]}
    chars[j]=$tmp
  done

  printf '%s' "${chars[*]}"
}

valid_ipv4() {
  local ip=$1
  local a b c d extra octet

  IFS=. read -r a b c d extra <<< "$ip"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1

  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done

  a=$((10#$a))
  b=$((10#$b))
  c=$((10#$c))
  d=$((10#$d))

  # Reject unspecified, loopback, multicast/reserved, broadcast, and link-local addresses.
  (( a != 0 && a != 127 && a < 224 )) || return 1
  (( !(a == 169 && b == 254) )) || return 1
  (( !(a == 255 && b == 255 && c == 255 && d == 255) )) || return 1

  return 0
}

get_primary_ipv4() {
  local ip_addr
  ip_addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' || true)
  if [[ -z "$ip_addr" ]]; then
    ip_addr=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ {print; exit}' || true)
  fi
  printf '%s' "$ip_addr"
}

get_effective_cpu_count() {
  local cpu_count quota period quota_count

  cpu_count=$(nproc 2>/dev/null || true)
  [[ "$cpu_count" =~ ^[0-9]+$ && "$cpu_count" -ge 1 ]] || cpu_count=1

  # nproc normally respects affinity. Also cap by cgroup CPU quota when present.
  if [[ -r /sys/fs/cgroup/cpu.max ]]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
    if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] && (( period > 0 )); then
      quota_count=$(((quota + period - 1) / period))
      (( quota_count >= 1 )) || quota_count=1
      (( quota_count >= cpu_count )) || cpu_count=$quota_count
    fi
  elif [[ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us && -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]]; then
    quota=$(</sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(</sys/fs/cgroup/cpu/cpu.cfs_period_us)
    if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] && (( quota > 0 && period > 0 )); then
      quota_count=$(((quota + period - 1) / period))
      (( quota_count >= 1 )) || quota_count=1
      (( quota_count >= cpu_count )) || cpu_count=$quota_count
    fi
  fi

  printf '%s' "$cpu_count"
}

get_effective_memory_mb() {
  local host_kb effective_bytes limit_file limit_value

  host_kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
  [[ "$host_kb" =~ ^[0-9]+$ && "$host_kb" -gt 0 ]] || return 1
  effective_bytes=$((host_kb * 1024))

  # Respect common cgroup v2/v1 memory limits used by LXC and containers.
  for limit_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [[ -r "$limit_file" ]] || continue
    limit_value=$(<"$limit_file")
    if [[ "$limit_value" =~ ^[0-9]+$ ]] && \
      (( limit_value > 0 && limit_value < effective_bytes )); then
      effective_bytes=$limit_value
    fi
  done

  printf '%s' $((effective_bytes / 1024 / 1024))
}

detect_storage_profile() {
  # Storage is intentionally forced to SSD as requested. This avoids unreliable
  # rotational reporting from virtual disks, RAID controllers, SAN volumes,
  # cloud block devices, and some hypervisors where lsblk may report ROTA=1
  # even when the underlying storage is SSD-backed.
  STORAGE_PROFILE="${FORCE_STORAGE_PROFILE}"
  INNODB_IO_CAPACITY=1000
  INNODB_IO_CAPACITY_MAX=2000
  INNODB_FLUSH_NEIGHBORS=0
}

calculate_tuning() {
  local buffer_pool_percent reserve_mb max_buffer_pool_mb
  local memory_connection_cap cpu_connection_cap

  if [[ "$SERVER_ENVIRONMENT" == *-database ]]; then
    TUNING_PROFILE="dedicated-database"
    if (( RAM_TOTAL_MB < 2048 )); then
      buffer_pool_percent=35
    elif (( RAM_TOTAL_MB < 4096 )); then
      buffer_pool_percent=45
    elif (( RAM_TOTAL_MB < 8192 )); then
      buffer_pool_percent=55
    elif (( RAM_TOTAL_MB < 16384 )); then
      buffer_pool_percent=65
    else
      buffer_pool_percent=70
    fi
  else
    TUNING_PROFILE="shared-web-database"
    if (( RAM_TOTAL_MB < 2048 )); then
      buffer_pool_percent=20
    elif (( RAM_TOTAL_MB < 4096 )); then
      buffer_pool_percent=25
    elif (( RAM_TOTAL_MB < 8192 )); then
      buffer_pool_percent=30
    elif (( RAM_TOTAL_MB < 16384 )); then
      buffer_pool_percent=35
    else
      buffer_pool_percent=40
    fi
  fi

  INNODB_BUFFER_POOL_MB=$((RAM_TOTAL_MB * buffer_pool_percent / 100))

  if (( RAM_TOTAL_MB <= 2048 )); then
    reserve_mb=384
  elif (( RAM_TOTAL_MB <= 8192 )); then
    reserve_mb=768
  elif [[ "$TUNING_PROFILE" == "dedicated-database" ]]; then
    reserve_mb=1024
  else
    reserve_mb=2048
  fi

  max_buffer_pool_mb=$((RAM_TOTAL_MB - reserve_mb))
  (( max_buffer_pool_mb >= 128 )) || max_buffer_pool_mb=128
  (( INNODB_BUFFER_POOL_MB <= max_buffer_pool_mb )) || INNODB_BUFFER_POOL_MB=$max_buffer_pool_mb
  (( INNODB_BUFFER_POOL_MB >= 128 )) || INNODB_BUFFER_POOL_MB=128

  # Use stable 64 MiB increments for normal server sizes.
  if (( INNODB_BUFFER_POOL_MB >= 512 )); then
    INNODB_BUFFER_POOL_MB=$((INNODB_BUFFER_POOL_MB / 64 * 64))
  fi

  if (( RAM_TOTAL_MB < 2048 )); then
    memory_connection_cap=75
    TMP_TABLE_SIZE_MB=16
    TABLE_OPEN_CACHE=1000
    INNODB_LOG_FILE_SIZE_MB=128
    INNODB_LOG_BUFFER_SIZE_MB=16
    PERFORMANCE_SCHEMA_SETTING="OFF"
  elif (( RAM_TOTAL_MB < 4096 )); then
    memory_connection_cap=125
    TMP_TABLE_SIZE_MB=16
    TABLE_OPEN_CACHE=1500
    INNODB_LOG_FILE_SIZE_MB=128
    INNODB_LOG_BUFFER_SIZE_MB=16
    PERFORMANCE_SCHEMA_SETTING="ON"
  elif (( RAM_TOTAL_MB < 8192 )); then
    if [[ "$TUNING_PROFILE" == "dedicated-database" ]]; then
      memory_connection_cap=200
    else
      memory_connection_cap=150
    fi
    TMP_TABLE_SIZE_MB=32
    TABLE_OPEN_CACHE=2000
    INNODB_LOG_FILE_SIZE_MB=256
    INNODB_LOG_BUFFER_SIZE_MB=32
    PERFORMANCE_SCHEMA_SETTING="ON"
  elif (( RAM_TOTAL_MB < 16384 )); then
    if [[ "$TUNING_PROFILE" == "dedicated-database" ]]; then
      memory_connection_cap=300
    else
      memory_connection_cap=200
    fi
    TMP_TABLE_SIZE_MB=32
    TABLE_OPEN_CACHE=4000
    INNODB_LOG_FILE_SIZE_MB=512
    INNODB_LOG_BUFFER_SIZE_MB=32
    PERFORMANCE_SCHEMA_SETTING="ON"
  elif (( RAM_TOTAL_MB < 32768 )); then
    if [[ "$TUNING_PROFILE" == "dedicated-database" ]]; then
      memory_connection_cap=400
    else
      memory_connection_cap=250
    fi
    TMP_TABLE_SIZE_MB=64
    TABLE_OPEN_CACHE=6000
    INNODB_LOG_FILE_SIZE_MB=512
    INNODB_LOG_BUFFER_SIZE_MB=64
    PERFORMANCE_SCHEMA_SETTING="ON"
  else
    if [[ "$TUNING_PROFILE" == "dedicated-database" ]]; then
      memory_connection_cap=500
    else
      memory_connection_cap=300
    fi
    TMP_TABLE_SIZE_MB=64
    TABLE_OPEN_CACHE=8000
    INNODB_LOG_FILE_SIZE_MB=1024
    INNODB_LOG_BUFFER_SIZE_MB=64
    PERFORMANCE_SCHEMA_SETTING="ON"
  fi

  # Fixed operational target requested by the administrator. MariaDB does not
  # reserve all connection memory up front, but per-session buffers can still
  # make 300 busy connections memory-intensive under heavy concurrency.
  MAX_CONNECTIONS=${MAX_CONNECTIONS_TARGET}

  THREAD_CACHE_SIZE=$((MAX_CONNECTIONS / 3))
  (( THREAD_CACHE_SIZE >= 32 )) || THREAD_CACHE_SIZE=32
  (( THREAD_CACHE_SIZE <= 256 )) || THREAD_CACHE_SIZE=256
  TABLE_DEFINITION_CACHE=$TABLE_OPEN_CACHE

  detect_storage_profile
}

write_server_environment() {
  local env_file=$1
  local value=$2
  local tmp_file

  tmp_file=$(mktemp)
  TEMP_FILES+=("$tmp_file")

  if [[ -f "$env_file" ]]; then
    grep -v '^SERVER_ENVIRONMENT=' "$env_file" > "$tmp_file" || true
  fi
  printf 'SERVER_ENVIRONMENT=%s\n' "$value" >> "$tmp_file"

  install -m 0600 "$tmp_file" "$env_file"
}

add_ufw_rule() {
  sudo -n ufw "$@"
}

join_by() {
  local separator=$1
  shift
  local first=true
  local value
  for value in "$@"; do
    if [[ "$first" == true ]]; then
      printf '%s' "$value"
      first=false
    else
      printf '%s%s' "$separator" "$value"
    fi
  done
}

mariadb_root() {
  sudo -n mariadb --defaults-extra-file="$ROOT_CLIENT_FILE" "$@"
}

# ---------------- Starting script ----------------

trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
IFS=$'\n\t'
umask 077

# ---------------- Preliminary validation ----------------

[[ -t 0 ]] || fatal "This installer is interactive and requires a terminal."

# /etc/os-release is a trusted local operating-system metadata file.
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "$REQUIRED_OS_ID" ]] || fatal "Ubuntu is required; detected: ${PRETTY_NAME:-unknown}."
[[ "${VERSION_ID:-}" == "$REQUIRED_OS_VERSION" ]] || \
  fatal "Ubuntu ${REQUIRED_OS_VERSION} is required; detected: ${PRETTY_NAME:-unknown}."

if dpkg-query -W -f='${Status}\n' mariadb-server 2>/dev/null | grep -q 'installed'; then
  INSTALLED_VERSION=$(mariadb --version 2>/dev/null || true)
  fatal "MariaDB Server is already installed. No changes were made. ${INSTALLED_VERSION}"
fi

if command -v mariadbd >/dev/null 2>&1 || command -v mysqld >/dev/null 2>&1; then
  fatal "A database server binary already exists. Remove or migrate the existing installation manually first."
fi

CURRENT_USER=$(id -un)
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || fatal "Cannot determine the current user's home directory."

ENV_FILE="${USER_HOME}/server.env"

# Standardize the server clock before collecting timestamps or installing MariaDB.
CURRENT_TZ=$(timedatectl show -p Timezone --value)
if [[ "$CURRENT_TZ" != "$TARGET_TIMEZONE" ]]; then
  info "Server timezone will be changed from ${CURRENT_TZ:-unknown} to ${TARGET_TIMEZONE}."
fi

CLIENT_CODE=""
while [[ -z "$CLIENT_CODE" ]]; do
  printf '\n'
  read_input "Client code (3-12 lowercase alphanumeric characters):" code_input || exit 1
  if [[ ! "$code_input" =~ ^[a-z0-9]{3,12}$ ]]; then
    warn "Invalid client code. Example values: meta, microsoft, sps."
    continue
  fi

  if confirm_yes_no "Use client code '${code_input}'?"; then
    CLIENT_CODE=$code_input
  fi
done

SERVER_ENVIRONMENT=""
if [[ -f "$ENV_FILE" ]]; then
  STORED_ENV=$(sed -n 's/^SERVER_ENVIRONMENT=//p' "$ENV_FILE" | tail -n 1)
  if [[ "$STORED_ENV" =~ ^${CLIENT_CODE}-(dev|dev-database|production|production-database)$ ]]; then
    SERVER_ENVIRONMENT=$STORED_ENV
    info "Using saved environment: ${SERVER_ENVIRONMENT}"
  fi
fi

if [[ -z "$SERVER_ENVIRONMENT" ]]; then
  printf '\n'
  printf '%s\n' "Choose this server's role:" >&2
  printf '%s\n' "  1) dev                  (web application + database)" >&2
  printf '%s\n' "  2) dev-database         (database server only)" >&2
  printf '%s\n' "  3) production           (web application + database)" >&2
  printf '%s\n' "  4) production-database  (database server only)" >&2

  while true; do
    read_input "Choose an option [1-4]:" choice || exit 1
    [[ "$choice" =~ ^[1-4]$ ]] && break
    warn "Please enter 1, 2, 3, or 4."
  done

  case "$choice" in
    1)
      selected_env="dev"
      ;;
    2)
      selected_env="dev-database"
      ;;
    3)
      selected_env="production"
      ;;
    4)
      selected_env="production-database"
      ;;
  esac

  SERVER_ENVIRONMENT="${CLIENT_CODE}-${selected_env}"
  confirm_yes_no "Use environment '${SERVER_ENVIRONMENT}'?" || {
    warn "Installation cancelled."
    exit 1
  }
  ENV_NEEDS_WRITE=1
fi

HOST_NAME=$(hostname --fqdn 2>/dev/null || hostname)
LOCAL_IP=$(get_primary_ipv4)
valid_ipv4 "$LOCAL_IP" || fatal "Could not determine a valid primary IPv4 address."

REMOTE_APP_IPS=()
DB_ACCOUNT_HOSTS=()

if [[ "$SERVER_ENVIRONMENT" == *-database ]]; then
  DB_HOST="$LOCAL_IP"
  BIND_ADDRESS="$LOCAL_IP"

  printf '\n'
  printf '%s\n' "Enter one or more web-application IPv4 addresses allowed to connect." >&2
  printf '%s\n' "Separate multiple addresses with spaces or commas." >&2

  while true; do
    read_input "Allowed application IP address(es):" ip_input || exit 1
    ip_input=${ip_input//,/ }
    IFS=' ' read -r -a candidates <<< "$ip_input"

    REMOTE_APP_IPS=()
    declare -A seen_ips=()
    invalid_ip=""

    for candidate in "${candidates[@]:-}"; do
      [[ -n "$candidate" ]] || continue
      if ! valid_ipv4 "$candidate" || [[ "$candidate" == "$LOCAL_IP" ]]; then
        invalid_ip=$candidate
        break
      fi
      if [[ -z "${seen_ips[$candidate]+x}" ]]; then
        REMOTE_APP_IPS+=("$candidate")
        seen_ips[$candidate]=1
      fi
    done

    if [[ -n "$invalid_ip" || ${#REMOTE_APP_IPS[@]} -eq 0 ]]; then
      warn "Invalid address '${invalid_ip:-empty input}'. Enter valid non-local IPv4 addresses."
      continue
    fi

    printf "Allowed application IPs: " >&2
    join_by ', ' "${REMOTE_APP_IPS[@]}" >&2
    printf "\n" >&2
    confirm_yes_no "Continue with these addresses?" && break
  done

  DB_ACCOUNT_HOSTS=("${REMOTE_APP_IPS[@]}")
else
  DB_HOST="127.0.0.1"
  BIND_ADDRESS="127.0.0.1"
  DB_ACCOUNT_HOSTS=("127.0.0.1")
fi

if [[ "$SERVER_ENVIRONMENT" == *-dev || "$SERVER_ENVIRONMENT" == *-dev-database ]]; then
  DB_NAME="db_${CLIENT_CODE}_dev"
else
  DB_NAME="db_${CLIENT_CODE}_prod"
fi

CREDENTIALS_FILE="${USER_HOME}/${CLIENT_CODE}-mariadb-credentials.txt"
CONFIG_FILE="/etc/mysql/mariadb.conf.d/60-orangt-server.cnf"
PACKAGE_LOGROTATE_FILE="/etc/logrotate.d/mariadb"
CUSTOM_LOGROTATE_FILE="/etc/logrotate.d/orangt-mariadb-slow"

CPU_CORE_COUNT=$(get_effective_cpu_count)
RAM_TOTAL_MB=$(get_effective_memory_mb) || fatal "Cannot determine effective system memory."
(( RAM_TOTAL_MB >= 512 )) || fatal "At least 512 MiB of effective RAM is required. Detected: ${RAM_TOTAL_MB} MiB."
calculate_tuning

MYSQLTUNER_COMMAND="sudo mysqltuner --nocolor"
if [[ "$TUNING_PROFILE" == "shared-web-database" ]]; then
  MYSQLTUNER_COMMAND+=" --nondedicated"
fi

cat <<SUMMARY

Installation summary
--------------------
OS                 : ${PRETTY_NAME}
Server timezone    : ${CURRENT_TZ}
Environment        : ${SERVER_ENVIRONMENT}
Database name      : ${DB_NAME}
MariaDB bind IP    : ${BIND_ADDRESS}
Application DB host: ${DB_HOST}
Detected CPU       : ${CPU_CORE_COUNT} core(s)
Effective RAM      : ${RAM_TOTAL_MB} MiB
Tuning profile     : ${TUNING_PROFILE}
Storage profile    : ${STORAGE_PROFILE}
InnoDB buffer pool : ${INNODB_BUFFER_POOL_MB} MiB
Max connections    : ${MAX_CONNECTIONS}
Slow query log     : enabled, >= ${SLOW_QUERY_TIME_SECONDS} second(s)
Slow query file    : ${SLOW_LOG_FILE}
UFW rule reset     : ${RESET_UFW_RULES}

MariaDB root will use password authentication and remain restricted to localhost.
Root and application passwords will each contain ${GENERATED_PASSWORD_LENGTH} characters, including uppercase, lowercase, digits, and special characters.
The generated root password will be stored in the credentials file.
Administrative login:
  mariadb -u root -p

Application credentials will be saved with mode 0600 to:
  ${CREDENTIALS_FILE}
SUMMARY

confirm_yes_no "Start the installation?" || {
  warn "Installation cancelled."
  exit 1
}

preflight_installation

if [[ "$CURRENT_TZ" != "$TARGET_TIMEZONE" ]]; then
  info "Setting server timezone to ${TARGET_TIMEZONE}..."
  sudo -n timedatectl set-timezone "$TARGET_TIMEZONE"
fi
CURRENT_TZ=$(timedatectl show -p Timezone --value)
[[ "$CURRENT_TZ" == "$TARGET_TIMEZONE" ]] || \
  fatal "Failed to set the server timezone to ${TARGET_TIMEZONE}."
info "Server timezone: ${CURRENT_TZ}"

if (( ENV_NEEDS_WRITE )); then
  write_server_environment "$ENV_FILE" "$SERVER_ENVIRONMENT"
  info "Environment saved to ${ENV_FILE}."
fi

# ---------------- Package installation ----------------

# MariaDB and MySQLTuner are provided through Ubuntu's repositories.
if ! apt-cache show mariadb-server >/dev/null 2>&1 || ! apt-cache show mysqltuner >/dev/null 2>&1; then
  info "Enabling the Ubuntu universe repository..."
  require_sudo_command add-apt-repository -y universe
  sudo -n add-apt-repository -y universe
  apt_update_strict
fi

info "Installing MariaDB Server, client tools, and MySQLTuner-perl..."
# Ubuntu packages the Perl project MySQLTuner-perl under the package name "mysqltuner".
sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mariadb-server mariadb-client mysqltuner libjson-perl libtext-template-perl

sudo -n systemctl enable --now mariadb
sudo -n systemctl is-active --quiet mariadb

INSTALLED_VERSION=$(sudo -n mariadb --batch --skip-column-names -e 'SELECT VERSION();')
if [[ "$INSTALLED_VERSION" != ${EXPECTED_MARIADB_SERIES}.* ]]; then
  warn "Ubuntu installed MariaDB ${INSTALLED_VERSION}; expected the ${EXPECTED_MARIADB_SERIES}.x series. Continuing with Ubuntu's supported package."
fi

DB_USER="user_$(openssl rand -hex 8)"
DB_PASSWORD_ROOT=$(generate_secure_password "$GENERATED_PASSWORD_LENGTH")
DB_PASSWORD=$(generate_secure_password "$GENERATED_PASSWORD_LENGTH")

# Save the generated secret immediately so a later configuration failure does not lose it.
cat > "$CREDENTIALS_FILE" <<CREDS_PENDING
DATABASE INSTALLATION INFORMATION (INSTALLATION IN PROGRESS)
============================================================
Client code         : ${CLIENT_CODE}
Environment         : ${SERVER_ENVIRONMENT}
Hostname            : ${HOST_NAME}
Server IPv4         : ${LOCAL_IP}
MariaDB version     : ${INSTALLED_VERSION}
Server timezone     : ${CURRENT_TZ}
Password format     : ${GENERATED_PASSWORD_LENGTH} characters; uppercase, lowercase, digits, and special characters

ADMINISTRATION
--------------
MariaDB root host       : localhost only
MariaDB root auth       : password (unix_socket disabled)
MariaDB root username   : root
MariaDB root password   : ${DB_PASSWORD_ROOT}
Login command           : mariadb -u root -p

LARAVEL / WEB APPLICATION .env
------------------------------
DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD='${DB_PASSWORD}'
CREDS_PENDING
chmod 0600 "$CREDENTIALS_FILE"

# ---------------- MariaDB account hardening ----------------

DROP_USERS_SQL=$(mktemp)
TEMP_FILES+=("$DROP_USERS_SQL")

sudo -n mariadb --batch --skip-column-names -e \
  "SELECT CONCAT('DROP USER IF EXISTS ', QUOTE(User), '@', QUOTE(Host), ';')
   FROM mysql.user
   WHERE User = '' OR (User = 'root' AND Host <> 'localhost');" > "$DROP_USERS_SQL"

if [[ -s "$DROP_USERS_SQL" ]]; then
  sudo -n mariadb < "$DROP_USERS_SQL"
fi

APP_SQL=$(mktemp)
TEMP_FILES+=("$APP_SQL")

{
  printf 'DROP DATABASE IF EXISTS `test`;\n'
  printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$DB_NAME"

  for account_host in "${DB_ACCOUNT_HOSTS[@]}"; do
    printf "CREATE USER '%s'@'%s' IDENTIFIED BY '%s';\n" "$DB_USER" "$account_host" "$DB_PASSWORD"
    printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n" "$DB_NAME" "$DB_USER" "$account_host"
  done

  printf 'FLUSH PRIVILEGES;\n'
} > "$APP_SQL"

sudo -n mariadb < "$APP_SQL"

# Switch root@localhost from the Ubuntu/MariaDB unix_socket default to explicit
# password authentication. Omitting unix_socket from ALTER USER removes that
# authentication method on modern MariaDB releases.
ROOT_SQL=$(mktemp)
TEMP_FILES+=("$ROOT_SQL")
cat > "$ROOT_SQL" <<ROOTSQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${DB_PASSWORD_ROOT}');
FLUSH PRIVILEGES;
ROOTSQL
sudo -n mariadb < "$ROOT_SQL"

# All commands below this point authenticate with the generated root password.
# The secret stays in a mode-0600 option file instead of the process list.
ROOT_CLIENT_FILE=$(mktemp)
TEMP_FILES+=("$ROOT_CLIENT_FILE")
cat > "$ROOT_CLIENT_FILE" <<ROOTCLIENT
[client]
protocol=socket
user=root
password=${DB_PASSWORD_ROOT}
ROOTCLIENT
chmod 0600 "$ROOT_CLIENT_FILE"

mariadb_root --batch --skip-column-names -e "SELECT 1;" | grep -qx '1'

# Prove that passwordless unix_socket authentication is no longer accepted.
if sudo -n mariadb --no-defaults --protocol=socket --user=root --batch --skip-column-names \
  -e "SELECT 1;" >/dev/null 2>&1; then
  fatal "root@localhost still permits passwordless socket authentication."
fi

# ---------------- Server configuration ----------------

info "Preparing MariaDB slow-query logging..."
sudo -n install -d -o mysql -g adm -m 2750 "$(dirname "$SLOW_LOG_FILE")"
sudo -n touch "$SLOW_LOG_FILE"
sudo -n chown mysql:adm "$SLOW_LOG_FILE"
sudo -n chmod 0640 "$SLOW_LOG_FILE"

# Ubuntu's MariaDB package normally rotates /var/log/mysql/*.log. Reuse that
# rule when present, avoiding a duplicate-log definition in logrotate.
if [[ -f "$PACKAGE_LOGROTATE_FILE" ]] && \
  grep -Eq '/var/log/mysql/\*\.log|mariadb-slow\.log' "$PACKAGE_LOGROTATE_FILE"; then
  # The package rule already owns this log path, so do not create a duplicate
  # logrotate stanza. Set its retention to exactly the requested seven rotations.
  LOGROTATE_TMP=$(mktemp)
  TEMP_FILES+=("$LOGROTATE_TMP")
  cat "$PACKAGE_LOGROTATE_FILE" > "$LOGROTATE_TMP"

  if grep -Eq '^[[:space:]]*rotate[[:space:]]+[0-9]+' "$LOGROTATE_TMP"; then
    sed -Ei "s/^([[:space:]]*)rotate[[:space:]]+[0-9]+/\1rotate ${SLOW_LOG_ROTATE_COUNT}/" "$LOGROTATE_TMP"
  else
    awk -v count="$SLOW_LOG_ROTATE_COUNT" '
      !inserted && /\{/ { print; print "    rotate " count; inserted=1; next }
      { print }
    ' "$LOGROTATE_TMP" > "${LOGROTATE_TMP}.new"
    mv "${LOGROTATE_TMP}.new" "$LOGROTATE_TMP"
  fi

  chmod 0644 "$LOGROTATE_TMP"
  ROOT_LOGROTATE_TEST=$(sudo -n mktemp /etc/logrotate.d/.orangt-mariadb-test.XXXXXX)
  ROOT_TEMP_FILES+=("$ROOT_LOGROTATE_TEST")
  sudo -n install -o root -g root -m 0644 "$LOGROTATE_TMP" "$ROOT_LOGROTATE_TEST"
  if ! sudo -n logrotate --debug "$ROOT_LOGROTATE_TEST"; then
    fatal "The proposed MariaDB logrotate configuration is invalid: $PACKAGE_LOGROTATE_FILE"
  fi
  sudo -n install -o root -g root -m 0644 "$LOGROTATE_TMP" "$PACKAGE_LOGROTATE_FILE"
  SLOW_LOG_ROTATION_CONFIG="$PACKAGE_LOGROTATE_FILE"
  info "Using MariaDB package log rotation with ${SLOW_LOG_ROTATE_COUNT} retained rotations: ${SLOW_LOG_ROTATION_CONFIG}"
else
  LOGROTATE_TMP=$(mktemp)
  TEMP_FILES+=("$LOGROTATE_TMP")
  cat > "$LOGROTATE_TMP" <<LOGROTATE
${SLOW_LOG_FILE} {
    daily
    rotate ${SLOW_LOG_ROTATE_COUNT}
    missingok
    notifempty
    compress
    delaycompress
    create 0640 mysql adm
    copytruncate
}
LOGROTATE
  chmod 0644 "$LOGROTATE_TMP"
  ROOT_LOGROTATE_TEST=$(sudo -n mktemp /etc/logrotate.d/.orangt-mariadb-test.XXXXXX)
  ROOT_TEMP_FILES+=("$ROOT_LOGROTATE_TEST")
  sudo -n install -o root -g root -m 0644 "$LOGROTATE_TMP" "$ROOT_LOGROTATE_TEST"
  if ! sudo -n logrotate --debug "$ROOT_LOGROTATE_TEST"; then
    fatal "The proposed slow-log rotation configuration is invalid: $CUSTOM_LOGROTATE_FILE"
  fi
  sudo -n install -o root -g root -m 0644 "$LOGROTATE_TMP" "$CUSTOM_LOGROTATE_FILE"
  SLOW_LOG_ROTATION_CONFIG="$CUSTOM_LOGROTATE_FILE"
fi

CONFIG_TMP=$(mktemp)
TEMP_FILES+=("$CONFIG_TMP")

cat > "$CONFIG_TMP" <<CONFIG
# Managed by 02-install-mariadb-server-ubuntu-26.04-v7.sh
# Generated for ${CPU_CORE_COUNT} CPU core(s), ${RAM_TOTAL_MB} MiB effective RAM,
# and the ${TUNING_PROFILE} role. Treat these as safe initial values, then
# reassess with MySQLTuner after representative production workload has run.

[mariadbd]
# Network and defaults
bind-address = ${BIND_ADDRESS}
skip-name-resolve
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max_allowed_packet = 64M

# Slow-query logging: intentionally enabled by default.
log_output = FILE
slow_query_log = ON
slow_query_log_file = ${SLOW_LOG_FILE}
long_query_time = ${SLOW_QUERY_TIME_SECONDS}
min_examined_row_limit = ${SLOW_QUERY_MIN_ROWS}
log_queries_not_using_indexes = OFF
log_slow_verbosity = query_plan

# Hardware-aware conservative baseline.
max_connections = ${MAX_CONNECTIONS}
thread_cache_size = ${THREAD_CACHE_SIZE}
table_open_cache = ${TABLE_OPEN_CACHE}
table_definition_cache = ${TABLE_DEFINITION_CACHE}
tmp_table_size = ${TMP_TABLE_SIZE_MB}M
max_heap_table_size = ${TMP_TABLE_SIZE_MB}M
performance_schema = ${PERFORMANCE_SCHEMA_SETTING}
query_cache_type = 0
query_cache_size = 0

# InnoDB baseline. Durability defaults are deliberately not weakened.
innodb_buffer_pool_size = ${INNODB_BUFFER_POOL_MB}M
innodb_log_file_size = ${INNODB_LOG_FILE_SIZE_MB}M
innodb_log_buffer_size = ${INNODB_LOG_BUFFER_SIZE_MB}M
innodb_file_per_table = ON
innodb_buffer_pool_dump_at_shutdown = ON
innodb_buffer_pool_load_at_startup = ON
innodb_stats_on_metadata = OFF
innodb_io_capacity = ${INNODB_IO_CAPACITY}
innodb_io_capacity_max = ${INNODB_IO_CAPACITY_MAX}
innodb_flush_neighbors = ${INNODB_FLUSH_NEIGHBORS}
CONFIG

chmod 0644 "$CONFIG_TMP"

# Stage the candidate under /etc/mysql instead of asking the confined mariadbd
# process to read an arbitrary file from /tmp. Ubuntu's AppArmor policy and
# sudo execution context can make the old /tmp-based --verbose --help check
# fail even when the MariaDB options themselves are valid.
CONFIG_TEST_FILE=$(sudo -n mktemp /etc/mysql/mariadb.conf.d/.orangt-server-test.XXXXXX.cnf)
ROOT_TEMP_FILES+=("$CONFIG_TEST_FILE")
sudo -n install -o root -g root -m 0644 "$CONFIG_TMP" "$CONFIG_TEST_FILE"

CONFIG_VALIDATION_LOG=$(mktemp)
TEMP_FILES+=("$CONFIG_VALIDATION_LOG")
MARIADBD_BIN=$(command -v mariadbd)

# This is only an advisory parser check. The systemd restart below is the
# authoritative validation because it uses Ubuntu's complete packaged service
# environment, defaults, AppArmor profile, directories, and permissions.
if ! sudo -n "$MARIADBD_BIN" \
  --defaults-file="$CONFIG_TEST_FILE" \
  --user=mysql --verbose --help >"$CONFIG_VALIDATION_LOG" 2>&1; then
  warn "Standalone MariaDB option validation was inconclusive; continuing to the authoritative systemd restart check."
  sed -n '1,80p' "$CONFIG_VALIDATION_LOG" >&2 || true
fi

CONFIG_BACKUP_FILE=""
if sudo -n test -f "$CONFIG_FILE"; then
  CONFIG_BACKUP_FILE=$(sudo -n mktemp /etc/mysql/mariadb.conf.d/.60-orangt-server.backup.XXXXXX)
  ROOT_TEMP_FILES+=("$CONFIG_BACKUP_FILE")
  sudo -n cp -a "$CONFIG_FILE" "$CONFIG_BACKUP_FILE"
fi
sudo -n install -o root -g root -m 0644 "$CONFIG_TMP" "$CONFIG_FILE"

# ---------------- IPv4-only firewall ----------------

info "Configuring UFW..."

if grep -q '^IPV6=' /etc/default/ufw; then
  sudo -n sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
else
  printf 'IPV6=no\n' | sudo -n tee -a /etc/default/ufw >/dev/null
fi

if [[ "$RESET_UFW_RULES" == "yes" ]]; then
  sudo -n ufw --force reset
fi

sudo -n ufw default deny incoming
sudo -n ufw default allow outgoing
add_ufw_rule allow "${SSH_PORT}/tcp" comment 'SSH'

if [[ "$SERVER_ENVIRONMENT" == *-database ]]; then
  for remote_ip in "${REMOTE_APP_IPS[@]}"; do
    add_ufw_rule allow from "$remote_ip" to any port "$DB_PORT" proto tcp comment 'MariaDB application access'
  done
else
  add_ufw_rule allow 80/tcp comment 'HTTP'
  add_ufw_rule allow 443/tcp comment 'HTTPS'
fi

sudo -n ufw --force enable
sudo -n ufw reload

# Apply bind-address only after the firewall is active. A real service restart
# is the authoritative configuration test. Roll back automatically if it fails.
if ! sudo -n systemctl restart mariadb; then
  warn "MariaDB rejected the generated configuration. Restoring the previous configuration..."
  if [[ -n "$CONFIG_BACKUP_FILE" ]] && sudo -n test -f "$CONFIG_BACKUP_FILE"; then
    sudo -n cp -a "$CONFIG_BACKUP_FILE" "$CONFIG_FILE"
  else
    sudo -n rm -f "$CONFIG_FILE"
  fi

  sudo -n systemctl restart mariadb >/dev/null 2>&1 || true
  sudo -n systemctl status mariadb --no-pager -l >&2 || true
  sudo -n journalctl -u mariadb -n 100 --no-pager >&2 || true
  fatal "MariaDB could not start with the generated configuration. The previous configuration was restored."
fi
sudo -n systemctl is-active --quiet mariadb

# ---------------- Verification ----------------

LISTENING_ADDRESSES=$(sudo -n ss -ltnp | awk -v port=":${DB_PORT}" '$4 ~ port"$" {print $4}' | paste -sd, -)
[[ -n "$LISTENING_ADDRESSES" ]] || fatal "MariaDB is active but is not listening on TCP port ${DB_PORT}."

if [[ "$SERVER_ENVIRONMENT" != *-database ]]; then
  TEST_CLIENT_FILE=$(mktemp)
  TEMP_FILES+=("$TEST_CLIENT_FILE")
  cat > "$TEST_CLIENT_FILE" <<CLIENT
[client]
protocol=tcp
host=127.0.0.1
port=${DB_PORT}
user=${DB_USER}
password=${DB_PASSWORD}
CLIENT
  chmod 0600 "$TEST_CLIENT_FILE"
  mariadb --defaults-extra-file="$TEST_CLIENT_FILE" --batch --skip-column-names \
    -e "SELECT DATABASE();" "$DB_NAME" | grep -qx "$DB_NAME"
fi

ACCOUNT_COUNT=$(mariadb_root --batch --skip-column-names -e \
  "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}';")
[[ "$ACCOUNT_COUNT" -eq "${#DB_ACCOUNT_HOSTS[@]}" ]] || \
  fatal "Expected ${#DB_ACCOUNT_HOSTS[@]} application account(s), found ${ACCOUNT_COUNT}."

IFS=$'\t' read -r SLOW_LOG_ENABLED EFFECTIVE_SLOW_LOG EFFECTIVE_LONG_QUERY_TIME \
  EFFECTIVE_BUFFER_POOL_MB EFFECTIVE_MAX_CONNECTIONS < <(
    mariadb_root --batch --skip-column-names -e \
      "SELECT @@slow_query_log, @@slow_query_log_file, @@long_query_time, ROUND(@@innodb_buffer_pool_size/1024/1024), @@max_connections;"
  )

[[ "$SLOW_LOG_ENABLED" == "1" ]] || fatal "Slow-query logging is not enabled after restart."
[[ "$EFFECTIVE_SLOW_LOG" == "$SLOW_LOG_FILE" ]] || \
  fatal "Unexpected slow-query log path: ${EFFECTIVE_SLOW_LOG}."
sudo -n -u mysql test -w "$SLOW_LOG_FILE" || fatal "MariaDB cannot write to ${SLOW_LOG_FILE}."
command -v mysqltuner >/dev/null 2>&1 || fatal "MySQLTuner was not installed correctly."

IFS=$'\t' read -r ROOT_HOST ROOT_PLUGIN < <(
  mariadb_root --batch --skip-column-names -e \
    "SELECT Host, plugin FROM mysql.user WHERE User='root' AND Host='localhost';"
)
[[ "$ROOT_HOST" == "localhost" ]] || fatal "root@localhost account verification failed."
[[ "$ROOT_PLUGIN" == "mysql_native_password" ]] || \
  fatal "Unexpected root authentication plugin: ${ROOT_PLUGIN:-empty}."
REMOTE_ROOT_COUNT=$(mariadb_root --batch --skip-column-names -e \
  "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host <> 'localhost';")
[[ "$REMOTE_ROOT_COUNT" -eq 0 ]] || fatal "A non-local MariaDB root account still exists."

INSTALL_DATE=$(date --iso-8601=seconds)
ALLOWED_IP_TEXT="local only"
if [[ ${#REMOTE_APP_IPS[@]} -gt 0 ]]; then
  ALLOWED_IP_TEXT=$(join_by ', ' "${REMOTE_APP_IPS[@]}")
fi

cat > "$CREDENTIALS_FILE" <<CREDS
DATABASE INSTALLATION INFORMATION
=================================
Created             : ${INSTALL_DATE}
Client code         : ${CLIENT_CODE}
Environment         : ${SERVER_ENVIRONMENT}
Hostname            : ${HOST_NAME}
Server IPv4         : ${LOCAL_IP}
MariaDB version     : ${INSTALLED_VERSION}
Server timezone     : ${CURRENT_TZ}
Password format     : ${GENERATED_PASSWORD_LENGTH} characters; uppercase, lowercase, digits, and special characters
MariaDB listen      : ${LISTENING_ADDRESSES}
Allowed app IP(s)   : ${ALLOWED_IP_TEXT}
Detected CPU       : ${CPU_CORE_COUNT} core(s)
Effective RAM      : ${RAM_TOTAL_MB} MiB
Tuning profile     : ${TUNING_PROFILE}
Storage profile    : ${STORAGE_PROFILE}

PERFORMANCE BASELINE
--------------------
InnoDB buffer pool : ${EFFECTIVE_BUFFER_POOL_MB} MiB
Max connections    : ${EFFECTIVE_MAX_CONNECTIONS}
Temp table limit   : ${TMP_TABLE_SIZE_MB} MiB per connection
Table open cache   : ${TABLE_OPEN_CACHE}
Redo log file size : ${INNODB_LOG_FILE_SIZE_MB} MiB
I/O capacity       : ${INNODB_IO_CAPACITY} (max ${INNODB_IO_CAPACITY_MAX})
Flush neighbors    : ${INNODB_FLUSH_NEIGHBORS}
Performance schema : ${PERFORMANCE_SCHEMA_SETTING}

SLOW-QUERY LOG
--------------
Enabled            : yes
Threshold          : ${EFFECTIVE_LONG_QUERY_TIME} second(s)
Log file           : ${EFFECTIVE_SLOW_LOG}
Rotation config    : ${SLOW_LOG_ROTATION_CONFIG}
Retention           : ${SLOW_LOG_ROTATE_COUNT} rotations

MYSQLTUNER-PERL
---------------
Ubuntu package     : mysqltuner
When to run        : after at least 24-48 hours of representative workload
Run command        : ${MYSQLTUNER_COMMAND}
Login username     : root
Login password     : use the MariaDB root password shown below

How to use:
1. Run the command above from the Linux shell.
2. When MySQLTuner requests a database login, enter: root
3. Enter the generated MariaDB root password from ADMINISTRATION below.
4. Review recommendations carefully; do not apply every suggestion automatically.
5. After changing MariaDB settings, restart MariaDB and observe real workload again.

ADMINISTRATION
--------------
MariaDB root host       : localhost only
MariaDB root auth       : password (unix_socket disabled)
MariaDB root username   : root
MariaDB root password   : ${DB_PASSWORD_ROOT}
Login command           : mariadb -u root -p

LARAVEL / WEB APPLICATION .env
------------------------------
DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD='${DB_PASSWORD}'
CREDS

chmod 0600 "$CREDENTIALS_FILE"

printf "\n"
info "MariaDB installation completed successfully."
printf "MariaDB version : %s\n" "$INSTALLED_VERSION"
printf "Listening on    : %s\n" "$LISTENING_ADDRESSES"
printf "Slow query log  : %s (>= %s second(s))\n" "$EFFECTIVE_SLOW_LOG" "$EFFECTIVE_LONG_QUERY_TIME"
printf "Buffer pool     : %s MiB\n" "$EFFECTIVE_BUFFER_POOL_MB"
printf "Max connections : %s\n" "$EFFECTIVE_MAX_CONNECTIONS"
printf "Storage profile : %s\n" "$STORAGE_PROFILE"
printf "Credentials file: %s (mode 0600)\n" "$CREDENTIALS_FILE"
printf "\nUFW status:\n"
sudo -n ufw status verbose

printf "\nMySQLTuner-perl is installed from Ubuntu's mysqltuner package.\n"
printf "Allow 24-48 hours of representative workload before trusting its recommendations.\n"
printf "When prompted, enter login root and the generated MariaDB root password:\n"
printf "  %s\n\n" "$MYSQLTUNER_COMMAND"
