# Kernel-module builder for QNAP TS-X51: DVB (WinTV-dualHD) and USB-serial families
# Based on mammo0/qnap-ip6tables_nat-module approach
FROM mammo0/qnap-qts-toolchain:vivid

ARG BUILD_USER=builder
ARG PUID=1000
ARG PGID=1000
ENV BUILD_DIR=/build
ENV VOLUME_DIR=/out

# add build user
RUN [ $(getent group $PGID) ] || groupadd -f -g $PGID $BUILD_USER && \
    [ $(getent passwd $PUID) ] || useradd -ms /bin/bash -u $PUID -g $PGID $BUILD_USER

# setup build context
RUN mkdir -p "$BUILD_DIR" "$VOLUME_DIR" /kernel-source /modules-out && \
    chown $PUID:$PGID "$VOLUME_DIR" /modules-out
# --chown avoids a second full-tree layer that a separate `RUN chown -R` costs.
ADD --chown=$PUID:$PGID . "$BUILD_DIR"
WORKDIR "$BUILD_DIR"

USER $PUID:$PGID
VOLUME ["$VOLUME_DIR", "/modules-out"]
COPY docker_entrypoint.sh /usr/bin/
ENTRYPOINT ["docker_entrypoint.sh"]