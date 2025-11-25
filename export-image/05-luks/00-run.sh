#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"
[ -f "${IMG_FILE}" ] || { log "Image not found: ${IMG_FILE}"; exit 1; }

# Source rootfs directory (where pi-gen built the OS tree for export).
: "${EXPORT_ROOTFS_DIR:?EXPORT_ROOTFS_DIR not set}"
: "${ROOTFS_DIR:?ROOTFS_DIR not set}"

# Passphrase source (exported in build.sh / config)
: "${LUKS_PASSPHRASE:?LUKS_PASSPHRASE must be set in config}"

# Reuse the loop device set up by export-image/prerun.sh
LOOP_DEV="$(losetup -n -O NAME -j "${IMG_FILE}" || true)"
if [ -z "${LOOP_DEV}" ]; then
	log "ERROR: No loop device found for ${IMG_FILE} (did export-image/prerun.sh run?)"
	exit 1
fi

ensure_loopdev_partitions "${LOOP_DEV}"

BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

log "Using loop device ${LOOP_DEV} (root partition ${ROOT_PART}) for LUKS conversion."

log "DEBUG: Current mounts before unmount attempts:"
mount | sed 's/^/DEBUG:   /'

log "DEBUG: realpath(ROOTFS_DIR) = $(realpath "${ROOTFS_DIR}")"
log "DEBUG: looking for existing mount of ROOTFS_DIR..."
if mount | awk '{print $3}' | grep -qx "$(realpath "${ROOTFS_DIR}")"; then
    log "Un-mounting existing plaintext rootfs at ${ROOTFS_DIR}."
    unmount "${ROOTFS_DIR}"
else
    log "DEBUG: No mount entry exactly matching $(realpath "${ROOTFS_DIR}")"
fi

if mount | awk '{print $3}' | grep -qx "$(realpath "${ROOTFS_DIR}/boot/firmware")"; then
	log "Un-mounting existing boot partition at ${ROOTFS_DIR}/boot/firmware."
	unmount "${ROOTFS_DIR}/boot/firmware"
fi

# --- 1. Encrypt the root partition with LUKS ---

log "Creating LUKS container on ${ROOT_PART}..."

# DEBUG: Inspect what is still using ${ROOT_PART} before wipefs.
log "DEBUG: ROOTFS_DIR = ${ROOTFS_DIR}"
log "DEBUG: mount entries mentioning ${ROOT_PART}:"
mount | grep "${ROOT_PART}" || log "DEBUG: (no direct mount entry for ${ROOT_PART})"

log "DEBUG: mount entries under ROOTFS_DIR (${ROOTFS_DIR}):"
mount | grep "$(realpath "${ROOTFS_DIR}")" || log "DEBUG: (no mount entries under ROOTFS_DIR)"

log "DEBUG: findmnt -rno SOURCE,TARGET for ${ROOT_PART}:"
if command -v findmnt >/dev/null 2>&1; then
    findmnt -rno SOURCE,TARGET "${ROOT_PART}" || log "DEBUG: findmnt reports no mount for ${ROOT_PART}"
else
    log "DEBUG: findmnt not available"
fi

log "DEBUG: lsblk -f ${LOOP_DEV}:"
lsblk -f "${LOOP_DEV}" || log "DEBUG: lsblk failed for ${LOOP_DEV}"

log "DEBUG: dmsetup ls (if any):"
if command -v dmsetup >/dev/null 2>&1; then
    dmsetup ls || log "DEBUG: no dmsetup mappings"
else
    log "DEBUG: dmsetup not available"
fi

log "DEBUG: fuser -vm ${ROOT_PART} (if available):"
if command -v fuser >/dev/null 2>&1; then
    fuser -vm "${ROOT_PART}" || log "DEBUG: fuser reports no processes on ${ROOT_PART}"
else
    log "DEBUG: fuser not available"
fi

# Wipe old filesystem signatures on the root partition
wipefs -a "${ROOT_PART}"

# Create LUKS container
printf '%s' "${LUKS_PASSPHRASE}" | \
  cryptsetup luksFormat --batch-mode "${ROOT_PART}" -

# Open it as /dev/mapper/cryptroot
printf '%s' "${LUKS_PASSPHRASE}" | \
  cryptsetup open "${ROOT_PART}" cryptroot -

# Create ext4 filesystem inside the LUKS container
mkfs.ext4 -L rootfs /dev/mapper/cryptroot

# --- 2. Mount decrypted FS and copy the rootfs ---

mkdir -p "${ROOTFS_DIR}"
mount /dev/mapper/cryptroot "${ROOTFS_DIR}"

mkdir -p "${ROOTFS_DIR}/boot/firmware"
mount "${BOOT_PART}" "${ROOTFS_DIR}/boot/firmware"

# Copy rootfs from build tree into encrypted filesystem
rsync -aHAX --delete \
  "${EXPORT_ROOTFS_DIR}/" \
  "${ROOTFS_DIR}/"

# --- 3. Configure crypttab, fstab, cmdline.txt ---

# Identify the underlying LUKS partition by PARTUUID
BOOT_PARTUUID="$(blkid -s PARTUUID -o value "${BOOT_PART}")"
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${ROOT_PART}")"

# /etc/crypttab: cryptroot from the underlying partition
cat > "${ROOTFS_DIR}/etc/crypttab" <<EOF
cryptroot PARTUUID=${ROOT_PARTUUID} none luks,discard,initramfs,keyscript=/usr/local/sbin/cryptroot-usb-askpass
EOF

# /etc/fstab: root from /dev/mapper/cryptroot (Debian-style)
awk '
  $2 == "/" { next } { print }
' "${ROOTFS_DIR}/etc/fstab" > "${ROOTFS_DIR}/etc/fstab.new"

cat >> "${ROOTFS_DIR}/etc/fstab.new" <<EOF
/dev/mapper/cryptroot / ext4 defaults 0 1
EOF

mv "${ROOTFS_DIR}/etc/fstab.new" "${ROOTFS_DIR}/etc/fstab"

# Fix the boot partition line: replace BOOTDEV placeholder with real PARTUUID
if grep -q '^BOOTDEV[[:space:]]' "${ROOTFS_DIR}/etc/fstab"; then
    sed -i "s/^BOOTDEV[[:space:]]\+/PARTUUID=${BOOT_PARTUUID} /" \
        "${ROOTFS_DIR}/etc/fstab"
fi

# /boot/firmware/cmdline.txt: use root=/dev/mapper/cryptroot
CMDLINE_FILE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
if [ ! -f "${CMDLINE_FILE}" ]; then
	log "ERROR: Expected ${CMDLINE_FILE} to exist, but it does not."
	exit 1
fi

# Replace existing root= argument
NEW_CMDLINE="$(sed -E 's#\broot=[^ ]+#root=/dev/mapper/cryptroot#g' "${CMDLINE_FILE}")"
echo "${NEW_CMDLINE}" > "${CMDLINE_FILE}"
log "Updated cmdline.txt to: ${NEW_CMDLINE}"

log "LUKS conversion complete. Encrypted root is mounted at ${ROOTFS_DIR} via /dev/mapper/cryptroot."
# NOTE:
# Do NOT unmount ${ROOTFS_DIR} or close cryptroot here.
# 06-finalise still needs the rootfs mounted, and build.sh/06-finalise
# will handle unmounting the filesystem and detaching the loop device.
