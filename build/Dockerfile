# Hauppauge dualHD DVB module builder for QNAP TS-X51
FROM mammo0/qnap-qts-toolchain:vivid

ARG BUILD_USER=builder
ARG PUID=1000
ARG PGID=1000
ENV BUILD_DIR=/build
ENV VOLUME_DIR=/out

RUN [ $(getent group $PGID) ] || groupadd -f -g $PGID $BUILD_USER && \
    [ $(getent passwd $PUID) ] || useradd -ms /bin/bash -u $PUID -g $PGID $BUILD_USER

RUN mkdir -p "$BUILD_DIR" "$VOLUME_DIR" /kernel-source /modules-out && \
    chown $PUID:$PGID "$VOLUME_DIR" /modules-out
ADD --chown=$PUID:$PGID --chmod=755 . "$BUILD_DIR"
USER root
COPY docker_entrypoint.sh /usr/bin/docker_entrypoint.sh
RUN chmod 755 /usr/bin/docker_entrypoint.sh
USER $PUID:$PGID
VOLUME ["$VOLUME_DIR", "/modules-out"]
ENTRYPOINT ["/usr/bin/docker_entrypoint.sh"]
