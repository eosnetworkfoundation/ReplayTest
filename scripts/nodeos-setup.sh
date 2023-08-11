#!/usr/bin/env bash

PUBLIC_KEY="${1}"
OS="ubuntu22.04"
LEAP_VERSION="4.0.4"
DEB_FILE="leap_""${LEAP_VERSION}"-"${OS}""_amd64.deb"
DEB_URL="https://github.com/AntelopeIO/leap/releases/download/v""${LEAP_VERSION}"/"${DEB_FILE}"
USER="enf-replay"

TUID=$(id -ur)
# must be root to run
if [ "$TUID" -ne 0 ]; then
  echo "Must run as root"
  exit
fi

## packages ##
apt update >> /dev/null
apt install unzip

## aws cli ##
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install

## root setup ##
# clean out un-needed files
for not_needed_deb_file in /tmp/leap_[0-9]*.deb
do
  if [ "${not_needed_deb_file}" != /tmp/"${DEB_FILE}" ]; then
    echo "removing ${not_needed_deb_file}"
    rm -rf ${not_needed_deb_file}
  fi
done

# download file if needed
if [ ! -f /tmp/"${DEB_FILE}" ]; then
  wget --directory-prefix=/tmp "${DEB_URL}"
fi
# install nodeos
dpkg -i /tmp/"${DEB_FILE}"

# add user
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
"${SCRIPT_DIR}"/adduser.sh "${PUBLIC_KEY}"


## enf-replay user setup ##
# copy scripts and config to location
for dir in scripts config
do
  [ -d /tmp/replay-${dir} ] && rm -rf /tmp/replay-${dir}
  mkdir -m 777 /tmp/replay-${dir}
  cp "${SCRIPT_DIR}"/../${dir}/*.* /tmp/replay-${dir}/
  sudo -i -u "${USER}" cp -r /tmp/replay-${dir} /home/"${USER}"/
done
sudo -i -u "${USER}" /home/"${USER}"/replay-scripts/installnodeos.sh /home/"${USER}"/replay-config/config.ini
