#!/usr/bin/env bash
set -e # exit on error

print () {
    echo -e "\n\033[1m> $1\033[0m\n"
}

ask () {
    read -p "> $1 " -r
    echo
}

tests () {
    ls /sys/firmware/efi/efivars > /dev/null && \
        ping nixos.org -c 1 > /dev/null &&  \
        modprobe zfs &&                         \
        print "Tests ok"
}

select_disk () {
    select ENTRY in $(ls /dev/disk/by-id/);
    do
        DISK="/dev/disk/by-id/$ENTRY"
        echo "Installing on $ENTRY."
        break
    done
}

wipe () {
    ask "Do you want to wipe all datas on $ENTRY ?"
    if [[ $REPLY =~ ^[Yy]$ ]]
    then
        # Clear disk
        dd if=/dev/zero of="$DISK" bs=512 count=1
        wipefs -af "$DISK"
        sgdisk -Zo "$DISK"
    fi
}


partition_disk () {
    # EFI part
    print "Creating EFI part"
    sgdisk -n1:1M:+1024M -t1:EF00 "$DISK"
    EFI="$DISK-part1"
    
    print "Creating ZFS part"
    sgdisk -n3:0:0 -t3:bf01 "$DISK"
    ZFS="$DISK-part3"

    partprobe "$DISK"
    sleep 1
    
    print "Format EFI part"
    mkfs.vfat "$EFI"
}


create_pool_zroot () {
    # Create ZFS pool
    print "Create ZFS pool zroot"
    zpool create -f -o ashift=12                          \
                 -o autotrim=on                           \
                 -O acltype=posixacl                      \
                 -O compression=zstd                      \
                 -O relatime=on                           \
                 -O xattr=sa                              \
                 -O dnodesize=legacy                      \
                 -O encryption=aes-256-gcm                \
                 -O keyformat=passphrase                  \
                 -O keylocation=prompt                    \
                 -O normalization=formD                   \
                 -O mountpoint=none                       \
                 -O canmount=off                          \
                 -O devices=off                           \
                 -R /mnt                                  \
                 zroot "$ZFS"
}

create_datasets () {
    # ephemeral dataset
    print "Creating ephemeral dataset"
    zfs create -o mountpoint=none zroot/ephemeral

    # eternal dataset
    print "Creating eternal dataset"
    zfs create -o mountpoint=none zroot/eternal

    # slash dataset
    print "Creating slash dataset in ephemereal"
    zfs create -o mountpoint=legacy zroot/ephemeral/slash
    print "Create empty snapshot of slash dataset"
    zfs snapshot zroot/ephemeral/slash@blank

    # /nix dataset
    print "Creating nix dataset in ephemereal"
    zfs create -o mountpoint=legacy -o atime=off zroot/ephemeral/nix
    
    # /home dataset
    print "Creating home dataset in eternal"
    zfs create -o mountpoint=legacy zroot/eternal/home

    # /persist dataset
    print "Creating persist dataset in eternal"
    zfs create -o mountpoint=legacy zroot/eternal/persist

}

mount_datasets () {
  mount -t zfs zroot/ephemeral/slash /mnt
  mkdir /mnt/boot
  mkdir /mnt/nix
  mkdir /mnt/home
  mkdir /mnt/persist
  mount $EFI /mnt/boot
  mount -t zfs zroot/ephemeral/nix /mnt/nix
  mount -t zfs zroot/eternal/home /mnt/home
  mount -t zfs zroot/eternal/persist /mnt/persist
}

generate_hostid () {  
    print "Generate hostid"
    HOSTID=$(head -c8 /etc/machine-id)
}

generate_nixos_config () {
  print "Generate NixOS configuration"
  nixos-generate-config --root /mnt
}

append_nixos_config () {
  HARDWARE_CONFIG=$(mktemp)
  cat << CONFIG > "$HARDWARE_CONFIG"
  networking.hostId = "$HOSTID";
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "$ZFS";
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r zroot/ephemeral/slash@blank
  '';
  boot.kernelParams = [ "elevator=none" ];
}
CONFIG

  print "Append configuration to configuration.nix"
  CONFIG_TEMP=$(mktemp)
  head -n -2 /mnt/etc/nixos/configuration.nix > "$CONFIG_TEMP" && cat "$CONFIG_TEMP" > /mnt/etc/nixos/configuration.nix
  cat "$HARDWARE_CONFIG" >> /mnt/etc/nixos/configuration.nix
}

export_pool () {
    print "Export zpool"
    zpool export zroot
}

import_pool () {
    print "Import zpool"
    zpool import -d /dev/disk/by-id -R /mnt zroot -N -f
    zfs load-key zroot
}

##### MAIN

tests

select_disk

wipe
partition_disk
create_pool_zroot
create_datasets
generate_hostid
export_pool
import_pool
mount_datasets
generate_nixos_config
append_nixos_config


