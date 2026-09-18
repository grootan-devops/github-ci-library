# Dependabot for consumer repositories

`.github/dependabot.yml` is **not** inherited from this library. Each repository that calls these
workflows needs its own, and it has two jobs the library cannot do for you:

1. Keep the `uses:` reference to this library current.
2. Keep the repository's own dependencies current — the thing `scan.yml` will fail you for.

---

## Minimum viable config

Covers the library reference plus one language ecosystem. Start here.

```yaml
version: 2

updates:
  # The ci-library reference in .github/workflows/*.yml
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    groups:
      ci:
        patterns:
          - "*"
    commit-message:
      prefix: "chore(ci)"

  # Your application dependencies. Swap the ecosystem for your language.
  - package-ecosystem: npm            # gomod | maven | pip | uv | docker | terraform
    directory: /
    schedule:
      interval: weekly
    open-pull-requests-limit: 10
    groups:
      minor-and-patch:
        update-types: ["minor", "patch"]
    commit-message:
      prefix: "chore(deps)"
```

> [!IMPORTANT]
> `package-ecosystem: github-actions` updates the `uses:` line that points at this library, so a
> new library release reaches you as a pull request. Without it you stay pinned forever.

---

## Full config, all ecosystems

For a polyglot repository with a chart and a Dockerfile. Delete the blocks you do not have.

```yaml
version: 2

updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
      time: "06:00"
    groups:
      ci:
        patterns:
          - "*"
    commit-message:
      prefix: "chore(ci)"
    labels:
      - dependencies

  - package-ecosystem: docker         # FROM lines in your Dockerfile
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: "chore(docker)"

  - package-ecosystem: gomod
    directory: /
    schedule:
      interval: weekly
    groups:
      go-minor-patch:
        update-types: ["minor", "patch"]

  - package-ecosystem: npm
    directory: /frontend              # a directory per lockfile
    schedule:
      interval: weekly
    groups:
      npm-minor-patch:
        update-types: ["minor", "patch"]

  - package-ecosystem: pip            # also covers uv / pyproject.toml
    directory: /
    schedule:
      interval: weekly

  - package-ecosystem: maven
    directory: /
    schedule:
      interval: weekly

  - package-ecosystem: terraform
    directory: /infra
    schedule:
      interval: monthly
```

---

## Notes that save time

**One entry per lockfile directory.** Dependabot does not recurse. A monorepo with
`frontend/package.json` and `services/api/go.mod` needs two entries with two `directory:` values.

**Group aggressively.** Ungrouped, a mid-sized repository produces 20+ pull requests a week and
every one of them runs your full pipeline. `groups:` with `update-types: ["minor", "patch"]` gives
you one pull request to review and one pipeline run.

**Majors deserve their own pull request.** Leave majors ungrouped so they arrive alone and get read
properly. This library's own config additionally ignores majors of the `actions/*` toolkit, because
those change action inputs.

**Dependabot pull requests and `secrets: inherit`.** Pull requests opened by Dependabot run with a
read-only token and *no* access to repository secrets by default. A pipeline that pushes to a
registry will fail on them. Either grant Dependabot access to the secrets it needs, or skip the
publishing jobs:

```yaml
jobs:
  image:
    if: github.actor != 'dependabot[bot]'
    uses: <org>/ci-library/.github/workflows/docker.yml@2.0.0
```

**Keep the library pin a tag, not a branch.** `@2.0.0` is what lets Dependabot see a newer version
and open the pull request. `@main` silently changes under you and Dependabot has nothing to bump.
