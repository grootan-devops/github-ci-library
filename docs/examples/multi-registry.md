# 9. Publishing to Several Registries

One image published to the organisation's Harbor, to Quay and to Docker Hub, and one chart
published to Harbor and Docker Hub. Nothing in the workflows changes: any shape above publishes
to several registries once the repository names a credential group. The credentials of every
registry live once, in the `REGISTRY_CONFIG` organisation secret, one group per client or
organisation, every value quoted:

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

The repository names its group and lists the full repositories it publishes to, the first being
the primary. `vars.IMAGE_REGISTRY` and `vars.CHART_REGISTRY` must not reach it: limit those
organisation variables to the repositories that still publish to a single registry.

```yaml
# Repository variables
PROJECT_REGISTRY_NAME: oneuptime/prod
IMAGE_REPOSITORY: "registry.example.com/core/api quay.io/oneuptime/api docker.io/oneuptime/api"
CHART_REPOSITORY: "registry.example.com/helm registry-1.docker.io/oneuptime"
```

Callers that use `secrets: inherit`, as every example above does, pass `REGISTRY_CONFIG` on
their own. A deploy caller that lists its secrets adds it:

```yaml
  deploy:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/deploy-argocd-gitops.yml@1.0.0
    secrets:
      REGISTRY_CONFIG: ${{ secrets.REGISTRY_CONFIG }}
      ARGOCD_AUTH_TOKEN: ${{ secrets.ARGOCD_AUTH_TOKEN }}
      GITOPS_TOKEN: ${{ secrets.GITOPS_TOKEN }}
```

> **What a pull request run publishes** for version `1.4.0`:
>
> - `docker.yml` · `build` pushes `registry.example.com/core/api/dev:1.4.0-<run>.<pr>`, and
>   `copy` copies it by digest to `quay.io/oneuptime/api/dev` and
>   `docker.io/oneuptime/api-dev`. Each registry is logged in to once, with its credentials in
>   `oneuptime/prod`.
> - `chart.yml` · `push` publishes to `oci://registry.example.com/helm/dev` and
>   `oci://registry-1.docker.io/oneuptime`, the namespace root Docker Hub keeps candidates and
>   releases in.
>
> **On release**, `docker.yml` · `promote` and `chart.yml` · `promote` release `1.4.0` in
> `registry.example.com`, then copy the image by digest, with `latest`, `1` and `1.4`, to Quay
> and Docker Hub, and publish the same chart package to Docker Hub.
>
> `init.yml` stops in its first step when `PROJECT_REGISTRY_NAME` is set together with
> `IMAGE_REGISTRY` or `CHART_REGISTRY`, and before any build when a repository's registry is not
> in the group or has no username and password there. `buildah.yml` keeps publishing to a single
> `IMAGE_REGISTRY`.

[Documentation index](../../README.md)
