#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

function error() { echo -e "${RED}[ERROR] $* ${NC}" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root!"
  exit 1
fi

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
    value=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length")

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
    echo "$port"
    return
  done
}

read_value() {
  local prompt="$1"
  local default_value="$2"
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

XUIDB="/etc/x-ui/x-ui.db"

username=$(read_value "Enter username" "$(generate_unique_string 10)")
password=$(read_value "Enter password" "$(generate_unique_string 10)")

panel_port=$(generate_unique_port)
sub_port=$(generate_unique_port)
ws_port=$(generate_unique_port)

reality_port=443
decoy_port=$(read_port_or_default 8443 "Enter decoy port")

panel_path=$(read_value "Enter panel path" "$(generate_unique_string 10)")
sub_path=$(read_value "Enter sub path" "$(generate_unique_string 10)")
clash_path=$(read_value "Enter clash path" "$(generate_unique_string 10)")
ws_path=$(read_value "Enter ws path" "$(generate_unique_string 10)")
xhttp_path=$(read_value "Enter xhttp path" "$(generate_unique_string 10)")

domain=$(read_value "Enter domain")

cert_path=$(read_value "Enter SSL certificate path (fullchain.pem)" "/root/cert/${domain}/fullchain.pem")
cert_key_path=$(read_value "Enter SSL private key path (privkey.pem)" "/root/cert/${domain}/privkey.pem")

decoy_folder=$(read_value "Enter decoy folder" "/var/www/html")

function get_ssh_config() {
  local key="${1,,}"
  sshd -T | awk -v key="$key" '$1 == key {print $2}'
}

download_from_github() {
  local user="$1"
  local repo="$2"
  local branch="$3"
  local path="$4"
  local current_dir="${5:-.}"

  local api_url="https://api.github.com/repos/$user/$repo/contents/$path?ref=$branch"

  local response=$(curl -s -w "\n%{http_code}" "$api_url")
  local http_code=$(echo "$response" | tail -n1)
  local json_body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ne 200 ]; then
    error "Ошибка API: Получен код ответа $http_code"
    return 1
  fi

  local type=$(echo "$json_body" | jq -r 'type')
  if [ "$type" == "object" ]; then
    local file_name=$(echo "$json_body" | jq -r '.name')
    local download_url=$(echo "$json_body" | jq -r '.download_url')

    echo "Скачивание файла: $current_dir/$file_name"
    mkdir -p "$current_dir"
    curl -s -L "$download_url" -o "$current_dir/$file_name"
  elif [ "$type" == "array" ]; then
    echo "$json_body" | jq -c '.[]' | while read -r item; do
      local item_type=$(echo "$item" | jq -r '.type')
      local item_name=$(echo "$item" | jq -r '.name')
      local item_path=$(echo "$item" | jq -r '.path')

      if [ "$item_type" == "file" ]; then
        local download_url=$(echo "$item" | jq -r '.download_url')
        echo "Скачивание файла: $current_dir/$item_name"
        mkdir -p "$current_dir"
        curl -s -L "$download_url" -o "$current_dir/$item_name"
      elif [ "$item_type" == "dir" ]; then
        echo "Вход в папку: $current_dir/$item_name"
        download_from_github "$user" "$repo" "$branch" "$item_path" "$current_dir/$item_name"
        if [ $? -ne 0 ]; then
            return 1
        fi
      fi
    done
  else
    error "Неизвестный тип объекта в API."
    return 1
  fi
}

install_3xui() {
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
  emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s https://ipwho.is/ | jq -r '.flag.emoji')

  output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
  private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
  public_key=$(echo "$output" | grep "^Password" | awk '{print $3}')

  output=$(/usr/local/x-ui/bin/xray-linux-amd64 tls ech --serverName "${domain}")
  ech_config=$(echo "$output" | grep -A 1 "ECH config list:" | tail -n 1)
  ech_server=$(echo "$output" | grep -A 1 "ECH server keys:" | tail -n 1)

  finalmask=$(openssl rand -hex 8)

  short=()

  for _ in {1..8}; do
    len=$(( (RANDOM % 8 + 1) * 2 ))
    short+=("$(openssl rand -hex $((len / 2)))")
  done

  sqlite3 $XUIDB << EOF
INSERT INTO settings(key,value) VALUES("subPort","$sub_port");
INSERT INTO settings(key,value) VALUES("subPath","/$sub_path/");
INSERT INTO settings(key,value) VALUES("subURI","https://$domain/$sub_path/");
INSERT INTO settings(key,value) VALUES("subClashPath","/$clash_path/");
INSERT INTO settings(key,value) VALUES("subClashURI","https://$domain/$clash_path/");
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag Reality',1,0,'',${reality_port},'vless','{"clients":[],"decryption":"none","encryption":"none","testseed":[900,500,900,256]}','{"network":"tcp","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}},"security":"reality","realitySettings":{"show":false,"xver":2,"target":"127.0.0.1:${decoy_port}","serverNames":["${domain}"],"privateKey":"${private_key}","minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":["${short[0]}","${short[1]}","${short[2]}","${short[3]}","${short[4]}","${short[5]}","${short[6]}","${short[7]}"],"mldsa65Seed":"","settings":{"publicKey":"${public_key}","fingerprint":"chrome","serverName":"","spiderX":"/","mldsa65Verify":""}}}','in-${reality_port}-tcp','{"enabled":false}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'${emoji_flag} XHTTP',1,0,'/dev/shm/xrxh.socket,0666',0,'vless','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"xhttp","xhttpSettings":{"path":"/${xhttp_path}","host":"","mode":"packet-up","xPaddingBytes":"100-1000","xPaddingObfsMode":false,"xPaddingKey":"","xPaddingHeader":"","xPaddingPlacement":"","xPaddingMethod":"","sessionPlacement":"","sessionKey":"","seqPlacement":"","seqKey":"","uplinkDataPlacement":"","uplinkDataKey":"","scMaxEachPostBytes":"1000000","noSSEHeader":false,"scMaxBufferedPosts":30,"scStreamUpServerSecs":"20-80","serverMaxHeaderBytes":0,"uplinkHTTPMethod":"","headers":{},"scMinPostsIntervalMs":"30","uplinkChunkSize":0,"noGRPCHeader":false,"enableXmux":false},"security":"none","externalProxy":[{"forceTls":"tls","dest":"$domain","port":${reality_port},"remark":"","sni":"","alpn":[]}],"sockopt":{"acceptProxyProtocol":false,"tcpFastOpen":true,"mark":0,"tproxy":"off","tcpMptcp":true,"penetrate":false,"domainStrategy":"AsIs","tcpMaxSeg":1440,"dialerProxy":"","tcpKeepAliveInterval":45,"tcpKeepAliveIdle":45,"tcpUserTimeout":10000,"tcpcongestion":"bbr","V6Only":false,"tcpWindowClamp":600,"interface":"","trustedXForwardedFor":[],"addressPortStrategy":"none","customSockopt":[]}}','in-/dev/shm/xrxh.socket,0666:1-tcp','{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag WebSocket',1,0,'',${ws_port},'vless','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"ws","wsSettings":{"acceptProxyProtocol":false,"path":"/${ws_port}/${ws_path}","host":"","headers":{},"heartbeatPeriod":0},"security":"none","externalProxy":[{"forceTls":"tls","dest":"${domain}","port":${reality_port},"remark":"","sni":"","alpn":[]}]}','in-${ws_port}-tcp','{"enabled":false}');
INSERT INTO inbounds(user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,'$emoji_flag Hysteria2',1,0,'',${ws_port},'vless','{"clients":[],"decryption":"none","encryption":"none"}','{"network":"hysteria","hysteriaSettings":{"version":2,"udpIdleTimeout":60},"security":"tls","tlsSettings":{"serverName":"${domain}","minVersion":"1.2","maxVersion":"1.3","cipherSuites":"","rejectUnknownSni":false,"disableSystemRoot":false,"enableSessionResumption":false,"certificates":[{"certificateFile":"${cert_path}","keyFile":"${cert_key_path}","oneTimeLoading":false,"usage":"encipherment","buildChain":false}],"alpn":["h3"],"echServerKeys":"${ech_server}","settings":{"fingerprint":"chrome","echConfigList":"${ech_config}","pinnedPeerCertSha256":[]}},"finalmask":{"udp":[{"type":"salamander","settings":{"password":"${finalmask}"}}]}}
','in-${reality_port}-udp','{"enabled":false}');

EOF
  /usr/local/x-ui/x-ui setting -username "$username" -password "$password" -port "$panel_port" -webBasePath "$panel_path"
  x-ui start
}

enable_bbr() {
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
  echo -e "${GREEN}BBR is already enabled!${NC}"
  return
  fi

  # Enable BBR
  if [ -d "/etc/sysctl.d/" ]; then
    {
      echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    } > "/etc/sysctl.d/99-bbr-x-ui.conf"
    if [ -f "/etc/sysctl.conf" ]; then
      # Backup old settings from sysctl.conf, if any
      sed -i 's/^net.core.default_qdisc/# &/' /etc/sysctl.conf
      sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
    fi
    sysctl --system
  else
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
    sysctl -p
  fi

  # Verify that BBR is enabled
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
    echo -e "${GREEN}BBR has been enabled successfully.${NC}"
  else
    echo -e "${RED}Failed to enable BBR. Please check your system configuration.${NC}"
  fi
}

apt -y install ufw jq wget nginx-full sqlite3 curl

systemctl stop nginx

rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/nginx/stream-enabled/*
rm -f /etc/nginx/snippets/includes.conf

cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
  listen 80;
  server_name $domain;
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

  location ~* ^/(${sub_path}|${clash_path}) {
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

    client_body_timeout 5m;
    grpc_read_timeout 315;
    grpc_send_timeout 5m;

    grpc_pass unix:/dev/shm/xrxh.socket;
  }

  location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
    if (\$hack = 1) {return 404;}
    client_max_body_size 0;
    client_body_timeout 5m;
    proxy_read_timeout 315;

    proxy_socket_keepalive on;
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_request_buffering off;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;

    proxy_set_header X-Real-IP \$proxy_protocol_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

    if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
      proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
    }
  }

  location / { try_files \$uri \$uri/ =404; }
}

EOF

ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
ln -s "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/" 2>/dev/null

if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
  error "nginx config is not ok!" && exit 1
else
  www=$(curl -s "https://api.github.com/repos/GFW4Fun/randomfakehtml/contents/" | jq -r '.[] | select(.type == "dir" and .name != "assets") | .name' | shuf -n 1)
  rm -rf "$decoy_folder"
  download_from_github "GFW4Fun" "randomfakehtml" "master" "$www" "$decoy_folder" >/dev/null
fi

install_3xui
setup_3xui

enable_bbr

CRON_JOB='@daily /usr/bin/x-ui restart > /dev/null 2>&1 && /usr/sbin/nginx -s reload'
(
    crontab -l 2>/dev/null | grep -Fv "$CRON_JOB"
    echo "$CRON_JOB"
) | crontab -

CRON_JOB='0 4 * * 0 /usr/sbin/reboot'
(
    crontab -l 2>/dev/null | grep -Fv "$CRON_JOB"
    echo "$CRON_JOB"
) | crontab -

ufw allow "$(get_ssh_config 'Port')/tcp" >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow ${reality_port}/tcp >/dev/null
ufw allow ${reality_port}/udp >/dev/null
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
