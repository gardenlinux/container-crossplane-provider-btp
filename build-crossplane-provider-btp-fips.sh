#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/SAP/crossplane-provider-btp}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/crossplane-provider-btp-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-crossplane-provider-btp}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-2.2.2}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-f25ff4a6aa6b41f67049b765e97e47aa3c183373}"
GO_IMAGE="${GO_IMAGE:-golang:1.26-bookworm}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- clone source ------------------------------------------------------------

CLONE_DIR=".build/fips-port-crossplane-provider-btp"
if [ ! -d "$CLONE_DIR" ]; then
    git clone "$REPO_URL" "$CLONE_DIR"
fi
cd "$CLONE_DIR"
git checkout "v${VERSION}"
cd -

# --- generate Dockerfile -----------------------------------------------------

mkdir -p "$WORKDIR"

cat > "$WORKDIR/Dockerfile.fips" <<DOCKERFILE
ARG GO_IMAGE
FROM --platform=\$BUILDPLATFORM \${GO_IMAGE} AS builder
ARG ARCH
ARG VERSION
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOARCH=\${ARCH} go build \\
    -ldflags "-s -w -X github.com/sap/crossplane-provider-btp/internal/version.Version=\${VERSION} -X github.com/sap/crossplane-provider-btp/internal/version.ProviderVersion=\${VERSION}" \\
    -o /crossplane-provider-btp ./cmd/provider

FROM ${BASE_IMAGE}
ARG UPSTREAM_GIT_SHA
LABEL org.opencontainers.image.description="A FIPS-enabled Crossplane Provider BTP image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="\${UPSTREAM_GIT_SHA}"
COPY --from=builder /crossplane-provider-btp /usr/local/bin/crossplane-provider-btp
ENV GODEBUG=fips140=only
EXPOSE 8080
RUN groupadd -g 65532 nonroot \\
    && useradd -u 65532 -g 65532 -s /sbin/nologin -d /home/nonroot nonroot
USER 65532
ENTRYPOINT ["/usr/local/bin/crossplane-provider-btp"]
DOCKERFILE

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg ARCH="${ARCH}" \
    --build-arg VERSION="${VERSION}" \
    --build-arg GO_IMAGE="${GO_IMAGE}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    -f "$WORKDIR/Dockerfile.fips" \
    "$CLONE_DIR"

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"

# --- SBOM --------------------------------------------------------------------
# Syft version is pinned; update SYFT_VERSION to pick up a newer release.
SYFT_VERSION="${SYFT_VERSION:-1.57.1}"
SYFT_BIN="${WORKDIR}/syft"

install_syft() {
    local arch_syft
    arch_syft=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    local tarball="syft_${SYFT_VERSION}_linux_${arch_syft}.tar.gz"
    local checksum_file="syft_${SYFT_VERSION}_checksums.txt"
    local base_url="https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}"

    curl -sSfL "${base_url}/${tarball}"       -o "/tmp/${tarball}"
    curl -sSfL "${base_url}/${checksum_file}" -o "/tmp/${checksum_file}"
    grep "${tarball}" "/tmp/${checksum_file}" | (cd /tmp && sha256sum -c)
    tar -xzf "/tmp/${tarball}" -C "${WORKDIR}" syft
    chmod +x "${SYFT_BIN}"
}

{ [ -x "${SYFT_BIN}" ] && "${SYFT_BIN}" version 2>/dev/null | grep -q "${SYFT_VERSION}"; } || install_syft

# Phase 2: scan the final image for OS packages + language packages.
# Catalogers are driven by syft.yaml (catalogers.default).
IMAGE_NAME_BASE=$(basename "${IMAGE_NAME}")
SBOM_TMP="${WORKDIR}/${IMAGE_NAME_BASE}-${VERSION}-${ARCH}.raw.cdx.json"
SBOM_OUT="${WORKDIR}/${IMAGE_NAME_BASE}-${VERSION}-${ARCH}.cdx.json"

"${SYFT_BIN}" "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    --output "cyclonedx-json=${SBOM_TMP}"

jq \
    --arg name "crossplane-provider-btp" \
    --arg version "${VERSION}" \
    --arg purl "pkg:oci/gl-fips-crossplane-provider-btp@${VERSION}?arch=${ARCH}" \
    --arg revision "${UPSTREAM_GIT_SHA}" \
    --arg arch "${ARCH}" \
    '.metadata.lifecycles = [{"phase": "post-build"}] |
     .metadata.component = {
       "type": "application",
       "name": $name,
       "version": $version,
       "purl": $purl,
       "properties": [
         {"name": "org.opencontainers.image.revision", "value": $revision},
         {"name": "arch", "value": $arch}
       ]
     }' \
    "${SBOM_TMP}" > "${SBOM_OUT}"

rm "${SBOM_TMP}"
echo "SBOM: ${SBOM_OUT}"
