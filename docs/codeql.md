# Codeql Actions Reference

```yaml
name: CodeQL Security

on:
  push:
    branches:
      - main

  pull_request:
    branches:
      - main

  schedule:
    # Monday 05:20 UTC
    - cron: "20 5 * * 1"

  workflow_dispatch:

concurrency:
  group: codeql-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  analyze:
    name: CodeQL / ${{ matrix.language }}

    runs-on: ${{ matrix.os }}

    timeout-minutes: 30

    permissions:
      contents: read
      security-events: write

    strategy:
      fail-fast: false
      matrix:
        include:
          # Current repository mainly needs GitHub Actions scanning.
          - language: actions
            build-mode: none
            os: ubuntu-latest

          # Add when corresponding source appears:
          #
          # - language: javascript-typescript
          #   build-mode: none
          #   os: ubuntu-latest
          #
          # - language: python
          #   build-mode: none
          #   os: ubuntu-latest
          #
          # - language: go
          #   build-mode: autobuild
          #   os: ubuntu-latest
          #
          # - language: java-kotlin
          #   build-mode: autobuild
          #   os: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v7
        with:
          persist-credentials: false

      - name: Initialize CodeQL
        uses: github/codeql-action/init@v4
        with:
          languages: ${{ matrix.language }}
          build-mode: ${{ matrix.build-mode }}

          # Default queries + additional security checks.
          queries: security-extended

      - name: Perform CodeQL analysis
        uses: github/codeql-action/analyze@v4
        with:
          category: /language:${{ matrix.language }}
```
