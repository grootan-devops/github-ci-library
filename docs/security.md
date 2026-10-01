# Security and scanning

## Warming the Trivy cache from the default branch

`trivy-cache.yml` is only worth calling if something in the repository scans — `scan.yml`
with `scan-type: image`, or `sbom.yml`. **A repository that does not scan should not call it
and needs no cache-warm workflow at all.** A CI image that never leaves the build farm is a
fair reason not to scan; so is a repository that ships no image.

If you do scan, one more workflow is needed, and its absence is silent. The cache uses a
UTC-dated key and automatically saves a new entry when the key is missing. GitHub scopes a
cache entry to the ref that wrote it, so the scheduled/default-branch run is the one that
creates a cache available to later pull requests. Without it, every run re-downloads the
vulnerability database.

A scheduled workflow closes that, because a schedule executes on the default branch:

```yaml
# .github/workflows/cache-warm.yml
name: Cache · Trivy Database
run-name: "Cache · ${{ github.event_name }} · ${{ github.sha }}"

on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch:

concurrency:
  group: "cache-warm-${{ github.ref }}"
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  trivy-cache:
    permissions:
      contents: read
    uses: grootan-devops/github-ci-library/.github/workflows/trivy-cache.yml@1.0.0
    secrets: inherit
    with:
      enable-java-db: false
```

Set `enable-java-db: true` only for a repository that ships a JVM artifact — the Java
database is roughly 900MB and dominates the cached tree. Keep `workflow_dispatch` beside the
schedule so the cache can be rebuilt on demand after a base-image change.

> [!NOTE]
> A `release.yml` that only promotes does not call `trivy-cache.yml`, so on that shape the
> scheduled run is the only thing that writes the cache. Drop it and pull requests restore
> an entry that nothing ever refreshes.
>
> [!IMPORTANT]
> The repository's default token scope caps all of this. If **Settings → Actions → General →
> Workflow permissions** is set to read-only, `contents: write` is denied and the release
> cannot tag, whatever the workflow declares.

## Promotion requires a scan verdict

`docker.yml` and `buildah.yml` refuse to promote an image unless the caller proves it was
scanned. The scan job lives in *your* workflow, so the library cannot make `promote` depend
on it — the verdict has to be handed over:

```yaml
  image:
    needs: [init, scan]
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/docker.yml@1.0.0
    with:
      is-release: true
      scan-result: ${{ needs.scan.result }}
```

| Input | Default | Effect |
| --- | --- | --- |
| `require-scan` | `true` | Promotion refuses unless `scan-result` is `success`. |
| `scan-result` | `""` | The scan job's `result`. Empty means refused. |

It fails closed and it fails loudly: a caller that forgets `scan-result` gets an empty
value and the promote job **errors**, naming the fix. It is a failing step rather than a
job condition on purpose — a skipped job reads as success to the caller's graph, so
refusing by condition would let a release carry on having promoted nothing.

Set `require-scan: false` only for an artifact with no scan in its pipeline.

## Ignored CVEs & Licenses (`ignored-cves.yml`)

Create `ignored-cves.yml` in your project root to suppress verified findings:

```yaml
image:
  - id: CVE-2023-12345
    reason: "Vulnerability does not affect our usage — we do not call the affected code path"
  - id: CVE-2024-99999
    reason: "No upstream fix available; mitigated by network policy restricting inbound traffic"

iac:
  chart:
    - id: KSV-0016
      reason: "Memory requests not required for batch workloads"
  terraform:
    - id: AVD-AWS-0001
      reason: "S3 bucket is private and only accessed via VPC endpoint"

license:
  - id: LGPL-3.0-or-later
    package: "org.hibernate.orm:hibernate-core"
    reason: "Dynamically linked backend ORM library compliant with server architecture"
  - id: MPL-2.0
    package: "*"
    reason: "File-level copyleft unmodified library used as standalone module"

sbom:
  - id: CVE-2024-11111
    reason: "Dev-only dependency not bundled in production artifact"
```

> [!IMPORTANT]
> **Reason validation.** Every `reason` must be at least **10 characters** and must not be a
> placeholder (`todo`, `tbd`, `n/a`, `fix`, `fixme`, `later`, `wip`, `none`, `unknown`,
> `ignore`, `skip`, `test`, `temp`). A failing reason fails the scan.
>
> **Stale suppressions fail the scan.** An entry for a finding that is no longer present is
> an error, not a warning — the file cannot rot.
>
> **Licence scoping.** Set `package` to scope a copyleft exception to one package, so a
> future dependency under the same licence is not silently ignored. Use `package: "*"` or
> omit for a global exception.

When a scan finds something not yet suppressed, it prints a ready-to-paste
`ignored-cves.yml` fragment at the end of the job log.

---

## Scan Exit Codes

All scanning jobs evaluate results with the same status codes:

| Exit code | Meaning | Job result |
| --- | --- | --- |
| `0` | Clean scan — all checks passed. | Success ✅ |
| `1` | Fixable vulnerabilities, stale ignore entries, or invalid reasons. | Failed ❌ |
| `2` | Warnings only — unfixable vulnerabilities or approved suppressions. | Success with warning ⚠️ |

GitHub has no equivalent of GitLab's `allow_failure: exit_codes: [2]`, so exit code 2 is
handled in the workflow: it annotates and summarises but does not fail. Pass
`fail-on-warnings: true` to `scan.yml` or `sbom.yml` to make warnings blocking.

## Optional security configuration examples

These existing standalone examples are reference configurations, not additional reusable workflows:

- [CodeQL](codeql.md)
- [Dependabot](dependabot.md)

## Reviewing a consumer repository

The pipeline's own checks are exact and structural. What follows needs someone to read a value
and judge what it means.

### Secrets — classify by value, not by key name

Ask of every value in the repository, its CI variables, `.env` and compose files:

- **Does a URL embed a credential?** A connection string with `user:password@` before its host
  (Postgres, AMQP, MongoDB, a Git remote with a token) is a live credential, however innocuous
  its key.
- **Is it high-entropy?** Long random-looking strings are keys even in a field called `id` or
  `ref`; `API_KEY: ""` or a vault reference is fine.
- **Is a private key or certificate inlined?** `-----BEGIN ... PRIVATE KEY-----` anywhere.
- **Is a real value posing as a placeholder?** `changeme`, `admin` or `test123` shipped to an
  environment is a credential.
- **Is a non-secret value in the secret store?** Over-classification hides which values matter.
- **Is a secret transformed before it is printed?** Masking covers the known value, not its
  base64 encoding, a `jq` extract or a slice.

### Pipeline posture

- Prefer a short-lived, job-scoped token to a long-lived one; a static credential is
  read-only unless the job pushes.
- Every secret variable is both masked and protected.
- No secret is echoed, including through `set -x` or a constructed URL.
- Third-party components are pinned when the job holds credentials.
- Failures do not pass silently: no `curl` without `--fail`, no `|| true` around an auth step.
- A job publishing outside its own project uses an explicitly granted credential; if it "just
  works", something is over-permissioned.

### GitHub specifics

Anyone can open a pull request, and several triggers run something in response. For each
workflow, ask who can cause it to run and what it holds while running.

| Trigger | Attacker can trigger? | Secrets? | Token |
| --- | --- | --- | --- |
| `pull_request` from a fork | yes | no | read-only |
| `pull_request_target` | yes | **yes** | read/write |
| `issue_comment`, `issues` | yes | **yes** | read/write |
| `workflow_run` | indirectly | **yes** | read/write |
| `push`, `schedule`, `workflow_dispatch` | no (needs write access) | yes | per `permissions:` |

- **Untrusted input arrives indirectly** — through a step output capturing a PR title, through
  `env:` into a script file that interpolates it, through an action input the action `eval`s,
  through `github.head_ref`, or through an artifact from a fork run unpacked in a privileged job.
- **`workflow_run`** runs in the base repository with full secrets. Downloading and executing
  an artifact from the untrusted run, trusting an artifact-supplied PR number or branch, or
  checking out a ref taken from the triggering run defeats the privilege separation.
- **`permissions:`**: `contents: read` at workflow level, and each elevation on the one job
  that needs it, explainable in one sentence. An absent block inherits the repository default,
  which on older repositories is read/write everywhere. `id-token: write` on a workflow that
  never uses OIDC signals copied configuration.
- **Runners and environments**: a self-hosted runner on a public repository runs fork code; a
  protected Environment (required reviewers, restricted branches) is the real production gate,
  and production credentials are Environment-scoped.
- **Supply chain**: judge whose unpinned action it is; a pinned composite action may call an
  unpinned one; `npm install`/`pip install` on fork-controlled lockfiles in a privileged context
  runs arbitrary code; prefer OIDC federation to stored cloud keys.

[Documentation index](../README.md)
