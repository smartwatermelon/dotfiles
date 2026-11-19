#!/usr/bin/env bash
#shellcheck shell=bash
# Tests tunnelblick/romano/build-tblk.sh: builds, refusals, old bundle kept.
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${REPO_ROOT}/tunnelblick/romano/build-tblk.sh"

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tunnelblick-build-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# rm and mv wrappers that refuse any path outside WORKDIR.
mkdir -p "${WORKDIR}/bin"
for cmd in rm mv; do
  real="$(command -v "${cmd}")"
  cat >"${WORKDIR}/bin/${cmd}" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    -*) ;;
    "${WORKDIR}"/*) ;;
    *) echo "guarded-${cmd}: refusing path outside test dir: \$a" >&2; exit 97 ;;
  esac
done
exec "${real}" "\$@"
EOF
  chmod +x "${WORKDIR}/bin/${cmd}"
done
export RM_BIN="${WORKDIR}/bin/rm" MV_BIN="${WORKDIR}/bin/mv"

check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected '$3', got '$2')"
    fail=1
  fi
}

# Self-signed cert valid for $1 days, PEM on stdout.
make_cert() {
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj /CN=test \
    -days "$1" 2>/dev/null
}

# Source dir $1 with an .ovpn whose remote line is $2 and CA PEM is $3.
# The scripts are symlinks, as install.sh leaves them.
make_src() {
  mkdir -p "$1"
  {
    printf 'client\n%s\n<ca>\n' "$2"
    printf '%s\n' "$3"
    printf '</ca>\n'
  } >"$1/VPNConfig.ovpn"
  ln -sf "${REPO_ROOT}/tunnelblick/romano/connected.sh" "$1/connected.sh"
  ln -sf "${REPO_ROOT}/tunnelblick/romano/disconnected.sh" "$1/disconnected.sh"
}

run_build() {
  TUNNELBLICK_SRC_DIR="$1" bash "${BUILD}" >"${WORKDIR}/out" 2>"${WORKDIR}/err" && echo 0 || echo $?
}

# is_file, is_exec, exists: print a word for check() instead of returning a
# status, so each assertion reads as one line.
is_file() { if [[ -f "$1" && ! -L "$1" ]]; then echo file; else echo other; fi; }
is_exec() { if [[ -x "$1" ]]; then echo x; else echo no; fi; }
exists() { if [[ -e "$1" ]]; then echo built; else echo none; fi; }
ca_state() {
  local pem
  pem="$(sed -n '/<ca>/,/<\/ca>/p' "$1" | sed '1d;$d')"
  if printf '%s\n' "${pem}" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
    echo valid
  else
    echo invalid
  fi
}

valid_ca="$(make_cert 365)"

# 1. Happy path: bundle holds real copies of all three files.
src="${WORKDIR}/ok"
make_src "${src}" "remote vpn.example 1194" "${valid_ca}"
rc="$(run_build "${src}")"
check "valid config builds" "${rc}" "0"
res="${src}/VPNConfig.tblk/Contents/Resources"
same=differ
if cmp -s "${src}/VPNConfig.ovpn" "${res}/VPNConfig.ovpn"; then same=same; fi
check "ovpn copied verbatim" "${same}" "same"
for s in connected.sh disconnected.sh; do
  got="$(is_file "${res}/${s}")"
  check "${s} is a regular file, not a symlink" "${got}" "file"
  got="$(is_exec "${res}/${s}")"
  check "${s} is executable" "${got}" "x"
done
leftovers=("${src}"/.VPNConfig.tblk.*)
check "no staging dir left behind" "${leftovers[*]}" "${src}/.VPNConfig.tblk.*"

# 2. Placeholder remote line is refused.
src="${WORKDIR}/placeholder"
make_src "${src}" "remote YOUR_SERVER_IP 1194" "${valid_ca}"
rc="$(run_build "${src}")"
check "placeholder remote refused" "${rc}" "1"
got="$(exists "${src}/VPNConfig.tblk")"
check "placeholder: no bundle built" "${got}" "none"

# 3. Missing .ovpn is refused.
src="${WORKDIR}/missing"
mkdir -p "${src}"
rc="$(run_build "${src}")"
check "missing ovpn refused" "${rc}" "1"

# 4. CA close to expiry builds, with a warning.
src="${WORKDIR}/soon"
soon_ca="$(make_cert 10)"
make_src "${src}" "remote vpn.example 1194" "${soon_ca}"
rc="$(run_build "${src}")"
check "near-expiry CA still builds" "${rc}" "0"
warned=no
if grep -q 'expires within' "${WORKDIR}/err"; then warned=yes; fi
check "near-expiry CA warns" "${warned}" "yes"

# 5. Expired CA is refused, and a previous bundle survives.
expired_ca="$(openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj /CN=test \
  -not_before 20200101000000Z -not_after 20210101000000Z 2>/dev/null || true)"
if [[ -z "${expired_ca}" ]]; then
  echo "SKIP: expired-CA cases (this openssl lacks -not_after)"
else
  src="${WORKDIR}/expired"
  make_src "${src}" "remote vpn.example 1194" "${valid_ca}"
  rc="$(run_build "${src}")"
  check "expired CA: first build succeeds" "${rc}" "0"
  make_src "${src}" "remote vpn.example 1194" "${expired_ca}"
  rc="$(run_build "${src}")"
  check "expired CA refused" "${rc}" "1"
  got="$(ca_state "${src}/VPNConfig.tblk/Contents/Resources/VPNConfig.ovpn")"
  check "expired CA: old bundle kept, with the valid CA" "${got}" "valid"
fi

# 6. A failed swap puts the old bundle back. This mv fails only on the swap.
cat >"${WORKDIR}/bin/mv-fail-swap" <<EOF
#!/usr/bin/env bash
case "\$1" in
  *.old) ;;
  */.VPNConfig.tblk.*) echo "mv-fail-swap: simulated failure" >&2; exit 1 ;;
esac
exec "${WORKDIR}/bin/mv" "\$@"
EOF
chmod +x "${WORKDIR}/bin/mv-fail-swap"
src="${WORKDIR}/swap"
make_src "${src}" "remote vpn.example 1194" "${valid_ca}"
rc="$(run_build "${src}")"
check "swap: first build succeeds" "${rc}" "0"
echo marker >"${src}/VPNConfig.tblk/Contents/Resources/marker"
rc="$(MV_BIN="${WORKDIR}/bin/mv-fail-swap" run_build "${src}")"
check "swap failure is reported" "${rc}" "1"
got="$(exists "${src}/VPNConfig.tblk/Contents/Resources/marker")"
check "swap failure: old bundle restored" "${got}" "built"
leftovers=("${src}"/.VPNConfig.tblk.*)
check "swap failure: no staging dir left behind" "${leftovers[*]}" "${src}/.VPNConfig.tblk.*"

exit "${fail}"
