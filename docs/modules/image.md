# image

Container image building and registry management, supporting both Docker/BuildKit and
Buildah.

```mermaid
flowchart LR
    IB["docker.yml · build<br/>buildx build --push"]
    IB --> IT["docker.yml · test<br/>smoke test in the image"]
    IB --> IS["scan.yml<br/>scan-type: image"]
    IP["docker.yml · promote<br/>crane mutate --tag"]
    BB["buildah.yml · build<br/>buildah commit + push"]
    BB --> BT["buildah.yml · test<br/>smoke test in the image"]
    BB --> IS
    BP["buildah.yml · promote<br/>crane mutate --tag"]
```

| Workflow · Job | Description |
| --- | --- |
| `docker.yml` · `build` | Buildx build and push to the primary registry, with every organisation base image injected as a build argument and registry layer cache. Outputs `image-ref-digest`. |
| `docker.yml` · `copy` | Only with several destinations in `IMAGE_REPOSITORY`: copies the candidate by digest to the other registries. See [Registries](../configuration.md#registries). |
| `docker.yml` · `test` | Optional smoke test executed **inside** the built image. Off by default. |
| `docker.yml` · `promote` | Release-mode only. Refuses unless the caller passes a successful `scan-result`. Resolves the candidate and copies it by digest with `crane mutate --tag`, then tags `latest`, `MAJOR`, `MINOR`, and copies the release to the other registries. |
| `buildah.yml` · `build` | Dockerfile-free minimal image assembly from a base image: `microdnf install`, package-manager purge, documentation/systemd/PAM strip, `USER 10001`. |
| `buildah.yml` · `test` | Same optional smoke test as `docker.yml` · `test`, run against the Buildah image's `image-ref-digest`. Off by default. |
| `buildah.yml` · `promote` | Same digest-preserving promotion as `docker.yml`. Buildah publishes to one registry, `IMAGE_REGISTRY`. |

> [!IMPORTANT]
> `docker.yml` · `build` and the `test` job of `docker.yml` and `buildah.yml` are the
> **only** jobs in the library that do not run inside an organisation build container.
> Building an image needs the daemon and BuildKit on the runner itself, and the smoke test
> runs the image with the runner's `docker run`. Every other job, both `promote` jobs and
> `buildah.yml` · `build` included, is containerised.

## Image smoke test — off unless asked for

`docker.yml` and `buildah.yml` (from `1.6.0`) can run a script **inside the built image**,
pulled by its digest-pinned `image-ref-digest`, alongside the image scan. It is `test: false` by default, so a pipeline that never sets it builds
an artifact nobody executed.

| Input | Default | Meaning |
| --- | --- | --- |
| `test` | `false` | Run the smoke test at all. |
| `test-script` | `ci_image_test.sh` | Script executed inside the image, relative to `test-path`. |
| `test-path` | the project path | Directory mounted into the image at `/tmp`. |
| `test-shell` | `bash` | Interpreter the image runs it with. |

A Buildah image is minimal and usually ships no `bash`: set `test-shell` to an interpreter
the image contains (e.g. `sh`), or the test fails before the script starts.

```yaml
  image:
    needs: [init, build]
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/docker.yml@1.0.0
    secrets: inherit
    with:
      test: true
      image-tag: ${{ needs.init.outputs.image-push-tag }}
      image-repository: ${{ needs.init.outputs.image-push-repository }}
```

The `buildah.yml` caller takes the same inputs:

```yaml
  image:
    needs: init
    permissions:
      contents: read
      packages: write
    uses: grootan-devops/github-ci-library/.github/workflows/buildah.yml@1.6.0
    secrets: inherit
    with:
      test: true
      test-shell: sh
      image-tag: ${{ needs.init.outputs.image-push-tag }}
      image-repository: ${{ needs.init.outputs.image-push-repository }}
```

Assert the contract the image publishes, not the base image's contents: the entrypoint is
on `PATH` and reports the expected version, the port named in `EXPOSE` is listening, the
process is running as `10001`. A test that greps the package manifest passes on any image
and tells you nothing. GitLab's equivalent is `.Image:Test`, on the same script name.

[Dockerfile standards and examples](../docker.md) · [Documentation index](../../README.md)
