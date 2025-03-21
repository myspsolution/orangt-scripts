#!/bin/bash
# 02-install-mariadb-server.sh
# prepared by dicky@bitzen19.com
# last update: June 4th, 2024

# predefined console font color/style
RED='\033[1;41;37m'
BLU='\033[1;94m'
YLW='\033[1;33m'
STD='\033[0m'
BLD='\033[1;97m'

CHECK_USER="orangt"

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

# --------------- Preliminary checking/validation ---------------

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

# check Linux distro: Ubuntu or not
if [ $(echo $OS_INFO | egrep -c -i ubuntu) -eq 0 ]; then
  echo ""
  echo -e "This installation script must be run on ${BLD}Ubuntu only${STD}."
  echo -e "Your detected OS: ${BLD}${OS_INFO}${STD}"
  echo ""
  exit
fi

# check Ubuntu version, must be version 22.04 only
if [ $(lsb_release -sr | egrep -c -i "22.04") -eq 0 ]; then
  echo ""
  echo -e "This installation script must be run on ${BLD}Ubuntu 22.04 only${STD}."
  echo -e "Your detected OS: ${BLD}${OS_INFO}${STD}"
  echo -e "Installation is aborted."
  echo ""
  exit
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

# End of -------- Preliminary checking/validation ---------------

# Starting specific installation script

if which mysql &> /dev/null; then
  echo ""
  MYSQL_VERSION=$(mysql -V | head -1 | egrep -o "\s([0-9\.])+" | head -1)
  echo -e "${BLD}mysql version${MYSQL_VERSION} is already installed on this system.${STD}"
  echo -e "MySQL (MariaDB) installation is aborted."
  echo ""
  exit
fi

cd ~

echo "Standard Ubuntu repositories update:"
echo -e "${YLW}sudo apt -y update${STD}"
sudo apt -y update

echo ""
echo "Standard Ubuntu repositories upgrade:"
echo -e "${YLW}sudo apt -y upgrade${STD}"
sudo apt -y upgrade

echo ""
echo "Install MariaDB Database Server:"
echo -e "${YLW}sudo apt install mariadb-server wget perl -y${STD}"
sudo apt install mariadb-server wget perl -y

echo ""
echo "Install mysqltuner:"
cd ~
echo -e "${YLW}wget http://mysqltuner.pl/ -O mysqltuner.pl${STD}"
wget http://mysqltuner.pl/ -O mysqltuner.pl
echo -e "${YLW}chmod +x mysqltuner.pl${STD}"
chmod +x mysqltuner.pl
echo -e "${YLW}sudo mv mysqltuner.pl /usr/local/bin/mysqltuner${STD}"
sudo mv mysqltuner.pl /usr/local/bin/mysqltuner

HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $NF}')
THE_DATE=$(date)

echo ""
echo -e "Before proceed, ${BLD}MAKE SURE YOU CAN COPY TEXT ON THIS TERMINAL AND PASTE IT SOMEWEHERE ELSE${STD}."
echo -e "The following will ${BLD}generate a random secure password${STD} for mysql (mariadb) ${YLW}root${STD} user."
echo -e "Then database login information including generated password will be shown on screen."
echo -e "You're expected to ${BLD}copy database login information and save it to a text file as documentation${STD},"
echo -e "This database login information ${BLD}will be shown only once, so make sure you copy it${STD}."
echo -e "Press [ENTER] when you're ready"
read

echo "Generating mysql root password and run security related sql commands..."

export MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)

sudo systemctl start mariadb

# Run the commands to set the root password
sudo mysql -u root <<_EOF_
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
_EOF_

echo ""
echo "Restarting mariadb service:"
echo -e "${YLW}sudo systemctl restart mariadb${STD}"
sudo systemctl restart mariadb

if [ -f /home/orangt/server.env ]; then
. /home/orangt/server.env
fi

if [ -z "${SERVER_ENVIRONMENT}" ]; then
  SERVER_ENVIRONMENT="${BLD}(define manually later)${STD}"
else
  SERVER_ENVIRONMENT="${YLW}${YLW}${SERVER_ENVIRONMENT}${STD}"
fi

echo ""
echo -e "${BLD}PLEASE COPY AND PASTE TO TEXT FILE AND SAVE IT THE FOLLOWING DATABASE INFO:${STD}"
echo ""
echo -e "${BLD}DB LOGIN INFORMATION :${STD}"
echo ""
echo -e "database environment : ${SERVER_ENVIRONMENT}"
echo -e "hostname             : ${BLD}${HOSTNAME}${STD}"
echo -e "local ip address     : ${BLD}${LOCAL_IP}${STD}"
echo -e "port                 : ${BLD}3306${STD}"
echo -e "mysql user login     : ${YLW}root${STD}"
echo -e "password             : ${YLW}${MYSQL_ROOT_PASSWORD}${STD}"
echo -e "last update          : ${BLD}${THE_DATE}${STD}"
echo ""

export MYSQL_ROOT_PASSWORD=""

echo "MySQL (MariaDB) Database Server installation is finished. Next, updated sysinfo will be displayed"
echo "Press [ENTER] to continue"

read

echo -e "${YLW}spstool sysinfo${STD}"
echo ""
spstool sysinfo
