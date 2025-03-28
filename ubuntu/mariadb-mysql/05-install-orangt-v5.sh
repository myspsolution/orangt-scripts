#!/bin/bash
# 05-install-orangt-v5.sh
# prepared by dicky.dwijanto@myspsolution.com
# last update: Nov 8th, 2024

CHECK_USER="orangt"

# predefined console font color/style
#RED='\033[1;41;37m'
RED='\033[1;31m'
BLU='\033[1;94m'
YLW='\033[1;33m'
STD='\033[0m'
BLD='\033[1;97m'

function msg_ok() {
  printf "${BLU}\u2714${STD} $1\n"
}

function msg_error() {
  printf "${RED}\u2716${STD} $1${STD}\n"
}

# --------------- Preliminary checking/validation ---------------

if [ "$USER" != "$CHECK_USER" ]; then
  echo ""
  msg_error "Please run this installation script as user: ${BLD}${CHECK_USER}${STD}"
  echo ""
  exit
fi

# Define prerequisites
PREREQUISITES=(spstool php node nginx)

# Loop through each prerequisite and check if it exists
for cmd in "${PREREQUISITES[@]}"; do
  if ! which "${cmd}" &> /dev/null; then
    echo ""
    msg_error "Please install ${BLD}${cmd}${STD} prior to this installation"
    echo ""
    exit
  fi
done

# check internet connection
if ! ping -q -c 1 -W 1 google.com > /dev/null; then
  echo ""
  msg_error "No internet connection detected"
  echo "This installation script requires internet connection to download required libraries/repositories"
  echo "Please set proper network and internet connection on this server before proceed"
  echo ""
  exit
fi

OS_INFO=$(cat /etc/os-release | grep "^PRETTY_NAME=" | sed -n "s/^PRETTY_NAME[ ]*=//p" | xargs)

# check Linux distro: Ubuntu or not
if [ $(echo $OS_INFO | egrep -c -i ubuntu) -eq 0 ]; then
  echo ""
  msg_error "This installation script must be run on ${BLD}ubuntu only${STD}"
  printf "Your detected OS: ${BLD}${OS_INFO}${STD}\n"
  echo ""
  exit
fi

# check whether user is root or superuser
if [ $(id -u) -eq 0 ]; then
  echo ""
  msg_error "Please run this script as ${BLD}sudoer user${STD}"
  echo "Running this script as root or superuser is prohibited"
  printf "Please googling: ${BLD}create sudo user ubuntu linuxize${STD}\n"
  echo ""
  exit
fi

# check whether user is sudoer or not
NOT_SUDOER=$(sudo -l -U $USER 2>&1 | egrep -c -i "not allowed to run sudo|unknown user")
if [ "$NOT_SUDOER" -ne 0 ]; then
  echo ""
  msg_error "${BLD}user ${USER} is not a sudoer user.${STD}"
  echo "Please run this script as sudoer"
  printf "Please googling: ${BLD}create sudo user ubuntu linuxize${STD}\n"
  echo ""
  exit
fi

is_valid_domain() {
  local domain=$1
  # Regular expression for validating FQDN with multi-level domains
  if [[ $domain =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    return 0
  else
    return 1
  fi
}

# End of -------- Preliminary checking/validation ---------------

clear

# Prompt user for PROJECT_DOMAIN
while true; do
  printf "Enter ${BLD}PROJECT DOMAIN${STD}, example: ${YLW}orangt.example.com${STD} : "
  read PROJECT_DOMAIN
    if is_valid_domain "$PROJECT_DOMAIN"; then
      break
    else
     msg_error "Invalid domain format. Please enter a valid domain like: ${YLW}orangt.example.com${STD}"
    fi
done

if [ -d "/var/www/html/${PROJECT_DOMAIN}" ]; then
  echo ""
  msg_error "Project: ${BLD}$PROJECT_DOMAIN${STD} is already created"
  echo "Installation is canceled"
  echo ""
  exit
fi

if [ -d "/var/www/html/${PROJECT_DOMAIN}.backend" ]; then
  echo ""
  msg_error "Project: ${BLD}$PROJECT_DOMAIN.backend${STD} is already created"
  echo "Installation is canceled"
  echo ""
  exit
fi

# Prompt user for BACKEND_REPO
while true; do
  printf "Enter ${BLD}BACKEND REPO${STD}, example: ${YLW}gitlab.com/user/repo.git${STD} : "
  read BACKEND_REPO
  if [[ $BACKEND_REPO =~ ^gitlab\.com/.+ ]]; then
    break
  else
    msg_error "Invalid repository format. Please enter a valid repository URL like: ${YLW}gitlab.com/user/repo.git${STD}"
  fi
done

# Prompt user for BACKEND_TOKEN
while true; do
  printf "Enter ${BLD}BACKEND TOKEN${STD}: "
  read BACKEND_TOKEN
  if [[ ${#BACKEND_TOKEN} -ge 10 ]]; then
    break
  else
    msg_error "Invalid token. Please enter token string with  ${BLD}at least 10 characters${STD}"
  fi
done

# Prompt user for BACKEND_REPO
while true; do
  printf "Enter ${BLD}FRONTEND REPO${STD}, example: ${YLW}github.com/user/repo.git${STD} : "
  read FRONTEND_REPO
  if [[ $FRONTEND_REPO =~ ^github\.com/.+ ]]; then
    break
  else
    msg_error "Invalid repository format. Please enter a valid repository URL like: ${YLW}github.com/user/repo.git${STD}"
  fi
done

# Prompt user for BACKEND_TOKEN
while true; do
  printf "Enter ${BLD}FRONTEND TOKEN${STD}: "
  read FRONTEND_TOKEN
  if [[ ${#FRONTEND_TOKEN} -ge 10 ]]; then
    break
  else
    msg_error "Invalid token. Please enter token string with ${BLD}at least 10 characters${STD}"
  fi
done

echo "OK1"

exit

GIT_URL_BACKEND="https://oauth2:${BACKEND_TOKEN}@${BACKEND_REPO}"
GIT_URL_FRONTEND="https://oauth2:${FRONTEND_TOKEN}@${FRONTEND_REPO}"

echo ""
echo "Checking backend repo and token..."
if ! git ls-remote "${GIT_URL_BACKEND}" > /dev/null; then
  echo ""
  msg_error "Invalid backend repo and/or token"
  echo ""
  exit 1
fi

msg_ok "backend repo and token valid"
echo ""

echo "Checking frontend repo and token..."
if ! git ls-remote "${GIT_URL_FRONTEND}" > /dev/null; then
  echo ""
  msg_error "Invalid frontend repo and/or token"
  echo ""
  exit 1
fi

msg_ok "frontend repo and token valid"

sudo mkdir -p /var/www/html

cd /var/www/html

echo ""

echo "cloning backend source..."

git clone "${GIT_URL_BACKEND}" "${PROJECT_DOMAIN}.backend"

sudo chown -R "$USER:$USER" "/var/www/html/${PROJECT_DOMAIN}.backend"

rm -f "/var/www/html/${PROJECT_DOMAIN}.backend/.env"

mv "/var/www/html/${PROJECT_DOMAIN}.backend/.env.example" "/var/www/html/${PROJECT_DOMAIN}.backend/.env"

cd /var/www/html

echo ""

echo "cloning frontend source..."

git clone "${GIT_URL_FRONTEND}" "${PROJECT_DOMAIN}"

sudo chown -R "$USER:$USER" "/var/www/html/${PROJECT_DOMAIN}"

rm -f "/var/www/html/${PROJECT_DOMAIN}/.env.production"

mv "/var/www/html/${PROJECT_DOMAIN}/.env.production.example" "/var/www/html/${PROJECT_DOMAIN}/.env.production"

echo ""

echo "please modify these env files, and continue..."
echo "nano /var/www/html/${PROJECT_DOMAIN}.backend/.env"
echo "nano /var/www/html/${PROJECT_DOMAIN}/.env.production"

cd /var/www/html

echo ""
