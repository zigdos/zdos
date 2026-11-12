#!/usr/bin/bash
# Installation to EFI Partition. Linux.
DIR="/boot/efi/EFI/ZDOS"
# As root: the ESP is mounted for root only (Fedora: dmask=0077)
if ! sudo test -d "$DIR"; then
  sudo mkdir -p "$DIR"
  echo "Created: $DIR"
fi

SRC="build/metal-x86_64/BOOTX64.EFI"
DEST="/boot/efi/EFI/ZDOS/ZIGDOS.EFI"
if sudo cp "$SRC" "$DEST"; then
  echo "Copied: $SRC to $DEST"
else
  echo "Error: Failed to copy $SRC" >&2
  exit 1
fi

# #Update EFI (only once; not needed when reinstall / copy new version):
# sudo efibootmgr --create --disk /dev/nvme0n1 --part 1 --label "ZDOS" --loader /EFI/ZDOS/ZIGDOS.EFI
# #Change boot order:
# sudo efibootmgr --bootorder 0000,0001,0002... # see your original boot order.
# # Removal:
# # sudo efibootmgr -b 0002 -B
