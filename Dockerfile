# syntax=docker/dockerfile:1

ARG DEBIAN_VERSION=trixie-slim

FROM --platform=$BUILDPLATFORM debian:${DEBIAN_VERSION} AS fetch
ARG TARGETARCH
ARG TARGETOS
ARG ZSASS_VERSION
ARG ZSASS_REPO=nihen/zsass

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tar \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/zsass
RUN set -eux; \
    case "${TARGETOS}/${TARGETARCH}" in \
      linux/amd64) asset_arch="x86_64" ;; \
      linux/arm64) asset_arch="aarch64" ;; \
      *) echo "unsupported target platform: ${TARGETOS}/${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    version="${ZSASS_VERSION#v}"; \
    if [ -z "${version}" ]; then echo "ZSASS_VERSION is required" >&2; exit 1; fi; \
    if [ -z "${ZSASS_REPO}" ]; then echo "ZSASS_REPO is required" >&2; exit 1; fi; \
    asset="zsass-v${version}-linux-${asset_arch}.tar.gz"; \
    url="https://github.com/${ZSASS_REPO}/releases/download/v${version}/${asset}"; \
    curl --retry 3 --retry-delay 2 --retry-connrefused -fSL -o "${asset}" "${url}"; \
    curl --retry 3 --retry-delay 2 --retry-connrefused -fSL -o "${asset}.sha256" "${url}.sha256"; \
    sha256sum -c "${asset}.sha256"; \
    mkdir -p /out; \
    tar -xzf "${asset}" --strip-components=1 -C /out "zsass-v${version}-linux-${asset_arch}/zsass"; \
    chmod 0755 /out/zsass

FROM debian:${DEBIAN_VERSION}
COPY LICENSE /usr/share/licenses/zsass/LICENSE
COPY --from=fetch /out/zsass /usr/local/bin/zsass
WORKDIR /work
ENTRYPOINT ["zsass"]
CMD ["--help"]
