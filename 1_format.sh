#!/bin/bash
DISK="TODO"

if [ -z "$DISK" ] || [ "$DISK" = "TODO" ] ; then
    echo "Please specify DISK to continue!"
    exit 1
fi
if [ "$EUID" -ne 0 ]
    then echo "Please run as root"
    exit 1
fi

# Clear the partition table with `--zap-all` and partition the disk. This **destroys all data** on the specified device.

sgdisk      --zap-all /dev/disk/by-id/$DISK
partprobe
sgdisk     -n1:1M:+512M   -t1:EF00 -c 1:"EFI_Partition"  /dev/disk/by-id/$DISK
sgdisk     -n2:0:+4096M   -t2:BF01 -c 2:"BOOT_Partition" /dev/disk/by-id/$DISK
sgdisk     -n3:0:0        -t3:8300 -c 3:"ROOT_Partition" /dev/disk/by-id/$DISK
partprobe

umount /mnt/*
umount /mnt
rm -rf /mnt/*
