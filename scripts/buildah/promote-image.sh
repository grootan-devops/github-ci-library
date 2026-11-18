#!/usr/bin/env bash
# Promote the scanned candidate image to the production release (buildah.yml · promote).
#
# Nothing is rebuilt: the exact candidate the merged pull request built and
# scanned is copied by digest to the production tag. The rules -- exact
# candidate only, digest kept, a published tag never overwritten, aliases
# only for the highest release -- live in scripts/release/image-promotion.sh,
# shared with docker/promote-image.sh.
#
# Env:
#   REGISTRY_HOST         registry holding both repositories
#   REGISTRY_USERNAME     registry credentials
#   REGISTRY_PASSWORD     registry credentials
#   DEV_REPOSITORY        candidate repository to promote from
#   PROD_REPOSITORY       production repository to promote into
#   TAG                   production tag to release as
#   CANDIDATE_TAG         exact candidate tag to promote; empty refuses the release
#   IMAGE_INFO_FILE_NAME  markdown summary written into the working directory
#
# Exit codes: 0 promoted (or already promoted at the same digest); 1 no
# candidate was named, the named one is missing, the production tag holds a
# different image, or the registry refused the copy.
set -euo pipefail

# Unset-only guards (`?`, not `:?`): the block these came from ran under
# `set -u`, where an empty value was not fatal at this point.
: "${REGISTRY_HOST?REGISTRY_HOST must be set}"
: "${REGISTRY_USERNAME?REGISTRY_USERNAME must be set}"
: "${REGISTRY_PASSWORD?REGISTRY_PASSWORD must be set}"
: "${DEV_REPOSITORY?DEV_REPOSITORY must be set}"
: "${PROD_REPOSITORY?PROD_REPOSITORY must be set}"
: "${TAG?TAG must be set}"
: "${IMAGE_INFO_FILE_NAME?IMAGE_INFO_FILE_NAME must be set}"
: "${CANDIDATE_TAG:=}"

crane auth login "${REGISTRY_HOST}" --username "${REGISTRY_USERNAME}" --password "${REGISTRY_PASSWORD}"

# shellcheck source=scripts/release/image-promotion.sh
source "$(dirname "${BASH_SOURCE[0]}")/../release/image-promotion.sh"
promote_candidate_image
