# fedora-kernel-compilation

dnf install -y fedpkg fedora-packager rpmdevtools ncurses-devel pesign grubby && \
dnf install -y make gcc flex bison openssl-devel elfutils-libelf-devel automake libtool libuuid-devel libudev-devel libblkid-devel libtirpc-devel && \
dnf install -y bpftool dwarves elfutils-devel gcc-c++ glibc-static kernel-rpm-macros perl-devel perl-generators python3-devel systemd-boot-unsigned zstd && \
dnf install -y bc binutils bison dwarves elfutils-libelf-devel flex gcc make openssl openssl-devel perl python3 rsync

# extra:

dnf install screen ruby htop git neovim
