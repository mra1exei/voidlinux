#!/bin/sh
# Void installation.

xbps-install -Su xbps

read -p "Введите путь к диску [/dev/sda]" DEVICE1
wipefs --force --all $DEVICE1
parted --script $DEVICE1 \
    mklabel gpt \
    mkpart primary 1MiB 513MiB \
    mkpart primary 513MiB 100%

read -p "Введите путь к диску [/dev/sdb]" DEVICE2
wipefs --force --all $DEVICE2
parted --script $DEVICE2 \
    mklabel gpt \
    mkpart primary 1MiB 100%

mkfs.vfat -nBOOT -F32 "$DEVICE1"1

cryptsetup luksFormat --type=luks1 "$DEVICE1"2
cryptsetup luksOpen "$DEVICE1"2 cryptboot
mkfs.ext2 -L boot /dev/mapper/cryptboot

cryptsetup luksFormat -s=512 "$DEVICE2"1
cryptsetup luksOpen "$DEVICE2"1 cryptroot
mkfs.btrfs -L root /dev/mapper/cryptroot

BTRFS_OPTS="rw,noatime,ssd,compress=zstd,commit=120"
mount -o $BTRFS_OPTS /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o $BTRFS_OPTS,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home
mount -o $BTRFS_OPTS,subvol=@home /dev/mapper/cryptroot /mnt/home
mkdir -p /mnt/.snapshots
mount -o $BTRFS_OPTS,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mkdir -p /mnt/var/cache
btrfs subvolume create /mnt/var/cache/xbps
btrfs subvolume create /mnt/var/tmp
btrfs subvolume create /mnt/srv
btrfs subvolume create /mnt/var/swap

mkdir -p /mnt/boot/efi
mount -o rw,noatime "$DEVICE1"1 /mnt/boot/efi
mount -o rw,noatime /dev/mapper/cryptboot /mnt/boot

mkdir -p /mnt/{dev,proc,sys}
mount -t proc /proc /mnt/proc
mount --rbind /dev /mnt/dev
mount --rbind /sys /mnt/sys

REPO=https://mirror.yandex.ru/mirrors/voidlinux/current
ARCH=x86_64
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=$ARCH xbps-install -S -R "$REPO" -r /mnt base-system btrfs-progs cryptsetup grub-x86_64-efi

cp /etc/resolv.conf /mnt/etc/
chroot /mnt chown root:root /
chroot /mnt chmod 755 /
chroot /mnt passwd root
read -p "Введите имя компьютера: " HOSTNAME
chroot /mnt echo $HOSTNAME > /etc/hostname
chroot /mnt cat <<EOF > /etc/rc.conf
TIMEZONE="Europe/Moscow"
KEYMAP="en"
EOF
chroot /mnt echo "LANG=en_US.UTF-8" > /etc/locale.conf
chroot /mnt cat <<EOF > /etc/default/libc-locales
en_US.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
EOF
chroot /mnt echo "hostonly=yes" > /etc/dracut.conf.d/hostonly.conf
chroot /mnt xbps-reconfigure -f glibc-locales

UEFI_UUID=$(blkid -s UUID -o value "$DEVICE1"1)
GRUB_UUID=$(blkid -s UUID -o value /dev/mapper/cryptboot)
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/cryptroot)
chroot /mnt cat <<EOF > /etc/fstab
UUID=$ROOT_UUID / btrfs $BTRFS_OPTS,subvol=@ 0 1
UUID=$UEFI_UUID /boot/efi vfat defaults,noatime 0 2
UUID=$GRUB_UUID /boot ext2 defaults,noatime 0 2
UUID=$ROOT_UUID /home btrfs $BTRFS_OPTS,subvol=@home 0 2
UUID=$ROOT_UUID /.snapshots btrfs $BTRFS_OPTS,subvol=@snapshots 0 2
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

chroot /mnt btrfs subvolume create /var/swap
chroot /mnt truncate -s 0 /var/swap/swapfile
chroot /mnt chattr +C /var/swap/swapfile
chroot /mnt btrfs property set /var/swap/swapfile compression none
chroot /mnt chmod 600 /var/swap/swapfile
chroot /mnt dd if=/dev/zero of=/var/swap/swapfile bs=1G count=16 status=progress
chroot /mnt mkswap /var/swap/swapfile
chroot /mnt swapon /var/swap/swapfile

RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/var/swap/swapfile)
chroot /mnt cat << EOF > /etc/default/grub
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR="Void"
GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.uuid=$UEFI_UUID resume=UUID=$ROOT_UUID resume_offset=$RESUME_OFFSET"
GRUB_DISABLE_OS_PROBER=true
GRUB_ENABLE_CRYPTODISK=y
EOF

chroot /mnt grub-install $DEVICE1
chroot /mnt xbps-reconfigure -fa

umount -R /mnt
shutdown -r now
