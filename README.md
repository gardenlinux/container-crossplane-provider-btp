FIPS Port Report: crossplane-provider-btp
==========================================

## Summary

crossplane-provider-btp is a Crossplane provider for SAP Business Technology Platform (BTP), enabling
Kubernetes-native management of SAP BTP resources (subaccounts, entitlements, service instances, etc.)
via Crossplane's managed-resource model. It is built on the upjet framework, which wraps the SAP BTP
Terraform provider.

### Initial triage results

- Primary language:   Go (go.mod present, go 1.26.8)
- FIPS mechanism:     ENV GODEBUG=fips140=only (standard Go FIPS mode)
- Build pattern:      Pattern D — generate Dockerfile from scratch
  Reason: the upstream Dockerfile (cluster/images/provider-btp/Dockerfile) is a single-stage image
  that simply COPYs pre-built binaries from a bin/ directory produced by the upstream make/crossplane
  build system. It has no builder stage, so we write our own two-stage Dockerfile that compiles the
  binary from source inside a golang builder container.

### Application metadata

- Version:            2.2.2
- License:            Apache-2.0
- Git commit SHA:     f25ff4a6aa6b41f67049b765e97e47aa3c183373
- FIPS crypto:        Go standard library FIPS mode (GODEBUG=fips140=only); no external crypto library

### Docker image produced

- Image:              gl-fips-crossplane-provider-btp:2.2.2-amd64
- Size:               56 MiB
- Base:               ghcr.io/gardenlinux/gardenlinux/fips:1877.22
- Builder:            golang:1.26-bookworm

---

## Steps taken

- Cloned https://github.com/SAP/crossplane-provider-btp and checked out v2.2.2
  (commit f25ff4a6aa6b41f67049b765e97e47aa3c183373).

- Confirmed go.mod declares `go 1.26.8`; chose golang:1.26-bookworm as builder image.
  Verified it publishes both amd64 and arm64 manifests (no QEMU needed).

- Identified the single provider binary at cmd/provider. The Makefile also lists cmd/exporter
  in GO_STATIC_PACKAGES, but that binary has no Dockerfile and is a CLI tool, not a long-running
  server, so only the provider binary is containerised here.

- Upstream Dockerfile uses `gcr.io/distroless/static` (USER 65532 = nonroot) and EXPOSE 8080.
  Adopted the same UID/port. Because gardenlinux ships only root (0) and nobody (65534) by default,
  added explicit groupadd/useradd steps for nonroot (65532) before the USER directive.

- ldflags extracted from Makefile:
    -X github.com/sap/crossplane-provider-btp/internal/version.Version=<VERSION>
    -X github.com/sap/crossplane-provider-btp/internal/version.ProviderVersion=<VERSION>

- Generated a two-stage Dockerfile.fips:
    Stage 1 (builder): FROM --platform=$BUILDPLATFORM golang:1.26-bookworm; CGO_ENABLED=0 go build
    Stage 2 (final):   FROM ghcr.io/gardenlinux/gardenlinux/fips:1877.22; nonroot user; GODEBUG=fips140=only

- ARG UPSTREAM_GIT_SHA re-declared in the final stage (per rules) so the revision label is populated.

- Script ran successfully on first attempt — no fixes required.

---

## Test script output (abridged)

*** Checking if gl-fips-crossplane-provider-btp:2.2.2-amd64 docker image is available ***   PASS
*** Checking if gl-fips-crossplane-provider-btp:2.2.2-amd64 is based on gardenlinux ***      PASS
*** Checking if gl-fips-crossplane-provider-btp:2.2.2-amd64 is using FIPS-enabled image ***  PASS (VARIANT_ID=container-sslfips-amd64)
*** Checking that gl-fips-crossplane-provider-btp:2.2.2-amd64 starts under a non-root user *** PASS (nonroot)
*** Checking if gl-fips-crossplane-provider-btp:2.2.2-amd64 has GO FIPS mode enabled ***     PASS (GODEBUG=fips140=only)
*** Checking org.opencontainers.image.description label ***                                   PASS
*** Checking org.opencontainers.image.licenses label ***                                      PASS
*** Checking org.opencontainers.image.revision label ***                                      PASS

---

## Kubernetes (k3d) test output

Pod: fips-port-crossplane-provider-btp-pod
Status: 1/1 Running (healthy, no restarts)

Log excerpt (first lines):
  {"level":"info","msg":"Beta feature enabled","flag":"EnableAlphaManagementPolicies"}
  {"level":"info","logger":"controller-runtime.metrics","msg":"Starting metrics server"}
  {"level":"info","logger":"controller-runtime.metrics","msg":"Serving metrics server","bindAddress":":8080","secure":false}
  {"level":"info","msg":"Starting EventSource","controller":"managed/account.btp.sap.crossplane.io/v1alpha1, kind=directoryentitlement",...}
  ... (controllers starting up, waiting for CRDs — expected in a bare cluster)

Result: PASS — the binary starts under UID 65532, metrics server binds on :8080, controllers
initialise normally. The provider then waits for Crossplane CRDs to be installed, which is
expected behaviour in a bare k3s cluster.

---

## Final image summary

| Image tag                                  | Pod status | Pass/fail |
|--------------------------------------------|------------|-----------|
| gl-fips-crossplane-provider-btp:2.2.2-amd64 | Running  | PASS      |
