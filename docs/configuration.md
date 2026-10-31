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
| `IMAGE_REGISTRY` | Container image registry host, e.g. `registry.domain.local`. Required when Buildah publishing is enabled, and when Docker publishing is enabled without `PROJECT_REGISTRY_NAME`. |
| `IMAGE_REPOSITORY` | Container image repository path, e.g. `myapp/order-backend`. With `PROJECT_REGISTRY_NAME`, the full repositories instead, e.g. `registry.domain.local/myapp/order-backend quay.io/myorg/order-backend`, the first being the primary. Required when image publishing is enabled. |
| `CHART_REGISTRY` | Helm chart OCI registry host, e.g. `registry.domain.local`. Required when chart publishing is enabled without `PROJECT_REGISTRY_NAME`. |
| `CHART_REPOSITORY` | Helm chart repository path, e.g. `helm` or a Docker Hub namespace root. With `PROJECT_REGISTRY_NAME`, the full repositories instead, e.g. `registry.domain.local/helm`, the first being the primary. Required when chart publishing is enabled. |
| `PROJECT_REGISTRY_NAME` | The `REGISTRY_CONFIG` group to publish with, e.g. `oneuptime/prod`. `IMAGE_REPOSITORY` and `CHART_REPOSITORY` then list full repositories, and `IMAGE_REGISTRY` and `CHART_REGISTRY` must be unset. See [Publishing to several registries](#publishing-to-several-registries). |

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
> `grootantech/toolkit:2.0.1` literally, and `docker.yml` hardcodes the
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
| `CHART_REPOSITORY` | — | Chart repository path in `CHART_REGISTRY`. For Docker Hub, set this to the namespace root (for example `oneuptime`), because Helm appends the chart name. |
| `DOCKERFILE` | `Dockerfile` | Dockerfile path for linting and building. |
| `MASTER_BRANCH_REGEX` | `^(.*/)?master$` | **Additional** protected branches treated as release branches. The repository's own default branch always is, whatever it is called — leave this alone unless you release from a second branch such as `release/master`. |
| `IMAGE_DEV_REPOSITORY_SUFFIX` | automatic | Appended for candidate images: `-dev` on Docker Hub and `/dev` on other registries. Set an explicit value to override; on Docker Hub a `/` in it still becomes `-`. |
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
| `IMAGE_REGISTRY_USERNAME` / `IMAGE_REGISTRY_PASSWORD` | When image publishing is enabled with `IMAGE_REGISTRY` | Authenticate to `IMAGE_REGISTRY` for image builds, scans and pushes. Ignored with `PROJECT_REGISTRY_NAME`. |
| `CHART_REGISTRY_USERNAME` / `CHART_REGISTRY_PASSWORD` | When chart publishing is enabled with `CHART_REGISTRY` | Authenticate to `CHART_REGISTRY` for chart dependency resolution, checks and OCI pushes. Ignored with `PROJECT_REGISTRY_NAME`. |
| `REGISTRY_CONFIG` | With `PROJECT_REGISTRY_NAME` | Credential groups, as YAML or JSON: each maps registry hosts to a `username` and `password`. See [Publishing to several registries](#publishing-to-several-registries). |
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
- **Registry credential groups** — `secrets.REGISTRY_CONFIG`, one secret holding the
  credentials of every registry, grouped per client or organisation, so a repository names
  its group (`vars.PROJECT_REGISTRY_NAME`) and needs no registry secrets of its own.
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
Docker Hub namespace root, for example `oneuptime`. Helm appends the chart name, so
`core-library` is published at `oci://registry-1.docker.io/oneuptime/core-library`.
Candidate and release versions use that same chart repository; candidate version suffixes
keep them distinct.

- **Auth**: `helm registry login` with `CHART_REGISTRY_USERNAME` /
  `CHART_REGISTRY_PASSWORD`, or with a group each registry's credentials in it. Image
  credentials are independent and are only needed when the repository publishes images.
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
Without an override they log in to the chart registry when it has credentials, or with
`PROJECT_REGISTRY_NAME` to every registry `CHART_REPOSITORY` names; public and `file://`
dependencies can resolve without credentials. These settings do not replace required
publishing settings.

### Container image publishing & authentication

- **Target**: `${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}${IMAGE_DEV_REPOSITORY_SUFFIX}:${TAG}`
  for candidates, `${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${TAG}` for releases. With
  `PROJECT_REGISTRY_NAME`, each full repository `IMAGE_REPOSITORY` lists takes the place of
  `${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}`.
- **Auth**: in `docker.yml`, `scripts/registry/login.sh` runs `docker login` for the primary
  registry in the build and smoke-test jobs and logs out again when the job ends, so nothing
  stays behind on a self-hosted runner; its containerised promote and copy jobs, and the
  checks, use `crane auth login`. These logins read the password from stdin. `buildah.yml`
  logs in to its single registry as it always has.
- **Dev vs production**: `docker.yml` · `promote` uses `crane mutate --tag` to copy the
  manifest **layerlessly** from the dev path to the production path, rewriting only the
  version label, then tags `${TAG}`, `latest`, `${MAJOR}` and `${MINOR}`. Rewriting the label
  gives the released image its own digest; `IMAGE_INFO.md` records both it and the scanned
  candidate's.
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

### Publishing to several registries

A repository publishes each artifact to one registry, set by `IMAGE_REGISTRY` and
`CHART_REGISTRY`, or to several with a credential group. `REGISTRY_CONFIG`, an organisation
secret, holds the groups: each maps the registries one client or organisation uses to their
credentials. `PROJECT_REGISTRY_NAME` names the group a repository publishes with, and its
`IMAGE_REPOSITORY` and `CHART_REPOSITORY` list the full repositories to publish to.

```yaml
# secrets.REGISTRY_CONFIG
oneuptime/prod:
  registry.example.com:
    username: 'robot$ci'
    password: '<token>'
  quay.io:
    username: 'oneuptime+ci'
    password: '<token>'
  docker.io:
    username: 'oneuptime'
    password: '<access token>'
oneuptime/dev:
  registry.example.com:
    username: 'robot$dev'
    password: '<token>'
```

```yaml
# Repository variables (vars.IMAGE_REGISTRY and vars.CHART_REGISTRY left unset)
PROJECT_REGISTRY_NAME: oneuptime/prod
IMAGE_REPOSITORY: "registry.example.com/core/api quay.io/oneuptime/api docker.io/oneuptime/api"  # the first is the primary
CHART_REPOSITORY: "registry.example.com/helm registry-1.docker.io/oneuptime"
```

A pull request run of version `1.4.0` with these variables publishes:

| Repository | Candidate |
| --- | --- |
| `registry.example.com/core/api` | `registry.example.com/core/api/dev:1.4.0-<run>.<pr>` |
| `quay.io/oneuptime/api` | `quay.io/oneuptime/api/dev:1.4.0-<run>.<pr>` |
| `docker.io/oneuptime/api` | `docker.io/oneuptime/api-dev:1.4.0-<run>.<pr>` |
| `registry.example.com/helm` | `oci://registry.example.com/helm/dev/<chart>`, version `1.4.0-<run>.<pr>` |
| `registry-1.docker.io/oneuptime` | `oci://registry-1.docker.io/oneuptime/<chart>`, version `1.4.0-<run>.<pr>` |

- **A group** is any name without spaces, such as `client/org`, mapping registry hosts,
  optionally with a port, to a `username` and a `password`. A registry appears once in a
  group, so the repositories on it share its account. Hosts match ignoring case, and
  `docker.io`, `index.docker.io` and `registry-1.docker.io` are one registry. Several groups
  can share an account through a YAML anchor, and JSON is read as well.
- **Quote every username and password.** YAML reads an unquoted `0123` as a number, which is
  refused, and ends an unquoted value at a space followed by `#`, which cannot be detected.
  Single quotes keep every character as written; write a `'` inside them as `''`.
- **Full repositories.** With a group, each entry of `IMAGE_REPOSITORY` and `CHART_REPOSITORY`
  is `<registry>/<path>`, separated by spaces or commas, and its registry must be in the group.
  A chart's may start with `oci://`; neither carries a tag. The first of each is the
  artifact's primary: base images and the SonarQube scanner are pulled from it, and smoke
  tests, scans and deployments read from it. `init.yml`'s registry outputs are the primaries'
  hosts, and its repository outputs list the full repositories, primary first, which
  `docker.yml`, `chart.yml`, `check.yml`, `scan.yml` and the deploy workflows accept as they
  are. Docker Hub rules apply per repository: `/dev` becomes `-dev` for its images, and its
  charts use the production repository.
- **Docker Hub**: write images as `docker.io/<namespace>/<name>` and charts as
  `registry-1.docker.io/<namespace>`, the host Helm pushes to. A group's `docker.io` serves both.
- **Copies, not rebuilds.** Every candidate and every release reaches every repository. The
  `docker.yml` build pushes to the primary, and its **Copy To Other Registries** job copies the
  image by digest to the others. A release is promoted once, in the primary, and the released
  image is then copied by digest, with its `latest`, major and minor tags, so every repository
  ships the bytes the scan looked at. A released chart is pushed as the same package.
- **Buildah publishes to one registry.** `buildah.yml` builds internal images and pushes them
  to `IMAGE_REGISTRY` alone, with its secret pair, so a repository that builds with it sets
  `IMAGE_REGISTRY`, not `PROJECT_REGISTRY_NAME`.
- **Every repository is tried before a job fails**, and the failure names each one that was
  refused, so one re-run fixes them all. **Collision checks** (`check.yml`) look for the release
  tag and chart version in every repository, because a copy would overwrite it there.
- **One way or the other.** `PROJECT_REGISTRY_NAME` set together with `IMAGE_REGISTRY` or
  `CHART_REGISTRY` is ambiguous, so the first step of `init.yml` fails and names both, before
  any job publishes anything. To use a group in one repository while the organisation sets
  `IMAGE_REGISTRY`, limit that organisation variable's repository access to the repositories
  that still use it. With a group, the `IMAGE_`/`CHART_REGISTRY_USERNAME` and `_PASSWORD`
  secrets are ignored.
- **Errors name the group and the registry, never their values**: a group `REGISTRY_CONFIG`
  does not define, a registry the group does not have, a repository that is not
  `<registry>/<path>` or is listed twice, a registry without a quoted username and password,
  two keys for one registry, and AWS ECR (`rolearn`, `*.dkr.ecr.*`), which is not supported.
- **Masking.** GitHub redacts a secret by exact match and does not reliably redact parts of a
  structured one, so each password read from `REGISTRY_CONFIG` is masked on its own before use,
  and nothing prints the secret. A repository-level `REGISTRY_CONFIG` replaces the
  organisation's.
- **Callers pass it with `secrets: inherit`.** `deploy-argocd-gitops.yml` and
  `deploy-komodo-gitops.yml` declare their secrets, so pass `REGISTRY_CONFIG` explicitly to them
  when you do not inherit.
- **Repositories must exist.** Create the repository, or the Harbor project, in every registry
  before the first push; a registry that refuses to create one fails the job.

> [!IMPORTANT]
> Releases before `1.10.0` ignore `PROJECT_REGISTRY_NAME`, read `IMAGE_REGISTRY` and
> `CHART_REGISTRY` only, and would take a full repository for a path. Set the group and the full
> repositories per repository as it moves to `1.10.0`, or at organisation level only once every
> repository pins `1.10.0` or later.

[Documentation index](../README.md)
