#!/bin/bash

cd /
crfsvol="/mnt/cryptrfs"
srcpart="/dev/mmcblk0p1"
bootpart_size_kb=$(du -s /boot | awk '{print $1}')
srcpart_sectorstart=$(fdisk -l /dev/mmcblk0 | grep -w ${srcpart} | awk '{print $2}')
srcpart_sectorend=$(fdisk -l /dev/mmcblk0 | grep -w ${srcpart} | awk '{print $3}')
srcpart_sectorsize=$(fdisk -l /dev/mmcblk0 | grep -w ${srcpart} | awk '{print $4}')
let "bootpart_size_sectors=(bootpart_size_kb*2*1024)/512" "bootpart_sectorend=srcpart_sectorstart+bootpart_size_sectors" "new_srcpart_sectorstart=bootpart_sectorend+1"

#Find the next available partition number to create
partcount=$(lsblk | grep mmcblk0p | awk '{print $1}' | wc -l)
partcount=$((${partcount}+1))

for (( i=1; i<=${partcount}; i++))
do
	if ! lsblk | grep -wq mmcblk0p$i
	then
		rootpartnum=$i
      break
	fi
done

#prevent auto mounting during phase 2
echo "Stopping Udisks2..."
systemctl stop udisks2.service
sleep 1
echo "done."

#Make sure GPT backup table is at the backup
sgdisk /dev/mmcblk0 -e

#Shrink the root partition to two partitions, one for boot and one for new root
echo "Repartitioning NVIDIA Device...."
umount ${srcpart}
sgdisk -d 1 -n 1:${srcpart_sectorstart}:${bootpart_sectorend} -n ${rootpartnum}:${new_srcpart_sectorstart}:${srcpart_sectorend} -g /dev/mmcblk0
partprobe /dev/mmcblk0
echo "done."

rootpart=/dev/mmcblk0p${rootpartnum}

sleep 1
mkfs.ext4 -j ${srcpart} -F >/dev/null || exit

echo "Mounting the new boot volume"
mkdir -p /boot
mkdir -p /var/lib/htc/
mount /dev/mmcblk0p1 /boot
tar -xzvf /original_zk_boot.tgz
echo "done."

echo -n "Creating LUKS key..."
ct=0
while [ $ct -lt 3 ]
do
  sleep 1
  let ct=ct+1
  dd if=/dev/urandom of=/run/key.bin bs=512 count=4
  if [ $? -ne 0 ]
  then
    echo "Retrying zkgrifs..."
    continue
  fi
  cp /run/key.bin  /var/lib/htc/key.bin.lock
  if [ $? -ne 0 ]
  then
    echo "Retrying zklockifs..."
  else
    break
  fi
done
if [ $ct -ge 3 ]
then
  echo "LUKS key creation failed"
  exit
fi
echo "done."

# Create the dm-crypt volume on SD card
echo -n "Formatting crypto file system on ${rootpart}..."
cat /run/key.bin | cryptsetup -q -v luksFormat ${rootpart} - >/dev/null
cat /run/key.bin | cryptsetup luksOpen ${rootpart} cryptrfs --key-file=- >/dev/null
echo "done."
echo -n "Creating ext4 partition on ${rootpart}..."
mkfs.ext4 -j /dev/mapper/cryptrfs -F >/dev/null || exit
echo "done."

# Mount the new crypto volume
echo "Copying files to crypto fs..."
mkdir -p ${crfsvol}
mount /dev/mapper/cryptrfs ${crfsvol} >/dev/null || exit
tar -xpf /original_zk_root.tgz -C ${crfsvol}
echo "done."

echo -n "Copying hostname..."
cp /etc/hosts ${crfsvol}/etc
cp /etc/hostname ${crfsvol}/etc
echo "done."

echo -n "Copying ssh keys..."
cp /etc/ssh/*_key* ${crfsvol}/etc/ssh
echo "done."

# Remove the plaintext key now
shred -u /run/key.bin

#copy over the existing bindings from current root to tmproot
mkdir -p ${crfsvol}/var/lib/htc
cp -rpf /var/lib/htc/* ${crfsvol}/var/lib/htc
# Change fstab to no longer use the unencrypted root volume
rfs=`grep -w "/" ${crfsvol}/etc/fstab | grep -v "^#" | awk '{print $1}'`; sed -i "s|$rfs|#$rfs|" ${crfsvol}/etc/fstab
grep -q "^/dev/mapper/cryptrfs" ${crfsvol}/etc/fstab || echo -e "\n# crypto root fs\n/dev/mapper/cryptrfs /             ext4    defaults,noatime  0       1" >> ${crfsvol}/etc/fstab
grep -q "^${srcpart}" ${crfsvol}/etc/fstab || echo -e "\n# Boot\n${srcpart} /boot auto defaults,noatime 0 1" >> ${crfsvol}/etc/fstab

# Add crypttab cfg
echo -e "cryptrfs\t${rootpart}\t/var/lib/htc/key.bin.lock\tluks,keyscript=/lib/cryptsetup/scripts/passdevc,tries=5,timeout=30s" > ${crfsvol}/etc/crypttab
cp /mnt/cryptrfs/etc/crypttab /etc/crypttab

# chroot to future root fs
mount -t proc /proc ${crfsvol}/proc/
mount --rbind /sys ${crfsvol}/sys/
mount --rbind /dev ${crfsvol}/dev/
mount --rbind /run ${crfsvol}/run/
mount --bind /boot ${crfsvol}/boot/

cat << INR | chroot ${crfsvol} /bin/bash
# Make the initramfs
echo -n "Building initramfs..."
cd /etc/initramfs-tools/hooks
mkinitramfs -o /boot/initrd
INR

#Get UUID of /dev/mapper/cryptrfs and the new root partition

crypt_blkid=`blkid | grep /dev/mapper/cryptrfs`
if [ $? -ne 0 ]
then
  echo "Could not /dev/mapper/cryptrfs"
  exit
fi

for kv in ${crypt_blkid}
do
  echo $kv | grep "UUID=" >/dev/null
  if [ $? -eq 0 ]
  then
    crypt_UUID=`echo $kv | cut -d'"' -f2`
  fi
done

root_blkid=`blkid | grep ${rootpart}`
if [ $? -ne 0 ]
then
  echo "Could not locate ${rootpart}"
  exit
fi

for kv in ${root_blkid}
do
  echo $kv | grep "UUID=" >/dev/null
  if [ $? -eq 0 ]
  then
    rootpart_UUID=`echo $kv | cut -d'"' -f2`
  fi
done

#Modify extlinux to boot to the new root fs and boot
sed -i "s@${srcpart}@UUID=${crypt_UUID} cryptdevice=UUID=${rootpart_UUID}:cryptrfs@" /boot/extlinux/extlinux.conf
sed -i "s@/boot/@/@" /boot/extlinux/extlinux.conf

# Reboot now
echo "Rebooting..."
sync
# reboot
exit 0
