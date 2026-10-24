# terraform

```mermaid
flowchart LR
    I["terraform-lint.yml · init"] --> V["validate + fmt -check"]
    I --> TL["tflint"]
    I --> DO["terraform-docs drift"]
    T["terraform-test.yml · test"] -->|on failure| DE["destroy"]
```

| Workflow · Job | Description |
| --- | --- |
| `terraform-lint.yml` · `init` | `terraform init` with the backend workspace key prefix. Caches `.terraform/providers` by `.terraform.lock.hcl`, saved from the default branch only. |
| `terraform-lint.yml` · `validate` | `terraform init -backend=false`, then `terraform validate` and `terraform fmt -recursive -check`. |
| `terraform-lint.yml` · `tflint` | `terraform init -backend=false`, then recursive `tflint` across all module call types. |
| `terraform-lint.yml` · `docs` | `terraform-docs` drift check for the root and every `modules/*`. |
| `terraform-test.yml` · `test` | `go test` module suite with a configurable timeout. |
| `terraform-test.yml` · `destroy` | Runs **only on test failure**, so a crashed test cannot strand real infrastructure. |
| `scan.yml` (`scan-type: config`, `config-type: terraform`) | Trivy IaC misconfiguration scan. |

Calling the workflow opts the repository in: no job checks for a `main.tf`, so `project-path`
points at the Terraform root.

## Consuming a module — no packaging step

Modules are consumed directly from git. There is no package, no registry upload and no
publish job to maintain: the git ref *is* the version.

```hcl
module "vpc" {
  source = "git::git@github.com:grootan-devops/terraform-modules.git//modules/vpc?ref=1.0.0"
}

module "eks" {
  # git::<repo_url>//<sub_folder>?ref=<tag | branch | commit>
  source = "git::git@github.com:grootan-devops/terraform-modules.git//modules/eks?ref=b4f8d29"
}
```

> [!IMPORTANT]
> Always pin `?ref=` to a tag or commit SHA. A branch ref (`?ref=main`) re-resolves on every
> `terraform init`, so a plan can change without the consuming repository changing.

[Documentation index](../../README.md)
