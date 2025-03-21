#!/bin/bash
# 03-install-spstool.sh
# prepared by dicky.dwijanto@myspsolution.com
# last update: Nov 8th, 2024

CHECK_USER="orangt"

# predefined console font color/style
RED='\033[1;41;37m'
BLU='\033[1;94m'
YLW='\033[1;33m'
STD='\033[0m'
BLD='\033[1;97m'

# --------------- Preliminary checking/validation ---------------

#if which spstool &> /dev/null; then
#  echo ""
#  echo -e "${BLD}spstool is already installed on this system.${STD}"
#  echo -e "spstool installation is canceled."
#  echo ""
#  exit
#fi

if [ "$USER" != "$CHECK_USER" ]; then
  echo ""
  echo -e "Please run this installation script as user: ${BLD}${CHECK_USER}${STD}"
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

# check Linux distro: Ubuntu or not
if [ $(echo $OS_INFO | egrep -c -i ubuntu) -eq 0 ]; then
  echo ""
  echo -e "This installation script must be run on ${BLD}Ubuntu only${STD}."
  echo -e "Your detected OS: ${BLD}${OS_INFO}${STD}"
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

REQUIRED=(curl git ncat)
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

cd ~

if [ -d "/home/${CHECK_USER}/spstool" ]; then
  sudo rm -rf "/home/${CHECK_USER}/spstool"
fi

sudo rm -f /etc/profile.d/spstool.sh

sudo rm -f /tmp/03-install-spstool.sh

git clone https://github.com/myspsolution/spstool.git spstool

sudo rm -f /usr/local/bin/spstool*
sudo cp /home/${USER}/spstool/spstool* /usr/local/bin/
sudo mv /usr/local/bin/spstool.sh /usr/local/bin/spstool
sudo chmod +x /usr/local/bin/spstool*

echo -e '#!/bin/bash\n/usr/local/bin/spstool sysinfo' | sudo tee /etc/profile.d/spstool.sh > /dev/null
sudo chmod +x /etc/profile.d/spstool.sh

spstool sysinfo
