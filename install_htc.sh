#!/bin/bash

mod=""

# ensure running as root or exit
if [ "$(id -u)" != "0" ]; then
  echo "run this as root or use sudo" 2>&1 && exit 1;
fi;

# insure that the group 'gpio' exists
grep "^gpio" /etc/group &>/dev/null
if [ $? -ne 0 ]
then
  if [ "$1" == "-y" ]
  then
     answer="YES"
  else
    echo "Group 'gpio' does not exist. This group is necessary for zymbit software to operate normally."
    read -p 'Type yes in all capital letters (YES) to create this group: ' answer <&1
  fi
  if [ "${answer}" == "YES" ]
  then
    # Add group 'gpio'
    groupadd gpio
    # Modify /etc/rc.local to change the group of /etc/sys/class/gpio
    grep "chown -R root:gpio" /etc/rc.local &>/dev/null
    if [ $? -ne 0 ]
    then
      echo "chown -R root:gpio /sys/class/gpio" >> /etc/rc.local
      echo "chmod -R ug+rw /sys/class/gpio" >> /etc/rc.local
    fi
    # Check for existence of udev rule
    if [ ! -f "/etc/udev/rules.d/80-gpio-noroot.rules" ]
    then
      echo "ACTION==\"add\", SUBSYSTEM==\"gpio\", PROGRAM=\"/bin/sh -c 'chown -R root:gpio /sys/${DEVPATH}; chmod -R g+w /sys/${DEVPATH}'\"" >> /etc/udev/rules.d/80-gpio-noroot.rules
    fi
  else
    echo "Quitting..."
    exit -1
  fi
fi

function pip()
{
   python -m pip $@
}

function pip3()
{
   python3 -m pip $@
}

distro=`lsb_release -c | cut -f2 -d$'\t'`
uname -m | grep "arm"
if [ $? -eq 0 ]
then
   arch=""
else
   arch="-"`uname -m`
fi

# for older versions of Raspbian, insure that apt-transport-https is installed first
echo -n "Installing prerequisites (this might take a few minutes)..."
apt update --allow-releaseinfo-change -y
apt install -y libboost-thread-dev lsb-release libjansson4 &>/dev/null
apt install -y apt-transport-https curl libyaml-dev libssl-dev libcurl4-openssl-dev python3-pip python-setuptools python-dev i2c-tools &>/dev/null

if [ "${distro}" != "focal" ]
then
   apt install -y python-pip
   pip install inotify || exit
   pip install pycurl
   pip install progress
   pip install python-gnupg
fi

pip3 install inotify
pip3 install pycurl
pip3 install progress
pip3 install python-gnupg

# install our packages
echo -n "Installing cryptsetup Packages..."
apt install -y cryptsetup &>/dev/nul || exit

# My app
# Install passdevc
gcc -s -o ./passdevc passdevc.c
chmod +x ./passdevc

cp ./passdevc /lib/cryptsetup/scripts/passdevc
cp ./passdevc /sbin/passdevc

chmod +x /lib/cryptsetup/scripts/passdevc
chmod +x /sbin/passdevc

# Install passdevsh
cp ./passdevsh /lib/cryptsetup/scripts/passdevsh
chmod +x /lib/cryptsetup/scripts/passdevsh

# Download Script encrypt
chmod +x ./mk_encr_ext.sh
mkdir -p /var/lib/htc
mkdir -p /etc/cryptroot/

# install our packages
echo -n "Installing cryptsetup Packages..."
apt install -y cryptsetup &>/dev/nul || exit

echo "Rebooting now..."
reboot
