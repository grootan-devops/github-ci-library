# 8. GitOps Deploy Entry Point

Deployment is deliberately outside every shape above: `pr.yml` and `release.yml` verify and
publish, and a *separate* dispatchable workflow moves a published version into an
environment. Add this alongside Section 1, 3, 4 or 5 when the repository deploys through
GitOps.

```yaml
# .github/workflows/deploy.yml
name: CD · GitOps Deploy
run-name: "CD · ${{ github.event_name }} · ${{ github.sha }}"

on:
  workflow_dispatch:
    inputs:
      environment:
        description: Target environment
        required: true
        type: choice
        options: [dev, staging, production]
      target-version:
        description: Version to deploy (defaults to the current chart version)
        required: false
        type: string

concurrency:
  group: "deploy-${{ inputs.environment }}"
  cancel-in-progress: false

permissions: { contents: read }

jobs:
  init:
    permissions:
      contents: read
      actions: read
      pull-requests: read
    uses: grootan-devops/github-ci-library/.github/workflows/init.yml@1.0.0
    secrets: inherit

  deploy:
    needs: init
    uses: grootan-devops/github-ci-library/.github/workflows/deploy-argocd-gitops.yml@1.0.0
    secrets: inherit
    with:
      environment: ${{ inputs.environment }}
      gitops-repo: contoso/app-gitops
      gitops-branch: main
      chart-values-file: apps/${{ inputs.environment }}/values.yaml
      chart-app-yq-path: .apps.order-backend
      chart-name: ${{ needs.init.outputs.chart-name }}
      chart-version: ${{ inputs.target-version || needs.init.outputs.chart-version }}
      chart-repository: ${{ needs.init.outputs.chart-repository }}
      image-repository: ${{ needs.init.outputs.image-repository }}
      argocd-app-name: order-backend-${{ inputs.environment }}
      github-environment-name: ${{ inputs.environment }}
```

`gitops-branch` and `argocd-app-name` are required inputs; the deploy refuses at
`validate` without them, and equally without either `chart-values-file` (Helm mode) or
`manifest-file` plus `new-image` (manifest mode). Swap
`deploy-argocd-gitops.yml` for `deploy-komodo-gitops.yml` to patch a Docker Compose stack
instead; its inputs are in the [deploy/gitops](../modules/gitops.md#deploygitops) module catalog.

[Documentation index](../../README.md)
