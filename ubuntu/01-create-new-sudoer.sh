#!/bin/bash
# 01-create-new-sudoer.sh
# prepared by dicky.dwijanto@myspsolution.com
# last update: November 5th, 2024

LINUX_DISTRO_CHECK="ubuntu"
# LINUX_VERSION_CHECK="24.04"

# predefined console font color/style
RED="\033[1;41;37m"
BLU="\033[1;94m"
YLW="\033[1;33m"
STD="\033[0m"
BLD="\033[1;97m"

OS_INFO=$(cat /etc/os-release | grep "^PRETTY_NAME=" | sed -n "s/^PRETTY_NAME[ ]*=//p" | xargs)

# --------------- Preliminary checking/validation ---------------

# check Linux distro
if [ $(printf $OS_INFO | egrep -c -i "${LINUX_DISTRO_CHECK}") -eq 0 ]; then
  printf "\n"
  printf "This installation script must be run on ${BLD}${LINUX_DISTRO_CHECK} only${STD}.\n"
  printf "Your detected OS: $OS_INFO\n"
  printf "\n"
  exit 1
fi

# check Linux version
# if [ $(lsb_release -sr | egrep -c -i "${LINUX_VERSION_CHECK}") -eq 0 ]; then
#   echo ""
#   echo -e "This installation script must be run on ${BLD}${LINUX_DISTRO_CHECK} ${LINUX_VERSION_CHECK} only${STD}."
#   echo -e "Your detected OS: ${BLD}${OS_INFO}${STD}"
#   echo -e "Installation is aborted."
#   echo ""
#   exit 1
# fi

# check whether user is root or superuser or sudoer
if [ $(id -u) -ne 0 ]; then
  # check whether user is sudoer or not
  NOT_SUDOER=$(sudo -l -U $USER 2>&1 | egrep -c -i "not allowed to run sudo|unknown user")
  if [ "$NOT_SUDOER" -ne 0 ]; then
    printf "\n"
    printf "${BLD}Please run this script as root (superadmin) or sudoer.${STD}\n"
    printf "This script requires super admin or sudoer.\n"
    printf "\n"
    exit 1
  fi
fi

# --------------- starting script ---------------

clear

printf "\n"

read -p "Input the new username you want to create as a sudoer: " CREATE_USER

while true; do
  read -p "Confirm new username: ${CREATE_USER} ? (y/n) " YN
    if [ "$YN" == "y" ] || [ "$YN" == "n" ]; then
    break;
  else
  echo "Please type [y]es or [n]o : "
  fi
done

if [ "$YN" == "n" ]; then
  printf "\n"
  exit
fi

if [ -d "/home/${CREATE_USER}" ]; then
  printf "\n"
  printf "${RED}User ${CREATE_USER} already exist.${STD}\n"
  printf "ensuring to make ${CREATE_USER} as sudoer:\n"
  printf "${YLW}sudo usermod -aG sudo ${CREATE_USER}${BLD}\n"
  sudo usermod -aG sudo "${CREATE_USER}"
  printf "User creation is aborted.\n"
  printf "\n"
  exit
fi

printf "\n"
printf "Before proceed, ${BLD}MAKE SURE YOU CAN COPY TEXT ON THIS TERMINAL AND PASTE IT TO A FILE${STD}.\n"
printf "The following will create new user ${YLW}${CREATE_USER}${STD} and ${BLD}generate a random secure keypair${STD}.\n"
printf "Then login information including generated keypair will be shown later on this screen.\n"
printf "\n"
read -p "Press [ENTER] when you're ready, or [Ctrl+c] to cancel..." name

printf "create new linux user: ${CREATE_USER}:\n"
printf "${YLW}sudo useradd -m ${CREATE_USER}${STD}\n"
sudo useradd -m "${CREATE_USER}"

if [ "$?" -ne 0 ]; then
  printf "\n"
  printf "${RED}Error creating new user: ${CREATE_USER}${STD}\n"
  printf "\n"
  exit 1
fi

# create random, but unused, password for created user, login requires ssh keypair
GENERATED_PASSWORD=$(openssl rand -base64 32)
#printf "\n"
#printf "set generated random password for user: ${CREATE_USER}...\n"
#printf "${YLW}echo ${CREATE_USER}:[some random password] | sudo chpasswd${STD}\n"
echo "${CREATE_USER}:${GENERATED_PASSWORD}" | sudo chpasswd

if [ "$?" -ne 0 ]; then
  printf "\n"
  printf "${RED}Error creating new user ${CREATE_USER} with auto generated password.${STD}\n"
  printf "\n"
  exit 1
fi

printf "\n"
printf "make ${CREATE_USER} as sudoer:\n"
printf "${YLW}sudo usermod -aG sudo ${CREATE_USER}${BLD}\n"
sudo usermod -aG sudo "${CREATE_USER}"

if [ "$?" -ne 0 ]; then
  printf "\n"
  printf "${RED}Failed to add new user ${CREATE_USER} as sudoer.${STD}\n"
  printf "You may have to make user ${CREATE_USER} as sudoer manually.\n"
fi

printf "\n"
printf "change the default login shell for user ${CREATE_USER} to bash:\n"
printf "${YLW}sudo chsh -s /bin/bash ${CREATE_USER}${STD}\n"
sudo chsh -s /bin/bash "${CREATE_USER}"
sudo -u "${CREATE_USER}" mkdir -p "/home/${CREATE_USER}/.ssh"

printf "\n"
printf "create ssh keypair for user ${CREATE_USER} to bash...\n"
sudo chmod 700 "/home/${CREATE_USER}/.ssh"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub"

sudo -u "${CREATE_USER}" ssh-keygen -t ed25519 -N "" -C "default key for ${CREATE_USER}" -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"

if [ -f "/home/${CREATE_USER}/.ssh/authorized_keys" ]; then
  sudo -u "${CREATE_USER}" sh -c "grep -qxFf /home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub /home/${CREATE_USER}/.ssh/authorized_keys || cat /home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub >> /home/${CREATE_USER}/.ssh/authorized_keys"
else
  sudo -u "${CREATE_USER}" sh -c "cat /home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub > /home/${CREATE_USER}/.ssh/authorized_keys"
fi

sudo chown "${CREATE_USER}:${CREATE_USER}" "/home/${CREATE_USER}/.ssh/authorized_keys"
sudo chmod 600 "/home/${CREATE_USER}/.ssh/authorized_keys"
echo "${CREATE_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/${CREATE_USER}"
sudo chmod 0440 "/etc/sudoers.d/${CREATE_USER}"

HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk "{print $NF}")
THE_DATE=$(date)

printf "\n"
printf "This newly created user login info ${BLD}will be shown only once, so make sure you copy it${STD}.\n"
printf "${YLW}PLEASE COPY AND PASTE TO TEXT FILE AND SAVE THE FOLLOWING:${STD}\n"
printf "${BLD}\n"
printf "**********************************************************************\n"
printf "\n"
printf "LOGIN INFORMATION  :\n"
printf "\n"
printf "server environment : (define later)\n"
printf "hostname           : ${HOSTNAME}\n"
printf "local ip address   : ${LOCAL_IP}\n"
printf "user login         : ${CREATE_USER}\n"
printf "private key        :\n"
printf "\n"
sudo cat "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"
printf "\n"
printf "public key         :\n"
printf "\n"
sudo cat "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp"
sudo rm -f "/home/${CREATE_USER}/.ssh/${CREATE_USER}_private_key_temp.pub"
printf "\n"
printf "last update        : ${THE_DATE}\n"
printf "\n"
printf "**********************************************************************\n"
printf "${STD}\n"
printf "Make sure you have copied information above.\n"
printf "Next, you will be ${BLD}logged out${STD}, and please ${BLD}relogin as ${YLW}${CREATE_USER}${STD} using above keypair\n"
read -p "Press [ENTER] when you're ready to log out ..." name
pkill -KILL -u "$USER"
