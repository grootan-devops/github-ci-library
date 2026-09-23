# Quick Start

Two files give you a complete pipeline. `init.yml` resolves every version, tag and
repository path once; every other workflow consumes its outputs.

```yaml
# .github/workflows/pr.yml
name: CI · PR Verification
run-name: "CI · ${{ github.event_name }} · ${{ github.sha }}"

on:
  pull_request:
    branches: [main]
  merge_group:
    types: [checks_requested]

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit

  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  build:
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/python-build.yml@1.0.0
    secrets: inherit

  trivy-cache:
    needs: init
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  image:
    needs: [init, build]
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/docker.yml@1.0.0
    secrets: inherit
    with:
      image-tag: ${{ needs.init.outputs.image-push-tag }}
      image-repository: ${{ needs.init.outputs.image-push-repository }}

  scan:
    needs: [init, image, trivy-cache]
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: image
      image-ref: ${{ needs.image.outputs.image-ref-digest }}

  check:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/check.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      image-tag: ${{ needs.init.outputs.image-tag }}
      image-repository: ${{ needs.init.outputs.image-repository }}
```

```yaml
# .github/workflows/release.yml
name: CD · Production Release
run-name: "CD · ${{ github.event_name }} · ${{ github.sha }}"

on:
  push:
    branches: [main]

concurrency:
  group: "release-${{ github.ref }}"
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit

  image:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/docker.yml@1.0.0
    secrets: inherit
    with:
      is-release: true
      require-scan: false
      image-tag: ${{ needs.init.outputs.tag }}
      release-tag: ${{ needs.init.outputs.tag }}
      candidate-tag: ${{ needs.init.outputs.candidate-image-tag }}
      image-repository: ${{ needs.init.outputs.image-repository }}
      image-dev-repository: ${{ needs.init.outputs.image-dev-repository }}

  release:
    needs: [init, image]
    permissions:
      contents: write
      actions: read
    uses: grootan-devops/github-ci-library/.github/workflows/release.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      upstream-run-id: ${{ needs.init.outputs.upstream-run-id }}
```

Before the first run, set the organisation variables and secrets listed under
[Key Variables & Configuration](configuration.md#key-variables--configuration). Every caller passes
`secrets: inherit`.

## Which branch releases

`init.yml` treats the repository's **own default branch** as the release branch — `main`,
`master` or anything else — by comparing `github.ref` against
`github.event.repository.default_branch`. Nothing needs configuring for that, and a repo on
`main` does not need `MASTER_BRANCH_REGEX` changed.

`MASTER_BRANCH_REGEX` is the *second* path: a protected branch that is **not** the default
and should still release, such as a maintenance `release/master`. Its default of
`^(.*/)?master$` matches nothing on a `main`-only repository, which is the intended no-op.

A push to any other branch gets a candidate suffix and the dev repositories, so it cannot
overwrite a published artifact.

## Caller-side permissions

A reusable workflow's `permissions:` block is a **ceiling request, not a grant** — the job
runs with the *caller's* token, and GitHub will not hand it a scope the caller did not have.
Under-grant and the call fails at **startup**, before any job runs.

**Declare `permissions: contents: read` at the workflow level and elevate on the individual
`uses:` job.** A job calling a reusable workflow takes a `permissions:` block like any other.
Putting the union at the top instead hands `packages: write` to the lint job and the secret
scan, which never push anything — and those are the jobs most likely to execute third-party
code.

Each workflow needs exactly this, and nothing else:

| Called workflow | `permissions:` on the calling job |
| --- | --- |
| `init` | `contents: read`, `actions: read`, `pull-requests: read` |
| `release` | `contents: write`, `actions: read` |
| `docker`, `buildah`, `chart` | `contents: read`, `packages: write` |
| `scan` | `contents: read`, `checks: write` |
| `<lang>-build` | `contents: read`, `checks: write` |
| `trivy-cache` | `contents: read` |
| `lint`, `<lang>-lint`, `check`, `sbom`, `sonarqube`, `secret-scanning`, `notify`, `terraform-*`, `deploy-*` | `contents: read` |

`contents: write` creates the git tag and GitHub Release. `packages: write` covers image and
chart pushes. `actions: read` lets `init` and `release` reach the upstream candidate run.
`checks: write` publishes test and scan results as Checks. The cache workflows use dated
`actions/cache` keys and require only `contents: read`; they no longer delete or rewrite a
stable cache entry through the Actions API.

[Documentation index](../README.md)
