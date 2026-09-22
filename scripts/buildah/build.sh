#!/usr/bin/env bash
# Builds a minimal OCI image with buildah: install only what the image needs,
# then remove the package manager and commit as non-root UID 10001.
# Port of the GitLab buildah Image:Build job.
set -euo pipefail

: "${BASE_IMAGE_REPO:?BASE_IMAGE_REPO must be set}"
: "${BASE_IMAGE_TAG:?BASE_IMAGE_TAG must be set}"
: "${IMAGE_NAME:?IMAGE_NAME must be set}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME must be set}"
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD must be set}"

: "${CONTAINER_ENV_VARS:=}"
: "${INSTALL_PKGS:=}"
: "${REQUIRED_RPMS:=}"
: "${REQUIRED_PKGS:=}"
: "${FORCE_REMOVE_PKGS:=}"
: "${CONTAINER_PATH_ENV:=}"
: "${CONTAINER_ENTRYPOINT:=}"
: "${CONTAINER_CMD:=}"
: "${BUILDAH_SCRIPT_FILE_NAME:=buildah.sh}"
: "${INSTALLED_PCKG_FILE_NAME:=installed_pkgs.txt}"
: "${DNF_INSTALL_ARG:=--setopt=install_weak_deps=0 --nodocs -y}"

BASE_CONTAINER=$(buildah from "--creds=${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG}")

run_in_container_mount() {
  buildah run "${BASE_CONTAINER}" bash -c "${1}"
}

CONTAINER_MOUNT=$(buildah mount "${BASE_CONTAINER}")
# shellcheck disable=SC2206 # deliberate word splitting into dnf arguments
DNF_INSTALLROOT_ARG=(--installroot "${CONTAINER_MOUNT}" --releasever 9 --setopt=install_weak_deps=False --nodocs)
# shellcheck disable=SC2206
DNF_INSTALL_ARGS=(${DNF_INSTALL_ARG})

cp /etc/yum.repos.d/* "${CONTAINER_MOUNT}/etc/yum.repos.d"
cp -r /etc/pki/rpm-gpg "${CONTAINER_MOUNT}/etc/pki"
buildah config --user root "${BASE_CONTAINER}"

dnf install "${DNF_INSTALL_ARGS[@]}" "${DNF_INSTALLROOT_ARG[@]}" microdnf
run_in_container_mount "microdnf update ${DNF_INSTALL_ARG} && microdnf upgrade ${DNF_INSTALL_ARG}"

if [[ -n "${CONTAINER_ENV_VARS}" ]]; then
  for VAR in ${CONTAINER_ENV_VARS}; do
    buildah config --env "${VAR}=${!VAR}" "${BASE_CONTAINER}"
  done
fi

if [[ -n "${INSTALL_PKGS}" ]]; then
  buildah run --network host "${BASE_CONTAINER}" bash -c "microdnf install -y ${DNF_INSTALL_ARG} ${INSTALL_PKGS}"
fi

if [[ -n "${REQUIRED_RPMS}" ]]; then
  buildah run "${BASE_CONTAINER}" bash -c "rpm -Uvh --excludedocs ${REQUIRED_RPMS}"
fi

# Sourced, not executed: the hook needs BASE_CONTAINER and CONTAINER_MOUNT in scope.
if [[ -f "./${BUILDAH_SCRIPT_FILE_NAME}" ]]; then
  echo "Sourcing project hook ./${BUILDAH_SCRIPT_FILE_NAME}"
  # shellcheck disable=SC1090 # path is project-supplied by design
  source "./${BUILDAH_SCRIPT_FILE_NAME}"
fi

if [[ -n "${CONTAINER_PATH_ENV}" ]]; then
  CURRENT_PATH=$(buildah inspect --format '{{range .OCIv1.Config.Env}}{{println .}}{{end}}' "${BASE_CONTAINER}" | grep '^PATH=' | cut -d= -f2-)
  if [[ -n "${CURRENT_PATH}" ]]; then
    NEW_PATH="${CONTAINER_PATH_ENV}:${CURRENT_PATH}"
  else
    NEW_PATH="${CONTAINER_PATH_ENV}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  fi
  buildah config --env PATH="${NEW_PATH}" "${BASE_CONTAINER}"
  echo "Updated container PATH to: ${NEW_PATH}"
fi

if [[ -n "${CONTAINER_ENTRYPOINT}" ]]; then
  buildah config --entrypoint "${CONTAINER_ENTRYPOINT}" "${BASE_CONTAINER}"
fi
if [[ -n "${CONTAINER_CMD}" ]]; then
  buildah config --cmd "${CONTAINER_CMD}" "${BASE_CONTAINER}"
fi

# dnf protects these from removal; the final image has no package manager or init.
rm -f "${CONTAINER_MOUNT}"/etc/dnf/protected.d/systemd.conf
rm -f "${CONTAINER_MOUNT}"/etc/dnf/protected.d/pam.conf
rm -f "${CONTAINER_MOUNT}"/etc/dnf/protected.d/bash.conf

EXCLUDE_PKG_ARG=()
if [[ -n "${REQUIRED_PKGS}" ]]; then
  EXCLUDE_PKG_ARG=("--exclude=$(tr -s ' \n' ',' <<<"${REQUIRED_PKGS}" | sed 's/^,*//;s/,*$//')")
fi

# shellcheck disable=SC2086 # FORCE_REMOVE_PKGS is a deliberate package list
dnf remove -y --setopt=protected_packages="" "${DNF_INSTALLROOT_ARG[@]}" "${EXCLUDE_PKG_ARG[@]}" microdnf ${FORCE_REMOVE_PKGS}
dnf repoquery --installed "${DNF_INSTALLROOT_ARG[@]}" > "./${INSTALLED_PCKG_FILE_NAME}" 2>/dev/null

run_in_container_mount "
rm -rf \
  /usr/share/{doc,man,info,locale,zoneinfo,i18n,icons,pixmaps,backgrounds}/* \
  /var/cache/{dnf,yum}/* /var/lib/dnf/* /var/lib/yum/* \
  /tmp/* /var/tmp/* \
  /etc/yum.repos.d/* /etc/dnf/modules.d/* /etc/rhsm /var/lib/rhsm \
  /etc/systemd /usr/lib/systemd /lib/systemd \
  /etc/pam.d /etc/security /usr/lib/security \
  /usr/bin/{dnf,yum,microdnf,rpm}
"

buildah config --user 10001:10001 "${BASE_CONTAINER}"
buildah umount "${BASE_CONTAINER}"
buildah commit --squash "${BASE_CONTAINER}" "${IMAGE_NAME}"

echo "Installed Packages:"
cat "./${INSTALLED_PCKG_FILE_NAME}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### 🧱 Buildah image"
    echo ""
    echo "Built \`${IMAGE_NAME}\` from \`${BASE_IMAGE_REPO}:${BASE_IMAGE_TAG}\` as 10001:10001."
    echo ""
    echo "<details><summary>Installed packages ($(wc -l < "./${INSTALLED_PCKG_FILE_NAME}" | tr -d ' '))</summary>"
    echo ""
    echo '```'
    cat "./${INSTALLED_PCKG_FILE_NAME}"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
  } >> "${GITHUB_STEP_SUMMARY}"
fi
