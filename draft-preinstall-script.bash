#!/bin/bash
set -euo pipefail

echo "=== NixOS Encrypted Setup Script ==="

read -rp "Enter the disk to operate on (e.g., /dev/sda): " DISK
lsblk "$DISK"
read -rp "Is this correct? Type 'YES' to proceed: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo "Aborted."; exit 1; }

echo ">> Checking for sufficient free space..."
FREE_INFO=$(parted -m "$DISK" unit GB print free | grep 'free' | tail -1)
IFS=":" read -r _ START END SIZE _ <<< "$FREE_INFO"
START_GB=${START%GB}
END_GB=${END%GB}
SIZE_GB=${SIZE%GB}

if (( $(echo "$SIZE_GB < 100" | bc -l) )); then
  echo "❌ Not enough continuous free space (found ${SIZE_GB}GB). Aborting."
  exit 1
fi

echo "✅ Found ${SIZE_GB}GB of free space starting at ${START_GB}GB"

BOOT_START="$START_GB"
BOOT_END=$(echo "$BOOT_START + 1" | bc)
LUKS_START="$BOOT_END"
LUKS_END="$END_GB"

# Create boot and LUKS partitions
parted --script "$DISK" mkpart primary fat32 "${BOOT_START}GB" "${BOOT_END}GB"
parted --script "$DISK" mkpart primary "${LUKS_START}GB" "${LUKS_END}GB"
parted --script "$DISK" set 4 boot on

sync
partprobe "$DISK"
sleep 2

# Get partition paths
BOOT_PART=$(lsblk -lnpo NAME,TYPE "$DISK" | grep part | tail -2 | head -1 | awk '{print $1}')
LUKS_PART=$(lsblk -lnpo NAME,TYPE "$DISK" | grep part | tail -1 | awk '{print $1}')

# Set XBOOTLDR and Linux filesystem types
sgdisk --typecode=4=EA00 "$DISK"    # XBOOTLDR
sgdisk --typecode=5=8300 "$DISK"    # Linux filesystem

# Format
mkfs.vfat -F32 "$BOOT_PART"
cryptsetup luksFormat "$LUKS_PART"
cryptsetup open "$LUKS_PART" cryptroot
mkfs.btrfs -L nix-system /dev/mapper/cryptroot

# Create subvolumes
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

# Create swapfile
echo ">> Creating 24GB swapfile"
dd if=/dev/zero of=/mnt/.swap/swapfile bs=1M count=24576 status=progress
chmod 600 /mnt/.swap/swapfile
mkswap /mnt/.swap/swapfile

# Mount boot and EFI
echo "Available partitions:"
lsblk "$DISK"
read -rp "Enter the EFI partition (e.g., /dev/sda1): " EFI_PART
mkdir -p /mnt/efi
mount "$EFI_PART" /mnt/efi

mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot

# Run NixOS config generator
echo ">> Running nixos-generate-config"
nixos-generate-config --root /mnt

# Modify hardware-configuration.nix correctly inside the { ... } block
echo ">> Patching hardware-configuration.nix (inside config block)"
HWCONF="/mnt/etc/nixos/hardware-configuration.nix"
TMPFILE=$(mktemp)

inserted_additional_config=0

while IFS= read -r line; do
  echo "$line" >> "$TMPFILE"

  # Patch mount options for all subvolumes except @swap
  if [[ "$line" =~ options\ =\ \[.*subvol=@([a-zA-Z0-9_-]+).* ]]; then
    subvol="${BASH_REMATCH[1]}"
    if [[ "$subvol" != "@swap" ]]; then
      line=$(echo "$line" | sed 's/\]/ "noatime" "ssd" "compress-force=zstd:1" ]/')
      echo "$line" >> "$TMPFILE"
    fi
    if [[ "$subvol" == "@persist" || "$subvol" == "@var_log" ]]; then
      echo "      neededForBoot = true;" >> "$TMPFILE"
    fi
  fi

  # Insert new config block after imports = [...]
  if [[ $inserted_additional_config -eq 0 && "$line" =~ ^[[:space:]]*]; ]]; then
    cat <<EOF >> "$TMPFILE"

  swapDevices = [{
    device = "/.swap/swapfile";
    size = 24 * 1024;
  }];

  zramSwap.enable = true;

  boot.initrd.systemd.enable = true;
  boot.loader.efi.efiSysMountPoint = "/efi";
  boot.loader.systemd-boot.xbootldrMountPoint = "/boot";

EOF
    inserted_additional_config=1
  fi
done < "$HWCONF"

mv "$TMPFILE" "$HWCONF"


# Copy config to persist
mkdir -p /mnt/.persist/etc/nixos
cp -r /mnt/etc/nixos/* /mnt/.persist/etc/nixos/

echo "✅ All setup steps completed successfully."
