# 2. Terraform Infrastructure / Module Registry

Terraform repositories build nothing and push nothing: no image, no chart, no language
artifact. That leaves `init.yml`, `terraform-lint.yml`, `terraform-test.yml`, the
`config`/`terraform` mode of `scan.yml`, `check.yml`, `release.yml`, `secret-scanning.yml`,
`sonarqube.yml` and `trivy-cache.yml`. `docker.yml`, `buildah.yml`, `chart.yml` and the
`<language>-build.yml` workflows do not apply, and neither does `sbom.yml` — there is no
built artifact to describe. The release publishes only a git tag; consumers pin it.

A Terraform repository has no `package.json`, `pyproject.toml`, `pom.xml` or `Chart.yaml`, so
it keeps its version in a `VERSION` file — which `init.yml` reads directly. Nothing else is
needed to resolve a version here.

```yaml
# .github/workflows/pr.yml
name: CI · PR Verification
run-name: >-
  ${{ github.event_name == 'pull_request'
      && format('PR #{0}: {1} -> {2} ({3})', github.event.pull_request.number, github.head_ref, github.base_ref, github.sha)
      || format('Verify · {0}', github.ref_name) }}

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
    with:
      ignore-chart: "true"
      ignore-docker: "true"

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

  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  terraform-lint:
    uses: grootan-devops/github-ci-library/.github/workflows/terraform-lint.yml@1.0.0
    secrets: inherit
    with:
      state-name: network

  terraform-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: config
      config-type: terraform
      scan-path: "."

  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit

  sonarqube:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}
```

The module test is a **separate workflow**, not a job in `pr.yml`. It provisions real
infrastructure and destroys it in a post-failure job, so it must run with
`cancel-in-progress: false` — a PR workflow cancels superseded runs, which would kill
teardown and leave the fixtures standing.

```yaml
# .github/workflows/terraform-test.yml
name: CI · Terraform Module Test
run-name: >-
  ${{ github.event_name == 'pull_request'
      && format('Test PR #{0}: {1} -> {2} ({3})', github.event.pull_request.number, github.head_ref, github.base_ref, github.sha)
      || format('Test · {0}', github.ref_name) }}

on:
  pull_request:
    branches: [main]
    paths:
      - "**.tf"
      - "**.tfvars"
      - "tests/**"
      - ".github/**"
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: false

permissions:
  contents: read

jobs:
  terraform-test:
    uses: grootan-devops/github-ci-library/.github/workflows/terraform-test.yml@1.0.0
    secrets: inherit
    with:
      test-timeout: 45m
```

```yaml
# .github/workflows/release.yml
name: CD · Tag & Release
run-name: "CD · ${{ github.event_name }} · ${{ github.sha }}"

on:
  push:
    branches: [main]
    paths-ignore:
      - ".github/**"

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: false

permissions:
  contents: read

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
      ignore-chart: "true"
      ignore-docker: "true"

  release:
    needs: init
    permissions:
      contents: write
      actions: read
    uses: grootan-devops/github-ci-library/.github/workflows/release.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
      notify: true
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
    with:
      ignore-chart: "true"
      ignore-docker: "true"

  check:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/check.yml@1.0.0
    secrets: inherit
    with:
      tag: ${{ needs.init.outputs.tag }}
```

With no `chart-name` and no `image-tag`, `check.yml` runs the git tag, changelog and
migration guards only — the chart and image guards switch themselves off.

```yaml
# .github/workflows/lint.yml
name: Lint · YAML, Markdown & Terraform
run-name: "Lint · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  lint:
    uses: grootan-devops/github-ci-library/.github/workflows/lint.yml@1.0.0
    secrets: inherit

  terraform-lint:
    uses: grootan-devops/github-ci-library/.github/workflows/terraform-lint.yml@1.0.0
    secrets: inherit
    with:
      state-name: network
      check-docs: true
```

```yaml
# .github/workflows/config-scan.yml
name: Scan · Terraform Configuration
run-name: "Scan · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit

  terraform-scan:
    needs: trivy-cache
    permissions:
      contents: read
      checks: write
    uses: grootan-devops/github-ci-library/.github/workflows/scan.yml@1.0.0
    secrets: inherit
    with:
      scan-type: config
      config-type: terraform
      scan-path: "."
      fail-on-warnings: true
```

```yaml
# .github/workflows/secret-scan.yml
name: Scan · Secrets
run-name: "Scan · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

concurrency:
  group: "${{ github.workflow }}-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  secret-scan:
    uses: grootan-devops/github-ci-library/.github/workflows/secret-scanning.yml@1.0.0
    secrets: inherit
    with:
      full-history: true
```

```yaml
# .github/workflows/sonarqube.yml
name: Quality · SonarQube
run-name: "Quality · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:

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
    with:
      ignore-chart: "true"
      ignore-docker: "true"

  sonarqube:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/sonarqube.yml@1.0.0
    secrets: inherit
    with:
      project-version: ${{ needs.init.outputs.tag }}
```

There is no publish step. The release tags the repository and consumers pin that tag:

```hcl
module "network" {
  source = "git::git@github.com:grootan-devops/terraform-modules.git//modules/network?ref=1.0.0"
}
```

[Documentation index](../../README.md)
