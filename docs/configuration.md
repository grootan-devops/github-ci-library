# Configuration

## Key Variables & Configuration

The GitLab library sets everything once in a group-level `variables:` block and each project
overrides almost nothing. This library does the same with **organisation variables**, which
is why callers pass so few inputs.

Set these under **Settings → Secrets and variables → Actions**, at organisation level
wherever possible.

### Required variables

| Variable | Description |
| --- | --- |
| `IMAGE_REGISTRY` | Container image registry host, e.g. `registry.domain.local`. Required when Docker or Buildah publishing is enabled. |
| `IMAGE_REPOSITORY` | Container image repository path, e.g. `myapp/order-backend`. Required when image publishing is enabled. |
| `CHART_REGISTRY` | Helm chart OCI registry host, e.g. `registry.domain.local`. Required when chart publishing is enabled. |
| `CHART_REPOSITORY` | Helm chart repository path, e.g. `helm` or a Docker Hub namespace root. Required when chart publishing is enabled. |

> [!IMPORTANT]
> Build and base image coordinates carry **no library defaults**. A container variable that
> is unset produces a pull failure naming the empty reference, which is a better failure
> than silently running a plausible-but-wrong image version. Set them at organisation level
> once and every repository inherits them.

### Build & base image variables

| Variable | Used by | Description |
| --- | --- | --- |
| `SONAR_SCANNER_IMAGE` | `sonarqube` | SonarSource scanner container |
| `MICRO_ROOT_BASE_IMAGE` | `buildah` | Golang / scratch base, injected as a build arg |

> [!IMPORTANT]
> **The build container and the Docker base images are pinned in the library, not
> configurable.** Every `container:` block names
> `grootantech/toolkit:1.1.0` literally, and `docker.yml` hardcodes the
> `micro-root`, `nginx`, `python-3-12`, `node-24` and `java-25` bases and the BuildKit
> driver. Setting `TOOLKIT_BUILD_IMAGE`, `BUILDKIT_IMAGE` or any `*_MICRO_BASE_IMAGE`
> organisation variable has **no effect** — those rows were removed from this table because
> they described an intent, not the code. Changing any of these means editing the library and
> cutting a release, which is what makes a pipeline reproducible from its tag alone.
>
> `MICRO_ROOT_BASE_IMAGE` is the one exception, and only for `buildah.yml`; `docker.yml`
> hardcodes it like the rest.

### Behavioural variables

| Variable | Default | Description |
| --- | --- | --- |
| `CI_RUNNER` | `ubuntu-26.04` | Runner label for every job. Pinned rather than tracking `ubuntu-latest`, so a platform migration cannot change the build environment under a release. |
| `CHART_FILE` | `Chart.yaml` | Chart manifest filename. |
| `CHART_REPOSITORY` | — | Chart repository path in `CHART_REGISTRY`. For Docker Hub, set this to the namespace root (for example `grootantech`), because Helm appends the chart name. |
| `DOCKERFILE` | `Dockerfile` | Dockerfile path for linting and building. |
| `MASTER_BRANCH_REGEX` | `^(.*/)?master$` | **Additional** protected branches treated as release branches. The repository's own default branch always is, whatever it is called — leave this alone unless you release from a second branch such as `release/master`. |
| `IMAGE_DEV_REPOSITORY_SUFFIX` | automatic | Appended for candidate images: `-dev` on Docker Hub and `/dev` on other registries. Set an explicit value to override. |
| `CHART_DEV_REPOSITORY_SUFFIX` | automatic | Appended for candidate charts as `/dev` on registries with nested paths. Docker Hub ignores this suffix and uses the same namespace-root repository for candidate and release versions. |
| `RELEASE_VERSION_SUFFIX` | — | Suffix appended to the version, e.g. `backend` → `1.5.0-backend`. |
| `CHANGELOG_FILE_NAME` | `./CHANGELOG.md` | Changelog path. |
| `MIGRATION_FILE_NAME` | `./MIGRATION.md` | Migration guide path. |
| `UPSTREAM_WORKFLOW` | `pr.yml` | Workflow file whose successful run produced the candidate artifacts. |
| `HADOLINT_IGNORE` | — | Comma-separated extra hadolint rules to ignore. |

**Monorepo children** are the reason `project-path` exists. Pass it to every workflow that
touches the child, and each resolves its own paths, caches and artifacts beneath it:

```yaml
  build:
    uses: grootan-devops/github-ci-library/.github/workflows/node-build.yml@1.0.0
    secrets: inherit
    with:
      project-path: services/admin-ui

  image:
    needs: [init, build]
    uses: grootan-devops/github-ci-library/.github/workflows/docker.yml@1.0.0
    secrets: inherit
    with:
      project-path: services/admin-ui
      image-tag: ${{ needs.init.outputs.image-push-tag }}
      image-repository: ${{ needs.init.outputs.image-push-repository }}
```

A single-project repository omits it; it defaults to the repository root.

> [!NOTE]
> **A repository's own layout is an input, not a variable.** `project-path`, `chart-dir` and
> the linter globs are passed per call with a real default in the workflow that declares
> them — there is no `vars.PROJECT_PATH` or `vars.CHART_DIR` to set. A variable here is
> something the whole organisation shares; anything describing one repository's file layout
> belongs in the `with:` block. The trade is deliberate: a repository whose chart is not at
> `./chart` repeats `chart-dir:` in each caller workflow that touches it.

### Security & quality variables

| Variable | Default | Description |
| --- | --- | --- |
| `TRIVY_HOST` | — | Shared Trivy server. **Unset means every scan downloads the ~1.2 GB database.** |
| `TRIVY_TIMEOUT` | `60m` | Scan timeout. |
| `TRIVY_IGNORE_CONFIG_FILE` | `ignored-cves.yml` | Suppression configuration path. |
| `TRIVY_IGNORE_CVES` | `KSV-0011 KSV-0014 KSV-0015 KSV-0016 KSV-0018 KSV-0110 KSV-0113 KSV-0125` | Space-separated misconfiguration IDs suppressed platform-wide (set by the platform at deploy time, not by the chart). |
| `TRIVY_IGNORED_LICENSE_CLASSIFICATIONS` | `notice,permissive,unencumbered` | Licence classes that never warn. |
| `SKIP_CVE_SCAN` | `false` | Emergency global scan bypass. |
| `SONAR_URL` / `SONAR_EXTERNAL_URL` / `SONAR_PROJECT_KEY` | — | SonarQube server, dashboard link and project key. |
| `ARGOCD_SERVER` / `KOMODO_SERVER` | — | GitOps endpoints. |

### Secrets

| Secret | Required | Description |
| --- | :--: | --- |
| `IMAGE_REGISTRY_USERNAME` / `IMAGE_REGISTRY_PASSWORD` | When image publishing is enabled | Authenticate to `IMAGE_REGISTRY` for image builds, scans and pushes. |
| `CHART_REGISTRY_USERNAME` / `CHART_REGISTRY_PASSWORD` | When chart publishing is enabled | Authenticate to `CHART_REGISTRY` for chart dependency resolution, checks and OCI pushes. |
| `CI_LIBRARY_TOKEN` | | Only when this library lives in a repository `GITHUB_TOKEN` cannot read. |
| `TRIVY_TOKEN` | | Authenticate to a shared Trivy server. |
| `SONARQUBE_TOKEN` | | SonarQube analysis. |
| `RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL` | | Comma-separated Power Automate webhook URLs. |
| `ARGOCD_AUTH_TOKEN` | | ArgoCD API token. |
| `KOMODO_API_KEY` / `KOMODO_API_SECRET` | | Komodo API credentials. |
| `GITOPS_TOKEN` | | GitOps repository write access. Falls back to `GITHUB_TOKEN`. |

> [!NOTE]
> **Organisation limits.** GitHub allows up to 1,000 organisation variables and 1,000
> organisation secrets, each up to 48 KB. A single workflow can read at most **100
> organisation secrets** — if a repository is granted access to more, only the first 100
> alphabetically are visible. Keep the enabled library's variable and secret inventory
> within those limits. Verify current limits in the GitHub documentation.

## DevOps Reference & Platform Defaults

### Organisation-injected configuration

Configure once at the GitHub organisation level to propagate to every repository:

- **Image registry** — `vars.IMAGE_REGISTRY`, `vars.IMAGE_REPOSITORY`,
  `secrets.IMAGE_REGISTRY_USERNAME`, and `secrets.IMAGE_REGISTRY_PASSWORD` when a repository
  publishes container images.
- **Chart registry** — `vars.CHART_REGISTRY`, `vars.CHART_REPOSITORY`,
  `secrets.CHART_REGISTRY_USERNAME`, and `secrets.CHART_REGISTRY_PASSWORD` when a repository
  publishes Helm charts. A repository that publishes both artifact types must configure both
  sets; chart-only repositories must not need image variables.
- **Build containers** — `vars.SONAR_SCANNER_IMAGE`. The toolkit build container is pinned
  in the library, not set here.
- **Base images** — `vars.MICRO_ROOT_BASE_IMAGE`, read by `buildah.yml` only. The other
  `*_MICRO_BASE_IMAGE` values are pinned in `docker.yml`.
- **Security & quality** — `vars.SONAR_URL`, `vars.SONAR_EXTERNAL_URL`,
  `secrets.SONARQUBE_TOKEN`, `vars.TRIVY_HOST`, `secrets.TRIVY_TOKEN`.
- **Deployment credentials** — `secrets.ARGOCD_AUTH_TOKEN`, `secrets.KOMODO_API_KEY`,
  `secrets.KOMODO_API_SECRET`, `secrets.GITOPS_TOKEN`. Deployment endpoints are caller
  inputs (`argocd-server` / `komodo-server`), not organisation variables.
- **Notifications** — `secrets.RELEASE_MESSAGE_TEAMS_WORKFLOWS_URL`.

### Helm chart publishing & authentication

Charts publish over **OCI** to `oci://${CHART_REGISTRY}/${CHART_REPOSITORY}`.
`CHART_REGISTRY` is required for publishing and must be a hostname, optionally with a port,
not an HTTP URL. There is no package-registry fallback or HTTP publishing option.
Authentication and lookup errors fail the job; only confirmed absence means a version is available.

For Docker Hub, set `CHART_REGISTRY=registry-1.docker.io` and `CHART_REPOSITORY` to the
Docker Hub namespace root, for example `grootantech`. Helm appends the chart name, so
`tpl-library` is published at `oci://grootantech/tpl-library`.
Candidate and release versions use that same chart repository; candidate version suffixes
keep them distinct.

- **Auth**: `helm registry login` with `CHART_REGISTRY_USERNAME` /
  `CHART_REGISTRY_PASSWORD`. Image credentials are independent and are only needed when the
  repository publishes images.
- **Dev vs production**: on registries with nested paths, candidates publish to
  `${CHART_REPOSITORY}${CHART_DEV_REPOSITORY_SUFFIX}`. On Docker Hub, candidates and releases
  publish to `${CHART_REPOSITORY}` and are distinguished by their chart versions. At release,
  `chart.yml` · `promote` pulls the exact candidate, repackages it at the release version and
  pushes it to the production repository.
- **Consuming a published chart**:

  ```bash
  helm registry login "${CHART_REGISTRY}" --username "${USER}" --password-stdin
  helm pull "oci://${CHART_REGISTRY}/${CHART_REPOSITORY}/order-backend" --version 1.4.0
  ```

### Private chart dependencies

For a different dependency registry, set `vars.CHART_DEPENDENCY_REGISTRY` and
`secrets.CHART_DEPENDENCY_REGISTRY_USERNAME` / `secrets.CHART_DEPENDENCY_REGISTRY_PASSWORD`.
Lint, packaging, unit tests and chart scanning use this pair independently of publishing.
Without an override they reuse configured chart credentials; public and `file://` dependencies
can resolve without credentials. These settings do not replace required publishing settings.

### Container image publishing & authentication

- **Target**: `${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}${IMAGE_DEV_REPOSITORY_SUFFIX}:${TAG}`
  for candidates, `${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${TAG}` for releases.
- **Auth**: `docker/login-action` for the build job, `crane auth login` for the containerised
  promote and check jobs.
- **Dev vs production**: `docker.yml` · `promote` uses `crane mutate --tag` to copy the
  manifest **layerlessly** from the dev path to the production path, rewriting only the
  version label, then tags `${TAG}`, `latest`, `${MAJOR}` and `${MINOR}`. The released
  digest is the scanned digest.
- **Digest pinning**: `docker.yml` and `buildah.yml` output `image-ref-digest`
  (`registry/repo@sha256:...`). Feed it to `scan.yml` as `image-ref` so the scan cannot
  resolve a different tag than the one that was built.
- The Buildah workflow reads the digest back from the registry after pushing the target;
  it must not assume that `podman image inspect` returns the target at `.RepoDigests[0]`.
  Podman may return stale or multiple local repository digests, so the registry response
  is the authoritative reference for smoke tests and scans.
- Image smoke tests and image scans are independent caller jobs. An image scan should
  depend on the image build and Trivy cache, not on `image-test`, so a smoke-test failure
  does not suppress the CVE result.

[Documentation index](../README.md)
