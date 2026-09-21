# Dependabot Reference

Ref: <https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-manifests-for-dependency-scope> <https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference>

```yaml
# .github/dependabot.yml
#
# Dependabot configuration for:
#   - Go
#   - Java / Maven
#   - Java / Gradle
#   - Python 3
#   - Node.js / TypeScript / JavaScript
#
# HTML/CSS do not have their own package ecosystem.
# Frontend tooling such as:
#   vite, webpack, eslint, typescript, tailwindcss,
#   postcss, sass, stylelint, etc.
# is managed through the npm ecosystem.
#
# IMPORTANT:
# Dependabot ALERT FILTERS such as:
#
#   is:open
#   severity:critical
#   ecosystem:npm
#   scope:development
#   relationship:direct
#   has:patch
#
# are NOT valid dependabot.yml configuration.
# They are search/filter expressions used in GitHub's
# Dependabot Alerts UI / Security Overview.
#
# This file configures dependency VERSION updates and
# the behavior of Dependabot SECURITY update PRs.

version: 2

updates:

  # ============================================================
  # GO
  # ============================================================
  #
  # Supported manifests:
  #   go.mod
  #   go.sum
  #
  # package-ecosystem:
  #   gomod
  #
  # Dependency scope note:
  # GitHub currently treats dependencies from go.mod as runtime
  # for Dependabot alert scope purposes.
  #
  - package-ecosystem: "gomod"

    # Globs are supported by "directories".
    #
    # Examples:
    #   /services/go-api
    #   /services/go-worker
    #   /libs/go-common
    directories:
      - "/services/go-*"
      - "/libs/go-*"

    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:00"
      timezone: "Asia/Kolkata"

    # Applies to VERSION update PRs.
    # Security update PRs are not counted against this limit.
    open-pull-requests-limit: 10

    # Dependabot automatically rebases by default.
    # Explicitly disabling it is possible with:
    #
    # rebase-strategy: "disabled"

    commit-message:
      prefix: "deps(go)"
      include: "scope"

    pull-request-branch-name:
      separator: "-"
      prefix: "dependabot-go"
      max-length: 100

    # Cooldown applies only to VERSION updates.
    # It does NOT delay security updates.
    cooldown:
      default-days: 3

    groups:

      # --------------------------------------------------------
      # Security vulnerabilities
      # --------------------------------------------------------
      #
      # Combine compatible Go security updates into fewer PRs.
      go-security:
        applies-to: "security-updates"
        patterns:
          - "*"

      # --------------------------------------------------------
      # Routine version updates
      # --------------------------------------------------------
      go-minor-patch:
        applies-to: "version-updates"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"

      # Major versions stay separate from normal updates.
      go-major:
        applies-to: "version-updates"
        patterns:
          - "*"
        update-types:
          - "major"

    # Example dependency exclusions.
    #
    # Uncomment ONLY when intentionally pinning something.
    #
    # ignore:
    #   - dependency-name: "github.com/example/example"
    #     update-types:
    #       - "version-update:semver-major"


  # ============================================================
  # JAVA — MAVEN
  # ============================================================
  #
  # Supported manifest:
  #   pom.xml
  #
  # Maven dependency identifiers used in allow/ignore rules:
  #
  #   groupId:artifactId
  #
  # Example:
  #
  #   org.springframework:spring-core
  #
  - package-ecosystem: "maven"

    directories:
      - "/services/java-*"
      - "/libs/java-*"

    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:15"
      timezone: "Asia/Kolkata"

    open-pull-requests-limit: 10

    commit-message:
      prefix: "deps(java)"
      prefix-development: "deps-dev(java)"
      include: "scope"

    pull-request-branch-name:
      separator: "-"
      prefix: "dependabot-maven"
      max-length: 100

    cooldown:
      default-days: 3

    groups:

      # --------------------------------------------------------
      # Security updates
      # --------------------------------------------------------
      maven-security:
        applies-to: "security-updates"
        patterns:
          - "*"

      # --------------------------------------------------------
      # Production dependencies — minor + patch
      # --------------------------------------------------------
      maven-production-minor-patch:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"

      # --------------------------------------------------------
      # Development/test dependencies
      # --------------------------------------------------------
      maven-development:
        applies-to: "version-updates"
        dependency-type: "development"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
          - "major"

      # --------------------------------------------------------
      # Production major upgrades
      # --------------------------------------------------------
      #
      # Keeping these separate is useful because major Java
      # dependency upgrades frequently require code changes.
      maven-production-major:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "major"

    # Example:
    #
    # ignore:
    #   - dependency-name: "org.springframework.boot:spring-boot"
    #     update-types:
    #       - "version-update:semver-major"
    #
    #   - dependency-name: "org.apache.logging.log4j:log4j-core"
    #     versions:
    #       - "[3.0,)"
    #
    # WARNING:
    # Avoid ignoring security-sensitive packages unless there
    # is a specific documented reason.


  # ============================================================
  # JAVA — GRADLE
  # ============================================================
  #
  # Covers:
  #   build.gradle
  #   build.gradle.kts
  #
  # Dependency names in allow/ignore rules generally use:
  #
  #   groupId:artifactId
  #
  - package-ecosystem: "gradle"

    directories:
      - "/services/java-*"
      - "/libs/java-*"

    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:30"
      timezone: "Asia/Kolkata"

    open-pull-requests-limit: 10

    commit-message:
      prefix: "deps(gradle)"
      include: "scope"

    pull-request-branch-name:
      separator: "-"
      prefix: "dependabot-gradle"
      max-length: 100

    cooldown:
      default-days: 3

    groups:

      gradle-security:
        applies-to: "security-updates"
        patterns:
          - "*"

      gradle-minor-patch:
        applies-to: "version-updates"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"

      gradle-major:
        applies-to: "version-updates"
        patterns:
          - "*"
        update-types:
          - "major"

    # Do NOT use dependency-type: production/development here.
    #
    # GitHub currently documents group dependency-type support
    # for Maven, npm, pip, Bundler, Composer, and Mix — but not
    # Gradle.


  # ============================================================
  # PYTHON 3
  # ============================================================
  #
  # package-ecosystem "pip" covers several Python dependency
  # formats including:
  #
  #   requirements.txt
  #   requirements-dev.txt
  #   requirements-test.txt
  #   Pipfile / Pipfile.lock
  #   pyproject.toml / Poetry
  #   poetry.lock
  #   pip-compile
  #
  # If using uv as the package manager, GitHub also has a
  # separate "uv" ecosystem. It is intentionally NOT included
  # here because this example is restricted to pip-style Python.
  #
  - package-ecosystem: "pip"

    directories:
      - "/services/python-*"
      - "/libs/python-*"

    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:45"
      timezone: "Asia/Kolkata"

    open-pull-requests-limit: 10

    commit-message:
      prefix: "deps(python)"
      prefix-development: "deps-dev(python)"
      include: "scope"

    pull-request-branch-name:
      separator: "-"
      prefix: "dependabot-python"
      max-length: 100

    # For npm and pip, versioning-strategy is supported.
    #
    # "increase-if-necessary":
    #   - update lock/resolved versions
    #   - don't unnecessarily tighten manifest constraints
    #   - widen constraints when required
    versioning-strategy: "increase-if-necessary"

    cooldown:
      default-days: 3

    groups:

      # --------------------------------------------------------
      # Security updates
      # --------------------------------------------------------
      python-security:
        applies-to: "security-updates"
        patterns:
          - "*"

      # --------------------------------------------------------
      # Production dependencies
      # --------------------------------------------------------
      python-production-minor-patch:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"

      # --------------------------------------------------------
      # Development/test dependencies
      # --------------------------------------------------------
      python-development:
        applies-to: "version-updates"
        dependency-type: "development"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
          - "major"

      # --------------------------------------------------------
      # Production major versions
      # --------------------------------------------------------
      python-production-major:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "major"

    # Example exclusions:
    #
    # ignore:
    #   - dependency-name: "django"
    #     update-types:
    #       - "version-update:semver-major"
    #
    #   - dependency-name: "numpy"
    #     versions:
    #       - ">=3"


  # ============================================================
  # NODE.JS / TYPESCRIPT / JAVASCRIPT / FRONTEND
  # ============================================================
  #
  # Use "npm" for:
  #
  #   npm
  #   yarn
  #   pnpm
  #
  # Typical manifests / lockfiles include:
  #
  #   package.json
  #   package-lock.json
  #   yarn.lock
  #   pnpm-lock.yaml
  #
  # TypeScript is NOT a separate Dependabot ecosystem.
  #
  # HTML/CSS are NOT separate ecosystems either.
  #
  # Dependencies used by HTML/CSS/JS/TS projects such as:
  #
  #   typescript
  #   vite
  #   webpack
  #   react
  #   vue
  #   next
  #   eslint
  #   prettier
  #   tailwindcss
  #   postcss
  #   sass
  #   stylelint
  #
  # are all handled here.
  #
  - package-ecosystem: "npm"

    directories:
      - "/web"
      - "/packages/*"

    schedule:
      interval: "weekly"
      day: "monday"
      time: "10:00"
      timezone: "Asia/Kolkata"

    open-pull-requests-limit: 10

    commit-message:
      prefix: "deps(node)"
      prefix-development: "deps-dev(node)"
      include: "scope"

    pull-request-branch-name:
      separator: "-"
      prefix: "dependabot-node"
      max-length: 100

    versioning-strategy: "increase-if-necessary"

    cooldown:
      default-days: 3

    groups:

      # --------------------------------------------------------
      # SECURITY
      # --------------------------------------------------------
      #
      # Security-update grouping is independent from the
      # normal version-update groups below.
      node-security:
        applies-to: "security-updates"
        patterns:
          - "*"

      # --------------------------------------------------------
      # Production dependencies — minor + patch
      # --------------------------------------------------------
      node-production-minor-patch:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"

      # --------------------------------------------------------
      # Development dependencies
      # --------------------------------------------------------
      #
      # Includes things such as:
      #   eslint
      #   prettier
      #   typescript
      #   @types/*
      #   test frameworks
      #
      node-development:
        applies-to: "version-updates"
        dependency-type: "development"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"
          - "major"

      # --------------------------------------------------------
      # Production major versions
      # --------------------------------------------------------
      node-production-major:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "major"

    # Example dependency exclusions.
    #
    # Prefer leaving this empty unless a dependency has a
    # documented compatibility constraint.
    #
    # ignore:
    #
    #   - dependency-name: "node"
    #     update-types:
    #       - "version-update:semver-major"
    #
    #   - dependency-name: "@types/node"
    #     update-types:
    #       - "version-update:semver-major"

  - package-ecosystem: "npm"
    directory: "/"

    schedule:
      interval: "weekly"
      day: "monday"
      time: "10:00"
      timezone: "Asia/Kolkata"

    # Limit normal version-update PRs.
    # Security update PRs do not count toward this limit.
    open-pull-requests-limit: 10

    # Applies only to normal version updates.
    # Security updates are not delayed by cooldown.
    cooldown:
      default-days: 3

    groups:

      # ========================================================
      # SECURITY UPDATES
      # ========================================================
      #
      # Groups vulnerable dependencies into security-update PRs.
      #
      # This does NOT mean:
      #   severity:critical
      #   severity:high
      #
      # Dependabot YAML currently groups by dependency/package
      # patterns, not advisory severity.
      security-updates:
        applies-to: "security-updates"
        patterns:
          - "*"

      # ========================================================
      # PRODUCTION MINOR/PATCH
      # ========================================================
      #
      # package.json:
      #
      #   "dependencies": {
      #      ...
      #   }
      #
      production-minor-patch:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "minor"
          - "patch"

      # ========================================================
      # DEVELOPMENT DEPENDENCIES
      # ========================================================
      #
      # package.json:
      #
      #   "devDependencies": {
      #      "typescript": "...",
      #      "eslint": "...",
      #      "@types/node": "...",
      #      "vitest": "..."
      #   }
      #
      development-dependencies:
        applies-to: "version-updates"
        dependency-type: "development"
        patterns:
          - "*"
        update-types:
          - "major"
          - "minor"
          - "patch"

      # ========================================================
      # PRODUCTION MAJOR UPDATES
      # ========================================================
      #
      # Keep breaking upgrades separate from routine updates.
      production-major:
        applies-to: "version-updates"
        dependency-type: "production"
        patterns:
          - "*"
        update-types:
          - "major"

    commit-message:
      prefix: "deps(node)"
      prefix-development: "deps-dev(node)"
      include: "scope"
```
