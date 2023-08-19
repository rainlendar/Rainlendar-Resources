#!/usr/bin/bash

RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'
RESET='\033[0m'

log_text() {
    echo -e "${GREEN}$1${RESET}"
}

log_error() {
    echo -e "${GREEN}$1${RESET}"
}

show_intro() {
  echo "#######################################################################"
  echo "#                                                                     #"
  echo "# Radical server installation for Rainlendar and other CalDAV clients #"
  echo "#                                                                     #"
  echo "#######################################################################"
  echo 
  echo "This script will install the following software on your computer:"
  echo "- radical (This is the CalDAV server)"
  echo "- nginx (Webserver which is used as reverse proxy for radical)"
  echo

  if [ "$EUID" -ne 0 ]; then
    log_error "ERROR: The script must be run as root"
    exit
  fi

  read -r -p "Do you want to continue (y/N)? " RESPONSE
  if ! [[ "$RESPONSE" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    exit
  fi
}

check_prequisites() {
  command -v python3 >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    log_error "ERROR: Python3 is not found. Unable to continue."
    exit
  fi

  log_text "Checking public IP"
  IP=$(curl -s ifconfig.co)
}

install_software() {
  log_text "Installing required software"
  apt install -qq -y python3-pip apache2-utils pwgen nginx unattended-upgrades fail2ban
  dpkg-reconfigure -f noninteractive unattended-upgrades

  log_text "Installing radicale"
  python3 -m pip install --upgrade radicale

  command -v radicale >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    log_error "ERROR: radicale is not found. Something went wrong with the installation. Unable to continue."
    exit
  fi
}

configure_radicale() {
  log_text "Creating users file"

  USERNAME=""
  while [ -z "${USERNAME}" ]; do
    read -r -p "Please give the user name: " USERNAME

    if ! [[ "$USERNAME" =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]]; then
      echo "Invalid username (${USERNAME}). Please use only lower case letters and no spaces."
      USERNAME=""
    fi
  done

  PASSWORD=$(pwgen -s 24 1)

  htpasswd -cBb /etc/radicale/users $USERNAME $PASSWORD

  log_text "Creating radical config file"

  mkdir -p /etc/radicale
  cat <<EOT > /etc/radicale/config
[server]
hosts = 127.0.0.1:5232
[auth]
type = htpasswd
htpasswd_filename = /etc/radicale/users
htpasswd_encryption = bcrypt
EOT

  log_text "Creating systemd service"

  useradd --system --user-group --home-dir / --shell /sbin/nologin radicale
  mkdir -p /var/lib/radicale/collections
  chown -R radicale:radicale /var/lib/radicale/collections
  chmod -R o= /var/lib/radicale/collections

  cat <<EOT > /etc/systemd/system/radicale.service
[Unit]
Description=A simple CalDAV (calendar) and CardDAV (contact) server
After=network.target
Requires=network.target

[Service]
ExecStart=/usr/bin/env python3 -m radicale
Restart=on-failure
User=radicale
UMask=0027
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
NoNewPrivileges=true
ReadWritePaths=/var/lib/radicale/collections

[Install]
WantedBy=multi-user.target
EOT

  log_text "Starting radicale systemd service"

  systemctl enable radicale
  systemctl start radicale

  systemctl status radicale >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    log_error "ERROR: radicale service could not be started. Something went wrong with the installation. Unable to continue."
    exit
  fi
}

create_certificate() {
  log_text "Creating self-signed SSL certificate"

  cat <<EOT > san.cnf
[req]
default_bits  = 2048
distinguished_name = req_distinguished_name
req_extensions = req_ext
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
countryName = XX
stateOrProvinceName = N/A
localityName = N/A
organizationName = Self-signed certificate
commonName = $IP: Self-signed certificate

[req_ext]
subjectAltName = @alt_names

[v3_req]
subjectAltName = @alt_names

[alt_names]
IP.1 = $IP
EOT

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/ssl/private/nginx-server-selfsigned.key -out /etc/ssl/certs/nginx-server-selfsigned.crt -config san.cnf
  rm san.cnf
}

configure_nginx() {
  log_text "Configuring nginx webserver"

  cat <<EOT > /etc/nginx/sites-available/radicale
server {
    listen 80;
    listen 443 ssl http2;
    server_name ${IP};

    ssl_certificate /etc/ssl/certs/nginx-server-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/nginx-server-selfsigned.key;

    location /radicale/ {
        proxy_pass        http://localhost:5232/;
        proxy_set_header  X-Script-Name /radicale;
	    proxy_set_header  X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header  X-Remote-User \$remote_user;
        proxy_set_header  Host \$http_host;
	    proxy_pass_header Authorization;
    }
}
EOT

  rm /etc/nginx/sites-enabled/radicale
  ln -s /etc/nginx/sites-available/radicale /etc/nginx/sites-enabled/radicale

  systemctl reload nginx
  systemctl status nginx >/dev/null 2>&1
  if [ $? -eq 1 ]; then
    log_error "ERROR: nginx service could not be restarted. Something went wrong with the installation. Unable to continue."
    exit
  fi
}

all_done() {
  log_text "SUCCESS"
  echo "Radical is successfully installed and configured."
  echo "You can access it from here: https://${IP}/radicale"
  echo
  echo "Here's your credentials for the login (and caldav access):"
  echo
  echo "Username: ${USERNAME}"
  echo "Password: ${PASSWORD}"
  echo
  echo "Make sure to store them to your password manager!"
}

main() {
  show_intro
  check_prequisites
  install_software
  configure_radicale
  create_certificate
  configure_nginx
  all_done
}

main
