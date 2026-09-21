#!/usr/bin/env bash
# Baseline hadolint ignore set, shared by docker-lint.sh and readme-dockerfile-check.sh
# so a consumer's Dockerfile and the README examples are judged identically.
# shellcheck disable=SC2034  # sourced by callers
HADOLINT_DEFAULT_IGNORE="DL3008,DL3013,DL3016,DL3018,DL3028,DL3033,DL3037,DL3041,DL3062"
