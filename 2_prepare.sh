#!/bin/bash
DISK="TODO"
HOSTNAME="TODO"
NET_DEVICE="TODO"

if [ -z "$DISK" ] || [ "$DISK" = "TODO" ] ; then
    echo "Please specify DISK to continue!"
    exit 1
fi
if [ -z "$DISK" ] || [ "$HOSTNAME" = "TODO" ]; then
    echo "Please specify HOSTNAME to continue!"
    exit 1
fi
if [ -z "$NET_DEVICE" ] || [ "$NET_DEVICE" = "TODO" ]; then
    echo "Please specify NET_DEVICE to continue!"
    exit 1
fi
if [ "$EUID" -ne 0 ]
    then echo "Please run as root"
    exit 1
fi

umount /mnt/*
umount /mnt
rm -rf /mnt/*

apt update
apt install -y debootstrap gdisk zfs-initramfs zfsutils-linux

# The following command creates a ZFS pool called `bpool` on the second partition.

zpool create -f -o ashift=12 -d \
        -o feature@async_destroy=enabled \
        -o feature@bookmarks=enabled \
        -o feature@embedded_data=enabled \
        -o feature@empty_bpobj=enabled \
        -o feature@enabled_txg=enabled \
        -o feature@extensible_dataset=enabled \
        -o feature@filesystem_limits=enabled \
        -o feature@hole_birth=enabled \
        -o feature@large_blocks=enabled \
        -o feature@lz4_compress=enabled \
        -o feature@spacemap_histogram=enabled \
        -o feature@userobj_accounting=enabled \
        -O acltype=posixacl \
        -O canmount=off \
        -O compression=lz4 \
        -O devices=off \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=/ \
        -R /mnt \
        bpool /dev/disk/by-id/$DISK-part2

# Before we can use the root partition, we have to encrypt it with [`LUKS`](https://en.wikipedia.org/wiki/Linux_Unified_Key_Setup).

cryptsetup luksFormat -c aes-xts-plain64 -s 512 -h sha256 \
        /dev/disk/by-id/$DISK-part3

cryptsetup luksOpen /dev/disk/by-id/$DISK-part3 root

zpool create -f -o ashift=12 \
      -O atime=off \
      -O acltype=posixacl -O canmount=off -O compression=lz4 \
      -O normalization=formD -O relatime=on -O xattr=sa \
      -O mountpoint=/ -R /mnt \
      rpool /dev/mapper/root

# Make sure that the pools are mounted
      
zpool import rpool -R /mnt
zpool import bpool -R /mnt

# Create filesystems to act as container for other datasets.

zfs create -o mountpoint=none -o canmount=off                 rpool/root
zfs create -o mountpoint=none -o canmount=off -o setuid=off   rpool/var
zfs create -o mountpoint=none -o canmount=off -o setuid=off   rpool/var/lib

zfs create -o mountpoint=none -o canmount=off                 bpool/boot
zfs create -o mountpoint=none -o canmount=off                 bpool/boot/env

# Create and mount the default boot environment.

zfs create -o mountpoint=legacy -o canmount=noauto    rpool/root/default
zfs create -o mountpoint=legacy -o canmount=noauto    bpool/boot/env/zedenv-default

mkdir -p /mnt
mount -t zfs rpool/root/default             /mnt/

mkdir -p /mnt/boot
mount -t zfs bpool/boot/env/zedenv-default  /mnt/boot

# Create and mount the dataset for GRUB.

zfs create -o mountpoint=legacy -o canmount=noauto      bpool/boot/grub

mkdir -p /mnt/boot/grub
mount -t zfs bpool/boot/grub  /mnt/boot/grub

# Create the remaining datasets. Manual mounting is only required,  if `mountpoint` is set to `legacy`.

zfs create -o setuid=off                      rpool/home
zfs create -o mountpoint=/root                rpool/home/root
zfs create                                    rpool/opt
zfs create -o com.sun:auto-snapshot=false     rpool/var/cache
zfs create -o com.sun:auto-snapshot=false     rpool/var/lib/docker

zfs create -o mountpoint=legacy -o canmount=noauto -o acltype=posixacl -o xattr=sa            rpool/var/log
zfs create -o mountpoint=legacy -o canmount=noauto                                            rpool/var/spool
zfs create -o mountpoint=legacy -o canmount=noauto -o com.sun:auto-snapshot=false -o exec=on  rpool/var/tmp

mkdir -p /mnt/var/log 
mkdir -p /mnt/var/spool
mkdir -p /mnt/var/tmp

mount -t zfs rpool/var/log        /mnt/var/log
mount -t zfs rpool/var/spool      /mnt/var/spool
mount -t zfs rpool/var/tmp        /mnt/var/tmp
chmod 1777 /mnt/var/tmp

zfs set devices=off rpool

# Install system

debootstrap bionic /mnt

echo $HOSTNAME > /mnt/etc/hostname
echo "127.0.0.1       $HOSTNAME" > /mnt/etc/hosts

echo "
network:
  version: 2
  ethernets:
    $NET_DEVICE:
      dhcp4: true" > /mnt/etc/netplan/01-netcfg.yaml

#  Add APT repositories

echo "
deb     http://archive.ubuntu.com/ubuntu bionic main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu bionic main restricted universe multiverse

deb     http://security.ubuntu.com/ubuntu bionic-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu bionic-security main restricted universe multiverse

deb     http://archive.ubuntu.com/ubuntu bionic-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu bionic-updates main restricted universe multiverse" > /mnt/etc/apt/sources.list


# Prepare chroot for new system

mount --rbind /dev  /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys  /mnt/sys
