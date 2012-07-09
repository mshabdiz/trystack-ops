#!/bin/bash -e
# 
# Installs all the packages that a TryStack management node requires
# and sets up the basic DHCP server, netboot install server and
# Chef Server
SCRIPTS_DIR=$(cd $(dirname "$0") && pwd)
ROOT_DIR=$(cd $SCRIPTS_DIR/../ && pwd)
VAR_DIR=$(cd $ROOT_DIR/var && pwd)
ETC_DIR=$(cd $ROOT_DIR/etc && pwd)
PRECISE_DOWNLOAD_URI="http://www.ubuntu.com/start-download?distro=server&bits=64&release=precise"

if [ ! $USER == "root" ]; then
  echo "Please run this script as root. Exiting."
  exit 1
fi

if [ -z $ZONE_ID ]; then
  if [ $# -eq 0 ]; then
    echo "You need to set the ZONE_ID environment variable or "
    echo "supply it as the first argument to this script."
    exit 1
  fi
  ZONE_ID=$1
fi

NODE_INFO_FILE=$VAR_DIR/zones/${ZONE_ID,,}.info
if [ ! -f $NODE_INFO_FILE ]; then
  echo "Could not locate node info file for zone $ZONE_ID. Expected $NODE_INFO_FILE."
  exit 1
fi

# Exit on error to stop unexpected errors
set -o errexit

# Create the images download and mount directories
IMAGES_DIR=$ROOT_DIR/images
if [[ ! -d $IMAGES_DIR ]]; then
  mkdir -p $IMAGES_DIR/precise/mnt
fi

# Import common functions
source $SCRIPTS_DIR/functions

# Write out the commands we execute to stdout
set -o xtrace

# Grab tools for DHCP and managing servers via IPMI
apt_get install dnsmasq ipmitool --force-yes

# Install Cobbler and register the service nodes in this zone with Cobbler
apt_get install cobbler --force-yes

# cobbler check will cry if Apache isn't restarted...
service apache2 restart

# Grab bootloaders for Cobbler so cobbler check won't cry
cobbler get-loaders

# See if we've got anything we need to check on...
cobbler check || die "Cobbler check failed. Please fix any issues and re-run."

# TODO(jaypipes): Copy the $ETC_DIR/cobbler/settings.tpl and
# replace the placeholder variables, then copy into /etc/cobbler.
# Right now, installing Cobbler installs an /etc/cobbler/settings file
# that already has the server and next-server variables set to the
# management node's IP address automatically.

# Grab the base operating system image that will be used
# on the service nodes
ISO_FILEPATH=$IMAGES_DIR/precise/ubuntu-12.04-server-amd64.iso
if [ ! -f $ISO_FILEPATH ]; then
  wget -O $ISO_FILEPATH $PRECISE_DOWNLOAD_URI
fi

# Mount the Precise ISO and import it into Cobbler
PRECISE_MNT_PATH=$IMAGES_DIR/precise/mnt
mkdir -p $PRECISE_MNT_PATH
mount -o loop $ISO_FILEPATH $PRECISE_MNT_PATH
cobbler import --path=$PRECISE_MNT_PATH --name=precise --arch=x86_64
cobbler sync
umount $PRECISE_MNT_PATH

# Adds a profile to Cobbler for a base service node. Note
# that we use Chef roles to further classify what packages
# and other things are set up on individual service nodes
cobbler profile add --name=service_node --distro=precise-x86_64

# Create a record in Cobbler for each service node in the zone
OIFS=$IFS
IFS=$'\n'
for line in $(<${NODE_INFO_FILE}); do
  if [[ $line == \#* ]]; then
    continue  # Skip comment lines...
  fi
  # Each line in the service node info file is like so:
  # HOSTNAME MAC IP
  hostname=$(echo $line | cut -d ' ' -f 1)
  mac=$(echo $line | cut -d ' ' -f 2 | tr '-' ':')
  ip=$(echo $line | cut -d ' ' -f 3)
  cobbler system add --name=$hostname --mac=$mac --ip-address=$ip --profile=service_node --netboot-enabled=true
done
IFS=$OIFS

cobbler sync
cobbler report

# Install and configure the Chef server
$SCRIPTS_DIR/install_chef_server.sh

# Restart the dnsmasq server
/etc/init.d/dnsmasq restart

# Behave.
exit 0
