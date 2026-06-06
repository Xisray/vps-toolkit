#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

function error() { echo -e "${RED}[ERROR] $* ${NC}" >&2; }
function info()  { echo -e "${CYAN}[INFO] $* ${NC}"; }
function ok()    { echo -e "${GREEN}[OK] $* ${NC}"; }
function warn()  { echo -e "${YELLOW}[WARN] $* ${NC}"; }

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root!"
  exit 1
fi

DEFAULT=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --default|-d) DEFAULT=true; shift 1;;
    *) shift 1;;
  esac
done

declare -A USED_PORTS
declare -A USED_STRINGS

check_port_busy() {
  local port="$1"
  ss -lnt "( sport = :$port )" | grep -q ":$port"
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

read_port_or_default() {
  local default_value="$1"
  local prompt="$2"
  local default="${3:-false}"
  if [ "$default" = true ]; then
    USED_PORTS["$default_value"]=1
    echo "$default_value"
    return 0
  fi
  local port

  while true; do
    read -rp "$prompt [$default_value]: " port

    [[ -z "$port" ]] && port="$default_value"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
      continue
    fi

    if [[ -n ${USED_PORTS[$port]} ]]; then
      continue
    fi

    if check_port_busy "$port"; then
      continue
    fi

    USED_PORTS["$port"]=1
    break
  done
  echo "$port"
}

read_value() {
  local prompt="$1"
  local default_value="$2"
  local default="${3:-false}"
  if [ "$default" = true ] && [[ -n "$default_value" ]]; then
    echo "$default_value"
    return 0
  fi
  local value

  while true; do
    if [[ -n "$default_value" ]]; then
      read -rp "$prompt [$default_value]: " value
      [[ -z "$value" ]] && value="$default_value"
    else
      read -rp "$prompt: " value
    fi

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]*}"}"

    [[ -n "$value" ]] && {
      echo "$value"
      return
    }
  done
}

read_reality_mask() {
  local PRESET_DOMAINS=(
    "www.sony.com"
    "www.oracle.com"
    "www.intel.com"
    "aws.amazon.com"
    "www.amazon.com"
    "www.nvidia.com"
    "www.amd.com"
  )

  echo -e "${CYAN}Choose Reality masquerade type:${NC}" >&2
  echo -e "  ${YELLOW}1)${NC} Select from popular domains" >&2
  echo -e "  ${YELLOW}2)${NC} Enter custom URL" >&2
  echo -e "  ${YELLOW}3)${NC} Use stub/placeholder website (no external masquerade)" >&2

  local choice
  while true; do
    read -rp "Your choice [1-3]: " choice
    case "$choice" in
      1|2|3) break ;;
      *) warn "Please enter 1, 2, or 3." ;;
    esac
  done

  case "$choice" in
    1)
      echo -e "${CYAN}Select a domain:${NC}" >&2
      for i in "${!PRESET_DOMAINS[@]}"; do
        echo -e "  ${YELLOW}$((i+1)))${NC} ${PRESET_DOMAINS[$i]}" >&2
      done

      local idx
      while true; do
        read -rp "Your choice [1-${#PRESET_DOMAINS[@]}]: " idx
        if [[ "$idx" =~ ^[0-9]+$ ]] && ((idx >= 1 && idx <= ${#PRESET_DOMAINS[@]})); then
          echo "${PRESET_DOMAINS[$((idx-1))]}"
          return
        fi
        warn "Enter a number between 1 and ${#PRESET_DOMAINS[@]}."
      done
      ;;

    2)
      local custom
      while true; do
        read -rp "Enter custom domain (e.g. example.com): " custom
        custom="${custom#"${custom%%[![:space:]]*}"}"
        custom="${custom%"${custom##*[![:space:]]*}"}"
        custom="${custom#https://}"
        custom="${custom#http://}"
        custom="${custom%%/*}"
        [[ -n "$custom" ]] && break
        warn "Domain cannot be empty."
      done
      echo "$custom"
      ;;

    3)
      echo ""
      ;;
  esac
}

function get_ssh_config() {
  local key="${1,,}"
  sshd -T | awk -v key="$key" '$1 == key {print $2}'
}

install_acme() {
  if command -v ~/.acme.sh/acme.sh &> /dev/null; then
    info "acme.sh is already installed."
    return 0
  fi

  info "Installing acme.sh..."
  cd ~ || return 1

  curl -s https://get.acme.sh | sh
  if [ $? -ne 0 ]; then
    error "Installation of acme.sh failed."
    return 1
  else
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    info "Installation of acme.sh succeeded."
  fi

  return 0
}

ssl_cert_issue() {
  install_acme || { error "Install acme failed"; exit 1; }

  local domain_list=()

  if [[ $# -gt 0 ]]; then
    for sci_domain in "$@"; do
      if [[ "$sci_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        domain_list+=("$sci_domain")
      else
        error "Invalid domain: $sci_domain"
      fi
    done
    if [[ ${#domain_list[@]} -eq 0 ]]; then
      error "No valid domains provided."
      exit 1
    fi
  else
    error "Zero domains"
    exit 1
  fi

  local primary_domain="${domain_list[0]}"
  local domain_flags=()
  for d in "${domain_list[@]}"; do
    domain_flags+=("-d" "$d")
  done

  local cert_exists=0
  if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${primary_domain}"; then
    cert_exists=1
  fi

  local certPath="/root/cert/${primary_domain}"
  rm -rf "$certPath"
  mkdir -p "$certPath"

  if [[ ${cert_exists} -eq 0 ]]; then
    local web_port=$(read_port_or_default 80 "Enter HTTP challenge port (acme standalone)")

    local max_attempts=3
    local attempt=0
    local success=0

    while [[ $attempt -lt $max_attempts ]]; do
      attempt=$((attempt + 1))
      info "Certificate issuance attempt $attempt/$max_attempts..."

      rm -rf ~/.acme.sh/"${primary_domain}_ecc"
      rm -rf ~/.acme.sh/ca/acme-v02.api.letsencrypt.org

      ~/.acme.sh/acme.sh --issue "${domain_flags[@]}" \
        --server letsencrypt \
        --listen-v6 --standalone \
        --httpport "${web_port}" \
        --force

      if [[ $? -eq 0 ]]; then
        success=1
        break
      fi

      if [[ $attempt -lt $max_attempts ]]; then
        info "Retrying in 15 seconds..."
        sleep 15
      fi
    done

    if [[ $success -eq 0 ]]; then
      error "Issuing certificate failed after $max_attempts attempts."
      rm -rf "~/.acme.sh/${primary_domain}"
      exit 1
    fi
  fi

  local installOutput=$(~/.acme.sh/acme.sh --installcert "${domain_flags[@]}" --key-file /root/cert/${primary_domain}/privkey.pem --fullchain-file /root/cert/${primary_domain}/fullchain.pem 2>&1)
  local installRc=$?
  echo "${installOutput}"

  local installWroteFiles=0
  if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
    installWroteFiles=1
  fi

  if [[ -f "/root/cert/${primary_domain}/privkey.pem" && -f "/root/cert/${primary_domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
    info "Installing certificate succeeded, enabling auto renew..."
  else
    error "Installing certificate failed, exiting."
    if [[ ${cert_exists} -eq 0 ]]; then
      rm -rf "~/.acme.sh/${primary_domain}"
    fi
    exit 1
  fi

  local res=$(~/.acme.sh/acme.sh --upgrade --auto-upgrade)

  chmod 600 "$certPath/privkey.pem"
  chmod 644 "$certPath/fullchain.pem"
  if [ $? -ne 0 ]; then
    error "Auto renew failed"
    exit 1
  fi
  info "Auto renew succeeded"
}

install_3xui() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
  elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
  else
    echo "Failed to detect OS"
    exit 1
  fi

  cd /root/
  rm -rf x-ui/ /usr/local/x-ui/ /usr/bin/x-ui
  wget https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-${XUI_ARCH}.tar.gz
  tar zxvf x-ui-linux-${XUI_ARCH}.tar.gz
  rm -f x-ui-linux-${XUI_ARCH}.tar.gz
  chmod +x x-ui/x-ui x-ui/bin/xray-linux-* x-ui/x-ui.sh
  cp x-ui/x-ui.sh /usr/bin/x-ui

  if [ -f "x-ui/x-ui.service" ]; then
    cp -f x-ui/x-ui.service /etc/systemd/system/
  elif [[ "$release" == "ubuntu" || "$release" == "debian" || "$release" == "armbian" ]]; then
    if [ -f "x-ui/x-ui.service.debian" ]; then
      cp -f x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
    else
      echo "Service file not found in archive, downloading..."
      curl -fLo /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.debian
    fi
  else
    if [ -f "x-ui/x-ui.service.rhel" ]; then
      cp -f x-ui/x-ui.service.rhel /etc/systemd/system/x-ui.service
    else
      echo "Service file not found in archive, downloading..."
      curl -fLo /etc/systemd/system/x-ui.service https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.service.rhel
    fi
  fi

  mv x-ui/ /usr/local/
  systemctl daemon-reload
  systemctl enable x-ui
  systemctl restart x-ui
}

setup_3xui() {
  x-ui stop
  /usr/local/x-ui/x-ui migrate

  emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s https://ipwho.is/ | jq -r '.flag.emoji')

  output=$($XRAY_BIN x25519)
  private_key=$(echo "$output" | awk '/^PrivateKey:/ {print $2}')
  public_key=$(echo "$output" | awk '/^Password/ {print $3}')

  output=$($XRAY_BIN tls ech --serverName "${domain}")
  ech_config=$(echo "$output" | grep -A 1 "ECH config list:" | tail -n 1)
  ech_server=$(echo "$output" | grep -A 1 "ECH server keys:" | tail -n 1)

  finalmask=$(openssl rand -hex 8)

  short=()

  for _ in {1..8}; do
    len=$(( (RANDOM % 8 + 1) * 2 ))
    short+=("$(openssl rand -hex $((len / 2)))")
  done

  if [[ -z "$reality_mask" ]]; then
    reality_target="127.0.0.1:${reality_decoy_port}"
    reality_sni="${reality_domain}"
    reality_proxy_domain="${domain}"
  else
    reality_target="${reality_mask}:443"
    reality_sni="${reality_mask}"
    reality_proxy_domain="${reality_domain}"
  fi

  sqlite3 $XUIDB << EOF
DELETE FROM client_traffics;
DELETE FROM inbounds;
DELETE FROM settings
WHERE "key" IN ('subPort','subPath','subURI','subClashEnable','subClashPath','subClashURI','webPort','webCertFile','webKeyFile','webBasePath','subCertFile','subKeyFile','subJsonEnable','subJsonPath','subJsonURI','subEnableRouting','subRoutingRules','subUpdates');
INSERT INTO settings(key,value) VALUES("subUpdates","8");
INSERT INTO settings(key,value) VALUES("subPort","$sub_port");
INSERT INTO settings(key,value) VALUES("subPath","/$sub_path/");
INSERT INTO settings(key,value) VALUES("subURI","https://$domain/$sub_path/");
INSERT INTO settings(key,value) VALUES("subJsonEnable","true");
INSERT INTO settings(key,value) VALUES("subJsonPath","/$json_path/");
INSERT INTO settings(key,value) VALUES("subJsonURI","https://$domain/$json_path/");
INSERT INTO settings(key,value) VALUES("subClashEnable","true");
INSERT INTO settings(key,value) VALUES("subClashPath","/$clash_path/");
INSERT INTO settings(key,value) VALUES("subClashURI","https://$domain/$clash_path/");
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag Reality',1,0,'',${reality_port},'vless','{"clients":[],"decryption":"none","encryption":"none","testseed":[900,500,900,256]}','{"network":"tcp","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}},"security":"reality","realitySettings":{"show":false,"xver":0,"target":"${reality_target}","serverNames":["${reality_sni}"],"privateKey":"${private_key}","minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":["${short[0]}","${short[1]}","${short[2]}","${short[3]}","${short[4]}","${short[5]}","${short[6]}","${short[7]}"],"mldsa65Seed":"","settings":{"publicKey":"${public_key}","fingerprint":"firefox","serverName":"","spiderX":"/","mldsa65Verify":""}},"externalProxy":[{"forceTls":"same","dest":"${reality_proxy_domain}","port":${https_port},"remark":"","sni":"","alpn":[]}]}','in-${reality_port}-tcp','{"enabled":true,"destOverride":["tls","http","quic","fakedns"],"routeOnly":true}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'${emoji_flag} XHTTP',1,0,'/dev/shm/xrxh.socket,0666',0,'vless','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"xhttp","xhttpSettings":{"path":"/${xhttp_path}","host":"","mode":"packet-up","xPaddingBytes":"100-1000","xPaddingObfsMode":false,"xPaddingKey":"","xPaddingHeader":"","xPaddingPlacement":"","xPaddingMethod":"","sessionPlacement":"","sessionKey":"","seqPlacement":"","seqKey":"","uplinkDataPlacement":"","uplinkDataKey":"","scMaxEachPostBytes":"1000000","noSSEHeader":false,"scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80","serverMaxHeaderBytes":0,"uplinkHTTPMethod":"","headers":{},"scMinPostsIntervalMs":"30","uplinkChunkSize":0,"noGRPCHeader":false,"enableXmux":false},"security":"none","externalProxy":[{"forceTls":"tls","dest":"$domain","port":${https_port},"remark":"","sni":"","alpn":[]}],"sockopt":{"acceptProxyProtocol":false,"tcpFastOpen":true,"mark":0,"tproxy":"off","tcpMptcp":true,"penetrate":false,"domainStrategy":"AsIs","tcpMaxSeg":1440,"dialerProxy":"","tcpKeepAliveInterval":45,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr","V6Only":false,"tcpWindowClamp":600,"interface":"","trustedXForwardedFor":[],"addressPortStrategy":"none","customSockopt":[]}}','in-0-tcp','{"enabled":true,"destOverride":["tls","http","quic","fakedns"]}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag WebSocket',1,0,'',${ws_port},'vless','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"ws","wsSettings":{"acceptProxyProtocol":false,"path":"/${ws_port}/${ws_path}","host":"","headers":{},"heartbeatPeriod":0},"security":"none","externalProxy":[{"forceTls":"tls","dest":"${domain}","port":${https_port},"remark":"","sni":"","alpn":[]}]}','in-${ws_port}-tcp','{"enabled":true,"destOverride":["tls","http","quic","fakedns"],"routeOnly":true}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag Trojan',1,0,'',${trojan_port},'trojan','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"grpc","grpcSettings":{"serviceName":"/${trojan_port}/${trojan_path}","authority":"${domain}","multiMode":false},"security":"none","externalProxy":[{"forceTls":"tls","dest":"${domain}","port":${https_port},"remark":"","sni":"","alpn":[]}]}','in-${trojan_port}-tcp','{"enabled":true,"destOverride":["tls","http","quic","fakedns"],"routeOnly":true}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag Hysteria2',1,0,'',${https_port},'hysteria','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"hysteria","hysteriaSettings":{"version":2,"udpIdleTimeout":60},"security":"tls","tlsSettings":{"serverName":"${domain}","minVersion":"1.2","maxVersion":"1.3","cipherSuites":"","rejectUnknownSni":false,"disableSystemRoot":false,"enableSessionResumption":false,"certificates":[{"certificateFile":"${cert_path}","keyFile":"${cert_key_path}","oneTimeLoading":false,"usage":"encipherment","buildChain":false}],"alpn":["h3"],"echServerKeys":"${ech_server}","settings":{"fingerprint":"firefox","echConfigList":"${ech_config}","pinnedPeerCertSha256":[]}},"finalmask":{"udp":[{"type":"salamander","settings":{"password":"${finalmask}"}}]}}','in-${https_port}-udp','{"enabled":true,"destOverride":["tls","http","quic","fakedns"],"routeOnly":true}');

EOF
  /usr/local/x-ui/x-ui setting -username "$username" -password "$password" -port "$panel_port" -webBasePath "$panel_path"
  x-ui start
}

ARCH=$(uname -m)
case "${ARCH}" in
  x86_64 | x64 | amd64) XUI_ARCH="amd64" ;;
  i*86 | x86) XUI_ARCH="386" ;;
  armv8* | armv8 | arm64 | aarch64) XUI_ARCH="arm64" ;;
  armv7* | armv7) XUI_ARCH="armv7" ;;
  armv6* | armv6) XUI_ARCH="armv6" ;;
  armv5* | armv5) XUI_ARCH="armv5" ;;
  s390x) XUI_ARCH="s390x" ;;
  *) XUI_ARCH="amd64" ;;
esac

XUIDB="/etc/x-ui/x-ui.db"
XRAY_BIN="/usr/local/x-ui/bin/xray-linux-${XUI_ARCH}"
http_port=80
https_port=443
USED_PORTS["$http_port"]=1
USED_PORTS["$https_port"]=1

username=$(read_value "Enter username" "$(generate_unique_string 12)" "$DEFAULT")
password=$(read_value "Enter password" "$(generate_unique_string 12)" "$DEFAULT")

panel_port=$(generate_unique_port)
sub_port=$(generate_unique_port)
ws_port=$(generate_unique_port)
trojan_port=$(generate_unique_port)

reality_port=$(read_port_or_default 8443 "Enter reality port" "$DEFAULT")
decoy_port=$(read_port_or_default 7443 "Enter decoy port" "$DEFAULT")
decoy_folder=$(read_value "Enter decoy folder" "/var/www/html" "$DEFAULT")

panel_path=$(read_value "Enter panel path" "$(generate_unique_string 16)" "$DEFAULT")
sub_path=$(read_value "Enter sub path" "$(generate_unique_string 10)" "$DEFAULT")
json_path=$(read_value "Enter sub json path" "$(generate_unique_string 10)" "$DEFAULT")
clash_path=$(read_value "Enter clash path" "$(generate_unique_string 10)" "$DEFAULT")
xhttp_path=$(read_value "Enter xhttp path" "$(generate_unique_string 16)" "$DEFAULT")
ws_path=$(read_value "Enter ws path" "$(generate_unique_string 16)" "$DEFAULT")
trojan_path=$(read_value "Enter trojan path" "$(generate_unique_string 16)" "$DEFAULT")

domain=$(read_value "Enter main domain")
reality_domain=$(read_value "Enter reality domain")
reality_mask=$(read_reality_mask)
if [[ -z "$reality_mask" ]]; then
  info "Reality will use stub/placeholder mode (no external masquerade domain)."
  reality_decoy_port=$(read_port_or_default 9443 "Enter reality decoy port" "$DEFAULT")
else
  info "Reality masquerade domain set to: $reality_mask"
fi

ssl_cert_issue "$domain" "$reality_domain"

cert_path="/root/cert/${domain}/fullchain.pem"
cert_key_path="/root/cert/${domain}/privkey.pem"

DEFAULT=false

reality_cert_path="$cert_path"
reality_cert_key_path="$cert_key_path"

apt update && apt upgrade -y
apt -y install ufw jq wget nginx-full sqlite3 curl

systemctl stop nginx

rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/nginx/stream-enabled/*
rm -f /etc/nginx/snippets/includes.conf

mkdir -p /etc/nginx/stream-enabled

cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
  hostnames;
  ${reality_domain}          xray;
  ${domain}                  www;
  default                    xray;
}

upstream xray {
  server 127.0.0.1:${reality_port};
}

upstream www {
  server 127.0.0.1:${decoy_port};
}

server {
  proxy_protocol on;
  set_real_ip_from unix:;
  listen          443;
  proxy_pass      \$sni_name;
  ssl_preread     on;
}

EOF

grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_geoip2_module.so;" /etc/nginx* || sed -i '2s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_geoip2_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

cat > "/etc/nginx/sites-available/${http_port}.conf" << EOF
server {
  listen ${http_port};
  server_name $domain $reality_domain;
  return 301 https://\$host\$request_uri;
}

EOF

cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
  server_tokens off;
  listen $decoy_port ssl http2 proxy_protocol;
  server_name $domain;
  index index.html index.htm index.php index.nginx-debian.html;
  root $decoy_folder/;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
  ssl_certificate $cert_path;
  ssl_certificate_key $cert_key_path;

  if (\$host !~* ^(.+\.)?$domain\$ ){return 444;}
  if (\$scheme ~* https) {set \$safe 1;}
  if (\$ssl_server_name !~* ^(.+\.)?$domain\$ ) {set \$safe "\${safe}0";}
  if (\$safe = 10){return 444;}
  if (\$request_uri ~ "(\"|'|\|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}

  error_page 400 401 402 403 500 501 502 503 504 =404 /404;
  proxy_intercept_errors on;

  location /${panel_path} {
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header Range \$http_range;
    proxy_set_header If-Range \$http_if_range;

    proxy_redirect off;

    proxy_pass http://127.0.0.1:${panel_port};
  }

  location ~* ^/(${sub_path}|${json_path}|${clash_path}) {
    if (\$hack = 1) {return 404;}
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-Port \$server_port;
    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header Range \$http_range;
    proxy_set_header If-Range \$http_if_range;

    proxy_redirect off;
    proxy_pass http://127.0.0.1:${sub_port};
  }

  location /${xhttp_path} {
    grpc_buffer_size 16k;
    grpc_socket_keepalive on;

    grpc_set_header Connection "";
    grpc_set_header Host \$host;
    grpc_set_header X-Forwarded-Host \$host;
    grpc_set_header X-Forwarded-Port \$server_port;
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    grpc_set_header X-Forwarded-Proto \$scheme;

    client_body_timeout 1h;
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;

    grpc_pass unix:/dev/shm/xrxh.socket;
  }

  location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
    if (\$hack = 1) {return 404;}
    client_max_body_size 0;
    client_body_timeout 1h;
    proxy_read_timeout 1h;

    proxy_socket_keepalive on;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;

    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

    if (\$content_type ~* "GRPC") {
      grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
    }
    if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
      proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
    }
  }

  location / { try_files \$uri \$uri/ =404; }
}

EOF

ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
ln -s "/etc/nginx/sites-available/${http_port}.conf" "/etc/nginx/sites-enabled/" 2>/dev/null

if [[ -z "$reality_mask" ]]; then
  cat > "/etc/nginx/sites-available/${reality_domain}" << EOF
server {
  server_tokens off;
  listen $reality_decoy_port ssl http2;
  server_name $reality_domain;
  index index.html index.htm index.php index.nginx-debian.html;
  root $decoy_folder/;

  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
  ssl_certificate $reality_cert_path;
  ssl_certificate_key $reality_cert_key_path;

  if (\$host !~* ^(.+\.)?$reality_domain\$ ){return 444;}
  if (\$scheme ~* https) {set \$safe 1;}
  if (\$ssl_server_name !~* ^(.+\.)?$reality_domain\$ ) {set \$safe "\${safe}0";}
  if (\$safe = 10){return 444;}
  if (\$request_uri ~ "(\"|'|\|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}

  error_page 400 401 402 403 500 501 502 503 504 =404 /404;
  proxy_intercept_errors on;
}

EOF
  ln -s "/etc/nginx/sites-available/${reality_domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
fi

if ! nginx -t >/dev/null 2>&1; then
  error "nginx config is not ok!" && exit 1
else
  www=$(curl -s "https://api.github.com/repos/Xisray/reality-cloaks/contents/" | jq -r '.[] | select(.type == "dir" and .name != "assets") | .name' | shuf -n 1)
  rm -rf "$decoy_folder"
  curl -s https://raw.githubusercontent.com/Xisray/vps-toolkit/refs/heads/main/fetch-github-path.sh | bash -s -- "Xisray" "reality-cloaks" "build" "$www" "$decoy_folder" >/dev/null
fi

install_3xui
setup_3xui

INSTALL_PATH="/usr/local/bin/xui-rotator"
TMP_PATH="${INSTALL_PATH}.new"
REPO_URL="https://raw.githubusercontent.com/Xisray/vps-toolkit/main/xui-rotator.sh"

curl -fsSL "$REPO_URL" -o "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

ARGS="--shortids --ws --trojan --xhttp --hysteria"

if [[ -n "$reality_mask" ]]; then
  ARGS="$ARGS --sni"
fi

CRON_JOB="0 4 * * * curl -fsSL $REPO_URL -o $TMP_PATH && chmod +x $TMP_PATH && mv $TMP_PATH $INSTALL_PATH && $INSTALL_PATH $ARGS >/dev/null 2>&1"
(
    crontab -l 2>/dev/null | grep -Fv "$CRON_JOB"
    echo "$CRON_JOB"
) | crontab -

ufw allow "$(get_ssh_config 'Port')/tcp" >/dev/null
ufw allow ${http_port}/tcp >/dev/null
ufw allow ${https_port}/tcp >/dev/null
ufw allow ${https_port}/udp >/dev/null
ufw --force enable

systemctl start nginx

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                    X-UI Secure Panel                       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${GREEN}URL:${NC}      https://${domain}/${panel_path}/"
echo -e "${GREEN}Username:${NC} ${username}"
echo -e "${GREEN}Password:${NC} ${password}"
echo
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}⚠  Please save these credentials in a safe place!${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
