#!/bin/bash
cp ./install.sh /mnt/install.sh
chmod +x /mnt/install.sh

chroot /mnt /install.sh
