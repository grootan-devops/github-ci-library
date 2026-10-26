#!/usr/bin/env bash
# Log docker out of every registry this job logged in to.
#
# A self-hosted runner keeps ~/.docker/config.json between jobs, so a login
# made on the runner host must not outlive the job that made it.
# docker/login-action did this in its post step; login.sh records each server
# it logs in to, and only those are logged out here.
#
# Runs under `if: always()`, so it never fails: a logout that does not happen
# must not replace the job's real error.
#
# Exit codes: 0 always.
set -euo pipefail

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
registry_logout
