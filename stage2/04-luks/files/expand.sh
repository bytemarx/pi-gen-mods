#!/bin/sh
set -euo pipefail

MAPPER_NAME="cryptroot"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

if ! cryptsetup status "${MAPPER_NAME}" >/dev/null 2>&1; then
    echo "ERROR: '${MAPPER_NAME}' is not active." >&2
    exit 1
fi

MAPPER_DEV="/dev/mapper/${MAPPER_NAME}"
BACKING="$(cryptsetup status "$MAPPER_NAME" 2>/dev/null | sed -n 's/ *device:[[:space:]]*//p' | head -n1)"
DISK="/dev/$(lsblk -no PKNAME "$BACKING" 2>/dev/null | head -n1)"
PARTNUM="$(lsblk -no PARTN "$BACKING" 2>/dev/null)"

# Grow partition to 100% of the device
parted -s "$DISK" "resizepart $PARTNUM 100%"

# Re-read partition table
partprobe "$DISK"

# Resize LUKS mapping
cryptsetup resize "$MAPPER_NAME"

# Resize ext4 filesystem inside LUKS
resize2fs "$MAPPER_DEV"
