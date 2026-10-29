ARG K6_VERSION=1.8.2

FROM alpine:3.21

ARG K6_VERSION
ARG TARGETARCH

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

# k6 from its GitHub release for the build platform, checked against the
# release's sha256 checksums file.
RUN set -eu; \
    case "${TARGETARCH:-}" in \
        amd64 | arm64) ;; \
        *) echo "TARGETARCH '${TARGETARCH:-}' is not amd64 or arm64 (BuildKit sets it)" >&2; exit 1 ;; \
    esac; \
    release="https://github.com/grafana/k6/releases/download/v${K6_VERSION}"; \
    name="k6-v${K6_VERSION}-linux-${TARGETARCH}"; \
    cd /tmp; \
    curl -fsSLO "${release}/${name}.tar.gz"; \
    curl -fsSLO "${release}/k6-v${K6_VERSION}-checksums.txt"; \
    grep " ${name}.tar.gz\$" "k6-v${K6_VERSION}-checksums.txt" | sha256sum -c -; \
    tar -xzf "${name}.tar.gz"; \
    install -m 0755 "${name}/k6" /usr/local/bin/k6; \
    rm -rf "${name}" "${name}.tar.gz" "k6-v${K6_VERSION}-checksums.txt"; \
    k6 version

COPY --chmod=0755 entrypoint.sh /usr/local/bin/gateway-job-entrypoint

USER job
WORKDIR /job

ENTRYPOINT ["/usr/local/bin/gateway-job-entrypoint"]
