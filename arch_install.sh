#!/bin/bash
#
# to do:
# add profile (QT = qt5ct) and xprofile (dex -a) and anyting else
# add above to /etc/skel before user created
#

# Drive to install to.
DRIVE='/dev/sda'

# Is this a virtual box build - leave blank if not
VIRTUALBOX='TRUE'

# Hostname of the installed machine.
HOSTNAME='host100'

# Encrypt everything (except /boot).  Leave blank to disable.
ENCRYPT_DRIVE='TRUE'

# Passphrase used to encrypt the drive (leave blank to be prompted).
DRIVE_PASSPHRASE='a'

# Root password (leave blank to be prompted).
ROOT_PASSWORD='a'

# Main user to create (by default, added to wheel group, and others).
USER_NAME='user'

# The main user's password (leave blank to be prompted).
USER_PASSWORD='a'

# System timezone.
TIMEZONE='Europe/London'

# Have /tmp on a tmpfs or not.  Leave blank to disable.
# Only leave this blank on systems with very little RAM.
TMP_ON_TMPFS='TRUE'

KEYMAP='uk'
# KEYMAP='dvorak'

# Choose your video driver
# For Intel
#VIDEO_DRIVER="i915"
# For nVidia
#VIDEO_DRIVER="nouveau"
# For ATI
#VIDEO_DRIVER="radeon"
# For generic stuff
#VIDEO_DRIVER="vesa"
# For virtualbox
VIDEO_DRIVER="vbox"

# Wireless device, leave blank to not use wireless and use DHCP instead.
WIRELESS_DEVICE="wlan0"
# For tc4200's
#WIRELESS_DEVICE="eth1"

EFI_SIZE="512MiB"
ROOT_SIZE="14000MiB"
HOME_SIZE="100%"
SWAP_SIZE="2G"


setup() {
    #local boot_dev="$DRIVE"1
    local efi_dev="$DRIVE"1
    local lvm_dev="$DRIVE"2
    local home_dev="$DRIVE"3

    echo 'Creating partitions'
    partition_drive "$DRIVE"

    if [ -n "$ENCRYPT_DRIVE" ]
    then
        local lvm_part="/dev/mapper/lvm"

        if [ -z "$DRIVE_PASSPHRASE" ]
        then
            echo 'Enter a passphrase to encrypt the disk:'
            stty -echo
            read DRIVE_PASSPHRASE
            stty echo
        fi

        echo 'Encrypting partition'
        encrypt_drive "$lvm_dev" "$home_dev" "$DRIVE_PASSPHRASE"

    else
        local lvm_part="$lvm_dev"
        local home_part="$home_dev"
    fi

    echo 'Setting up LVM'
    setup_lvm "$lvm_part" vg00

    echo 'Formatting filesystems'
    format_filesystems "$efi_dev"

    echo 'Mounting filesystems'
    mount_filesystems "$efi_dev"

    echo 'Installing base system'
    install_base

    echo 'Chrooting into installed system to continue setup...'
    cp $0 /mnt/setup.sh
    arch-chroot /mnt ./setup.sh chroot

    if [ -f /mnt/setup.sh ]
    then
        echo 'ERROR: Something failed inside the chroot, not unmounting filesystems so you can investigate.'
        echo 'Make sure you unmount everything before you try to run this script again.'
    else
        echo 'Unmounting filesystems'
        unmount_filesystems
        echo 'Done! Reboot system.'
    fi
}

configure() {
    local efi_dev="$DRIVE"1
    local lvm_dev="$DRIVE"2
    local home_dev="$DRIVE"3

    echo 'Installing additional packages'
    install_packages

    echo 'Creating initial user'
    create_user "$USER_NAME" "$USER_PASSWORD"
    
    echo 'Installing yay'
    install_yay

    #echo 'Installing AUR packages'
    #install_aur_packages

    echo 'Clearing package tarballs'
    clean_packages

    echo 'Updating pkgfile database'
    update_pkgfile

    echo 'Setting hostname'
    set_hostname "$HOSTNAME"

    echo 'Setting timezone'
    set_timezone "$TIMEZONE"

    echo 'Setting locale'
    set_locale

    echo 'Setting console keymap'
    set_keymap

    echo 'Setting hosts file'
    set_hosts "$HOSTNAME"

    echo 'Setting fstab'
    set_fstab "$TMP_ON_TMPFS" "$efi_dev"

    echo 'Setting initial modules to load'
    set_modules_load

    echo 'Setting crypttab and generating keys for enctypted boot'
    if [ -n "$ENCRYPT_DRIVE" ]
    then
       set_encrypt_boot $lvm_dev $home_dev $DRIVE_PASSPHRASE
    fi

    echo 'Configuring initial ramdisk'
    set_initcpio

    echo 'Setting initial daemons'
    set_daemons "$TMP_ON_TMPFS"

    echo 'Configuring bootloader'
    set_grub "$lvm_dev"

    echo 'Configuring sudo'
    set_sudoers

    #echo 'Configuring slim'
    #set_slim

    #if [ -n "$WIRELESS_DEVICE" ]
    #then
    #    echo 'Configuring netcfg'
    #    set_netcfg
    #fi

    if [ -z "$ROOT_PASSWORD" ]
    then
        echo 'Enter the root password:'
        stty -echo
        read ROOT_PASSWORD
        stty echo
    fi
    echo 'Setting root password'
    set_root_password "$ROOT_PASSWORD"

    if [ -z "$USER_PASSWORD" ]
    then
        echo "Enter the password for user $USER_NAME"
        stty -echo
        read USER_PASSWORD
        stty echo
    fi

    echo 'Building locate database'
    update_locate

    mv /setup.sh /root/setup.sh
}

partition_drive() {
    local dev="$1"; shift

    # 512 MB /efi partition, everything else under LVM
    parted -s "$dev" \
        mklabel gpt \
        mkpart primary fat32 1MiB "$EFI_SIZE" \
        mkpart primary ext4 "$EFI_SIZE" "$ROOT_SIZE" \
        mkpart primary ext4 "$ROOT_SIZE" "$HOME_SIZE" \
        set 1 esp on
}

encrypt_drive() {
    local devroot="$1"; shift
    local devhome="$1"; shift
    local passphrase="$1"; shift

    echo -en "$passphrase" | cryptsetup --cipher aes-xts-plain64 --verify-passphrase --key-size 512 --hash sha256 --iter-time 2000 --use-random --type luks1 luksFormat "$devroot"
    echo -en "$passphrase" | cryptsetup --cipher aes-xts-plain64 --verify-passphrase --key-size 512 --hash sha256 --iter-time 2000 --use-random --type luks2 luksFormat "$devhome"
    echo -en "$passphrase" | cryptsetup luksOpen "$devroot" lvm
    echo -en "$passphrase" | cryptsetup luksOpen "$devhome" home

}

setup_lvm() {
    local partition="$1"; shift
    local volgroup="$1"; shift

    pvcreate "$partition"
    vgcreate "$volgroup" "$partition"

    # Create a swap partition
    lvcreate -C y -L "$SWAP_SIZE" "$volgroup" -n swap

    # Use the rest of the space for root
    lvcreate -l '+100%FREE' "$volgroup" -n root

    # Enable the new volumes
    vgchange -ay
}

format_filesystems() {
    local boot_dev="$1"; shift

    mkfs.vfat -F32 -n efi "$boot_dev"
    mkfs.ext4 -L root /dev/vg00/root
    mkfs.ext4 -L home /dev/mapper/home
    mkswap /dev/vg00/swap
}

mount_filesystems() {
    local boot_dev="$1"; shift

    mount /dev/vg00/root /mnt
    mkdir -p /mnt/boot/efi
    mkdir /mnt/home
    mount "$boot_dev" /mnt/boot/efi
    mount /dev/mapper/home /mnt/home
    swapon /dev/vg00/swap
}

install_base() {
    echo 'Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist

    pacstrap /mnt base base-devel linux linux-headers linux-firmware
    pacstrap /mnt grub efibootmgr
}

unmount_filesystems() {
    umount /mnt/boot
    umount /mnt
    swapoff /dev/vg00/swap
    vgchange -an
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        cryptsetup luksClose lvm
    fi
}

install_packages() {
    local packages=''

    # Xserver
    packages+=' xdg-utils xorg-server xorg-server-common xorg-apps xorg-xinit xterm'

    # On Intel processors
    packages+=' intel-ucode'

    # input devices
    packages+=' libinput xf86-input-libinput'

    # General utilities/libraries
    packages+=' alsa-utils pulseaudio pulseaudio-alsa aspell-en chromium firefox tlp vim ntp openssh p7zip pkgfile python python2 rfkill rsync sudo unrar unzip wget zip zsh grml-zsh-config pinentry mlocate cryptsetup lvm2 cronie man-db man-pages texinfo htop lsof strace screenfetch dunst dex menu-cache youtube-dl ranger gvfs gvfs-smb gvfs-nfs pavucontrol xdg-user-dirs'

    # terminal
    packages+=' termite'

    # Policy kit graphical 
    packages+=' mate-polkit'

    # Fonts
    packages+=' ttf-dejavu ttf-liberation terminus-font ttf-font-awesome ttf-ubuntu-font-family'

    # note: net-tools depracated so removed from list above and replaced with iproute2 (which should be part of base)

    # Development packages
    packages+=' cmake wget curl diffutils gdb git tcpdump valgrind wireshark-qt go'

    # Netcfg
    packages+=' dhcpcd networkmanager nm-connection-editor network-manager-applet iputils iproute2'
    # Wireless
    packages+=' ifplugd dialog wireless_tools wpa_supplicant'

    # Java stuff
    #packages+=' icedtea-web-java7 jdk7-openjdk jre7-openjdk'

    # Libreoffice
    #packages+=' libreoffice-calc libreoffice-en-US libreoffice-gnome libreoffice-impress libreoffice-writer hunspell-en hyphen-en mythes-en'

    # Misc programs
    packages+=' mpv vlc gparted dosfstools ntfs-3g'


    # Themeing
    packages+=' qt5ct lxappearance-gtk3 capitaine-cursors kvantum-qt5 kvantum-theme-arc kvantum-theme-adapta adapta-gtk-theme papirus-icon-theme'

    # Virtualbox
    if [ -n "$VIRTUALBOX" ]
    then
        packages+=' virtualbox-guest-dkms virtualbox-guest-utils xf86-video-vmware'
    fi

    # Desktop environment
    packages+=' spectrwm lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings'

    # Extra packages for tc4200 tablet
    #packages+=' ipw2200-fw xf86-input-wacom'

    if [ "$VIDEO_DRIVER" = "i915" ]
    then
        packages+=' xf86-video-intel libva-intel-driver'
    elif [ "$VIDEO_DRIVER" = "nouveau" ]
    then
        packages+=' xf86-video-nouveau'
    elif [ "$VIDEO_DRIVER" = "radeon" ]
    then
        packages+=' xf86-video-ati'
    elif [ "$VIDEO_DRIVER" = "vesa" ]
    then
        packages+=' xf86-video-vesa'
    elif [ "$VIDEO_DRIVER" = "vbox" ]
    then
        packages+=' xf86-video-vmware'
    fi

    pacman -Sy --needed --noconfirm $packages
}

install_yay() {
    rm -rf /foo
    mkdir -p /foo
    chown -R $USER_NAME:wheel foo
    cd /foo
    curl https://aur.archlinux.org/cgit/aur.git/snapshot/yay.tar.gz | tar xzf -

    chown -R $USER_NAME:wheel yay
    cd yay
    su - $USER_NAME -c  'cd /foo/yay && makepkg --noconfirm' 
    # yay depends
    pacman --needed --noconfirm -Sy go
    pacman -U *.pkg.tar.xz --needed --noconfirm 

    cd /
    rm -rf /foo
}

install_aur_packages() {
    mkdir /foo
    export TMPDIR=/foo
    #yay -S --noconfirm android-udev
    #yay -S --noconfirm chromium-pepper-flash-stable
    #yay -S --noconfirm chromium-libpdf-stable
    unset TMPDIR
    rm -rf /foo
}

clean_packages() {
    yes | pacman -Scc
}

update_pkgfile() {
    pkgfile -u
}

set_hostname() {
    local hostname="$1"; shift

    echo "$hostname" > /etc/hostname
}

set_timezone() {
    local timezone="$1"; shift

    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    hwclock --systohc
}

set_locale() {
    echo 'LANG="en_GB.UTF-8"' >> /etc/locale.conf
    echo 'LC_COLLATE="C"' >> /etc/locale.conf
    echo "en_GB.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
}

set_keymap() {
    echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
    echo "FONT=ter-132n" >> /etc/vconsole.conf
}

set_hosts() {
    local hostname="$1"; shift

    cat > /etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost
127.0.1.1       $hostname.localdomain   $hostname
EOF
}

set_fstab() {
    local tmp_on_tmpfs="$1"; shift
    local boot_dev="$1"; shift

    local boot_uuid=$(get_uuid "$boot_dev")

    cat > /etc/fstab <<EOF
#
# /etc/fstab: static file system information
#
# <file system> <dir>    <type> <options>    <dump> <pass>

/dev/vg00/swap none swap  sw                0 0
/dev/vg00/root /    ext4  defaults,relatime 0 1
/dev/mapper/home /home    ext4  defaults,relatime 0 2

#UUID=$boot_uuid /boot/efi  defaults,relatime 0 2
EOF
}

set_modules_load() {
    echo 'microcode' > /etc/modules-load.d/intel-ucode.conf
}

set_encrypt_boot() {
    local rootdev="$1"; shift
    local homedev="$1"; shift
    local passphrase="$1"; shift
    local homeuuid=$(get_uuid "$homedev")
    # get some entropy
    pacman -S --needed --noconfirm haveged
    systemctl start haveged.service
    dd bs=512 count=4 if=/dev/random of=/root/lvm.keyfile iflag=fullblock
    dd bs=512 count=4 if=/dev/random of=/root/home.keyfile iflag=fullblock
    chmod 000 /root/lvm.keyfile
    chmod 000 /root/home.keyfile
    chmod 600 /boot/initramfs-linux*
    echo -en "$passphrase" | cryptsetup -v luksAddKey "$rootdev" /root/lvm.keyfile
    echo -en "$passphrase" | cryptsetup -v luksAddKey "$homedev" /root/home.keyfile
#    sed -i '/FILES=/c\FILES=(/root/lvm.keyfile /root/home.keyfile)' /etc/mkinitcpio.conf
    echo "home     UUID=$homeuuid     /root/home.keyfile     luks" >> /etc/crypttab

}

set_initcpio() {
    local vid

    if [ "$VIDEO_DRIVER" = "i915" ]
    then
        vid='i915'
    elif [ "$VIDEO_DRIVER" = "nouveau" ]
    then
        vid='nouveau'
    elif [ "$VIDEO_DRIVER" = "radeon" ]
    then
        vid='radeon'
    fi

    local encrypt=""
    if [ -n "$ENCRYPT_DRIVE" ]
    then
        encrypt="encrypt"
    fi


    # Set MODULES with your video driver
    cp /etc/mkinitcpio.conf /etc/mkinitcpio.conf.orig
    cat > /etc/mkinitcpio.conf <<EOF
MODULES=($vid)
BINARIES=""
FILES="/root/lvm.keyfile /root/home.keyfile"
#HOOKS="base udev autodetect modconf block keymap keyboard $encrypt lvm2 resume filesystems fsck"
HOOKS=(base udev autodetect keyboard keymap consolefont modconf block $encrypt lvm2 filesystems fsck)
EOF

    mkinitcpio -p linux
}

set_daemons() {
    local tmp_on_tmpfs="$1"; shift

    systemctl enable cronie.service tlp.service tlp-sleep.service ntpd.service

#    if [ -n "$WIRELESS_DEVICE" ]
#    then
#        systemctl enable net-auto-wired.service net-auto-wireless.service
#    else
#        systemctl enable dhcpcd@eth0.service
#    fi

    systemctl enable NetworkManager.service
    if [ -z "$tmp_on_tmpfs" ]
    then
        systemctl mask tmp.mount
    fi
}

# insert grub function here
set_grub() {
    local rootdev="$1"; shift
    local rootuuid=$(get_uuid "$rootdev")
    cp /etc/default/grub /etc/default/grub.orig
    cat > /etc/default/grub <<EOF
# GRUB boot loader configuration

GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 cryptdevice=UUID=$rootuuid:lvm cryptkey=rootfs:/root/lvm.keyfile root=/dev/vg00/root"
GRUB_CMDLINE_LINUX=""
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_ENABLE_CRYPTODISK=y
GRUB_TIMEOUT_STYLE=menu
GRUB_TERMINAL_INPUT=console
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
EOF

#    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --boot-directory=/boot --recheck --debug
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --boot-directory=/boot --recheck --debug --removable
    grub-mkconfig -o /boot/grub/grub.cfg
}

set_sudoers() {
    cp /etc/sudoers /etc/sudoers.orig
    cat > /etc/sudoers <<EOF
##
## User privilege specification
##
root ALL=(ALL) ALL

## Uncomment to allow members of group wheel to execute any command
#%wheel ALL=(ALL) ALL

## Same thing without a password
%wheel ALL=(ALL) NOPASSWD: ALL

%rfkill ALL=(ALL) NOPASSWD: /usr/sbin/rfkill
#%network ALL=(ALL) NOPASSWD: /usr/bin/netcfg, /usr/bin/wifi-menu

## Read drop-in files from /etc/sudoers.d
## (the '#' here does not indicate a comment)
#includedir /etc/sudoers.d
EOF

    chmod 440 /etc/sudoers
}


#set_netcfg() {
#    cat > /etc/network.d/wired <<EOF
#CONNECTION='ethernet'
#DESCRIPTION='Ethernet with DHCP'
#INTERFACE='eth0'
#IP='dhcp'
#EOF
#
#    chmod 600 /etc/network.d/wired
#
#    cat > /etc/conf.d/netcfg <<EOF
## Enable these netcfg profiles at boot time.
##   - prefix an entry with a '@' to background its startup
##   - set to 'last' to restore the profiles running at the last shutdown
##   - set to 'menu' to present a menu (requires the dialog package)
## Network profiles are found in /etc/network.d
#NETWORKS=()
#
## Specify the name of your wired interface for net-auto-wired
#WIRED_INTERFACE="eth0"
#
## Specify the name of your wireless interface for net-auto-wireless
#WIRELESS_INTERFACE="$WIRELESS_DEVICE"
#
## Array of profiles that may be started by net-auto-wireless.
## When not specified, all wireless profiles are considered.
##AUTO_PROFILES=("profile1" "profile2")
#EOF
#}

set_root_password() {
    local password="$1"; shift

    echo -en "$password\n$password" | passwd
}

create_user() {
    local name="$1"; shift
    local password="$1"; shift
    if id "$USER_NAME" >/dev/null 2>&1; then
        echo "user exists"
    else
        echo "user does not exist"
        useradd -m -s /bin/zsh -G adm,systemd-journal,wheel,rfkill,games,network,video,audio,optical,floppy,storage,scanner,power,wireshark "$name"
        echo -en "$password\n$password" | passwd "$name"
    fi
    #useradd -m -s /bin/zsh -G adm,systemd-journal,wheel,rfkill,games,network,video,audio,optical,floppy,storage,scanner,power,adbusers,wireshark "$name"
}

update_locate() {
    updatedb
}

get_uuid() {
    blkid -o value -s UUID "$1"
}

set -ex

if [ "$1" == "chroot" ]
then
    configure
else
    setup
fi

echo "banana banana"

