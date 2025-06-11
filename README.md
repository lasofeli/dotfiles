# Installation SOP

Clone this repo.
Create /boot and / partitions.
Run pre-install script to format them.
Edit configuration.nix to desired specs.

Create swapfile
Edit hardware-configuration to take advantage of btrfs mount options and the new swapfile.

Sorta like this:

```nix
  boot.initrd.systemd.enable = true; // Not actually sure what this is for?
  boot.loader.efi.efiSysMountPoint = "/efi";
  boot.loader.systemd-boot.xbootldrMountPoint = "/boot";

  swapDevices = [{
    device = "/.swap/swapfile";
    size = 24 * 1024;
  }];

  zramSwap.enable = true;
```

