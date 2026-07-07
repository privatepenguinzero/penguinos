#!/bin/bash

set -ouex pipefail

## DNF5 Speedup
sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf

## DNF extra options (da fedora_things_to_do.sh)
sed -i '/^\[main\]/a fastestmirror=True' /etc/dnf/dnf.conf
sed -i '/^\[main\]/a defaultyes=True' /etc/dnf/dnf.conf

## Aggiornamenti automatici
dnf -y install dnf5-plugin-automatic
cp /usr/share/dnf5/dnf5-plugins/automatic.conf /etc/dnf/automatic.conf
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
systemctl enable dnf5-automatic.timer

## SSH server
dnf -y install openssh-server
systemctl enable sshd

## System apps
dnf -y install nautilus mpv gnome-terminal gnome-system-monitor gnome-calculator loupe mc btop rsync tmux fastfetch unzip git wget curl

## Virtualizzazione
dnf5 -y group install virtualization

## Ghostty
dnf -y copr enable scottames/ghostty
dnf -y install ghostty

# fully-featured ffmpeg with nonfree components from rpm fusion
dnf -y install https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
dnf -y install ffmpeg x264-libs --allowerasing

# Codec multimediali extra (equivalente di "dnf swap ffmpeg-free ffmpeg" + @multimedia + @sound-and-video)
dnf -y swap ffmpeg-free ffmpeg --allowerasing
dnf5 -y group upgrade multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
dnf5 -y group upgrade sound-and-video

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
#dnf -y install cargo evtest git input-remapper libevdev-devel libinput-utils python3-devel

# dnf -y install bitwarden-cli 

## VSCodium
rpmkeys --import https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/-/raw/master/pub.gpg
cat > /etc/yum.repos.d/vscodium.repo << 'EOF'
[gitlab.com_paulcarroty_vscodium_repo]
name=download.vscodium.com
baseurl=https://download.vscodium.com/rpms/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/-/raw/master/pub.gpg
metadata_expire=1h
EOF
dnf -y install codium

## Zsh + Oh My Zsh (installati nello skeleton, verranno usati dai nuovi utenti)
dnf -y install zsh
git clone https://github.com/ohmyzsh/ohmyzsh.git /etc/skel/.oh-my-zsh
cp /etc/skel/.oh-my-zsh/templates/zshrc.zsh-template /etc/skel/.zshrc
git clone https://github.com/zsh-users/zsh-autosuggestions /etc/skel/.oh-my-zsh/custom/plugins/zsh-autosuggestions
git clone https://github.com/marlonrichert/zsh-autocomplete.git /etc/skel/.oh-my-zsh/custom/plugins/zsh-autocomplete
git clone https://github.com/zsh-users/zsh-history-substring-search /etc/skel/.oh-my-zsh/custom/plugins/zsh-history-substring-search
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git /etc/skel/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
sed -i 's/plugins=(git)/plugins=(dnf aliases genpass git zsh-autosuggestions zsh-autocomplete zsh-history-substring-search z zsh-syntax-highlighting)/' /etc/skel/.zshrc
sed -i 's/ZSH_THEME="robbyrussell"/ZSH_THEME="jonathan"/' /etc/skel/.zshrc
# Nota: per rendere zsh la shell di default del nuovo utente serve "chsh" fatto dopo la creazione utente, non in fase di build immagine.

## NetBird
curl -fsSL https://pkgs.netbird.io/install.sh | sh

## Google Fonts (system-wide, non nella home utente che non esiste ancora in fase di build)
curl -Lo /tmp/google-fonts.zip https://github.com/google/fonts/archive/main.zip
mkdir -p /usr/share/fonts/google
unzip -q /tmp/google-fonts.zip -d /usr/share/fonts/google
rm -f /tmp/google-fonts.zip
fc-cache -f

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
