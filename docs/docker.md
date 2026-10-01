# Dockerfile standards

## Dockerfile Standards & Multi-Stack Reference (Packaging-Only & Non-Root 10001:10001)

Every image built by this platform adheres strictly to the **Packaging-Only Standard** and
**Non-Root Runtime Enforcement**:

1. **Packaging-Only Standard (zero compilation in the Dockerfile).**
   All compiling, bundling and transpiling (`npm run build`, `mvn package`, `go build`,
   `uv build`), linting and tests **MUST** execute in the `*-build.yml` workflows. The
   `Dockerfile` is purely an artifact packaging manifest; it copies pre-built output.
   Where an interpreted stack must install dependencies, it installs **offline** from a
   dependency cache explicitly made available inside the Docker build context, bind-mounted
   by BuildKit — never resolving over the network, which would re-resolve what the pipeline
   already pinned and scanned. The `--mount` source must name that provided directory
   (`.uv-cache` for Python or `.npm` for Node), and `.dockerignore` must admit it.
   `node_modules/`, `.venv/` and `vendor/` are never uploaded as artifacts — only real build
   output (`dist/`, a jar, a binary) is.

   **Never `ARG` a secret.** Build arguments persist in the image history even when a later
   layer deletes the file (`ARG NPM_TOKEN`, a `PIP_INDEX_URL` with credentials). Use a
   BuildKit secret mount (`--mount=type=secret`) when a build genuinely needs one.

   > [!IMPORTANT]
   > The GitHub `python-build.yml` and `node-build.yml` workflows cache `.uv-cache` and `.npm`
   > with `actions/cache`, but `docker.yml` builds in a separate job and does not restore or
   > receive those directories. Its registry-backed BuildKit cache stores image layers; it is
   > not a handoff for the host-side dependency directories. A consumer using the offline
   > examples below must arrange an explicit cache handoff into the image job's build context.
   > Do not assume that a successful language build makes the cache available to `docker.yml`.
2. **Non-root user and group (10001:10001).**
   - Containers must never run as `root` (UID `0`). Every Dockerfile declares `USER 10001:10001`.
   - All copied files must be owned by the non-root user: `COPY --chown=10001:10001 ...`.
   - Paths the application writes at runtime — a cache, a lock or a PID file — are chart
     mounts, not directories chowned in the image: an `emptyDir` for scratch data,
     `persistence` for data that must survive a restart (see the helm-tpl-library
     configuration guide). The image owns only what it ships.
   - Standard non-privileged listening port: `EXPOSE 8080`.
3. **Automatic build-arg base images.**
   `docker.yml` resolves and injects the following build arguments automatically, so a
   Dockerfile pins nothing itself.

   | Tech stack | Injected build arg | Description |
   | --- | --- | --- |
   | **Java** | `JAVA_25_MICRO_BASE_IMAGE` | Minimal hardened Java 25 JRE runtime |
   | **Golang** | `MICRO_ROOT_BASE_IMAGE` | Distroless minimal root container for static binaries |
   | **Python** | `PYTHON_312_MICRO_BASE_IMAGE` | Minimal Python 3.12 micro runtime |
   | **Node.js backend** | `NODE_JS_24_MICRO_BASE_IMAGE` | Minimal Node.js 24 micro runtime |
   | **Node.js frontend** | `NGINX_MICRO_BASE_IMAGE` | Non-root Nginx static SPA server |
   | **Multi-stage builder** | `TOOLKIT_BUILD_IMAGE` | The one build container, for a builder stage only. Every toolchain is baked into it. |
   | **All** | `VERSION` | `init.yml`'s `image-push-tag` |

   Each is passed as `${{ vars.IMAGE_REGISTRY }}/<value>`, where `<value>` is **pinned in
   `docker.yml`**, not read from an organisation variable. Bumping a base image is a change
   to the library and a new release — which is what lets a pipeline be reproduced from its
   tag alone.

   > [!NOTE]
   > GitLab additionally injects `CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX`. GitHub has no
   > Dependency Proxy and injects no equivalent, so a Dockerfile ported from GitLab must give
   > that ARG a default (`ARG CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX=`) or drop it.

4. **Base image selection.**
   Use the runtime image matching the project language; fall back to `MICRO_ROOT_BASE_IMAGE`
   when no language image fits. **A runtime stage is never built `FROM` a build image.** A
   `*_BUILD_IMAGE` carries compilers, package managers and credential helpers, all of which
   would ship to production — it belongs in a builder stage only.

   The micro images are deliberately minimal: no package manager and no `ps`, `awk`, `tar`
   or `which`; `linux/amd64` only; UID `10001` has no passwd entry and `HOME=/`. Anything
   the application or its scripts call must already be in the image — check a native
   dependency inside the built image (`ldd` on the shared object) before shipping. When a
   micro image lacks a small, general library, fix that base image and bump its pin in this
   library instead of working around it in each consumer; never graft packages into a micro
   image from a builder stage.

5. **Tags are pinned, never floating.**
   No `:latest`, and no untagged reference, on a literal `FROM`. A `FROM ${VAR}` reference
   takes its tag from CI; give its `ARG` the approved image at `:latest` as the default, so a
   plain local `docker build` works and nobody reaches for an unapproved public image, while
   CI overrides it with the exact pinned tag. Renovate bumps a literal `FROM` tag by itself; an image version held
   in an `ARG` needs a `# renovate:` annotation on the line above — for images from a
   **public** registry (Docker Hub, GCR, Amazon ECR Public, Quay) only. Images in a private
   registry need none.

6. **Runtime instructions.**
   - `EXPOSE` is required on a service image. It is the image's only self-describing
     contract, and the chart's `containerPort` is unverifiable without it.
   - **Prefer `CMD`.** It states the default command while leaving an operator free to
     override it with `docker run <image> <cmd>`.
   - **PID 1 is always an init.** The runtime stage declares
     `ENTRYPOINT ["/usr/bin/dumb-init", "--"]` and names the process in `CMD`, even when the
     base image already sets an ENTRYPOINT: a base's ENTRYPOINT is invisible in review, and a
     shell-form one silently drops `CMD`. A bare runtime as PID 1 installs no SIGTERM
     handler, so the pod is killed only when its grace period runs out, and it never reaps
     orphaned children; dumb-init forwards signals to the process group and reaps zombies.
   - **A start script is the `CMD`, never the ENTRYPOINT**, so `docker run <image> sh` still
     runs under dumb-init. Every branch ends with `exec`, so no shell stays between dumb-init
     and the service and the service's exit code is the container's, and an unknown mode
     exits non-zero. A multi-mode image picks its process from a `MODE` variable the chart
     sets. Where the process needs shell expansion,
     `CMD ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]` keeps the JVM a direct
     child of dumb-init. The chart leaves `command` and `args` empty (see the
     helm-tpl-library chart standards).

     ```sh
     #!/bin/sh
     set -e

     case "${MODE:-api}" in
       api) exec node dist/main.js ;;
       worker) exec node dist/worker.js ;;
       *) echo "invalid MODE: ${MODE}" >&2; exit 1 ;;
     esac
     ```

7. **Layout: the `USER` bracket, grouping and layers.**
   - `USER 0` immediately after the runtime stage's `FROM`, opening the root setup phase.
     `USER 10001:10001` closes it, before the runtime instructions. A builder stage is
     discarded and needs no `USER 0` — declaring one there trips hadolint `DL3002`
     ("last USER should not be root"), which is evaluated per stage and gates `lint.yml`.
   - Group by instruction kind and separate groups with one blank line. Instructions that
     form a single unit — a run of `COPY`s, one install-and-chown `RUN` — stay together with
     no blank line between them.
   - **Comments are one line saying why**, only where something differs from the default.
     No banners, and no comment restating the next instruction: keep
     `# local builds only; CI passes the pinned tag` above an `ARG` default, drop
     `# Copy application source code` above a `COPY`.
   - **Merge consecutive `RUN`s.** Each one is a layer, and a layer keeps whatever the
     previous one left behind. Chain with `&& \` instead.
   - **Clean in the layer that created the files**: a later `RUN rm` cannot shrink an earlier
     layer. In the `RUN` that installs, remove build-only tools, package lists and caches,
     `/var/log`, `/root/.cache`, `/var/tmp` and `/tmp`. Leave any path that `RUN`
     bind-mounts; deleting a mount source fails the build.
   - Group related `ARG`s into one continued statement. The exception is a version pin: an
     `ARG` carrying a `# renovate:` annotation stays on its own line, because the annotation
     binds to the line below it.
   - Copy source **after** the dependency install, never before, or every source edit
     invalidates the dependency layer.

### 1. Java / Spring Boot Microservice

```dockerfile
ARG JAVA_25_MICRO_BASE_IMAGE=grootantech/micro-java-25:latest
FROM ${JAVA_25_MICRO_BASE_IMAGE}

USER 0

WORKDIR /app

COPY --chown=10001:10001 target/*.jar /app/app.jar

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["java", "-XX:+UseContainerSupport", "-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]
```

```dockerignore
**
*
!target/*.jar
!build/libs/*.jar
```

### 2. Golang Static Binary

```dockerfile
ARG MICRO_ROOT_BASE_IMAGE=grootantech/micro-root:latest
FROM ${MICRO_ROOT_BASE_IMAGE}

USER 0

WORKDIR /app

COPY --chown=10001:10001 bin/app /app/app

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/app/app"]
```

```dockerignore
**
*
!bin/
!bin/*
```

### 3. Python (uv + `src/` layout)

```dockerfile
ARG PYTHON_312_MICRO_BASE_IMAGE=grootantech/micro-python-3-12:latest
FROM ${PYTHON_312_MICRO_BASE_IMAGE}

USER 0

WORKDIR /app

ENV PATH="/app/.venv/bin:$PATH"

COPY --chown=10001:10001 pyproject.toml uv.lock ./

# .uv-cache must be supplied in the build context; see the cache handoff note above
RUN --mount=type=bind,source=.uv-cache,target=/tmp/.uv-cache,rw \
    uv sync --frozen --no-dev --no-install-project --no-install-workspace --offline --cache-dir /tmp/.uv-cache && \
    chown -R 10001:10001 /app

COPY --chown=10001:10001 src/ /app/src/

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

```dockerignore
**
*
!pyproject.toml
!uv.lock
!.uv-cache
!.uv-cache/**
!src
!src/**
```

### 4. Node.js Backend (Express / NestJS)

```dockerfile
ARG NODE_JS_24_MICRO_BASE_IMAGE=grootantech/micro-node-24:latest
FROM ${NODE_JS_24_MICRO_BASE_IMAGE}

USER 0

WORKDIR /app

ENV NODE_ENV=production \
    PORT=8080

COPY --chown=10001:10001 package*.json /app/

# .npm must be supplied in the build context; see the cache handoff note above
RUN --mount=type=bind,source=.npm,target=/tmp/.npm,rw \
    npm ci --omit=dev --offline --no-audit --no-fund --cache /tmp/.npm && \
    chown -R 10001:10001 /app

COPY --chown=10001:10001 dist/ /app/dist/

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "/app/dist/main.js"]
```

```dockerignore
**
*
!package*.json
!.npm
!.npm/**
!dist/
!dist/**
```

### 5. Node.js Frontend (Nginx SPA)

```dockerfile
ARG NGINX_MICRO_BASE_IMAGE=grootantech/micro-nginx:latest
FROM ${NGINX_MICRO_BASE_IMAGE}

USER 0

COPY --chown=10001:10001 dist/ /usr/share/nginx/html/

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["nginx", "-g", "daemon off;"]
```

```dockerignore
**
*
!dist/
!dist/**
```

The micro-nginx default serves the SPA. A per-environment `default.conf` is a chart file
mount, not a file copied into the image (see the helm-tpl-library configuration guide,
*File mounts*).

### 6. Multi-stage (only when the pipeline cannot produce the artifact)

Most images need no builder stage: `*-build.yml` produces the artifact and the Dockerfile
copies it. Where a builder stage is genuinely needed, it uses a `*_BUILD_IMAGE` and the
runtime stage copies out of it — the runtime stage itself is always a micro base image.

```dockerfile
ARG TOOLKIT_BUILD_IMAGE \
    MICRO_ROOT_BASE_IMAGE=grootantech/micro-root:latest

FROM ${TOOLKIT_BUILD_IMAGE} AS builder

WORKDIR /src

COPY . .

RUN make build

FROM ${MICRO_ROOT_BASE_IMAGE}

USER 0

WORKDIR /app

COPY --from=builder --chown=10001:10001 /src/bin/app /app/app

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/app/app"]
```

## The Inverted `.dockerignore` Allowlist Standard (Default Deny)

To enforce packaging hygiene, keep the build context under ~100 KB, and guarantee that no
sensitive local file (`.git/`, `.env`, secrets, test caches, local virtualenvs) leaks into
an image, every project uses an **inverted allowlist**:

1. **Default deny.** Block everything recursively with `**` and `*` at the top of the file,
   in that order, as the first two lines.
2. **Explicit allowlist (`!`).** Unignore only the exact files the Dockerfile copies.
3. **Anchor root-only patterns without a leading slash.** `!*.js` admits root modules and does
   not cross `/`; a leading `/` is `.gitignore` and `.helmignore` syntax, not a reliable anchor
   here.
4. **No re-deny section.** `**` already denied everything, so a trailing block of `test/` or
   `**/*.md` re-denies what was never admitted. If something unwanted reaches the image, narrow
   the `!` line that admits it.
5. **Admit the package-manager cache (`.npm`, `.uv-cache`), never the installed tree**
   (`node_modules/`, `.venv/`): the image installs offline from the cache.

`COPY . .` is only as safe as the allowlist in front of it — review what the `!` lines admit,
not that the file exists.

| Tech stack | Allowlisted packaging targets |
| --- | --- |
| **Python** (`uv` + `src/`) | `pyproject.toml`, `uv.lock`, `.uv-cache/`, `src/` |
| **Java** (Spring Boot fat JAR) | `target/*.jar` or `build/libs/*.jar` |
| **Golang** (static binary) | `bin/` |
| **Node.js frontend** (Nginx SPA) | `dist/` |
| **Node.js backend** | `dist/`, `.npm` cache, `package*.json` |

[Documentation index](../README.md)
