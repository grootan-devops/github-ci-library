# golang

```mermaid
flowchart LR
    D["dependency<br/>go mod download"] --> B["build"]
    D --> T["test"]
    L["golang-lint.yml<br/>fmt ∥ vet ∥ golangci-lint ∥ gosec"]
```

| Workflow · Job | Description |
| --- | --- |
| `golang-build.yml` · `dependency` | `go mod download`. Caches `.go-cache` keyed by `go.sum`. |
| `golang-build.yml` · `build` | `go build -trimpath -o bin/ ./...`. Uploads `go-binaries`. |
| `golang-build.yml` · `test` | `go test` piped through `go-junit-report`. |
| `golang-lint.yml` · `fmt` | `go fmt ./...`, then fails on a dirty tree. |
| `golang-lint.yml` · `vet` | `go vet`, honouring a `// govet:ignore` pragma on the preceding line. |
| `golang-lint.yml` · `golangci-lint` | Full linter aggregate. |
| `golang-lint.yml` · `gosec` | Security static analysis, excluding generated code. |

## Project rules

- Unit tests run with `-race`; it catches what local runs do not.
- The Go module cache is warmed and restored under one project cache identity.

[Documentation index](../../README.md)
