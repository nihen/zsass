# syntax=docker/dockerfile:1

# Pinned by digest so a rebuild of a release uses the same base. To update:
#   docker buildx imagetools inspect debian:trixie-slim  (the index Digest)
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0

FROM --platform=$BUILDPLATFORM ${DEBIAN_IMAGE} AS fetch
ARG TARGETARCH
ARG TARGETOS
ARG ZSASS_VERSION
ARG ZSASS_REPO=nihen/zsass

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates cosign curl tar \
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
    for ext in sha256 sig pem; do \
      curl --retry 3 --retry-delay 2 --retry-connrefused -fSL -o "${asset}.${ext}" "${url}.${ext}"; \
    done; \
    sha256sum -c "${asset}.sha256"; \
    # The signature ties the archive to the release workflow at this tag;
    # the checksum alone comes from the same place as the archive.
    cosign verify-blob \
      --certificate "${asset}.pem" \
      --signature "${asset}.sig" \
      --certificate-identity "https://github.com/${ZSASS_REPO}/.github/workflows/release.yml@refs/tags/v${version}" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      "${asset}"; \
    mkdir -p /out; \
    tar -xzf "${asset}" --strip-components=1 -C /out "zsass-v${version}-linux-${asset_arch}/zsass"; \
    chmod 0755 /out/zsass

FROM ${DEBIAN_IMAGE}
RUN groupadd --system --gid 10001 zsass \
    && useradd --system --uid 10001 --gid zsass --home-dir /work --no-create-home --shell /usr/sbin/nologin zsass \
    && mkdir -p /work \
    && chown zsass:zsass /work
COPY LICENSE /usr/share/licenses/zsass/LICENSE
COPY --from=fetch /out/zsass /usr/local/bin/zsass
WORKDIR /work
USER zsass:zsass
ENTRYPOINT ["zsass"]
CMD ["--help"]
