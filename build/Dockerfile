FROM archlinux:latest

# Update and install archiso build tools
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        archiso \
        rsync \
        dosfstools \
        e2fsprogs \
        f2fs-tools \
        grub \
        mtools \
        parted \
        zstd \
    && pacman -Scc --noconfirm

COPY build.sh /build.sh
RUN chmod +x /build.sh

ENTRYPOINT ["/build.sh"]
