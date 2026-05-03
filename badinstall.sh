#!/bin/bash

# ==============================
# badOS Installer v3 PRO
# ==============================
set -e

# Colors
C='\033[0;36m'
G='\033[0;32m'
R='\033[0;31m'
Y='\033[0;33m'
P='\033[0;35m'
NC='\033[0m'

clear

echo -e "${P}============================================${NC}"
echo -e "${P}        badOS INSTALLER v3 PRO              ${NC}"
echo -e "${P}============================================${NC}"

# Logging
exec > >(tee install.log) 2>&1

# --- SYSTEM DETECTION ---
echo -e "${C}[*] Detecting system...${NC}"
[[ -d /sys/firmware/efi ]] && MODE="UEFI" || MODE="BIOS"
CPU=$(lscpu | grep "Vendor ID" | awk '{print $3}')
VM=$(systemd-detect-virt)

if [[ "$CPU" == "GenuineIntel" ]]; then
    UCODE="intel-ucode"
else
    UCODE="amd-ucode"
fi

echo -e "Mode: $MODE | CPU: $CPU | VM: $VM"

# --- USER INPUT ---
read -p "Hostname: " HOSTNAME
[[ -z "$HOSTNAME" ]] && echo "Invalid hostname" && exit

read -p "Username: " USERNAME
[[ -z "$USERNAME" ]] && echo "Invalid username" && exit

read -s -p "Password: " PASSWORD

echo ""

# --- PROFILE ---
echo "1) Minimal"
echo "2) KDE"
echo "3) GNOME"
read -p "Choose profile: " PROFILE

# --- FILESYSTEM ---
echo "1) ext4"
echo "2) btrfs"
read -p "Choose FS: " FSCHOICE

if [[ "$FSCHOICE" == "2" ]]; then
    FS="btrfs"
else
    FS="ext4"
fi

# --- DISK ---
lsblk -d -e 7,11
read -p "Disk (e.g. sda): " DISKNAME
DISK="/dev/$DISKNAME"

echo -e "${R}WARNING: ALL DATA ON $DISK WILL BE LOST${NC}"
read -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && exit

# --- PARTITION ---
sgdisk -Z $DISK

if [[ "$MODE" == "UEFI" ]]; then
    sgdisk -n 1:0:+512M -t 1:ef00 $DISK
    sgdisk -n 2:0:0 -t 2:8300 $DISK
    [[ $DISK == *"nvme"* ]] && P1="${DISK}p1" || P1="${DISK}1"
    [[ $DISK == *"nvme"* ]] && P2="${DISK}p2" || P2="${DISK}2"

    mkfs.fat -F32 $P1
else
    sgdisk -n 1:0:0 -t 1:8300 $DISK
    P2="${DISK}1"
fi

# --- FILESYSTEM SETUP ---
if [[ "$FS" == "btrfs" ]]; then
    mkfs.btrfs -f $P2
    mount $P2 /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt

    mount -o subvol=@ $P2 /mnt
    mkdir -p /mnt/home
    mount -o subvol=@home $P2 /mnt/home
else
    mkfs.ext4 -F $P2
    mount $P2 /mnt
fi

if [[ "$MODE" == "UEFI" ]]; then
    mkdir -p /mnt/boot
    mount $P1 /mnt/boot
fi

# --- GPU DETECT ---
GPU=$(lspci | grep -E "VGA|3D")
GPU_PKGS="mesa"
if echo "$GPU" | grep -iq nvidia; then
    GPU_PKGS="nvidia nvidia-utils"
fi

# --- PACKAGES ---
PKGS="base linux linux-firmware networkmanager grub efibootmgr sudo bash-completion $UCODE $GPU_PKGS"

if [[ "$PROFILE" == "2" ]]; then
    PKGS="$PKGS plasma kde-applications sddm"
elif [[ "$PROFILE" == "3" ]]; then
    PKGS="$PKGS gnome gdm"
fi

[[ "$FS" == "btrfs" ]] && PKGS="$PKGS btrfs-progs"
[[ "$VM" != "none" ]] && PKGS="$PKGS open-vm-tools"

pacstrap /mnt $PKGS

# --- SWAP ---
fallocate -l 2G /mnt/swapfile
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile

# --- FSTAB ---
genfstab -U /mnt >> /mnt/etc/fstab
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- CHROOT ---
arch-chroot /mnt /bin/bash -c "
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen

echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo '$HOSTNAME' > /etc/hostname

useradd -m -G wheel -s /bin/bash $USERNAME
echo '$USERNAME:$PASSWORD' | chpasswd
passwd -l root

echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

systemctl enable NetworkManager

if [[ '$PROFILE' == '2' ]]; then
    systemctl enable sddm
elif [[ '$PROFILE' == '3' ]]; then
    systemctl enable gdm
fi

if [[ '$VM' != 'none' ]]; then
    systemctl enable open-vm-tools
fi

if [[ '$MODE' == 'UEFI' ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=badOS
else
    grub-install --target=i386-pc $DISK
fi

mkinitcpio -P

grub-mkconfig -o /boot/grub/grub.cfg
"

echo -e "${G}Installation complete!${NC}"
