#!/bin/bash
# 04-install-php-npm-mysql.sh
# prepared by dicky.dwijanto@myspsolution.com
# last update: March 21th, 2025

CHECK_USER="orangt"
LINUX_DISTRO_CHECK="ubuntu"
LINUX_VERSION_CHECK="24.04"
PHP_VERSION="8.4"
NODE_VERSION="22"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
PHP_FPM_COMMAND="php-fpm${PHP_VERSION}"
NGINX_USER="www-data"

# predefined console font color/style
RED='\033[1;41;37m'
BLU='\033[1;94m'
YLW='\033[1;33m'
STD='\033[0m'
BLD='\033[1;97m'

# --------------- Preliminary checking/validation ---------------

if [ "$USER" != "$CHECK_USER" ]; then
  echo ""
  echo -e "Please run this installation script as user: ${BLD}${CHECK_USER}${STD}"
  echo ""
  exit
fi

if ! which spstool &> /dev/null; then
  echo ""
  echo -e "Please install ${BLD}spstool${STD} prior to this installation."
  echo ""
  exit
fi

# check internet connection
if ! ping -q -c 1 -W 1 google.com > /dev/null; then
  echo ""
  echo -e "${BLD}No internet connection detected.${STD}"
  echo -e "This installation script requires internet connection to download required libraries/repositories."
  echo -e "Please set proper network and internet connection on this server before proceed."
  echo ""
  exit
fi

OS_INFO=$(cat /etc/os-release | grep "^PRETTY_NAME=" | sed -n "s/^PRETTY_NAME[ ]*=//p" | xargs)

# check Linux distro
if [ $(printf $OS_INFO | egrep -c -i "${LINUX_DISTRO_CHECK}") -eq 0 ]; then
  printf "\n"
  printf "This installation script must be run on ${BLD}${LINUX_DISTRO_CHECK} only${STD}.\n"
  printf "Your detected OS: $OS_INFO\n"
  printf "\n"
  exit 1
fi

# check Linux version
if [ $(lsb_release -sr | egrep -c -i "${LINUX_VERSION_CHECK}") -eq 0 ]; then
   echo ""
   echo -e "This installation script must be run on ${BLD}${LINUX_DISTRO_CHECK} ${LINUX_VERSION_CHECK} only${STD}."
   echo -e "Your detected OS: ${BLD}${OS_INFO}${STD}"
   echo -e "Installation is aborted."
   echo ""
   exit 1
fi

# check whether user is root or superuser
if [ $(id -u) -eq 0 ]; then
  echo ""
  echo -e "Please run this script as ${BLD}sudoer user${STD}."
  echo -e "Running this script as root or superuser is prohibited."
  echo -e "Please googling: ${BLD}create sudo user ubuntu linuxize${STD}"
  echo ""
  exit
fi

# check whether user is sudoer or not
NOT_SUDOER=$(sudo -l -U $USER 2>&1 | egrep -c -i "not allowed to run sudo|unknown user")
if [ "$NOT_SUDOER" -ne 0 ]; then
  echo ""
  echo -e "${BLD}user ${USER} is not a sudoer user.${STD}"
  echo -e "Please run this script as sudoer."
  echo -e "Please googling: ${BLD}create sudo user ubuntu linuxize${STD}"
  echo ""
  exit
fi

if which php > /dev/null 2>&1; then
  PHP_VERSION=$(php -v | head -1 | egrep -o "\s([0-9\.])+" | head -1)
  echo ""
  echo -e "${BLD}php version${PHP_VERSION} is already installed on this system.${STD}"
  echo -e "PHP Installation is aborted."
  echo ""
  exit
fi

# End of -------- Preliminary checking/validation ---------------

replace_and_backup_file_with_url() {
  local targetfile="$1"
  local url="$2"

  # Check if targetfile exists
  if [ ! -e "$targetfile" ]; then
    echo "Error: Target file '$targetfile' does not exist."
    return 1
  fi

  # Obtain the original owner and permissions of targetfile
  local owner group perms
  owner=$(sudo stat -c '%u' "$targetfile")
  group=$(sudo stat -c '%g' "$targetfile")
  perms=$(sudo stat -c '%a' "$targetfile")

  # Check if "${targetfile}.original" exists; if not, back up the targetfile
  if [ ! -e "${targetfile}.original" ]; then
    sudo mv "$targetfile" "${targetfile}.original"
  else
    sudo rm -f "$targetfile"
  fi

  # Download the URL to the targetfile, tracing any errors
  if ! sudo curl -fsSL "$url" -o "$targetfile"; then
    echo "Error: Failed to download '$url'."
    return 1
  fi

  # Apply the original owner and permissions to the new targetfile
  sudo chown "$owner":"$group" "$targetfile"
  sudo chmod "$perms" "$targetfile"
}

replace_file_with_url() {
  local targetfile="$1"
  local url="$2"

  # Check if targetfile exists
  #if [ ! -e "$targetfile" ]; then
  #  echo "Error: Target file '$targetfile' does not exist."
  #  return 1
  #fi

  # Obtain the original owner and permissions of targetfile
  #local owner group perms
  #owner=$(sudo stat -c '%u' "$targetfile")
  #group=$(sudo stat -c '%g' "$targetfile")
  #perms=$(sudo stat -c '%a' "$targetfile")

  sudo rm -f "$targetfile"

  # Download the URL to the targetfile, tracing any errors
  if ! sudo curl -fsSL "$url" -o "$targetfile"; then
    echo "Error: Failed to download: '$url'."
    return 1
  fi

  # Apply the original owner and permissions to the new targetfile
  #sudo chown "$owner":"$group" "$targetfile"
  #sudo chmod "$perms" "$targetfile"
}

# Starting specific installation script

# everything started from current user home
echo "Everything started from current user home: $USER home"
cd ~

echo "Standard Ubuntu repositories update:"
echo "sudo apt update"
sudo apt update

echo "Standard Ubuntu repositories upgrade:"
echo "sudo apt -y upgrade"
sudo apt -y upgrade

# install common linux tools
echo "Installing required packages..."

REQUIRED=(nano curl wget zip unzip git ufw nginx acl logrotate openssl python3 lsb-release gnupg2 ca-certificates apt-transport-https software-properties-common fail2ban tmpreaper finger poppler-utils pdftk)
MISSING=()

# Check for missing commands
for cmd in "${REQUIRED[@]}"; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done

# If any commands are missing, update and install them
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "The following required command(s) are not installed: ${MISSING[*]}"
  sudo apt update
  sudo apt install -y "${MISSING[@]}"
fi

if ! which mysql > /dev/null 2>&1; then
  echo ""
  echo "Install mysql-client"
  sudo apt update
  echo "sudo apt -y install mysql-client"
  sudo apt -y install mysql-client
  echo ""
fi

sudo mkdir -p /usr/share/nginx/html/sps
sudo mkdir -p /etc/nginx/snippets/sps
sudo git clone https://github.com/myspsolution/nginx-custom-error-pages.git /usr/share/nginx/html/sps
sudo git clone https://github.com/myspsolution/nginx-custom-snippets.git /etc/nginx/snippets/sps

FILE_NGINX_CONF=/etc/nginx/nginx.conf

if [ ! -f "$FILE_NGINX_CONF" ]; then
  echo -e "Can not find nginx.conf file:"
  echo -e "${BLD}$FILE_NGINX_CONF${STD}"
  echo ""
  exit
fi

#echo "Find nginx user from file: $FILE_NGINX_CONF"
#if [ $(grep "\s*user\s\+[^\s]\+;$" "$FILE_NGINX_CONF" -m1 -c) -ne 1 ]; then
#  echo -e "Can not determine nginx user from file: ${BLD}${FILE_NGINX_CONF}${STD}"
#  echo ""
#  exit
#fi

#NGINX_USER=$(grep "\s*user\s\+[^\s]\+;$" "$FILE_NGINX_CONF" -m1 | awk -F'[ ]' '{print $NF}' | sed 's/;//')
#echo -e "nginx user: ${BLD}${NGINX_USER}${STD}"

sudo systemctl stop ufw
# disabling IPV6 on ufw
sudo sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw

# enable firewall service
echo "Enable firewall service:"
sudo systemctl start ufw
sudo systemctl enable ufw

echo "Enable nginx service:"
sudo systemctl start nginx
sudo systemctl enable nginx

echo "Set firewall rules, http(s) and ssh (common web server):"
sudo ufw allow http
sudo ufw allow https
sudo ufw allow ssh
sudo ufw --force enable
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw reload

echo "Set config file replacements to be downloaded, as variables:"

URL_BASE="https://raw.githubusercontent.com/myspsolution/orangt-templates/refs/heads/main"

REPLACE_FILE_PHP_FPM_WWW_CONF="${URL_BASE}/php/www.${PHP_VERSION}.conf"

REPLACE_FILE_PHP_INI="${URL_BASE}/php/php.${PHP_VERSION}.ini"

REPLACE_FILE_NGINX_CONF="${URL_BASE}/nginx/nginx.conf"

FILE_LOG_ROTATE_NGINX="/etc/logrotate.d/nginx"
FILE_LOG_ROTATE_PHP_FPM="/etc/logrotate.d/php${PHP_VERSION}-fpm"
FILE_LOG_ROTATE_FIREWALL="/etc/logrotate.d/ufw"
FILE_LOG_ROTATE_SUPERVISOR="/etc/logrotate.d/supervisor"

REPLACE_FILE_LOG_ROTATE_NGINX="${URL_BASE}/logrotate/logrotate-nginx"
REPLACE_FILE_LOG_ROTATE_PHP_FPM="${URL_BASE}/logrotate/logrotate-php${PHP_VERSION}-fpm"
REPLACE_FILE_LOG_ROTATE_FIREWALL="${URL_BASE}/logrotate/logrotate-ufw"
REPLACE_FILE_LOG_ROTATE_SUPERVISOR="${URL_BASE}/logrotate/logrotate-supervisor"

LARAVEL_TOOL_SCRIPT=https://cdn.bitzen19.com/script/install_laravel_tools.sh

# install php
echo "Installing PHP ${PHP_VERSION} and modules/dependencies..."
sudo apt update
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
sudo apt -y upgrade

sudo apt -y install php${PHP_VERSION} php${PHP_VERSION}-common php${PHP_VERSION}-cli php${PHP_VERSION}-fpm php${PHP_VERSION}-curl php${PHP_VERSION}-mysql php${PHP_VERSION}-zip php${PHP_VERSION}-mbstring php${PHP_VERSION}-mcrypt php${PHP_VERSION}-xml php${PHP_VERSION}-pdo php${PHP_VERSION}-bcmath php${PHP_VERSION}-tokenizer php${PHP_VERSION}-iconv php${PHP_VERSION}-gd php${PHP_VERSION}-dev php-pear

sudo apt update
sudo apt -y upgrade
sudo apt autoremove

# check php version and modules
echo "Check installed PHP version:"
php -v

echo "Check installed PHP modules:"
php -m

if [ $(sudo find /etc -type f -name php.ini | wc -l) -eq 0 ]; then
  echo ""
  echo -e "Can't find any file ${BLD}php.ini${STD} under ${BLD}/etc${STD} folder."
  echo -e "${BLD}php is installed but not complete.${STD}"
  echo ""
  exit
fi

if [ $(sudo find /etc -type f -name www.conf | wc -l) -eq 0 ]; then
  echo ""
  echo -e "Can't find any file ${BLD}www.conf${STD} under ${BLD}/etc${STD} folder."
  echo -e "${BLD}php is installed but not complete.${STD}"
  echo ""
  exit
fi

# install composer:
echo "Installing composer..."
cd ~
curl -fsSL https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
sudo chmod +x /usr/local/bin/composer

sudo mkdir -p /var/www/html
sudo rm -f /var/www/html/*
sudo mkdir -p /etc/ssl

# stop services
echo "Stop nginx and php-fpm services:"
sudo systemctl stop nginx
sudo systemctl stop "$PHP_FPM_SERVICE"
sudo systemctl stop ufw

echo "List every php.ini file(s) under /etc folder, backup and replace with downloaded one:"
PHP_INI_FILES=$(sudo find /etc -type f -name php.ini)

find ${PHP_INI_FILES} |
while read filename
  do
    echo "Backup original php.ini and replace it with downloaded one:"
    replace_and_backup_file_with_url "$filename" "${REPLACE_FILE_PHP_INI}"
  done

WWW_CONF_FILES=$(sudo find /etc -type f -name www.conf)
find ${WWW_CONF_FILES} |
while read filename
  do
    echo "Backup original www.conf and replace it with downloaded one:"
    replace_and_backup_file_with_url "$filename" "${REPLACE_FILE_PHP_FPM_WWW_CONF}"
  done

replace_and_backup_file_with_url "${FILE_NGINX_CONF}" "${REPLACE_FILE_NGINX_CONF}"

# We must connect things up so that NGINX (webserver) user can read files that belong to the website user’s group.\:
echo "Add $USER to $NGINX_USER group..."

sudo usermod -aG "$USER" "$NGINX_USER"

# set app folder to current sudo user
echo "Change owner/group of /var/www/html to current user: $USER"

sudo chown "$USER:$USER" /var/www/html

# make nginx virtual hosts
echo "Enable nginx virtual hosts:"
sudo mkdir -p /etc/nginx/sites-available
sudo rm -f /etc/nginx/sites-available/*
sudo mkdir -p /etc/nginx/sites-enabled
sudo rm -f /etc/nginx/sites-enabled/*

sudo rm -f /etc/nginx/sites-enabled/*

echo "Create file: /etc/ssl/dhparams-2048.pem for nginx ssl_dhparam"
echo "It takes a while, please wait..."
sudo openssl dhparam -out /etc/ssl/dhparams-2048.pem 2048

# set proper permission for nginx folder log
echo "Set proper permissions for nginx folder log: /var/log/nginx"

sudo setfacl -R -m "u:$USER:rX" /var/log/nginx

echo "Install supervisor service..."
sudo apt -y install supervisor
sudo systemctl start supervisor
sudo systemctl enable supervisor

sudo setfacl -R -m "u:$USER:rX" /var/log/supervisor

# testing
echo "Test php-fpm and nginx configuration before restarting services:"
sudo "$PHP_FPM_COMMAND" -t
sudo nginx -t

sudo systemctl stop supervisor

echo "Log rotate configuration..."

sudo rm -f /var/log/nginx/*.log

replace_file_with_url "${FILE_LOG_ROTATE_NGINX}" "${REPLACE_FILE_LOG_ROTATE_NGINX}"

echo "Replace $FILE_LOG_ROTATE_PHP_FPM with downloaded version..."
sudo rm -f "/var/log/php${PHP_VERSION}-fpm.log"
replace_file_with_url "${FILE_LOG_ROTATE_PHP_FPM}" "${REPLACE_FILE_LOG_ROTATE_PHP_FPM}"

sudo rm -f /var/log/ufw.log
echo "Replace $FILE_LOG_ROTATE_FIREWALL with downloaded version..."
replace_file_with_url "${FILE_LOG_ROTATE_FIREWALL}" "${REPLACE_FILE_LOG_ROTATE_FIREWALL}"

sudo rm -f /var/log/supervisor/*log
echo "Replace $FILE_LOG_ROTATE_SUPERVISOR with downloaded version..."
replace_file_with_url "${FILE_LOG_ROTATE_SUPERVISOR}" "${REPLACE_FILE_LOG_ROTATE_SUPERVISOR}"

echo "Restart firewall, supervisor, php-fpm and nginx services..."
sudo systemctl start ufw
sudo systemctl restart "$PHP_FPM_SERVICE"
sudo systemctl restart nginx
sudo systemctl restart supervisor

if ! which node > /dev/null 2>&1; then
  echo "Installing node.js...."
  sudo apt update
  sudo apt upgrade -y
  cd ~
  curl -fsSL "https://deb.nodesource.com/setup_${NODE)VERSION}.x" -o nodesource_setup.sh
  sudo -E bash nodesource_setup.sh
  sudo apt-get install -y nodejs
  rm ~/nodesource_setup.sh
fi

curl -fsSL -o "/home/$USER/robots.txt" https://cdn.bitzen19.com/script/robots.txt

echo "Download and install laravel tools installation script..."
sudo rm -f /tmp/install-laravel-tools.sh
curl -fsSL "$LARAVEL_TOOL_SCRIPT" -o /tmp/install-laravel-tools.sh && bash /tmp/install-laravel-tools.sh
sudo rm -f /tmp/install-laravel-tools.sh

echo ""

echo "PHP and supported components installation is finished. Next, updated sysinfo will be displayed."
echo "Press [ENTER] to continue"

read

echo -e "${YLW}spstool sysinfo${STD}"
echo ""
spstool sysinfo
