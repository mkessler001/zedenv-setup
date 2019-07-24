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

# Basic setup

passwd

ln -s /proc/self/mounts /etc/mtab

apt update
locale-gen --purge en_US.UTF-8
update-locale LANG=en_US.UTF-8 LANGUAGE=en_US
dpkg-reconfigure --frontend noninteractive locales

ln -fs /usr/share/zoneinfo/Europe/Vienna /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

# ZFS support

apt install -y cryptsetup dosfstools git python3-setuptools vim
apt install -y --no-install-recommends linux-image-generic zfs-initramfs zfs-zed

# Encryption support

echo root UUID=$(blkid -s UUID -o value /dev/disk/by-id/$DISK-part3) none \
     luks,discard,initramfs > /etc/crypttab

# TMPFS

cp /usr/share/systemd/tmp.mount /etc/systemd/system/
systemctl enable tmp.mount

# Disable log compression

for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "$file" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "$file"
    fi
done

# GRUB install

mkdosfs -F 32 -n EFI /dev/disk/by-id/$DISK-part1
mkdir -p /boot/efi
mount /dev/disk/by-id/$DISK-part1 /boot/efi

apt install -y grub-efi-amd64-signed shim-signed

# Refresh the ramdisk files.

update-initramfs -u -k all

echo '
GRUB_DEFAULT=0
#GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
' > /etc/default/grub

update-grub

# Install the UEFI bootloader

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=zedenv --recheck --no-floppy

# Install zedenv

git clone https://github.com/johnramsden/pyzfscmds.git
git clone https://github.com/mkessler001/zedenv.git
git clone https://github.com/mkessler001/zedenv-grub.git

cd pyzfscmds                                                  && python3.6 setup.py install && cd ..
cd zedenv      && git checkout feature-support_extra_bpool-20 && python3.6 setup.py install && cd ..
cd zedenv-grub && git checkout feature-support_extra_bpool    && python3.6 setup.py install && cd ..

# zedenv configuration

zpool set bootfs=rpool/root/default rpool
zedenv set org.zedenv:bootloader=grub
zedenv set org.zedenv.grub:boot=/boot rpool/root
chmod -x /etc/grub.d/10_linux
update-grub

# --- Mounting the filesystem ---

# zfs-import-bpool.service

echo "[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool

[Install]
WantedBy=zfs-import.target" > /etc/systemd/system/zfs-import-bpool.service

# zfs-import-zedenv-boot-env.service

echo "[Unit]
DefaultDependencies=no
After=zfs-import-bpool.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount_boot_pool 

[Install]
WantedBy=zfs-import.target" > /etc/systemd/system/zfs-import-zedenv-boot-env.service

# mount_boot_pool

echo '#!/bin/bash
BPOOL="bpool"

BE=`zedenv list -H | grep -oP "^.*(?=\tN.*$)"`

/bin/mount -t zfs "$BPOOL/boot/env/zedenv-$BE" /boot' > /bin/mount_boot_pool

chmod 755 /bin/mount_boot_pool

systemctl enable zfs-import-bpool.service
systemctl enable zfs-import-zedenv-boot-env.service

# /etc/fstab

echo 'bpool/boot/grub   /boot/grub    zfs nodev,relatime,x-systemd.requires=zfs-import-zedenv-boot-env.service 0 0' >> /etc/fstab
echo 'rpool/var/log     /var/log      zfs nodev,relatime 0 0' >> /etc/fstab
echo 'rpool/var/spool   /var/spool    zfs nodev,relatime 0 0' >> /etc/fstab
echo 'rpool/var/tmp     /var/tmp      zfs nodev,relatime 0 0' >> /etc/fstab

echo PARTUUID=$(blkid -s PARTUUID -o value /dev/disk/by-id/$DISK-part1) \
           /boot/efi vfat nofail,x-systemd.device-timeout=5 0 1 >> /etc/fstab

# Configure swap

zfs create -V 4G -b $(getconf PAGESIZE) -o compression=zle \
      -o logbias=throughput -o sync=always \
      -o primarycache=metadata -o secondarycache=none \
      -o com.sun:auto-snapshot=false rpool/swap

mkswap -f /dev/zvol/rpool/swap
echo /dev/zvol/rpool/swap none swap discard 0 0 >> /etc/fstab
echo RESUME=none > /etc/initramfs-tools/conf.d/resume
swapon -av

# Backup and exit

# zfs snapshot bpool/boot@install -r
# zfs snapshot rpool/root/default@install

# exit
