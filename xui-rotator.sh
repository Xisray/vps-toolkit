#!/bin/bash

LOG_FILE="/var/log/xui-rotator.log"

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root!"
  exit 1
fi

log() {
  local level="$1"
  local message="$2"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" | tee -a "$LOG_FILE"
}

XUIDB="/etc/x-ui/x-ui.db"
NGINX_CONF_DIR="/etc/nginx/sites-available"

CHANGE_SHORTIDS=false
CHANGE_WS=false
CHANGE_TROJAN=false
CHANGE_XHTTP=false
CHANGE_HYSTERIA=false
CHANGE_SNI=false

if [[ $# -eq 0 ]]; then
  CHANGE_SHORTIDS=true
  CHANGE_WS=true
  CHANGE_TROJAN=true
  CHANGE_XHTTP=true
  CHANGE_HYSTERIA=true
  CHANGE_SNI=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shortids)
      CHANGE_SHORTIDS=true
      ;;
    --ws)
      CHANGE_WS=true
      ;;
    --trojan)
      CHANGE_TROJAN=true
      ;;
    --xhttp)
      CHANGE_XHTTP=true
      ;;
    --hysteria)
      CHANGE_HYSTERIA=true
      ;;
    --sni)
      CHANGE_SNI=true
      ;;
    --all)
      CHANGE_SHORTIDS=true
      CHANGE_SNI=true
      CHANGE_WS=true
      CHANGE_TROJAN=true
      CHANGE_XHTTP=true
      ;;
    *)
      log "ERROR" "Неизвестный аргумент: $1"
      exit 1
      ;;
  esac
  shift
done

declare -A USED_PORTS
declare -A USED_STRINGS

generate_shortids() {
  local shorts=()
  for _ in {1..8}; do
    len=$(( (RANDOM % 8 + 1) * 2 ))
    shorts+=("\"$(openssl rand -hex $((len / 2)))\"")
  done
  printf '[%s]' "$(IFS=,; echo "${shorts[*]}")"
}

check_port_busy() {
  local port="$1"
  ss -lnt "( sport = :$port )" | grep -q ":$port"
}

generate_unique_port() {
  local port
  while true; do
    port=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
    [[ -z ${USED_PORTS[$port]} ]] || continue
    if ! check_port_busy "$port"; then
      USED_PORTS["$port"]=1
      echo "$port"
      return
    fi
  done
}

generate_unique_string() {
  local length="$1"
  local value
  while true; do
    value=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c "$length")
    [[ -z ${USED_STRINGS[$value]} ]] || continue
    USED_STRINGS["$value"]=1
    echo "$value"
    return
  done
}

generate_servername() {
  local exclude="$1"
  local domains=(
    "www.apple.com" "www.microsoft.com" "aws.amazon.com"
    "www.amazon.com" "www.oracle.com" "www.nvidia.com"
    "www.intel.com" "www.sony.com" "www.amd.com"
  )
  local filtered=()
  for domain in "${domains[@]}"; do
    [[ "$domain" != "$exclude" ]] && filtered+=("$domain")
  done
  (( ${#filtered[@]} == 0 )) && return 1
  printf '%s\n' "${filtered[@]}" | shuf -n1
}

if $CHANGE_SHORTIDS; then
  NEW_SHORTS=$(generate_shortids)
  sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings,'$.realitySettings.shortIds', json('$NEW_SHORTS')) WHERE remark LIKE '%Reality%';"
fi

if $CHANGE_XHTTP; then
  current_path=$(sqlite3 "$XUIDB" "SELECT json_extract(stream_settings,'$.xhttpSettings.path') FROM inbounds WHERE remark LIKE '%XHTTP%' LIMIT 1;")
  new_path="/$(generate_unique_string '10')"
  if [ -n "$current_path" ] && [ "$current_path" != "null" ]; then
    sed -i "s|location ${current_path} |location ${new_path} |g" $NGINX_CONF_DIR/* 2>/dev/null
  fi
  sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings,'$.xhttpSettings.path','$new_path') WHERE remark LIKE '%XHTTP%';"
fi

if $CHANGE_WS; then
  current_port=$(sqlite3 "$XUIDB" "SELECT port FROM inbounds WHERE remark LIKE '%WebSocket%' LIMIT 1;")
  new_port=$(generate_unique_port)
  new_path="/${new_port}/$(generate_unique_string '10')"
  sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings,'$.wsSettings.path','$new_path'), port = ${new_port}, tag = 'in-${new_port}-tcp' WHERE remark LIKE '%WebSocket%';"
fi

if $CHANGE_TROJAN; then
  current_port=$(sqlite3 "$XUIDB" "SELECT port FROM inbounds WHERE remark LIKE '%Trojan%' LIMIT 1;")
  new_port=$(generate_unique_port)
  new_path="/${new_port}/$(generate_unique_string '10')"
  sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings,'$.grpcSettings.serviceName','$new_path'), port = ${new_port}, tag = 'in-${new_port}-tcp' WHERE remark LIKE '%Trojan%';"
fi

if $CHANGE_HYSTERIA; then
  new_finalmask=$(openssl rand -hex 8)
  sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings,'$.finalmask.udp[0].settings.password','$new_finalmask') WHERE remark LIKE '%Hysteria2%';"
fi

if $CHANGE_SNI; then
  current_sni=$(sqlite3 "$XUIDB" "SELECT json_extract(stream_settings,'$.realitySettings.serverNames[0]') FROM inbounds WHERE remark LIKE '%Reality%' LIMIT 1;")
  new_sni=$(generate_servername "$current_sni")
  if [ -n "$new_sni" ]; then
    sqlite3 "$XUIDB" "UPDATE inbounds SET stream_settings = json_set(stream_settings, '$.realitySettings.target', '${new_sni}:443', '$.realitySettings.serverNames', json_array('$new_sni')) WHERE remark LIKE '%Reality%';"
  else
    log "ERROR" "Не удалось сгенерировать новый SNI."
  fi
fi

if /usr/sbin/nginx -t; then
  /usr/sbin/nginx -s reload
else
  log "CRITICAL" "Ошибка в конфиге Nginx! Сервер НЕ перезапущен. Вывод теста:"
  echo "$nginx_test_output" >> "$LOG_FILE"
fi

/usr/bin/x-ui restart 2>>"$LOG_FILE"
if [ $? -eq 0 ]; then
  log "SUCCESS" "X-UI успешно перезапущен."
else
  log "ERROR" "Не удалось перезапустить службу X-UI!"
fi
