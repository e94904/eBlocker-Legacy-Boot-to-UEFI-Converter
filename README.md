# eBlocker-Legacy-Boot-to-UEFI-Converter

[View Source Code on GitHub](https://github.com/e94904/eBlocker-Legacy-Boot-to-UEFI-Converter) | [Download Prebuilt Releases](https://github.com/e94904/eBlocker-Legacy-Boot-to-UEFI-Converter/releases)

This script automatically converts the official eBlocker OS (64-bit) disk image from legacy BIOS (MBR) to include full UEFI boot support. It is designed for modern mini-PCs and Thin Clients that no longer support legacy boot modes.

**Note this has only been tested to work on eBlockerVM-4.0.2 and I have no idea if it will work on future versions. Also, this script is intended to be run on Linux. I have tested it in Ubuntu Multipass and WSL but it may not work on your distro. **

## Pre-Built Images

To download the prebuilt images, go to the releases tab and it is visible there. Download the one appropriate for your system. 

[https://github.com/e94904/eBlocker-Legacy-Boot-to-UEFI-Converter/releases/tag/Standard](https://github.com/e94904/eBlocker-Legacy-Boot-to-UEFI-Converter/releases/tag/Standard)


## How It Works

By default, the stock eBlocker 64-bit disk image only includes a single Linux partition formatted with an MBR (Master Boot Record). This script fully automates the conversion process without requiring you to flash the image first:

1. Modifies the disk image directly to convert the partition table from MBR to GPT.
2. Allocates a new 200MB FAT32 EFI boot partition.
3. Uses a lightweight `chroot` environment to automatically fetch and install the official Debian `grub-efi-amd64` bootloader packages.
4. Generates a new `grub.cfg` and updates the internal `/etc/fstab` to properly mount the EFI partition on boot.


## The Scripts

There are two scripts provided in this repository. Both will output a fully working UEFI-bootable image and preserve your original `.img` or `.img.xz` file. Both resulting images have been tested and verified to successfully boot in VirtualBox. 

Why two? The original stock eBlocker image is exactly 8,192 MiB (~8.59 GB). However, most consumer "8GB" SSDs actually format to around 7.45 GiB of usable space. 

### 1. `create-uefi.sh` (Recommended)
This is the standard script and the safest approach because it avoids touching the internal Linux filesystem entirely. It simply appends the new 200MB EFI partition to the very end of the existing file. 
* **Final Image Size:** ~8,392 MiB (~8.8 GB)
* **Usage:** Use this script if you are flashing to a 16GB, 32GB, or larger drive. 

### 2. `create-uefi-shrunken.sh` 
If you are flashing eBlocker to an older Thin Client that *actually* has a strict 8GB SSD (or a 8GB mSATA module), the standard image will be too large and Etcher will fail. This script takes the extra steps to shrink the internal Linux filesystem (which is mostly empty space anyway), rebuild the partition boundaries, and trim the image down.
* **Final Image Size:** 7,200 MiB (~7.03 GB)
* **Usage:** Use this script only if you absolutely need the image to securely fit on a small 8GB consumer SSD.



## Usage

Both scripts handle `.img`, `.xz`, or `.gz` files natively. If you pass a compressed archive, it will automatically stream the decompression into the new file to save disk space!

```bash
# Make the script executable
chmod +x create-uefi.sh

# Run the script with sudo and pass your eBlocker image
sudo ./create-uefi.sh eBlockerVM-4.0.2-amd64-beta.img.xz
```

When finished, the script will output a new UEFI-compatible image named `eBlockerVM-4.0.2-amd64-beta-uefi.img.xz` that is ready to be flashed to your SSD or USB using BalenaEtcher or Linux Disks. I used Linux Mint and then used the Disks app to image my internal SSD but that isn't the only way. 
