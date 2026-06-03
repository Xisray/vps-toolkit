#!/bin/bash

XUIDB="/etc/x-ui/x-ui.db"

CHANGE_SHORTIDS=false
CHANGE_SNI=false

if [[ $# -eq 0 ]]; then
  CHANGE_SHORTIDS=true
  CHANGE_SNI=true
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shortids)
      CHANGE_SHORTIDS=true
      ;;
    --sni)
      CHANGE_SNI=true
      ;;
    --all)
      CHANGE_SHORTIDS=true
      CHANGE_SNI=true
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

generate_shortids() {
  local shorts=()
  for _ in {1..8}; do
    len=$(( (RANDOM % 8 + 1) * 2 ))
    shorts+=("\"$(openssl rand -hex $((len / 2)))\"")
  done
  printf '[%s]' "$(IFS=,; echo "${shorts[*]}")"
}

generate_servername() {
  local exclude="$1"
  local domains=(
    "www.apple.com"
    "www.microsoft.com"
    "aws.amazon.com"
    "www.amazon.com"
    "www.oracle.com"
    "www.nvidia.com"
    "www.intel.com"
    "www.sony.com"
    "www.amd.com"
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

  sqlite3 "$XUIDB" <<EOF
UPDATE inbounds
SET stream_settings = json_set(
  stream_settings,
  '$.realitySettings.shortIds', json('$NEW_SHORTS')
)
WHERE remark LIKE '%Reality%';
EOF
fi

if $CHANGE_SNI; then
  current_sni=$(sqlite3 "$XUIDB" "SELECT json_extract(stream_settings,'$.realitySettings.serverNames[0]') FROM inbounds WHERE remark LIKE '%Reality%' LIMIT 1;")
  new_sni=$(generate_servername "$current_sni")
  sqlite3 "$XUIDB" <<EOF
UPDATE inbounds
SET stream_settings = json_set(
  stream_settings,
  '$.realitySettings.target', '${new_sni}:443',
  '$.realitySettings.serverNames', json_array('$new_sni')
)
WHERE remark LIKE '%Reality%';
EOF
fi

/usr/bin/x-ui restart
