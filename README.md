

# **SLSA** Build Provenance For Goodmem

This repository contains GitHub Actions tooling to produce **SLSA v1.2 Build track** provenance for:

- Goodmem **file-based release artifacts**
- Goodmem **OCI container images**

It implements the **SLSA GitHub “Bring Your Own Builder” (BYOB)** pattern using `slsa-framework/slsa-github-generator` as the trusted provenance generator, while keeping the build logic in a separate, untrusted context.

References:

- SLSA v1.2 spec (Build track): https://slsa.dev/spec/v1.2/

---

## Quick verification (downstream)

### Verify a release artifact

```bash
PROV=~/Downloads/goodmem-linux-amd64.tar.gz.build.slsa
ART=~/Downloads/goodmem-linux-amd64.tar.gz
BUILDER_ID="https://github.com/PAIR-Systems-Inc/slsa/.github/workflows/slsa-release.yml@refs/tags/.*$"

slsa-verifier verify-artifact \
  --provenance-path "$PROV" \
  --source-uri github.com/PAIR-Systems-Inc/goodmem \
  --source-branch main \
  --builder-id "$BUILDER_ID" \
  "$ART"
```

### Verify a container image provenance attestation

```bash
IMAGE="ghcr.io/pair-systems-inc/goodmem/server@sha256:21e5832e9db9be4740483d867e87af9f91e7c14e0595ff03288d253a8bfcea05"

slsa-verifier verify-image \
  --source-uri github.com/PAIR-Systems-Inc/goodmem \
  --source-branch main \
  --builder-id "https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0" \
  --build-workflow-input draft-release=false \
  "$IMAGE"
```

Notes:
- Replace `--source-branch` and `BUILDER_ID` with the ref/tag you expect to be verified for the artifact you’re consuming.
- `--source-uri` comparisons are case-sensitive; use the exact org/repo casing found in the provenance.
- The goodmem installer uses cosign for verification of images and artifacts and further verifies parameters in each release artifact's attestation payload.

---

## 1. What is SLSA?

### What SLSA is

**SLSA (Supply-chain Levels for Software Artifacts)** is a set of security requirements and guidance for producing software artifacts in a way that:

- reduces opportunities for build tampering, and
- enables downstream consumers to **verify** how an artifact was produced via **provenance**.

SLSA is organized as a set of *levels* within the **Build track**.

### Purpose: build integrity and provenance

SLSA aims to make builds **more trustworthy** by ensuring that:

- the build runs in a controlled environment,
- the build result is tied to the source inputs, and
- a verifier can validate a signed statement (“provenance”) about the build.

### Source integrity vs build integrity vs provenance

- **Source integrity**: confidence that the *source inputs* (repo, ref, commit, reviewed changes) are what you intended to build and have not been altered.
- **Build integrity**: confidence that the *build process and environment* produced the artifact as intended, without unauthorized modification, and with appropriate isolation between builds.
- **Provenance**: a *verifiable statement* about **what** was built, **from what**, **by which builder**, and under **which invocation**, sufficient for a downstream verifier to evaluate trust.

### What “provenance” means in SLSA

In SLSA, **provenance** is an **attestation** describing the build, typically signed by a trusted identity bound to a build platform. Provenance is used by downstream systems to:

- bind an artifact (by digest) to its build,
- validate that the build ran on an expected platform/builder, and
- enforce policy (e.g., “only accept artifacts built with SLSA Build L3 provenance from builder X”).

### What the Build track covers

The **Build track** is about:

- producing **authenticated / non-forgeable provenance**, and
- protecting the build process (e.g., isolation to prevent cross-build influence).

This repository focuses on the **Build track only**. It does not claim to implement other SLSA concerns such as source governance, dependency hygiene, or distribution policies beyond attaching/verifying provenance.

---

## 2. Why SLSA Matters

SLSA’s Build track is designed to reduce risk from common build and CI/CD threats, including:

- **Artifact tampering**: an attacker replaces the output artifact after (or during) the build and before release.
- **Forged provenance**: an attacker produces a believable-looking attestation that did not come from an authorized builder.
- **Compromised build systems**: the build runner or workflow environment is modified to inject malicious behavior while keeping the same source inputs.
- **Cross-build influence**: one build affects another build’s outputs (e.g., cache poisoning, workspace reuse, shared runners).

### Why non-forgeable provenance matters

If provenance can be forged by the same principal that runs untrusted build steps, it becomes an unactionable “claim”. **Non-forgeable provenance** enables a verifier to treat provenance as evidence, not just metadata.

### Self-attestation vs verifiable provenance

- **Self-attestation**: the build logic (or a token available to it) signs and publishes provenance. If the build is compromised, the attacker can sign “good” provenance for “bad” artifacts.
- **Verifiable provenance**: provenance is generated and signed by a **separate trusted component** (a build platform / control plane) whose identity and permissions are not available to untrusted build steps.

### Downstream policy enforcement

When provenance is authentic and non-forgeable, downstream systems (deploy pipelines, admission controllers, artifact proxies) can enforce policies such as:

- only accept artifacts with SLSA v1.0 Build L3 provenance,
- only accept artifacts built from a specific repository and ref/commit,
- only accept artifacts built by an allowlisted builder identity.

The Goodmem installer verifies SLSA signatures by default.

---

## 3. SLSA Level 2 vs Level 3 (Build Track)

SLSA defines increasing requirements for the **Build track**. The table below highlights the practical differences relevant to GitHub Actions-style builds.

| Topic | SLSA Build L2 | SLSA Build L3 |
|---|---|---|
| Provenance exists | Yes | Yes |
| Authenticated provenance | Yes (verifier can authenticate where it came from) | Yes |
| Signed provenance | Commonly yes (signature/cert bound to an identity) | Yes (must support non-forgeability goals) |
| Who generates provenance | A build service/platform, not arbitrary post-processing | A build service/platform with stronger guarantees |
| Non-forgeability | Not a strict guarantee at L2 | Strong goal: provenance cannot be forged by the build steps |
| Isolation | Limited guarantees | Hardened builds with strong isolation between runs |
| Cross-build influence | May be possible | Must be prevented (e.g., isolated, ephemeral execution) |
| Provenance fields controlled by platform | Partial | Stronger separation: critical fields are not user-controlled |
| Separation of execution vs signing | Not required | Required in practice to prevent forging (build steps can’t mint/sign provenance) |

Notes:

- The exact requirement wording is defined by the SLSA spec; this repository’s design targets the **Build L3** intent by separating untrusted build execution from trusted provenance generation/signing.

---

## 4. BYOB Architecture

This repository uses the SLSA GitHub **BYOB** model as implemented by `slsa-framework/slsa-github-generator`.

BYOB is a practical pattern for GitHub Actions where:

- build logic may run in a context that must be treated as **untrusted**, and
- provenance generation/signing happens in a **trusted** workflow with tightly-scoped permissions and identities.

### Tool Callable Action (TCA)

In this repository, the **TCA** is:

- `./.github/actions/slsa-release` (composite action)

Conceptually, a TCA:

- performs the build logic (here: builds release artifacts into `dist/` and generates an outputs “layout”),
- runs in the **untrusted build context**, and therefore:
  - does **not** have permission to mint provenance,
  - does **not** need `id-token: write`,
  - must not have access to long-lived signing keys.

### Tool Callable Workflow (TCW)

In this repository, the **TCW** is:

- `./.github/workflows/slsa-release.yml` (reusable workflow)

Conceptually, a TCW:

- contains the **trusted control-plane jobs** that can request OIDC tokens,
- invokes SLSA generator/delegate workflows in `slsa-github-generator`,
- ensures artifact subjects are bound to immutable identifiers (files by digest; images by OCI digest),
- signs and publishes provenance.

Important:

- A TCW may also orchestrate **separate build jobs** (e.g., container image builds) that intentionally do **not** have signing/OIDC permissions. Those jobs must be treated as untrusted build execution.

### Why this separation is required for Build L3 non-forgeability

To make provenance **non-forgeable** at Build L3, the principal that runs arbitrary build steps must not be able to:

- obtain the signing identity/credentials used for provenance, or
- set/override platform-controlled provenance fields.

BYOB enforces this by splitting responsibilities between untrusted build logic (TCA) and a trusted, permissioned provenance generator (TCW + delegate workflow).

---
## 5. How This Repository Achieves SLSA Level 3 (Build Track)

This repository is structured to satisfy the **SLSA v1.2 Build L3** intent for provenance and build isolation.

### Authentic provenance

- The provenance is produced by `slsa-framework/slsa-github-generator` workflows which use GitHub’s OIDC identity to create verifiable signatures bound to the workflow run identity.

### Non-forgeable provenance

- The untrusted build logic (TCA) is separated from the provenance generation/signing identity.
- The TCA is designed to run without the permissions required to request OIDC tokens (`id-token: write`) or sign provenance.

### Platform-controlled metadata

- Critical provenance fields (builder identity, workflow identity, invocation context) are set by the trusted generator workflow and GitHub platform context, not by build scripts.

### Isolated signing permissions

- OIDC signing capability is granted only to the trusted control plane jobs (TCW / delegate), not to the untrusted build job(s).

### Separation of build execution and provenance generation

- The build produces artifacts/images; the generator workflows generate and sign provenance as separate steps with separate identity and permissions.

### No cross-build influence

- Using GitHub-hosted runners (`ubuntu-latest`) provides ephemeral VMs per job, which is a key assumption for preventing cross-build influence.

---

## 6. Container Image Provenance

This repository treats container images as **immutable subjects** identified by an OCI **digest**:

1. Images are built and pushed to a registry.
2. Provenance is generated for the image **digest**.
3. Attestations are attached to the image.

### How we build and sign images

We build container images in an **untrusted build job**, then generate/sign provenance in a **separate trusted job**:

1. **Build + push (untrusted)** uses the official Docker builder action `docker/build-push-action@v6` to build and push a multi-arch image, emitting an OCI digest (e.g. `sha256:...`). The build job intentionally does **not** have `id-token: write`, so it cannot mint OIDC identities for signing. In the workflow we also push by digest (`push-by-digest=true`) and disable BuildKit provenance (`provenance: false`) so the SLSA provenance we publish is the single source of truth.
2. **Provenance generation + signing (trusted)** passes that digest to the SLSA Build L3 container generator / digest signer: `slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.1.0`. This job has `id-token: write` and produces a DSSE SLSA provenance attestation bound to the image digest, then publishes/attaches it in the registry alongside the image.

### Why we pass digests

Tags are mutable. Digests are immutable. Treating the image **digest** as the subject ensures provenance is bound to exactly the bytes you pull, even if a tag is moved later.

---

## Repository layout

- `Makefile.slsa`: shared make targets used by the release workflow (tag bumping, labels, release publishing).
- `.github/workflows/slsa-release.yml`: reusable workflow (TCW) that:
  - runs the BYOB delegator for file artifacts, and
  - builds/pushes container images and generates container provenance.
- `.github/actions/slsa-release/`: composite action (TCA) that builds `dist/` artifacts and emits a layout for digest binding.

---

## Verifying provenance (downstream)

Downstream verification is done by:

- verifying the attestation signature and identity (OIDC-bound certificate),
- verifying the artifact subject digest matches what you are consuming,
- enforcing policy on provenance fields (builder identity, repository/ref, etc.).
