# Put Homebrew on PATH, the way the bluefin base used to.
#
# Homebrew installs into /home/linuxbrew, which is machine-local state under
# /var - so it survives an image change, but nothing in the image knows about
# it. bluefin:stable shipped its own profile.d snippet; moving the base to
# silverblue-main on 2026-09-06 removed that and left every brew-installed
# binary present on disk but invisible, `gh` among them.
#
# Guarded on the directory existing: on a machine that never ran `brew install`
# there is nothing to add, and an unconditional eval would print an error at
# every shell start.
#
# /etc/zshrc sources /etc/profile.d/*.sh (see its _src_etc_profile_d), so this
# reaches interactive zsh as well as bash, which is what the default shell here
# needs.
#
# Note that brew shellenv *prepends* to PATH, which is Homebrew's own
# behaviour: where a tool exists both in brew and in the image, the brew copy
# wins. `brew uninstall <tool>` is the way to fall back to the image's version.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
