# Publishing to several registries

A service publishes its image and chart to GitHub Container Registry, which is the primary, and
copies both to Quay and Docker Hub. The customer environment deploys from Docker Hub.

```yaml
# Repository variables
IMAGE_REPOSITORY: "ghcr.io/company/payment-service quay.io/company/payment-service docker.io/company/payment-service"
CHART_REPOSITORY: "ghcr.io/company/payment-service/helm docker.io/company"
```

```yaml
# REGISTRY_CONFIG: organisation secret
quay.io:   { username: "company+ci", password: "..." }
docker.io: { username: "company-ci", password: "...", dev: "-dev" }
```

| Artifact | Destination | Release | Candidate |
| --- | --- | --- | --- |
| Image | GHCR (primary) | `ghcr.io/company/payment-service` | `ghcr.io/company/payment-service/dev` |
| Image | Quay | `quay.io/company/payment-service` | `quay.io/company/payment-service/dev` |
| Image | Docker Hub | `docker.io/company/payment-service` | `docker.io/company/payment-service-dev` |
| Chart | GHCR (primary) | `oci://ghcr.io/company/payment-service/helm` | `oci://ghcr.io/company/payment-service/helm/dev` |
| Chart | Docker Hub | `oci://docker.io/company` | the same repository |

The workflows are the usual ones (see [full-stack](full-stack.md)), with `secrets: inherit`.
The deploy call for the customer environment picks Docker Hub:

```yaml
  deploy-customer:
    needs: [init, docker, chart]
    uses: grootan-devops/github-ci-library/.github/workflows/deploy-argocd-gitops.yml@1.10.0
    with:
      environment: customer
      chart-name: ${{ needs.init.outputs.chart-name }}
      chart-version: ${{ needs.init.outputs.chart-push-version }}
      deploy-image-repository: docker.io/company/payment-service
      deploy-chart-repository: docker.io/company
      gitops-repo: company/payment-service-gitops
      gitops-branch: customer
      chart-values-file: values.yaml
      chart-app-yq-path: .apps.payment
      argocd-server: argocd.example.com
      argocd-app-name: payment-service
    secrets: inherit
```

See [Registries](../configuration.md#registries) for the rules.

[Documentation index](../../README.md)
