#!/bin/bash

set -ouex pipefail

## DNF5 Speedup
sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

## System apps
dnf -y install nautilus mpv gnome-terminal gnome-system-monitor gnome-calculator loupe

## Ghostty
dnf -y copr enable scottames/ghostty
dnf -y install ghostty

# fully-featured ffmpeg with nonfree components from rpm fusion
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y install ffmpeg x264-libs --allowerasing

# Nautilus open any terminal extension
curl -Lo /etc/yum.repos.d/nautilus-open-any-terminal.repo \
  https://copr.fedorainfracloud.org/coprs/monkeygold/nautilus-open-any-terminal/repo/fedora-$(rpm -E %fedora)/monkeygold-nautilus-open-any-terminal-fedora-$(rpm -E %fedora).repo
# dnf install -y nautilus-open-any-terminal
# glib-compile-schemas /usr/share/glib-2.0/schemas
# gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal kitty


# Install Niri 
dnf -y install niri 

curl -Lo /etc/yum.repos.d/peterwu.repo \
  https://copr.fedorainfracloud.org/coprs/peterwu/rendezvous/repo/fedora-$(rpm -E %fedora)/peterwu-rendezvous-fedora-$(rpm -E %fedora).repo
dnf -y install bibata-cursor-themes

# # Install Noctalia shell
# curl -fsSL https://github.com/terrapkg/subatomic-repos/raw/main/terra.repo -o /etc/yum.repos.d/terra.repo
# dnf -y install terra-release
# dnf -y install noctalia-shell 
# # ABILITARE LE NOTIFICHE: systemctl --user enable --now swaync.service

# Install Dank Linux shell
curl --output-dir "/etc/yum.repos.d/" \
  --remote-name "https://copr.fedorainfracloud.org/coprs/avengemedia/dms/repo/fedora-$(rpm -E %fedora)/avengemedia-dms-fedora-$(rpm -E %fedora).repo"
dnf -y install quickshell dms greetd dms-greeter --allowerasing 
#
# Install greetd login manager with dank configuration (still needs some work)
mkdir -p /etc/greetd/
cat > /etc/greetd/config.toml << EOF
[terminal]
vt = 1
[default_session]
user = "greeter"
command = "dms-greeter --command niri"
EOF
rm -f /etc/systemd/system/display-manager.service
ln -s /usr/lib/systemd/system/greetd.service /etc/systemd/system/display-manager.service
systemctl enable --force greetd.service

mkdir -p /etc/skel/.config/systemd/user/graphical-session.target.wants
ln -s /usr/lib/systemd/user/dms.service /etc/skel/.config/systemd/user/graphical-session.target.wants/
mkdir -p /etc/skel/.config/niri/
#cp -rf /ctx/dot_config/niri/config.kdl /etc/skel/.config/niri/

# DEV packages
dbf -y innstall cargo evtest git input-remapper libevdev-devel libinput-utils python3-devel

# dnf -y install bitwarden-cli 

#### Enable podman

systemctl enable podman.socket

# Remove waybar
dnf -y remove waybar

# this is needed for some glib applications
glib-compile-schemas /usr/share/glib-2.0/schemas/


## CLEAN UP
# Clean up dnf cache to reduce image size
dnf5 -y clean all
rm -rf /run/dnf /run/selinux-policy
rm -rf /var/lib/dnf
