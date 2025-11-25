#!/bin/bash -e

on_chroot << EOF
systemctl enable serial-getty@ttyGS0.service
EOF
