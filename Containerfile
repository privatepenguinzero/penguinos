# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
#
# silverblue-main is the layer bluefin:stable is itself built from, so moving
# here loses only what Bluefin adds on top - homebrew, the GNOME shell
# extensions, bling/motd, bazaar, ZFS and Bluefin's flatpak preinstall list -
# none of which this image uses. Everything build.sh actually depends on (the
# signed kernel and akmods, uupd, ublue's udev rules, PipeWire, portals,
# Flatpak, mesa and the negativo17 codecs, fonts, nautilus) comes from below
# that line and is unchanged.
#
# The reason for the move is staleness. Bluefin pins its own Fedora base by
# digest in image-versions.yml, and their Renovate custom managers only match
# Justfile and .gitmodules - so nothing bumps that pin any more. It had not
# moved since 2026-08-07. bluefin:stable kept rebuilding on top of a frozen
# Fedora, leaving this image on kernel 7.1.6-201 and bootc 1.16.7 while Fedora
# had shipped 7.1.13-200 and 1.16.10. silverblue-main:44 rebuilds daily and was
# current the day this changed (44.20260906.2, kernel 7.1.13-200.fc44).
#
# Deliberately a floating tag, not a digest: a stale pinned digest is exactly
# the failure above, and it stays fresh only for as long as a bot keeps bumping
# it. .github/renovate.json5 turns pinDigest off here to keep it floating.
#
# The trade: bluefin:stable is a gated, promoted tag, so a bad Fedora update
# reached this image late or not at all. Now it arrives the day it lands. The
# nightly rebuild and `bootc rollback` are what cover that.
FROM ghcr.io/ublue-os/silverblue-main:44

# All package installation and configuration happens in build.sh.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
