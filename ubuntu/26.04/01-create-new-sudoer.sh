#!/usr/bin/env bash

# 01-create-new-sudoer.sh
# Create a sudo-enabled Linux user and an SSH keypair.
# Revised: 2026-10-29 09-31-07
# prepared by dicky.dwijanto@myspsolution.com
# Usage: bash 01-create-new-sudoer.sh

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
# LINUX_VERSION_CHECK="24.04"

CREATE_USER=""
OS_INFO=""
GENERATED_PASSWORD=""
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

configure_privilege() {
  if (( EUID == 0 )); then
    command -v runuser >/dev/null 2>&1 || {
      error 'Root execution requires runuser to run SSH setup as the new account.'
      exit 1
    }
    return
  fi

  SUDO_BIN=$(type -P sudo || true)
  [[ -n "$SUDO_BIN" ]] || {
    error 'This script requires root access or an authorized sudo account.'
    printf '%s\n' 'Start an authorized session, then run: bash 01-create-new-sudoer.sh' >&2
    exit 1
  }

  if [[ -t 0 && -t 2 ]]; then
    if ! "$SUDO_BIN" -v; then
      error 'Sudo authentication was cancelled or failed. No changes were made.'
      exit 1
    fi
  else
    SUDO_OPTIONS=(-n)
    if ! "$SUDO_BIN" -n -v 2>/dev/null; then
      error 'Noninteractive sudo authentication is unavailable. No changes were made.'
      exit 1
    fi
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
  if ! "$SUDO_BIN" "${SUDO_OPTIONS[@]}" -l -- "$command_path" "$@" >/dev/null 2>&1; then
    error "Sudo is not authorized for the required command: ${command_path} $*"
    exit 1
  fi
}

require_sudo_as_user() {
  local target_user="$1"
  local command_name="$2"
  local command_path
  local runuser_path
  shift 2

  (( EUID != 0 )) || return
  command_path=$(type -P "$command_name" || true)
  runuser_path=$(type -P runuser || true)
  [[ -n "$command_path" ]] || {
    error "Required command is unavailable: ${command_name}"
    exit 1
  }
  [[ -n "$runuser_path" ]] || {
    error 'The required runuser command is unavailable.'
    exit 1
  }
  if ! "$SUDO_BIN" "${SUDO_OPTIONS[@]}" -l -- "$runuser_path" \
    -u "$target_user" -- "$command_path" "$@" >/dev/null 2>&1; then
    error "Sudo is not authorized to run ${command_path} as ${target_user}."
    exit 1
  fi
}

preflight_privileged_commands() {
  local target_user="$1"
  local ssh_dir="/home/${target_user}/.ssh"

  if [[ -d "/home/${target_user}" ]]; then
    require_sudo_command usermod -aG sudo "$target_user"
    return
  fi

  require_sudo_command useradd -m "$target_user"
  require_sudo_command chpasswd
  require_sudo_command usermod -aG sudo "$target_user"
  require_sudo_command chsh -s /bin/bash "$target_user"
  require_sudo_as_user "$target_user" mkdir -p "$ssh_dir"
  require_sudo_command chmod 700 "$ssh_dir"
  require_sudo_command rm -f "$ssh_dir/${target_user}_private_key_temp"
  require_sudo_command rm -f "$ssh_dir/${target_user}_private_key_temp.pub"
  require_sudo_as_user "$target_user" ssh-keygen -t ed25519 -N '' \
    -C "default key for ${target_user}" \
    -f "$ssh_dir/${target_user}_private_key_temp"
  require_sudo_command chown "${target_user}:${target_user}" "$ssh_dir/authorized_keys"
  require_sudo_command chmod 600 "$ssh_dir/authorized_keys"
  require_sudo_command tee "/etc/sudoers.d/${target_user}"
  require_sudo_command chmod 0440 "/etc/sudoers.d/${target_user}"
  require_sudo_command cat "$ssh_dir/${target_user}_private_key_temp"
  require_sudo_command cat "$ssh_dir/${target_user}_private_key_temp.pub"
}

# Preserve command-level elevation while allowing an already-root process to
# run commands directly. User-context commands use runuser when sudo is absent.
sudo() {
  if (( EUID == 0 )); then
    if [[ "${1:-}" == '-u' ]]; then
      local target_user="$2"
      shift 2
      command runuser -u "$target_user" -- "$@"
    else
      command "$@"
    fi
  else
    if [[ "${1:-}" == '-u' ]]; then
      local target_user="$2"
      shift 2
      command "$SUDO_BIN" "${SUDO_OPTIONS[@]}" runuser -u "$target_user" -- "$@"
    else
      command "$SUDO_BIN" "${SUDO_OPTIONS[@]}" "$@"
    fi
  fi
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

# ---------------- Starting script ----------------

OS_INFO=$(awk -F= '$1 == "PRETTY_NAME" {sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print}' /etc/os-release)

# ---------------- Preliminary validation ----------------

if [[ "${OS_INFO,,}" != *"$LINUX_DISTRO_CHECK"* ]]; then
  error "This installation script must be run on ${LINUX_DISTRO_CHECK} only."
  printf 'Your detected OS: %s\n' "$OS_INFO" >&2
  exit 1
fi

[[ -t 0 ]] || {
  error 'This script requires an interactive terminal.'
  exit 1
}
if [[ -t 1 && "${TERM:-dumb}" != 'dumb' ]]; then
  clear
fi

printf '\n'
while [[ -z "$CREATE_USER" ]]; do
  read_input 'Enter the new username to create as a sudoer:' CREATE_USER || exit 1
  if [[ "$CREATE_USER" != *[![:space:]]* ]]; then
    CREATE_USER=""
    warn 'A username is required.'
  fi
done

if ! confirm_yes_no "Create sudoer '$CREATE_USER'?"; then
  printf '\n'
  exit 0
fi

# Linux version checking remains disabled, as in the original script.
configure_privilege
preflight_privileged_commands "$CREATE_USER"

if [[ -d "/home/${CREATE_USER}" ]]; then
  warn "User ${CREATE_USER} already exists."
  info "Ensuring ${CREATE_USER} is a sudoer..."
  printf 'sudo usermod -aG sudo %s\n' "$CREATE_USER"
  sudo usermod -aG sudo "$CREATE_USER"
  printf '%s\n' 'User creation is aborted.'
  exit 0
fi

warn 'Before proceeding, make sure you can copy terminal text and save it to a file.'
printf 'The following will create user %s and generate a random secure keypair.\n' "$CREATE_USER"
printf '%s\n' 'Login information, including the keypair, will be shown on this screen.'
if ! confirm_yes_no 'Ready to continue?'; then
  printf '\n'
  exit 0
fi

info "Creating Linux user ${CREATE_USER}..."
printf 'sudo useradd -m %s\n' "$CREATE_USER"
if ! sudo useradd -m "$CREATE_USER"; then
  error "Error creating new user: ${CREATE_USER}"
  exit 1
fi

# Create a random, unused password; login requires the SSH keypair.
GENERATED_PASSWORD=$(openssl rand -base64 32)
if ! printf '%s:%s\n' "$CREATE_USER" "$GENERATED_PASSWORD" | sudo chpasswd; then
  error "Error setting the generated password for ${CREATE_USER}."
  exit 1
fi

info "Making ${CREATE_USER} a sudoer..."
printf 'sudo usermod -aG sudo %s\n' "$CREATE_USER"
if ! sudo usermod -aG sudo "$CREATE_USER"; then
  error "Failed to add ${CREATE_USER} as sudoer."
  warn 'You may have to make the user a sudoer manually.'
fi

info "Changing the default login shell for ${CREATE_USER} to bash..."
printf 'sudo chsh -s /bin/bash %s\n' "$CREATE_USER"
sudo chsh -s /bin/bash "$CREATE_USER"
sudo -u "$CREATE_USER" mkdir -p "/home/${CREATE_USER}/.ssh"

info "Creating an SSH keypair for ${CREATE_USER}..."
sudo chmod 700 "/home/${CREATE_USER}/.ssh"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub"
sudo -u "$CREATE_USER" ssh-keygen -t ed25519 -N "" -C "default key for ${CREATE_USER}" -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"

if [[ -f "/home/${CREATE_USER}/.ssh/authorized_keys" ]]; then
  sudo -u "$CREATE_USER" bash -c 'grep -qxFf "$1" "$2" || cat "$1" >> "$2"' _ \
    "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub" \
    "/home/${CREATE_USER}/.ssh/authorized_keys"
else
  sudo -u "$CREATE_USER" bash -c 'cat "$1" > "$2"' _ \
    "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub" \
    "/home/${CREATE_USER}/.ssh/authorized_keys"
fi

sudo chown "${CREATE_USER}:${CREATE_USER}" "/home/${CREATE_USER}/.ssh/authorized_keys"
sudo chmod 600 "/home/${CREATE_USER}/.ssh/authorized_keys"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$CREATE_USER" | sudo tee "/etc/sudoers.d/${CREATE_USER}"
sudo chmod 0440 "/etc/sudoers.d/${CREATE_USER}"

HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')
THE_DATE=$(date)

warn 'This login information will be shown only once. Copy it and save it to a file.'
printf '%s\n' '**********************************************************************'
printf '\n'
info 'LOGIN INFORMATION'
printf '\n'
printf '%s\n' 'server environment : (define later)'
printf 'hostname           : %s\n' "$HOSTNAME"
printf 'local ip address   : %s\n' "$LOCAL_IP"
printf 'user login         : %s\n' "$CREATE_USER"
printf 'private key        :\n\n'
sudo cat "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"
printf '\npublic key         :\n\n'
sudo cat "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub"
printf '\nlast update        : %s\n\n' "$THE_DATE"
printf '%s\n' '**********************************************************************'
warn 'Make sure you have copied the information above.'
warn "A login shell for ${CREATE_USER} will start in this terminal. Type exit to return to your original session."
read_input 'Press [Enter] when you are ready to switch users:' REPLY || exit 1
if (( EUID == 0 )); then
  if ! command runuser -l "$CREATE_USER"; then
    error "Could not start a login shell for ${CREATE_USER}. Your original session remains open."
    exit 1
  fi
else
  if ! "$SUDO_BIN" -i -u "$CREATE_USER"; then
    error "Could not start a login shell for ${CREATE_USER}. Your original session remains open."
    exit 1
  fi
fi
