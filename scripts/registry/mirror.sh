#!/usr/bin/env bash
# Copy what the primary destination holds to every other destination, by digest.
#
# Usage: mirror.sh <image|chart> <stable|dev> <tag> [alias...]
#
# Needs a job prepared by auth.sh. With one destination it does nothing.
#
# Exit codes: 0 copied (or nothing to copy), 1 a destination failed; every destination is
# tried first, and the failed ones are named.
set -euo pipefail

# shellcheck source=scripts/registry/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KIND="${1:?image or chart}"
WHICH="${2:?stable or dev}"
TAG="${3:?tag}"
shift 3

registry_mirror "${KIND}" "${WHICH}" "${TAG}" "$@"
