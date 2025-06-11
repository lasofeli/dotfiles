#!/bin/bash
set -euo pipefail

echo "=== NixOS Encrypted Setup Script ==="

# Prompt for existing partitions
read -rp "Enter the XBOOTLDR (boot) partition to format as FAT32 (e.g., /dev/sdaX): " BOOT_PART
read -rp "Enter the LUKS/Btrfs partition (e.g., /dev/sdaY): " BTRFS_PART

# Format the boot partition as FAT32
echo ">> Formatting $BOOT_PART as FAT32 for /boot"
mkfs.vfat -F32 "$BOOT_PART"

# Set up LUKS on the Btrfs partition
echo ">> Setting up LUKS encryption on $BTRFS_PART"
cryptsetup luksFormat "$BTRFS_PART"
cryptsetup open "$BTRFS_PART" cryptroot

# Format the decrypted device as Btrfs and create subvolumes
echo ">> Formatting /dev/mapper/cryptroot as Btrfs"
mkfs.btrfs -L nix-system /dev/mapper/cryptroot

echo ">> Creating Btrfs subvolumes"
mount /dev/mapper/cryptroot /mnt
for subvol in @root @home @nix @persist @var_log @machines @portables @swap; do
  btrfs subvolume create "/mnt/$subvol"
done
btrfs subvolume snapshot -r /mnt/@root /mnt/@root-blank
umount /mnt

# Mount subvolumes
mount -o subvol=@root /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,nix,.persist,.swap,var/log,var/lib/machines,var/lib/portables}
mount -o subvol=@home        /dev/mapper/cryptroot /mnt/home
mount -o subvol=@nix         /dev/mapper/cryptroot /mnt/nix
mount -o subvol=@persist     /dev/mapper/cryptroot /mnt/.persist
mount -o subvol=@var_log     /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@machines    /dev/mapper/cryptroot /mnt/var/lib/machines
mount -o subvol=@portables   /dev/mapper/cryptroot /mnt/var/lib/portables
mount -o subvol=@swap        /dev/mapper/cryptroot /mnt/.swap

# Reminder for swapfile creation
echo "
>> Reminder: Create a swapfile on the @swap subvolume (e.g., using chattr +C, dd, mkswap, and enabling it) before proceeding with NixOS installation.
"

# Mount EFI and boot directories
echo ">> Mounting EFI and /boot partitions"
read -rp "Enter the EFI partition to mount at /mnt/efi (e.g., /dev/sdaZ): " EFI_PART
mkdir -p /mnt/efi
mount "$EFI_PART" /mnt/efi

mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# Run NixOS config generator
echo ">> Running nixos-generate-config"
nixos-generate-config --root /mnt

# Note: Manual tweaks to configuration files (swapDevices, boot.loader settings, mountOptions) may be required.

echo "✅ Setup steps completed (partitioning handled manually). Modify /mnt/etc/nixos/configuration.nix as needed and install NixOS."
