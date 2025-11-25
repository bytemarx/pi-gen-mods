#!/bin/bash -e

# Configure initramfs for LUKS + USB gadget serial unlock.

# 1. Ensure initramfs-tools config directory exists.
mkdir -p "${ROOTFS_DIR}/etc/initramfs-tools"

# Append (do not overwrite) so we don't clobber anything pi-gen already added.
cat << 'EOM' >> "${ROOTFS_DIR}/etc/initramfs-tools/modules"
# USB gadget serial for early LUKS unlock
libcomposite
u_serial
g_serial
# Function drivers required by g_serial:
usb_f_acm
usb_f_serial
EOM

# 2. Install the keyscript into /usr/local/sbin inside the rootfs.
install -d "${ROOTFS_DIR}/usr/local/sbin"
install -m 700 files/cryptroot-usb-askpass \
    "${ROOTFS_DIR}/usr/local/sbin/cryptroot-usb-askpass"

# 3. Install the initramfs hook to ensure modules + keyscript are bundled.
install -d "${ROOTFS_DIR}/etc/initramfs-tools/hooks"
install -m 755 files/initramfs-hook-usb-gadget-serial \
    "${ROOTFS_DIR}/etc/initramfs-tools/hooks/usb-gadget-serial"

# 4. Install the init-top script so /dev/ttyGS0 exists before cryptsetup runs.
install -d "${ROOTFS_DIR}/etc/initramfs-tools/scripts/init-top"
install -m 755 files/initramfs-init-top-usb-gadget-serial \
    "${ROOTFS_DIR}/etc/initramfs-tools/scripts/init-top/usb-gadget-serial"
