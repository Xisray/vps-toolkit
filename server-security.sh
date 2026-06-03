#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

function error() {
  echo -e "${RED}[ERROR] $* ${NC}" >&2
}

function info() {
  echo -e "${BLUE}$* ${NC}"
}

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root!"
  exit 1
fi

declare -A __used_ports
declare -A __used_strings

function read_or_default() {
  local var_name="$1"
  local prompt="$2"
  local default_value="$3"
  local __rod_input

  [[ -n "$default_value" ]] && prompt+=" [default: $default_value]"
  prompt+=":"

  read -r -p "$prompt" __rod_input
  __rod_input="${__rod_input#"${__rod_input%%[![:space:]]*}"}"
  __rod_input="${__rod_input%"${__rod_input##*[![:space:]]*}"}"

  if [[ -z $__rod_input ]]; then
    printf -v "$var_name" "%s" "$default_value"
  else
    printf -v "$var_name" "%s" "$__rod_input"
  fi
}

function read_non_empty() {
  local var_name="$1"
  local prompt="$2: "
  local __rne_input
  while true; do
    read -r -p "$prompt" __rne_input
    __rne_input="${__rne_input#"${__rne_input%%[![:space:]]*}"}"
    __rne_input="${__rne_input%"${__rne_input##*[![:space:]]*}"}"

    if [[ -n "$__rne_input" ]]; then
      break
    fi
  done
  printf -v "$var_name" "%s" "$__rne_input"
}

function get_port() { echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 )); }

function gen_random_string() {
  local length="${1:-12}"
  local unique="${2:-false}"
  local candidate
  while true; do
    candidate=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c "$length")
    if [[ "$unique" != "true" ]]; then
      echo "$candidate"
      return 0
    fi
    if [[ -z "${__used_strings[$candidate]}" ]]; then
      __used_strings[$candidate]=1
      echo "$candidate"
      return 0
    fi
  done
}

function is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

function is_occupied_port() {
	ss -lnt "( sport = :$1 )" | grep -q ":$1"
}

function get_valid_port() {
  local port
	while true; do
		port=$(get_port)
		if ! is_occupied_port "$port" && [[ -z "${__used_ports[$port]}" ]]; then
      __used_ports[$port]=1
			echo "$port"
			return 0
		fi
	done
}

function read_port() {
  local prompt="$1"
  local default_port="$2"
  local port

  if [[ -n "$default_port" ]]; then
    if ! is_valid_port "$default_port" || is_occupied_port "$default_port"; then
      default_port=""
    fi
  fi

  while true; do
    read_or_default port "$prompt" "$default_port"
    port="${port//[[:space:]]/}"
    if [[ -z "$port" && -n "$default_port" ]]; then
      echo "$default_port"
      return 0
    fi
    if ! is_valid_port "$port"; then
      error "Invalid port. Пожалуйста вводите числа между 1 и 65535."
      continue
    fi

    if is_occupied_port "$port"; then
      error "Port '$port' уже используется."
      continue
    fi
    echo "$port"
    return 0
  done
}

function get_ssh_config() {
  local key="${1,,}"
  sshd -T | awk -v key="$key" '$1 == key {print $2}'
}

function set_ssh_config() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  [[ ! -f "${file}.bak" ]] && cp "$file" "${file}.bak"

  if grep -qiE "^[#]*\s*${key}\b" "$file"; then
    sed -i -E "s|^[#]*\s*${key}\b.*|${key} ${value}|I" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

function add_user_pubkey() {
  local username="$1"
  if ! id "$username" &>/dev/null; then
    error "User '$username' not found!"
    return 1
  fi

  mkdir -p "/home/$username/.ssh"
  local ssh_key
  read_non_empty ssh_key "Enter pubkey"

  echo "$ssh_key" >> "/home/$username/.ssh/authorized_keys"

  chmod 700 "/home/$username/.ssh"
  chmod 600 "/home/$username/.ssh/authorized_keys"

  chown -R "$username:$username" "/home/$username/.ssh"
}

function create_user() {
  local default_user
  while true; do
    default_user=$(gen_random_string 10)
    ! id "$default_user" &>/dev/null && break
  done

  local username
  while true; do
    read_or_default username "Enter username" "$default_user"
    username="${username//[[:space:]]/}"
    if [[ -z $username ]]; then
      username="$default_user"
    fi
    if id "$username" &>/dev/null; then
      error "User '$username' уже существует!"
      continue
    fi
    break
  done

  local admin_group="sudo"
  if ! getent group sudo &>/dev/null; then
    admin_group="wheel"
  fi

  if useradd -m -s /bin/bash -G "$admin_group" "$username"; then
    info "User '$username' успешно создан." >&2
    info "Enter password for user '$username'" >&2
    passwd "$username"
  else
    error "Что-то пошло не так при создании пользователя '$username'"
    return 1
  fi

  add_user_pubkey "$username"

  echo "$username"
}

function change_ssh_port() {
  local new_port=$(read_port "Enter port" "$(get_valid_port)")
  local old_port=$(get_ssh_config "Port")
  echo "$new_port"
  [[ "$old_port" == "$new_port" ]] && return 0
  set_ssh_config "Port" "$new_port"
  if command -v ufw >/dev/null; then
    ufw allow "$new_port"/tcp >/dev/null
    ufw --force delete allow "$old_port"/tcp >/dev/null
  fi
}

apt update && apt upgrade -y
apt -y install ufw sudo
sed -i '/^Include/d' "/etc/ssh/sshd_config"
set_ssh_config "PubkeyAuthentication" "yes"
set_ssh_config "PasswordAuthentication" "no"
set_ssh_config "PermitRootLogin" "no"
change_ssh_port
create_user
ufw --force enable

if systemctl list-unit-files | grep -q '^sshd\.service'; then
  systemctl restart sshd
else
  systemctl restart ssh
fi

CRON_JOB='37 4 * * 0 /usr/sbin/reboot'
(
    crontab -l 2>/dev/null | grep -Fv "$CRON_JOB"
    echo "$CRON_JOB"
) | crontab -
