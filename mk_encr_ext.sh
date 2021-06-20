#!/bin/bash
#
# This script will make an encrypted root file system on a USB drive with the
# following steps:
#   1) create a LUKS key that is locked up by htc
#   2) create a LUKS dm-crypt partition on an external drive
#   3) create an ext4 volume on the dm-crypt partition
#   5) copy the existing root file system on /dev/mmcblkXpY (X=0, Y=2 by default)
#      to the dm-crypt volume
#   6) create an initramfs which will be used to boot to the dm-crypt volume
#   7) reboot to transfer control to the new root file system
#   8) the new root file system starts a service which scrubs and removes the
#      old root file system and then removes itself

# Ensure running as root or exit
if [ "$(id -u)" != "0" ]
then
  echo "run this as root or use sudo" 2>&1 && exit 1
fi

usage() { echo "Usage: $0 [-x <path to external storage device (e.g. /dev/sdX>] [-s <max size of new root part>] [-p <ext part num>] [-m <src part num>]" 1>&2; exit 1; }

MMC_DEV_NUM="0"
RFS_DST_PART_NUM="1"
RFS_SRC_PART_NUM="1"

while getopts ":x:s:p:m:d:" o; do
    case "${o}" in
        x)
            EXT_DEV=${OPTARG}
            if [ ! -e "${EXT_DEV}" ]
            then
                echo "specified external device ${EXT_DEV} does not exist"; usage
            fi
            ;;
        s)
            MAX_RFS_SIZE="+${OPTARG}"
            ;;
        p)
            RFS_DST_PART_NUM="${OPTARG}"
            ;;
        m)
            RFS_SRC_PART_NUM="${OPTARG}"
            ;;
        d)
            MMC_DEV_NUM="${OPTARG}"
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z ${EXT_DEV} ]
then
    echo "No volume name (/dev/...) specified. Defaulting to /dev/sda..."
    EXT_DEV="/dev/sda"
fi

MMC_DEV="/dev/mmcblk${MMC_DEV_NUM}"
MMC_SRC_PART="/dev/mmcblk0p${RFS_SRC_PART_NUM}"
EXT_RFS_PART="${EXT_DEV}${RFS_DST_PART_NUM}"

# Determine if we are running on an NVidia Jetson platform
grep "NVIDIA" /proc/device-tree/model
if [ $? -ne 0 ]
then
   echo "This script is meant to be run on the NVidia ARM platforms (e.g. Jetson). Aborting..."
   exit -1
fi

# Stop udisks2 service from auto mounting partitions
echo "Stopping udisks2..."
systemctl stop udisks2.service
sleep 10
echo "done."

# Unmount the temporary boot device
umount ${EXT_RFS_PART} &>/dev/null

# Format the external mass media
echo -n "Formatting external storage media on ${EXT_DEV}..."
dd if=/dev/zero of=${EXT_DEV} bs=512 count=1 conv=notrunc >/dev/null || exit
sync
echo -e "n\np\n${RFS_DST_PART_NUM}\n\n${MAX_RFS_SIZE}\nw\n" | fdisk ${EXT_DEV} >/dev/null || exit


# Make a htc-locked LUKS key
echo -n "Creating LUKS key..."
dd if=/dev/urandom of=/run/key.bin bs=512 count=4 || exit
cp /run/key.bin /var/lib/htc/key.bin.lock || exit
echo "done."

# Write a self-destruct script to erase the old root file system after the
# first boot on the new root

# Copy /var/lib/htc and all standalone htc utilities to initramfs
cat > /etc/initramfs-tools/hooks/htc_cryptfs_cfg <<"EOF"
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

mkdir -p ${DESTDIR}/var/lib/htc/
mkdir -p ${DESTDIR}/etc/cryptroot/
cp -prf /var/lib/htc/* ${DESTDIR}/var/lib/htc/
copy_exec /sbin/passdevc /sbin/
copy_file firmware /lib/firmware/tegra21x_xusb_firmware
copy_exec /sbin/cryptsetup /sbin/
copy_exec /sbin/passdevsh /sbin/

EOF
chmod +x /etc/initramfs-tools/hooks/htc_cryptfs_cfg

# Add crypto fs stuff to the kernel command line
# Get current file for kernel command line. Default to cmdline.txt
# if not present
cat > /run/mod_extlinux.py <<"EOF"
import sys
with open(sys.argv[1], "r") as fd:
    elc = fd.readlines()
    section_start = False
    new_elc = elc
    ln_idx = 0
    for ln in elc:
        if not section_start and "LABEL primary" in ln:
            section_start = True
        if section_start:
            ln = ln.rstrip()
            if "APPEND ${cbootargs}" in ln:
                ln += " %s\n" % (sys.argv[2])
                new_elc[ln_idx] = ln
                break
            if len(ln) == 0:
                # Get the previous line's space count
                prev_ln = elc[ln_idx-1]
                spc_cnt = len(prev_ln) - len(prev_ln.lstrip(' '))
                iln = "APPEND ${cbootargs} %s\n" % (sys.argv[2])
                new_elc.insert(ln_idx, iln.rjust(len(iln) + spc_cnt))
                break
        ln_idx += 1
print("".join(new_elc))
EOF
cmdline_file="/boot/extlinux/extlinux.conf"
cp ${cmdline_file} ${cmdline_file}.original
sed -i "s/root=[^ ]*//" ${cmdline_file}
sed -i "s/rootfstype=[^ ]*//" ${cmdline_file}
sed -i "s/cryptdevice=[^ ]*//" ${cmdline_file}
if [ ! -f /boot/initrd.original ]
then
   cp /boot/initrd /boot/initrd.original
fi
python3 /run/mod_extlinux.py ${cmdline_file} "root=/dev/mapper/cryptrfs cryptdevice=${EXT_RFS_PART}:cryptrfs" > ${cmdline_file}.new
cp ${cmdline_file}.new ${cmdline_file}

# Create the dm-crypt volume on external media
echo -n "Formatting crypto file system on ${EXT_DEV}..."
cat /run/key.bin | cryptsetup -q -v luksFormat ${EXT_RFS_PART} - >/dev/null
cat /run/key.bin | cryptsetup luksOpen ${EXT_RFS_PART} cryptrfs --key-file=- >/dev/null
echo "done."
echo -n "Creating ext4 partition on ${EXT_RFS_PART}..."
mkfs.ext4 -j /dev/mapper/cryptrfs -F >/dev/null || exit
echo "done."
# Mount the new crypto volume
echo -n "Mounting new crypto volume..."
crfsvol="/mnt/cryptrfs"
mkdir -p ${crfsvol}
mount /dev/mapper/cryptrfs ${crfsvol} >/dev/null || exit
echo "done."
# Copy all files over to new crypto volume and remove boot partition
echo "Copying files to crypto fs..."
rsync -axHAX --info=progress2 / ${crfsvol}
rm -rf ${crfsvol}/boot/*
sync
echo "done."

# Remove the plaintext key now
shred -u /run/key.bin

# Change fstab to no longer use the unencrypted root volume
rfs=`grep -w "/" ${crfsvol}/etc/fstab | grep -v "^#" | awk '{print $1}'`; sed -i "s|$rfs|#$rfs|" ${crfsvol}/etc/fstab
grep -q "^/dev/mapper/cryptrfs" ${crfsvol}/etc/fstab || echo -e "\n# crypto root fs\n/dev/mapper/cryptrfs /             ext4    defaults,noatime  0       1" >> ${crfsvol}/etc/fstab
grep -q "^${MMC_SRC_PART}" ${crfsvol}/etc/fstab || echo -e "\n# SD card\n${MMC_SRC_PART} /mnt/sd ext4 defaults,noatime 0 1" >> ${crfsvol}/etc/fstab
grep -q "^/mnt/sd/boot" ${crfsvol}/etc/fstab || echo -e "\n# bind mount the boot directory on the SD card\n/mnt/sd/boot /boot none defaults,bind 0 0" >> ${crfsvol}/etc/fstab

# Add crypttab cfg
echo -e "cryptrfs\t${EXT_RFS_PART}\t/var/lib/htc/key.bin.lock\tluks,keyscript=passdevsh,tries=10,timeout=50s" > ${crfsvol}/etc/crypttab

# chroot to future root fs
mount -t proc /proc ${crfsvol}/proc/
mount --rbind /sys ${crfsvol}/sys/
mount --rbind /dev ${crfsvol}/dev/
mount --rbind /run ${crfsvol}/run/
mount --bind /boot ${crfsvol}/boot/
cat << EOF | chroot ${crfsvol} /bin/bash
# Make the initramfs
echo -n "Building initramfs..."
cd /etc/initramfs-tools/hooks
mkinitramfs -o /boot/initrd
EOF
mkdir -p ${crfsvol}/mnt/sd
echo "done."

# Reboot now
echo "Rebooting..."
sync
# reboot
