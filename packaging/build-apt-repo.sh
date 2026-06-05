#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEB_DIR="${1:-${ROOT}/dist}"
SITE="${SITE:-${ROOT}/site}"
DIST="${DIST:-stable}"
COMPONENT="main"
ARCHES="${ARCHES:-amd64 arm64}"
GPG_KEY_ID="${GPG_KEY_ID:?set GPG_KEY_ID to the signing key id}"

rm -rf "${SITE}"
mkdir -p "${SITE}/pool/${COMPONENT}"
cp "${DEB_DIR}"/*.deb "${SITE}/pool/${COMPONENT}/"

for ARCH in ${ARCHES}; do
  BIN="dists/${DIST}/${COMPONENT}/binary-${ARCH}"
  mkdir -p "${SITE}/${BIN}"
  ( cd "${SITE}" && dpkg-scanpackages --arch "${ARCH}" "pool/${COMPONENT}" /dev/null > "${BIN}/Packages" )
  gzip -9kf "${SITE}/${BIN}/Packages"
done

(
  cd "${SITE}/dists/${DIST}"
  apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=pg_replica" \
    -o "APT::FTPArchive::Release::Label=pg_replica" \
    -o "APT::FTPArchive::Release::Suite=${DIST}" \
    -o "APT::FTPArchive::Release::Codename=${DIST}" \
    -o "APT::FTPArchive::Release::Components=${COMPONENT}" \
    -o "APT::FTPArchive::Release::Architectures=${ARCHES}" \
    release . > Release
  gpg --batch --yes --local-user "${GPG_KEY_ID}" -abs -o Release.gpg Release
  gpg --batch --yes --local-user "${GPG_KEY_ID}" --clearsign -o InRelease Release
)

gpg --export "${GPG_KEY_ID}" > "${SITE}/pg_replica.gpg"
cp "${ROOT}/packaging/install.sh" "${SITE}/install.sh"
echo "apt repo assembled in ${SITE}/"
