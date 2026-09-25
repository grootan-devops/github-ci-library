# Maintainer guide

## Repository Layout

A workflow in this library is a thin shell: inputs, permissions, step wiring, and a call out
to a script. Anything longer than a couple of dozen lines of bash lives in `scripts/`, where
`shellcheck` can see it, a reviewer can read it without YAML indentation in the way, and it
can be run outside CI.

```text
scripts/
├── build/      step summaries shared by every language stack
├── buildah/    rootless image build, push, promote, scan verification
├── chart/      Helm package, push, promote, unit-test summary, docs drift
├── checks/     the release guards check.yml dispatches, and its two drivers
├── deploy/
│   ├── argocd/ resolve target, patch manifests, sync, wait for health
│   └── komodo/ resolve target, commit, trigger, poll execution
├── docker/     hadolint, build failure summary, promote, scan verification
├── init/       config validation, version resolution, provenance, summary
├── lint/       the linter runner plus one script per linter
├── notify/     Teams adaptive card
├── release/    asset consolidation, GitHub Release publication
├── scan/       Trivy engine, SBOM, secret history, Trivy DB cache
├── self/       the library's own release version
├── sonarqube/  analysis, quality gate, cache refresh, summary
└── terraform/  docs drift, test summary
```

Names do not repeat what the directory already says: it is `init/resolve-version.sh`, not
`init/init-resolve-version.sh`.

### Reaching a script from a workflow

Scripts live in this repository, so a consumer's job has to clone it first. Every job that
calls one carries this step, after `Checkout Code`:

```yaml
      - name: Checkout CI Library
        uses: actions/checkout@v7
        with:
          repository: ${{ job.workflow_repository }}
          ref: ${{ job.workflow_sha }}
          path: .ci-library
          token: ${{ secrets.CI_LIBRARY_TOKEN || github.token }}
```

`job.workflow_sha` pins the clone to the same commit as the reusable workflow being called,
so the script and the YAML calling it can never disagree. The call is then:

```yaml
        env:
          CHART_NAME: ${{ inputs.chart-name }}
        run: bash "${GITHUB_WORKSPACE}/.ci-library/scripts/chart/push.sh"
```

Values reach a script only through `env:`. A `${{ ... }}` expression is interpolated by
GitHub before bash starts, so it does not survive into an external file — a script that
needs an input needs an `env:` entry for it.

Two workflows dispatch by name instead of calling a fixed path. `check.yml` builds a matrix
of guards and runs `scripts/checks/${SCRIPT}`, so every release guard lives in `checks/` and
is named in `scripts/checks/select-guards.sh`. `lint.yml` does the same with
`scripts/${{ matrix.script }}`, where the matrix value carries the subdirectory
(`lint/yaml.sh`, `docker/lint.sh`).

### Conventions

- `#!/usr/bin/env bash` and `set -euo pipefail`, except where a script deliberately runs
  without `-e` because its exit code is a contract — `scan/trivy.sh` returns 0 clean,
  1 errors, 2 warnings-only, and says so in its header.
- Required inputs are asserted up front with `: "${VAR:?VAR must be set}"`. Scripts whose
  step runs under `if: always()` use `: "${VAR?...}"` instead, because `steps.<id>.outcome`
  is an empty string when the step never ran and aborting there would turn a green job red.
  Each such script records that reasoning in its header.
- Conditionals are always written as a block, never as `[[ ... ]] && cmd` or on one line:

  ```bash
  if [[ "${CACHE_HIT}" == "true" ]]; then
    CACHE_STATE="restored"
  fi
  ```

- Two files are sourced rather than executed and therefore set no shell options of their
  own: `lint/summary.sh` (the `run_linted` helper) and `docker/hadolint-ignores.sh`.
- `self-lint.yml` runs `shellcheck` over every `*.sh` under `scripts/`, found recursively,
  so a new subdirectory is covered without touching the workflow.

## Migration Guide & Standard

Breaking changes between library versions are documented in [MIGRATION.md](../MIGRATION.md),
and every change is recorded in [CHANGELOG.md](../CHANGELOG.md).

Consuming projects are expected to follow the same standard the library applies to itself:

- **`CHANGELOG.md`** — Keep a Changelog format. Every release needs a `## [x.y.z]` section;
  `check.yml` extracts it as the release notes and fails without it.
- **`MIGRATION.md`** — every release needs a section covering the upgrade path, headed
  `## [previous...current]`, `## [current]` or `## [prevMajor...currentMajor]`. State
  "No migration required" when there is nothing to do; an empty section fails the check.
- **Semantic versioning** — the version lives in the project manifest (`package.json`,
  `pyproject.toml`, `pom.xml`) or `Chart.yaml`. `init.yml` discovers it; nothing is
  hand-stamped.

### The library's own pipeline

`self-pr.yml` (pull request) and `self-release.yml` (push to the default branch) are this
library's counterpart of `ci-templates/.gitlab-ci.yml`. They run the library against itself:

| Phase | Jobs |
| --- | --- |
| Lint | `self-lint.yml` — actionlint, shellcheck and repository self-checks; `lint.yml` covers YAML, changelog and migration guide |
| Check | `self-check.yml` / `self-version.yml` — git tag availability, changelog section and migration section |
| Security | `self-secret-scan.yml` — repository history secret scanning |
| Release | `self-release.yml` → reusable `release.yml` — tags the repository, publishes the GitHub Release with the extracted notes, posts the Teams card |

The released version is the contents of `VERSION`. Bump it in the pull request that ships
the change, the same way `RELEASE_VERSION` is bumped in the GitLab library's own
`.gitlab-ci.yml`.

The Dockerfile-example check discovers the root README and all Markdown pages under `docs/`.
Keep examples in fenced `dockerfile` blocks so moved examples remain linted.

[Documentation index](../README.md)
