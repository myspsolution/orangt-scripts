#!/bin/bash
# 02-install-postgresql-server.sh
# prepared by dicky.dwijanto@myspsolution.com
# last update: March 21th, 2025

LINUX_DISTRO_CHECK="ubuntu"
# LINUX_VERSION_CHECK="24.04"
DB_ENGINE=psql
DB_VERSION=17
DB_PORT=5432

# predefined console font color/style
RED="\033[1;41;37m"
BLU="\033[1;94m"
YLW="\033[1;33m"
STD="\033[0m"
BLD="\033[1;97m"

# --------------- Preliminary checking/validation ---------------

if which psql &> /dev/null; then
  echo ""
  PG_VERSION=$(psql -V | head -1 | egrep -o "\s([0-9\.])+" | head -1)
  echo -e "${BLD}PostgreSQL version${PG_VERSION} is already installed on this system.${STD}"
  echo -e "PostgreSQL installation is canceled."
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

REQUIRED=(curl ufw)
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

# Function to validate the IPv4 address
function valid_ip() {
  local ip=$1
  local IFS=.
  local -a octets=($ip)
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  return 0
}

CLIENT_CODE="UNDEFINED"
SERVER_ENVIRONMENT="UNDEFINED"
ALLOW_REMOTE_IP="UNDEFINED"
ENV_FILE="/home/$USER/server.env"
TIMEZONES=("Asia/Jakarta" "Asia/Makassar" "Asia/Jayapura")
CURRENT_TZ=$(timedatectl show -p Timezone --value)
SELECTED_TZ="none"

# Check if the current timezone is in the desired list
if [[ ! "${TIMEZONES[@]}" =~ "${CURRENT_TZ}" ]]; then
  echo ""
  echo -e "Your current timezone is ${BLD}${CURRENT_TZ}${STD}, which is not in the desired list."
  echo ""

  # Prompt the user to choose a timezone
  echo "Please choose a timezone based on your server location:"
  echo ""
  echo -e "${BLD}1${STD} ${YLW}WIB${STD}  : Asia/Jakarta (Default)"
  echo -e "${BLD}2${STD} ${YLW}WITA${STD} : Asia/Makassar"
  echo -e "${BLD}3${STD} ${YLW}WIT${STD}  : Asia/Jayapura"
  echo ""

  # Read user input with default value 1
  read -p "Enter your choice [1-3, default is 1]: " choice
  choice=${choice:-1}

  # Ensure the user inputs 1, 2, or 3
  while [[ ! $choice =~ ^[1-3]$ ]]; do
    echo -e "Invalid input. Please enter a number ${BLD}between 1 to 3${STD}"
    read -p "Enter your choice [1-3, default is 1]: " choice
    choice=${choice:-1}
  done

  # Set the selected timezone
  SELECTED_TZ=${TIMEZONES[$((choice-1))]}
  echo ""
  echo -e "Setting timezone to ${BLD}${SELECTED_TZ}${STD} ..."
  echo -e "${YLW}sudo timedatectl set-timezone ${SELECTED_TZ}${STD}"
  sudo timedatectl set-timezone "${SELECTED_TZ}"
fi

echo ""

# Loop until CLIENT_CODE is defined
while [[ "$CLIENT_CODE" == "UNDEFINED" ]]; do
  # Prompt the user for client code
  echo "Enter this project client code,"
  printf "${BLD}3 to 12 lowercase alphanumeric${STD}, example: ${YLW}myclient${STD}: "
  read CODE_INPUT

  # Validate the input using regex
  if [[ "$CODE_INPUT" =~ ^[a-z0-9]{3,12}$ ]]; then
    # Confirm the client code
    printf "You've entered client code: ${BLD}$CODE_INPUT${STD}\n"
    read -p "Confirm? (y/n): " confirm

    # Check the confirmation input
    while [[ ! "$confirm" =~ ^[yYnN]$ ]]; do
      echo -e "Invalid input. Please enter ${BLD}y${STD} or ${BLD}n${STD}"
      printf "You've entered client code: ${BLD}$CODE_INPUT${STD}\n"
      read -p "Confirm? (y/n): " confirm
    done

    if [[ "$confirm" =~ ^[yY]$ ]]; then
      CLIENT_CODE="$CODE_INPUT"
    else
      echo "Client code is not confirmed. Please try again."
    fi
  else
    echo -e "Invalid client code. It must be ${BLD}3 to 12 lowercase alphanumeric${STD}"
  fi
done

# Proceed with the confirmed CLIENT_CODE
echo ""
echo -e "Client code is set to: ${BLD}${CLIENT_CODE}${STD}"

# Check if the server.env file exists and source it
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
fi

if [[ "$SERVER_ENVIRONMENT" == "UNDEFINED" ]]; then
  echo ""
  # Prompt the user to choose an environment
  echo "Please choose this server environment:"
  echo ""
  echo -e "${BLD}1${STD} ${YLW}dev${STD} (single server, webapp+database)"
  echo -e "${BLD}2${STD} ${YLW}dev-database${STD} (database server only)"
  echo -e "${BLD}3${STD} ${YLW}production${STD} (single server, webapp+database)"
  echo -e "${BLD}4${STD} ${YLW}production-database${STD} (database server only)"
  echo ""
  # Read user input
  read -p "Enter your choice [1-4]: " choice

  # Ensure the user inputs 1-4
  while [[ ! "$choice" =~ ^[1-4]$ ]]; do
    echo -e "Invalid input. Please enter a number ${BLD}between 1 to 4${STD}"
    read -p "Enter your choice [1-4]: " choice
  done

  # Map the choice to the corresponding environment
  case $choice in
    1) SELECTED_ENV="dev" ;;
    2) SELECTED_ENV="dev-database" ;;
    3) SELECTED_ENV="production" ;;
    4) SELECTED_ENV="production-database" ;;
  esac

  # Confirm the selection
  printf "You have selected this server environment is: ${YLW}${SELECTED_ENV}${STD}\n"
  read -p "Confirm? (y/n): " confirm

  # Check the confirmation input
  while [[ ! "$confirm" =~ ^[yYnN]$ ]]; do
    echo -e "Invalid input. Please enter ${BLD}y${STD} or ${BLD}n${STD}"
    printf "You have selected this server environment is: ${YLW}${SELECTED_ENV}${STD}\n"
    read -p "Confirm? (y/n): " confirm
  done

  if [[ "$confirm" =~ ^[yY]$ ]]; then
    # Update or create the server.env file with the selected environment
    echo "SERVER_ENVIRONMENT=${CLIENT_CODE}-${SELECTED_ENV}" > "${ENV_FILE}"
    source "${ENV_FILE}"
    echo ""
    echo -e "Environment has been set to: ${BLD}${CLIENT_CODE}-${SELECTED_ENV}${STD} in ${BLD}${ENV_FILE}${STD}"
  else
    echo "Database installation is cancelled."
    exit 1
  fi
fi
# end of if [[ "$SERVER_ENVIRONMENT" == "UNDEFINED" ]];

HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')
LOCAL_IP_FIRST_SEGMENT=$(hostname -I | awk '{print $1}' | cut -d '.' -f1)
THE_DATE=$(date)

CPU_CORE=$(lscpu | grep '^CPU(s):' | awk '{print $2}')

RAM_TOTAL_MB=$(free -m | grep '^Mem:' | awk '{print $2}')
RAM_TOTAL_USABLE_GB=$(awk "BEGIN {printf \"%.1f\",${RAM_TOTAL_MB}/1024}")
RAM_TOTAL_GB=$(echo ${RAM_TOTAL_USABLE_GB} | awk '{print int($1+0.55)}')

ROOT_DEVICE=$(df / | tail -1 | awk '{print $1}')
ROOT_DEVICE_BASE=$(echo "${ROOT_DEVICE}" | sed 's/[0-9]*$//')
DISK_NAME=$(basename "${ROOT_DEVICE_BASE}")
ROTATIONAL=$(cat /sys/block/${DISK_NAME}/queue/rotational)
if [ "${ROTATIONAL}" -eq 0 ]; then
  SSD_OR_HDD="ssd"
else
  SSD_OR_HDD="hdd"
fi

PG_HBA_CONF="/etc/postgresql/${DB_VERSION}/main/pg_hba.conf"
POSTGRESQL_CONF="/etc/postgresql/${DB_VERSION}/main/postgresql.conf"

BASE_REPO_TEMPLATE_ROOT="https://github.com/myspsolution/orangt-templates/raw/refs/heads/main"

if [[ "$SERVER_ENVIRONMENT" == *database* ]]; then
  # remote connection
  DB_HOST="${LOCAL_IP}"
  REPLACE_PG_HBA_CONF="${BASE_REPO_TEMPLATE_ROOT}/pgsql/ubuntu/pg_hba.${DB_VERSION}.remote.${LOCAL_IP_FIRST_SEGMENT}.conf"
  REPLACE_POSTGRESQL_CONF="${BASE_REPO_TEMPLATE_ROOT}/pgsql/ubuntu/postgresql.${DB_VERSION}.remote.${SSD_OR_HDD}-cpu-${CPU_CORE}-ram-${RAM_TOTAL_GB}.conf"
  printf "\n"

  # prompting for remote web application IP address to connect from
  while [[ "${ALLOW_REMOTE_IP}" == "UNDEFINED" ]]; do
    # Prompt the user for the remote IP address
    printf "Enter the remote ${BLD}web application IP address${STD} to connect from.\n"
    printf "It must be a valid IPv4 address like ${BLD}${LOCAL_IP_FIRST_SEGMENT}.x.x.x${STD} ,\n"
    printf "and ${BLD}not your local IP ${LOCAL_IP}${STD} : "
    read IP_INPUT

    # Extract the first segment of the input IP
    IP_FIRST_SEGMENT=$(echo "${IP_INPUT}" | cut -d '.' -f1)

    # Validate the IP address
    if valid_ip "${IP_INPUT}" && [[ "${IP_FIRST_SEGMENT}" == "${LOCAL_IP_FIRST_SEGMENT}" ]] && [[ "${IP_INPUT}" != "${LOCAL_IP}" ]]; then
      # Confirm the IP address
      printf "You've entered remote web application IP address: ${BLD}${IP_INPUT}${STD}\n"
      read -p "Confirm? (y/n): " confirm

      # Check the confirmation input
      while [[ ! "$confirm" =~ ^[yYnN]$ ]]; do
        printf "Invalid input. Please enter ${BLD}y${STD} or ${BLD}n${STD}.\n"
        printf "You've entered remote web application IP address: ${BLD}$IP_INPUT${STD}\n"
        read -p "Confirm? (y/n): " confirm
      done

      if [[ "$confirm" =~ ^[yY]$ ]]; then
        ALLOW_REMOTE_IP="${IP_INPUT}"
      else
        printf "Web application IP address is not confirmed. Please try again.\n"
      fi
    else
      printf "Invalid IP address: ${YLW}${IP_INPUT}${STD}\n"
      printf "It must be a valid IPv4 address like ${BLD}${LOCAL_IP_FIRST_SEGMENT}.x.x.x${STD} ,\n"
      printf "and ${BLD}not your local IP ${LOCAL_IP}${STD}\n"
    fi
  done
  # end of while [[ "${ALLOW_REMOTE_IP}" == "UNDEFINED" ]]; do
else
  DB_HOST="127.0.0.1"
  REPLACE_PG_HBA_CONF="${BASE_REPO_TEMPLATE_ROOT}/pgsql/ubuntu/pg_hba.${DB_VERSION}.local.conf"
  REPLACE_POSTGRESQL_CONF="${BASE_REPO_TEMPLATE_ROOT}/pgsql/ubuntu/postgresql.${DB_VERSION}.local.conf"
fi

if ! curl -o /dev/null -s --head --fail "${REPLACE_PG_HBA_CONF}"; then
  echo -e "${RED} error ${STD} Unable to access url:${STD}"
  echo -e "${BLD}${REPLACE_PG_HBA_CONF}${STD}"
  echo ""
  exit 1
fi

if ! curl -o /dev/null -s --head --fail "${REPLACE_POSTGRESQL_CONF}"; then
  echo -e "${RED}error${STD} Unable to access url:${STD}"
  echo -e "${BLD}${REPLACE_POSTGRESQL_CONF}${STD}"
  echo ""
  exit 1
fi

# End of -------- Preliminary checking/validation ---------------

# Starting specific installation script

generate_user_string() {
  # Generate random length between 15 and 20
  local length=$(( RANDOM % 6 + 15 ))

  # Generate random lowercase alphanumeric string
  local str=$(tr -dc 'a-z0-9' < /dev/urandom | head -c "$length")

  # Output the result
  echo "user_$str"
}

# Function to generate a random password
generate_random_password() {
  local password=""
  for i in {1..7}; do
    # Generate a segment of random length between 5 and 7
    local length=$((5 + RANDOM % 3))
    # Generate the segment with random alphanumeric characters
    local segment=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1)
    # Append segment to the password with "-"
    password+="${segment}-"
  done
  # Remove trailing "-" and output the password
  echo "${password%-}"
}

replace_file_with_url() {
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

echo ""
echo -e "Before proceed, ${BLD}MAKE SURE YOU CAN COPY TEXT ON THIS TERMINAL AND PASTE IT SOMEWEHERE ELSE${STD}."
echo -e "This will ${BLD}generate a random secure password${STD} for PostgreSQL ${YLW}postgres${STD} user,"
echo -e "followed by ${BLD}generated database credential for web application${STD}."
echo -e "Then database login information including generated password will be shown on screen."
echo -e "You're expected to ${BLD}copy database login information and save it to a text file as documentation${STD},"
echo -e "This database login information ${BLD}will be shown only once, so make sure you copy it${STD}."
read -p "Press [ENTER] when you're ready to continue ..." key

echo ""

if [[ "${SERVER_ENVIRONMENT}" == *dev* ]]; then
  DB_NAME="db_${CLIENT_CODE}_dev"
else
  DB_NAME="db_${CLIENT_CODE}_prod"
fi

DB_USER=$(generate_user_string)
DB_PASSWORD_PROGRESS=$(generate_random_password)
DB_PASSWORD=$(generate_random_password)

cd ~
sudo apt update
sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
sudo apt update
sudo apt install "postgresql-${DB_VERSION}" -y
sudo systemctl start postgresql
sudo systemctl enable postgresql
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} WITH TEMPLATE = template0 ENCODING = 'UTF8' LOCALE = 'en_US.UTF-8';"
sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASSWORD}';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${DB_PASSWORD_PROGRESS}';"

sudo systemctl stop postgresql
sleep 3
replace_file_with_url "${PG_HBA_CONF}" "${REPLACE_PG_HBA_CONF}"
replace_file_with_url "${POSTGRESQL_CONF}" "${REPLACE_POSTGRESQL_CONF}"
sudo systemctl start postgresql

if [ "$?" -ne 0 ]; then
  printf "\n"
  printf "${RED}Error restarting PostgreSQL service after replacing config${STD}\n"
  printf "\n"
  exit 1
fi

echo "Enabling ufw and set firewall rules..."
sudo systemctl stop ufw
# disabling IPV6 on ufw
sudo sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
sudo systemctl start ufw
sudo systemctl enable ufw
sudo ufw allow ssh

if [[ "${ALLOW_REMOTE_IP}" != "UNDEFINED" ]]; then
  sudo ufw allow from "${ALLOW_REMOTE_IP}" to any port "${DB_PORT}" proto tcp
fi

sudo ufw --force enable
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw reload

# display ufw status
printf "\n"
sudo ufw status verbose

#printf "\n"
printf "This database login info ${BLD}will be shown only once, so make sure you copy it${STD}.\n"
printf "${YLW}PLEASE COPY AND PASTE TO TEXT FILE AND SAVE THE FOLLOWING:${STD}\n"
printf "${BLD}\n"
printf "**********************************************************************\n"
printf "\n"
printf "DATABASE LOGIN INFORMATION\n"
printf "\n"
printf "client code      : ${CLIENT_CODE}\n"
printf "database env     : ${SERVER_ENVIRONMENT}\n"
printf "hostname         : ${HOSTNAME}\n"
printf "local ip address : ${LOCAL_IP}\n"
printf "db port          : ${DB_PORT}\n"
printf "db sa/superadmin : postgres (do not use in .env)\n"
printf "db sa password   : ${DB_PASSWORD_PROGRESS}\n"
printf "last update      : ${THE_DATE}\n"
printf "\n"
printf "**********************************************************************\n"
printf "\n"
printf "WEB APP DATABASE CONFIG (.env)\n"
printf "\n"
printf "DB_CONNECTION=pgsql\n"
printf "DB_HOST=${DB_HOST}\n"
printf "DB_PORT=${DB_PORT}\n"
printf "DB_DATABASE=${DB_NAME}\n"
printf "DB_USERNAME=${DB_USER}\n"
printf "DB_PASSWORD='${DB_PASSWORD}'\n"
printf "\n"
printf "**********************************************************************\n"
printf "${STD}\n"
printf "Make sure you have copied information above.\n"
read -p "Press [ENTER] when you're ready to continue ..." key
confirm="x"
while [[ ! "$confirm" =~ ^[yY]$ ]]; do
  printf "Make sure ${BLD}you have copied information above${STD}.\n"
  read -p "Confirm? (y/n): " confirm
done
clear
