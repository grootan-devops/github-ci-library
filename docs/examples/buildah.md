# 5. Image Only, Built with Buildah

A Dockerfile-free image repository: a hardened base or runtime image assembled by
`buildah.yml` from `vars.MICRO_ROOT_BASE_IMAGE`. It uses `init`, `lint`, `buildah`,
`scan` (`image` and `license`), `sbom`, `check`, `release`, `secret-scanning`,
`sonarqube` and `trivy-cache`. `docker.yml` does not apply — there is no Dockerfile —
and neither do `chart.yml` or the `config` scans, because nothing here is packaged or
templated. There is no application source, so no `<language>-build.yml` or
`<language>-lint.yml` either.

Two things follow from having no Dockerfile and no manifest: `init.yml`'s `auto`
detection would switch the image side *off*, so `ignore-docker: "false"` is declared
explicitly, and there is no `package.json`/`Chart.yaml` to read a version from, so `tag`
is the one hand-stamped value in the repository.

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

permissions: { contents: read }

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "false"
      ignore-chart: "true"
      tag: "1.4.0"

  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  check:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/check.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      image-tag: ${{ needs.init.outputs.image-tag }}
      image-repository: ${{ needs.init.outputs.image-repository }}

  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit

  sonarqube:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}

  image:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/buildah.yml@1.0.0
    secrets: inherit
    with:
      image-tag: ${{ needs.init.outputs.image-push-tag }}
      image-repository: ${{ needs.init.outputs.image-push-repository }}
      install-packages: "tzdata ca-certificates"
      required-packages: "tzdata ca-certificates glibc-minimal-langpack"
      container-path-env: "/opt/app/bin"
      container-entrypoint: "/opt/app/bin/entrypoint"

  image-scan:
    needs: [image, trivy-cache]
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: image
      image-ref: ${{ needs.image.outputs.image-ref-digest }}

  license-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: license

  sbom:
    needs: trivy-cache
    uses: grootan-devops/github-ci-library/.github/workflows/sbom.yml@1.0.0
    secrets: inherit
```

> The Dockerfile lint lives in `lint.yml`, not in the image workflow — and with no
> Dockerfile present it is a no-op here, leaving YAML, markdown, `CHANGELOG.md` and
> `MIGRATION.md`. For anything `install-packages` cannot express, drop a `buildah.sh`
> in the project root: `buildah.yml` sources it mid-build with `BASE_CONTAINER` and
> `CONTAINER_MOUNT` in scope.

```yaml
# .github/workflows/release.yml
name: CD · Promote, Tag & Release
run-name: "CD · ${{ github.event_name }} · ${{ github.sha }}"

on:
  push:
    branches: [main]

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: false

permissions: { contents: read }

jobs:
  init:
    if: ${{ !cancelled() }}
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "false"
      ignore-chart: "true"
      tag: "1.4.0"

  image:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/buildah.yml@1.0.0
    secrets: inherit
    with:
      is-release: true
      require-scan: false
      image-tag: ${{ needs.init.outputs.tag }}
      image-repository: ${{ needs.init.outputs.image-repository }}
      image-dev-repository: ${{ needs.init.outputs.image-dev-repository }}
      release-tag: ${{ needs.init.outputs.tag }}
      candidate-tag: ${{ needs.init.outputs.candidate-image-tag }}

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
      additional-artifacts: "installed_pkgs.txt"
```

> [!IMPORTANT]
> `scan-result` is not optional. `buildah.yml` · `promote` fails closed: omit it and the
> release errors rather than silently promoting an unscanned image. The SBOM and licence
> reports are not re-run on the release — `upstream-run-id` restores them from the
> candidate run that produced the image being promoted.

The remaining workflows are the same modules on `workflow_dispatch`, for running one
concern on its own.

```yaml
# .github/workflows/build.yml
name: Build · Rebuild Candidate Image
run-name: "Build · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "false"
      ignore-chart: "true"
      tag: "1.4.0"

  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  image:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/buildah.yml@1.0.0
    secrets: inherit
    with:
      image-tag: ${{ needs.init.outputs.image-push-tag }}
      image-repository: ${{ needs.init.outputs.image-push-repository }}
      install-packages: "tzdata ca-certificates"
      required-packages: "tzdata ca-certificates glibc-minimal-langpack"
      container-path-env: "/opt/app/bin"
      container-entrypoint: "/opt/app/bin/entrypoint"

  image-scan:
    needs: [image, trivy-cache]
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: image
      image-ref: ${{ needs.image.outputs.image-ref-digest }}
```

```yaml
# .github/workflows/check.yml
name: Check · Release Prerequisites
run-name: "Check · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "false"
      ignore-chart: "true"
      tag: "1.4.0"

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
# .github/workflows/image-scan.yml
name: Scan · Published Image
run-name: "Scan · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:
    inputs:
      target-version:
        description: Image tag to scan (defaults to the current version)
        required: false
        type: string

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit
    with:
      ignore-docker: "false"
      ignore-chart: "true"
      tag: "1.4.0"

  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  image-scan:
    needs: [init, trivy-cache]
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: image
      image-repository: ${{ needs.init.outputs.image-repository }}
      target-version: ${{ inputs.target-version || needs.init.outputs.tag }}
```

```yaml
# .github/workflows/sbom.yml
name: SBOM · Generate & Licence Audit
run-name: "SBOM · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  sbom:
    needs: trivy-cache
    uses: grootan-devops/github-ci-library/.github/workflows/sbom.yml@1.0.0
    secrets: inherit

  license-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: license
```

```yaml
# .github/workflows/lint.yml
name: Lint · YAML, Changelog & Migration
run-name: "Lint · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit
```

```yaml
# .github/workflows/secret-scan.yml
name: Secret Scan · Full History
run-name: "Secret Scan · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit
    with:
      full-history: true
```

```yaml
# .github/workflows/sonarqube.yml
name: SonarQube · Quality Gate
run-name: "SonarQube · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions: { contents: read }

jobs:
  sonarqube:
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
```

> [!TIP]
> Every job that scans `needs` the `trivy-cache` job. Without that edge each scan
> re-downloads roughly 1GB of vulnerability database. The warm job saves dated cache entries
> automatically and needs only `contents: read`.

[Documentation index](../../README.md)
