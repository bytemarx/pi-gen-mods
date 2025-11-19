#!/bin/bash -e

# Enable serial login on USB gadget serial device ttyGS0
on_chroot << EOF
systemctl enable serial-getty@ttyGS0.service
EOF
