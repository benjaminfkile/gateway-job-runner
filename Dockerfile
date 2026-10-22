FROM alpine:3.21

RUN apk add --no-cache \
        bash \
        coreutils \
        curl \
        jq \
        postgresql17-client \
        aws-cli \
        ca-certificates \
        tzdata \
        gettext \
    && adduser -D -h /job -s /bin/bash job

COPY --chmod=0755 entrypoint.sh /usr/local/bin/gateway-job-entrypoint

USER job
WORKDIR /job

ENTRYPOINT ["/usr/local/bin/gateway-job-entrypoint"]
