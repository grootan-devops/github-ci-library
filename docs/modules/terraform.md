# terraform

```mermaid
flowchart LR
    I["terraform.yml · init"] --> V["validate + fmt -check"]
    I --> TL["tflint"]
    I --> DO["terraform-docs drift"]
    T["terraform.yml · test"] -->|on failure| DE["destroy"]
```

| Workflow · Job | Description |
| --- | --- |
| `terraform.yml` · `init` | `terraform init` with the backend workspace key prefix. Caches `.terraform/providers` by `.terraform.lock.hcl`, saved from the default branch only. |
| `terraform.yml` · `validate` | `terraform init -backend=false`, then `terraform validate` and `terraform fmt -recursive -check`. |
| `terraform.yml` · `tflint` | `terraform init -backend=false`, then recursive `tflint` across all module call types. |
| `terraform.yml` · `docs` | `terraform-docs` drift check for the root and every `modules/*`. |
| `terraform.yml` · `test` | `go test` module suite with a configurable timeout. |
| `terraform.yml` · `destroy` | Runs **only on test failure**, so a crashed test cannot strand real infrastructure. |
| `scan.yml` (`scan-type: config`, `config-type: terraform`) | Trivy IaC misconfiguration scan. |

`terraform.yml` runs the checks (`init`, `validate`, `tflint`, `docs`) by default, with
`lint: true` and the required `state-name`. `test: true` runs the module test and its
teardown; it provisions real infrastructure, so call it from its own workflow with
`cancel-in-progress: false` and `lint: false`, as the
[Terraform example](../examples/terraform.md) does.

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
