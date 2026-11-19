#!/usr/bin/env bash
# shellcheck shell=bash
# Build VPNConfig.tblk from the untracked .ovpn and the tracked scripts.
# See tunnelblick/README.md.
set -euo pipefail

# Tests point TUNNELBLICK_SRC_DIR at a scratch directory.
src_dir="${TUNNELBLICK_SRC_DIR:-${HOME}/.config/tunnelblick/romano}"
ovpn="${src_dir}/VPNConfig.ovpn"
# Tests swap in wrappers that refuse any path outside their scratch directory.
RM_BIN="${RM_BIN:-rm}"
MV_BIN="${MV_BIN:-mv}"
bundle="${src_dir}/VPNConfig.tblk"
# DSM's CA lasts a year; an expired one causes a reconnect loop.
warn_days=30

die() {
  echo "build-tblk: $*" >&2
  exit 1
}

[[ -f "${ovpn}" ]] || die "${ovpn} not found. Export it from DSM (VPN Server > OpenVPN > Export configuration); see VPNConfig.ovpn.example."
if grep -qE 'YOUR_SERVER_(IP|HOSTNAME)|YOUR_PORT' "${ovpn}"; then
  die "${ovpn} still has a placeholder on its remote line."
fi
for s in connected.sh disconnected.sh; do
  [[ -f "${src_dir}/${s}" ]] || die "${src_dir}/${s} not found."
done

ca_pem="$(sed -n '/<ca>/,/<\/ca>/p' "${ovpn}" | sed '1d;$d')"
[[ -n "${ca_pem}" ]] || die "${ovpn} has no <ca> block."
if ! printf '%s\n' "${ca_pem}" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
  die "the CA in ${ovpn} has expired. Re-export from DSM and replace the <ca> block."
fi
if ! printf '%s\n' "${ca_pem}" | openssl x509 -noout -checkend $((warn_days * 86400)) >/dev/null 2>&1; then
  ca_end="$(printf '%s\n' "${ca_pem}" | openssl x509 -noout -enddate)"
  echo "build-tblk: warning: the CA expires within ${warn_days} days (${ca_end#notAfter=})." >&2
fi

# Build beside the target, then swap, so a failed build leaves the old
# bundle in place.
staging="$(mktemp -d "${src_dir}/.VPNConfig.tblk.XXXXXX")"
old="${staging}.old"
# On any exit before the swap finishes: put a moved-aside old bundle back,
# then drop the staging dir.
cleanup() {
  if [[ -e "${old}" && ! -e "${bundle}" ]]; then
    "${MV_BIN}" "${old}" "${bundle}" \
      || echo "build-tblk: could not restore the old bundle; it is at ${old}" >&2
  fi
  "${RM_BIN}" -rf "${staging}"
}
trap cleanup EXIT
resources="${staging}/Contents/Resources"
mkdir -p "${resources}"
cp "${ovpn}" "${resources}/VPNConfig.ovpn"
# -L: install.sh replaces the scripts with symlinks into the repo.
cp -L "${src_dir}/connected.sh" "${src_dir}/disconnected.sh" "${resources}/"
chmod 644 "${resources}/VPNConfig.ovpn"
chmod 755 "${resources}/connected.sh" "${resources}/disconnected.sh"
chmod 755 "${staging}"

# Move the old bundle aside first, so a failed swap can put it back.
if [[ -e "${bundle}" ]]; then
  "${MV_BIN}" "${bundle}" "${old}" || die "could not move the old bundle aside."
fi
"${MV_BIN}" "${staging}" "${bundle}" || die "could not move the new bundle into place."
trap - EXIT
if [[ -e "${old}" ]]; then
  "${RM_BIN}" -rf "${old}"
fi

echo "Built ${bundle}"
echo "Install: open \"${bundle}\"  (choose Replace if Tunnelblick asks)"
