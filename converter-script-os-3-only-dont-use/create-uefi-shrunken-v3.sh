#!/bin/bash
# create-uefi-shrunken.sh - Converts an eBlocker OS image to UEFI bootable AND shrinks it to fit an 8GB SSD.
# Usage: sudo ./create-uefi-shrunken.sh <input_image.img>

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

if [ -z "$1" ]; then
  echo "Usage: $0 <input_image.img>"
  exit 1
fi

INPUT_FILE="$1"
FILENAME=$(basename -- "$INPUT_FILE")

# Determine uncompressed basename
if [[ "$FILENAME" == *.xz ]]; then
    EXT_REMOVED="${FILENAME%.xz}"
    BASENAME="${EXT_REMOVED%.*}"
elif [[ "$FILENAME" == *.gz ]]; then
    EXT_REMOVED="${FILENAME%.gz}"
    BASENAME="${EXT_REMOVED%.*}"
else
    BASENAME="${FILENAME%.*}"
fi

OUTPUT_IMG="${BASENAME}-uefi-shrunken.img"

echo "Installing required host dependencies..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y gdisk dosfstools e2fsprogs xz-utils

if [[ "$INPUT_FILE" == *.xz ]]; then
    echo "Decompressing original image directly to $OUTPUT_IMG (keeps original)..."
    xzcat "$INPUT_FILE" > "$OUTPUT_IMG"
elif [[ "$INPUT_FILE" == *.gz ]]; then
    echo "Decompressing original image directly to $OUTPUT_IMG (keeps original)..."
    zcat "$INPUT_FILE" > "$OUTPUT_IMG"
else
    echo "Copying original image to $OUTPUT_IMG..."
    cp "$INPUT_FILE" "$OUTPUT_IMG"
fi

echo "Setting up loop device to shrink filesystem..."
LOOP_DEV=$(losetup --show -P -f "$OUTPUT_IMG")
echo "Loop device is $LOOP_DEV"

# Backup original swap UUID
SWAP_UUID=$(blkid -s UUID -o value "${LOOP_DEV}p5" || true)
if [ -z "$SWAP_UUID" ]; then
    SWAP_UUID="0f20a39f-1777-4f51-9576-08c4b27097e8" # Fallback to known v3 swap UUID
fi

echo "Checking filesystem..."
e2fsck -y -f "${LOOP_DEV}p1"

echo "Shrinking internal filesystem to 6000M (leaving room for swap)..."
resize2fs -p "${LOOP_DEV}p1" 6000M

echo "Detaching loop device..."
losetup -d "$LOOP_DEV"

echo "Creating new GPT partition table (before truncating to avoid bounds errors)..."
sgdisk -g "$OUTPUT_IMG" || true
sgdisk -o "$OUTPUT_IMG"

echo "Truncating image file to 7200M (fits safely on a 7.45 GiB drive)..."
truncate -s 7200M "$OUTPUT_IMG"

echo "Moving GPT backup header to new end of file..."
sgdisk -e "$OUTPUT_IMG"

# Recreate partition 1 (Root) to match the 6000M filesystem
# 6000M = 6000 * 1024 * 1024 / 512 = 12288000 sectors. Start: 2048, End: 12290047
sgdisk -n 1:2048:12290047 -t 1:8300 "$OUTPUT_IMG"

# Recreate partition 2 (Swap) to 975M (original size)
# 975M = 975 * 1024 * 1024 / 512 = 1996800 sectors. Start: 12290048, End: 14286847
sgdisk -n 2:12290048:14286847 -t 2:8200 "$OUTPUT_IMG"

# Recreate partition 3 (EFI) to 200M
# 200M = 409600 sectors. Start: 14286848, End: 14696447
sgdisk -n 3:14286848:14696447 -t 3:ef00 "$OUTPUT_IMG"

echo "Setting up loop device again..."
LOOP_DEV=$(losetup --show -P -f "$OUTPUT_IMG")
echo "Loop device is $LOOP_DEV"

echo "Re-formatting swap partition with original UUID..."
mkswap -U "$SWAP_UUID" "${LOOP_DEV}p2"

echo "Formatting EFI partition..."
mkfs.fat -F32 "${LOOP_DEV}p3"

echo "Mounting partitions..."
mkdir -p /mnt/eblocker_img
mount "${LOOP_DEV}p1" /mnt/eblocker_img
mkdir -p /mnt/eblocker_img/boot/efi
mount "${LOOP_DEV}p3" /mnt/eblocker_img/boot/efi

echo "Preparing chroot..."
mount --bind /dev /mnt/eblocker_img/dev
mount --bind /proc /mnt/eblocker_img/proc
mount --bind /sys /mnt/eblocker_img/sys
mount --bind /run /mnt/eblocker_img/run
mount --bind /etc/resolv.conf /mnt/eblocker_img/etc/resolv.conf

OS_CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /mnt/eblocker_img/etc/os-release || true)
if [ -z "$OS_CODENAME" ]; then
    OS_CODENAME="bookworm" # fallback
fi

EFI_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP_DEV}p3")

echo "Installing GRUB for UEFI in chroot (Debian $OS_CODENAME)..."
chroot /mnt/eblocker_img /bin/bash << EOF
set -e

# Temporarily disable broken eBlocker repos
sed -i 's/^deb https:\/\/apt.eblocker/#deb https:\/\/apt.eblocker/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true

# Add standard Debian repo temporarily
if [ "$OS_CODENAME" = "buster" ]; then
    echo "deb [check-valid-until=no] http://archive.debian.org/debian buster main" > /etc/apt/sources.list.d/temp-debian.list
    apt-get -o Acquire::Check-Valid-Until=false update
else
    echo "deb http://deb.debian.org/debian $OS_CODENAME main" > /etc/apt/sources.list.d/temp-debian.list
    apt-get update
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated grub-efi-amd64

# Explicitly install GRUB to the fallback path so VirtualBox finds it
grub-install --target=x86_64-efi --efi-directory=/boot/efi --recheck
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
update-grub

# Re-enable eBlocker repos and clean up
sed -i 's/^#deb https:\/\/apt.eblocker/deb https:\/\/apt.eblocker/g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/temp-debian.list

# Update fstab to mount EFI
echo "PARTUUID=${EFI_PARTUUID} /boot/efi vfat defaults 0 1" >> /etc/fstab
EOF

echo "Cleaning up..."
umount -l /mnt/eblocker_img/etc/resolv.conf || true
umount -l /mnt/eblocker_img/run || true
umount -l /mnt/eblocker_img/sys || true
umount -l /mnt/eblocker_img/proc || true
umount -l /mnt/eblocker_img/dev || true
umount -l /mnt/eblocker_img/boot/efi || true
umount -l /mnt/eblocker_img || true
losetup -d "$LOOP_DEV" || true

echo "Compressing the final image back to .xz format (this may take a few minutes)..."
xz -T0 -z "$OUTPUT_IMG"

echo "Done! The shrunken UEFI bootable image is at: ${OUTPUT_IMG}.xz"
