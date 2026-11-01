#!/usr/bin/env bash
# Promote the scanned candidate image to the production release (docker.yml · promote).
#
# Nothing is rebuilt: the exact candidate the merged pull request built and
# scanned is copied by digest to the production tag. The rules -- exact
# candidate only, digest kept, a published tag never overwritten, aliases
# only for the highest release -- live in scripts/release/image-promotion.sh,
# shared with buildah/promote-image.sh.
#
# Exit codes: 0 promoted (or already promoted at the same digest); 1 no
# candidate was named, the named one is missing, the production tag holds a
# different image, or the registry refused the copy. The production tag is
# unchanged in every failure but the last alias step, which a re-run repeats.
#
# Needs a job prepared by scripts/registry/auth.sh, whose credentials file crane reads.
#
# Env:
#   REGISTRY_HOST      the primary image registry host
#   TAG                production tag to release as
#   CANDIDATE_TAG      exact candidate tag to promote; empty refuses the release
#   DEV_REPOSITORY     candidate repository, without the registry host
#   PROD_REPOSITORY    production repository, without the registry host
#
# Runner-provided: IMAGE_INFO_FILE_NAME (workflow-level env), GITHUB_STEP_SUMMARY.
set -euo pipefail

: "${TAG?TAG must be set}"
: "${CANDIDATE_TAG?CANDIDATE_TAG must be set}"
: "${DEV_REPOSITORY?DEV_REPOSITORY must be set}"
: "${PROD_REPOSITORY?PROD_REPOSITORY must be set}"
: "${REGISTRY_HOST?REGISTRY_HOST must be set}"
: "${IMAGE_INFO_FILE_NAME?IMAGE_INFO_FILE_NAME must be set}"

# shellcheck source=scripts/release/image-promotion.sh
source "$(dirname "${BASH_SOURCE[0]}")/../release/image-promotion.sh"
promote_candidate_image
