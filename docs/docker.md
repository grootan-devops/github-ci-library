# Dockerfile standards

## Dockerfile Standards & Multi-Stack Reference (Packaging-Only & Non-Root 10001:10001)

Every image built by this platform adheres strictly to the **Packaging-Only Standard** and
**Non-Root Runtime Enforcement**:

1. **Packaging-Only Standard (zero compilation in the Dockerfile).**
   All compiling, bundling and transpiling (`npm run build`, `mvn package`, `go build`,
   `uv build`), linting and tests **MUST** execute in the `*-build.yml` workflows. The
   `Dockerfile` is purely an artifact packaging manifest; it copies pre-built output.
   Where an interpreted stack must install dependencies, it installs **offline** from the
   CI package cache, bind-mounted by BuildKit — never resolving over the network, which
   would re-resolve what the pipeline already pinned and scanned. The `--mount` source must
   name the directory the pipeline actually cached (`.uv-cache` for `python-build.yml`,
   `.npm` for `node-build.yml`), and `.dockerignore` must admit it.
2. **Non-root user and group (10001:10001).**
   - Containers must never run as `root` (UID `0`). Every Dockerfile declares `USER 10001:10001`.
   - All copied files must be owned by the non-root user: `COPY --chown=10001:10001 ...`.
   - If the application writes logs, cache or PID files at runtime, create and chown those
     directories **before** the `USER` directive.
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

5. **Tags are pinned, never floating.**
   No `:latest`, and no untagged reference. A literal image carries an explicit tag with a
   `# renovate:` annotation on the line above so the bot can bump it. A `FROM ${VAR}`
   reference needs no tag: CI resolves it from the organisation variable.

6. **Runtime instructions.**
   - `EXPOSE` is required on a service image. It is the image's only self-describing
     contract, and the chart's `containerPort` is unverifiable without it.
   - **Prefer `CMD`.** It states the default command while leaving an operator free to
     override it with `docker run <image> <cmd>`.
   - Use `ENTRYPOINT` only to invoke a pre-start shim — a script that must substitute
     configuration before the service starts. If that shim `exec`s the service as its last
     action it becomes PID 1 and needs nothing further. If it forks, or leaves children
     running, `exec` through `dumb-init` so signals and zombie reaping work:
     `exec /usr/bin/dumb-init -- nginx -g "daemon off;"`.

7. **Layout: the `USER` bracket, grouping and layers.**
   - `USER 0` immediately after the runtime stage's `FROM`, opening the root setup phase.
     `USER 10001:10001` closes it, before the runtime instructions. A builder stage is
     discarded and needs no `USER 0` — declaring one there trips hadolint `DL3002`
     ("last USER should not be root"), which is evaluated per stage and gates `lint.yml`.
   - Group by instruction kind and separate groups with one blank line. Instructions that
     form a single unit — a run of `COPY`s, one install-and-chown `RUN` — stay together with
     no blank line between them, under one comment saying what the group is for.
   - **Merge consecutive `RUN`s.** Each one is a layer, and a layer keeps whatever the
     previous one left behind. Chain with `&& \` instead.
   - Group related `ARG`s into one continued statement. The exception is a version pin: an
     `ARG` carrying a `# renovate:` annotation stays on its own line, because the annotation
     binds to the line below it.
   - Copy source **after** the dependency install, never before, or every source edit
     invalidates the dependency layer.

### 1. Java / Spring Boot Microservice

```dockerfile
ARG JAVA_25_MICRO_BASE_IMAGE
FROM ${JAVA_25_MICRO_BASE_IMAGE}

USER 0

WORKDIR /app

# Copy the fat JAR produced by java-build.yml
COPY --chown=10001:10001 target/*.jar /app/app.jar

USER 10001:10001

EXPOSE 8080

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
ARG MICRO_ROOT_BASE_IMAGE
FROM ${MICRO_ROOT_BASE_IMAGE}

USER 0

WORKDIR /app

# Copy the static binary produced by golang-build.yml
COPY --chown=10001:10001 bin/app /app/app

USER 10001:10001

EXPOSE 8080

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
ARG PYTHON_312_MICRO_BASE_IMAGE
FROM ${PYTHON_312_MICRO_BASE_IMAGE}

USER 0

WORKDIR /app

ENV PATH="/app/.venv/bin:$PATH"

# Copy locked dependency manifests
COPY --chown=10001:10001 pyproject.toml uv.lock ./

# Mount the pre-warmed CI cache via Buildx, install production dependencies offline,
# and set ownership. The mount source is the directory python-build.yml cached.
RUN --mount=type=bind,source=.uv-cache,target=/tmp/.uv-cache \
    uv sync --frozen --no-dev --no-install-project --no-install-workspace --offline --cache-dir /tmp/.uv-cache && \
    chown -R 10001:10001 /app

# Copy application source code with non-root ownership
COPY --chown=10001:10001 src/ /app/src/

USER 10001:10001

EXPOSE 8080

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
ARG NODE_JS_24_MICRO_BASE_IMAGE
FROM ${NODE_JS_24_MICRO_BASE_IMAGE}

USER 0

WORKDIR /app

ENV NODE_ENV=production \
    PORT=8080

# Copy locked dependency manifests
COPY --chown=10001:10001 package*.json /app/

# Mount the cache node-build.yml warmed, install production dependencies offline,
# and set ownership
RUN --mount=type=bind,source=.npm,target=/tmp/.npm,rw \
    npm ci --omit=dev --offline --no-audit --no-fund --cache /tmp/.npm && \
    chown -R 10001:10001 /app

# Copy pre-compiled dist/ with non-root ownership
COPY --chown=10001:10001 dist/ /app/dist/

USER 10001:10001

EXPOSE 8080

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
ARG NGINX_MICRO_BASE_IMAGE
FROM ${NGINX_MICRO_BASE_IMAGE}

USER 0

# Copy the static bundle and SPA nginx configuration with non-root ownership
COPY --chown=10001:10001 dist/ /usr/share/nginx/html/
COPY --chown=10001:10001 nginx.conf /etc/nginx/conf.d/default.conf

USER 10001:10001

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
```

```dockerignore
**
*
!dist/
!dist/**
!nginx.conf
```

### 6. Multi-stage (only when the pipeline cannot produce the artifact)

Most images need no builder stage: `*-build.yml` produces the artifact and the Dockerfile
copies it. Where a builder stage is genuinely needed, it uses a `*_BUILD_IMAGE` and the
runtime stage copies out of it — the runtime stage itself is always a micro base image.

```dockerfile
ARG TOOLKIT_BUILD_IMAGE \
    MICRO_ROOT_BASE_IMAGE

FROM ${TOOLKIT_BUILD_IMAGE} AS builder

WORKDIR /src

COPY . .

RUN make build

FROM ${MICRO_ROOT_BASE_IMAGE}

USER 0

WORKDIR /app

# Copy only the built artifact out of the builder stage
COPY --from=builder --chown=10001:10001 /src/bin/app /app/app

USER 10001:10001

EXPOSE 8080

CMD ["/app/app"]
```

## The Inverted `.dockerignore` Allowlist Standard (Default Deny)

To enforce packaging hygiene, keep the build context under ~100 KB, and guarantee that no
sensitive local file (`.git/`, `.env`, secrets, test caches, local virtualenvs) leaks into
an image, every project uses an **inverted allowlist**:

1. **Default deny.** Block everything recursively with `**` and `*` at the top of the file.
2. **Explicit allowlist (`!`).** Unignore only the exact files the Dockerfile copies.

| Tech stack | Allowlisted packaging targets |
| --- | --- |
| **Python** (`uv` + `src/`) | `pyproject.toml`, `uv.lock`, `.uv-cache/`, `src/` |
| **Java** (Spring Boot fat JAR) | `target/*.jar` or `build/libs/*.jar` |
| **Golang** (static binary) | `bin/` |
| **Node.js frontend** (Nginx SPA) | `dist/`, `nginx.conf` |
| **Node.js backend** | `dist/`, `.npm` cache, `package*.json` |

[Documentation index](../README.md)
