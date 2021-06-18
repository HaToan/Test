#!/bin/bash
# Ensure running as root or exit
if [ "$(id -u)" != "0" ]
then
echo "run this as root or use sudo" 2>&1 && exit 1
fi

MMC_DEV_NUM="0"
RFS_DST_PART_NUM="1"
RFS_SRC_PART_NUM="1"

if [ -z ${EXT_DEV} ]
then
echo "No volume name (/dev/...) specified. Defaulting to /dev/sda..."
EXT_DEV="/dev/sda"
fi

MMC_DEV="/dev/mmcblk${MMC_DEV_NUM}"
MMC_SRC_PART="/dev/mmcblk0p${RFS_SRC_PART_NUM}"
EXT_RFS_PART="${EXT_DEV}${RFS_DST_PART_NUM}"
tmpvol="/mnt/tmproot"

# Determine if we are running on an NVidia Jetson platform
grep "NVIDIA" /proc/device-tree/model
if [ $? -ne 0 ]
then
echo "This script is meant to be run on the NVidia ARM platforms (e.g. Jetson). Aborting..."
exit -1
fi

mk_initramfs_hook()
{
# Copy /var/lib/zymbit and all standalone utilities to initramfs
cat > /etc/initramfs-tools/hooks/cryptfs_cfg <<"EOF"
#!/bin/sh

PREREQ=""

prereqs() {
     echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /usr/share/initramfs-tools/hook-functions

mkdir -p ${DESTDIR}/var/lib/htc
mkdir -p ${DESTDIR}/etc/cryptroot/
cp -prf /var/lib/htc/* ${DESTDIR}/var/lib/htc
copy_exec /sbin/passdevc /sbin/
copy_file firmware /lib/firmware/tegra21x_xusb_firmware

EOF
chmod +x /etc/initramfs-tools/hooks/cryptfs_cfg
}

install_init_cfg()
{
echo "Installing necessary packages..."

# Unmount the external device
umount ${EXT_RFS_PART}

echo "done."

# Format the USB mass media
echo -n "Formatting USB mass media on ${EXT_DEV}..."
dd if=/dev/zero of=${EXT_DEV} bs=512 count=1 conv=notrunc >/dev/null || exit
sync
echo -e "n\np\n\n\n\nw\n" | fdisk ${EXT_DEV} >/dev/null || exit

# Make an ext4 file system on the temp root fs
mkfs.ext4 -j ${EXT_RFS_PART} -F >/dev/null || exit

# Mount the new file system on temp root fs
mkdir -p ${tmpvol}
mount ${EXT_RFS_PART} ${tmpvol} || exit

# Write the initramfs-tools hook script
mk_initramfs_hook

# Tar up the original boot file system
echo -n "Making a tarball of original boot file system image..."
tar -chzpf ${tmpvol}/original_zk_boot.tgz /boot
echo "done."

# Tar up the original root file system on the root file system
echo -n "Making a tarball of original root file system image..."
tar -czpf ${tmpvol}/original_zk_root.tgz --exclude=var/lib/zymbit --one-file-system /
echo "done."

# Copy the original root filesystem over to the new drive
echo -n "Creating installer partition on ${EXT_RFS_PART}..."
rsync -axHAX --info=progress2 / ${tmpvol}
}

# Check for an external volume
if [ ! -e ${EXT_DEV} ]
then
echo "Storage device ${EXT_DEV} not detected"
exit 1
fi

# Stop the Udisks2 service from auto mounting partitions
echo "Stopping udisks2..."
systemctl stop udisks2.service
sleep 10
echo "done."

# Unmount the temporary boot device
umount ${EXT_RFS_PART} &>/dev/null

# Mount the temporary partition
mkdir -p ${tmpvol}
mount ${EXT_RFS_PART} ${tmpvol}
if [ $? != 0 ]
then
    echo "Mounting failed. Installing crypto installer on ${EXT_DEV}."
    install_init_cfg
fi

# Check for the existence of the distro tarball on the temporary root file
# system
if [ ! -f ${tmpvol}/original_zk_root.tgz ]
then
echo "Distro tarball not found on tmp root fs. Installing crypto installer on ${EXT_DEV}."
install_init_cfg
fi

rfs_type=`mount | grep " / " | awk '{print $5}'`
if [ "$rfs_type" != "ext4" ]
then
echo "Root file system type is not ext4. Installing crypto installer on ${EXT_DEV}."
install_init_cfg
fi

# Remove any stale bindings that might be on the tmproot and copy over
# the existing bindings from current root to tmproot
rm -rf ${tmpvol}/var/lib/zymbit/ 2>/dev/null
cp -rpf /var/lib/zymbit/ ${tmpvol}/var/lib/
# Copy the /etc/hosts and /etc/hostname
cp /etc/hosts ${tmpvol}/etc
cp /etc/hostname ${tmpvol}/etc
# Copy ssh keys
cp /etc/ssh/*_key* ${tmpvol}/etc/ssh

#Edit to boot to external device
sed -i "s@${MMC_SRC_PART}@${EXT_RFS_PART}@" /boot/extlinux/extlinux.conf

# Reboot now into instaler partition.
echo "root file sys conversion phase 1 complete."
echo "Rebooting to installer partition to start phase 2..."
sync
reboot
