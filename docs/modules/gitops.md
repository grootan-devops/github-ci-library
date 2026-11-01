# deploy/gitops

```mermaid
flowchart LR
    V["validate"] --> G["gitops-commit"] --> S["sync"]
```

## Komodo (`deploy-komodo-gitops.yml`)

Docker Compose stacks. Verifies the image exists in the deployed registry, patches the compose file in the GitOps
repository, and triggers a Komodo stack redeploy.

| Input | Required | Description |
| --- | :--: | --- |
| `environment` | ✅ | Target environment |
| `komodo-stack-name` | ✅ | Komodo stack to redeploy |
| `gitops-repo` | ✅ | GitOps repository holding the compose file |
| `gitops-branch` | ✅ | Branch in that repository to commit to |
| `gitops-service-image-yq-path` | ✅ | `yq` path to the service's image field in the compose file |
| `image-repository`, `image-tag` | ✅ | Image to deploy; `vars.IMAGE_REPOSITORY` wins when set |
| `gitops-compose-file` | | Compose file path (default `docker-compose.yml`) |
| `komodo-server` | ✅ | Komodo API endpoint |
| `deploy-image-repository` | | Destination to deploy from, as a full ref (default `vars.DEPLOY_IMAGE_REPOSITORY`, else the primary). See [Registries](../configuration.md#which-registry-is-read) |
| `dev-repository-suffix` | | Overrides the candidate suffix (default: the one configured for that registry; normalised to `-dev` on Docker Hub) |
| `build-env` | | Extra `KEY=VALUE` lines exported before the deploy |

## ArgoCD (`deploy-argocd-gitops.yml`)

Kubernetes. Supports both **Helm mode** (patch `targetRevision` / values) and **manifest
mode** (patch an image reference), then syncs and waits for `Healthy`.

| Input | Required | Description |
| --- | :--: | --- |
| `environment` | ✅ | Target environment |
| `gitops-repo` | ✅ | GitOps repository |
| `gitops-branch` | ✅ | Branch in that repository to commit to |
| `argocd-app-name` | ✅ | ArgoCD application to sync |
| `chart-name` / `chart-version` / `chart-repository` | | Helm mode |
| `chart-values-file` / `chart-app-yq-path` | | Helm mode: which file, and the `yq` path within it |
| `manifest-file` / `new-image` | | Manifest mode |
| `image-values-file` / `image-repo-yq-path` / `image-tag-yq-path` | | Image-values mode |
| `image-repository` | | Image to deploy, when `new-image` is not given |
| `argocd-server` | ✅ | ArgoCD API endpoint |
| `argocd-version` | | ArgoCD CLI to download (default `v3.2.6`) |
| `deploy-image-repository` / `deploy-chart-repository` | | Destinations to deploy from, as full refs (default `vars.DEPLOY_*_REPOSITORY`, else the primary). See [Registries](../configuration.md#which-registry-is-read) |
| `dev-repository-suffix` | | Overrides the candidate suffix (default: the one configured for each registry); Docker Hub uses one chart namespace-root repository and ignores it for Helm charts |
| `github-environment-name` / `github-environment-url` | | Deployment environment to record against |

[Documentation index](../../README.md)
