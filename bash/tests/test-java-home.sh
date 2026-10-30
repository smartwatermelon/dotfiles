#!/usr/bin/env bash
#shellcheck shell=bash

# env.sh sets JAVA_HOME to a JDK 17 from any vendor (#436). The oracle is
# java_home itself, so this adapts to the JDKs on the host.
set -euo pipefail
unset CDPATH

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/java-home-test.XXXXXX")"
trap 'rm -rf "${WORKDIR}"' EXIT

# Print the JAVA_HOME env.sh sets in a scrubbed env. The stub only needs to
# exist; see test-cdpath-echo.sh.
probe="${WORKDIR}/probe.sh"
cat >"${probe}" <<'PROBE'
_get_homebrew_root() { echo /opt/homebrew; }
#shellcheck source=/dev/null
source "${BASH_CONFIG_DIR}/env.sh" >/dev/null 2>&1
printf '%s' "${JAVA_HOME:-}"
PROBE
env_java_home="$(env -i HOME="${WORKDIR}" BASH_CONFIG_DIR="${REPO_ROOT}/bash" \
  PATH="/usr/bin:/bin" bash --norc "${probe}")"

expected=""
if [[ -x /usr/libexec/java_home ]]; then
  # Same scrubbed env as the probe: java_home may also scan ~/Library/Java.
  expected="$(env -i HOME="${WORKDIR}" PATH="/usr/bin:/bin" \
    /usr/libexec/java_home --failfast -v 17 2>/dev/null || true)"
fi

# Case 1: JAVA_HOME is set exactly when a JDK 17 is installed, to that JDK.
if [[ "${env_java_home}" == "${expected}" ]]; then
  echo "PASS: JAVA_HOME matches java_home -v 17 ('${env_java_home:-<unset>}')"
else
  echo "FAIL: JAVA_HOME is '${env_java_home:-<unset>}', expected '${expected:-<unset>}'"
  fail=1
fi

# Case 2: when set, it really is a 17 JDK, not java_home's newest-JDK fallback.
if [[ -n "${env_java_home}" ]]; then
  version="$(sed -n 's/^JAVA_VERSION="\(.*\)"$/\1/p' "${env_java_home}/release" 2>/dev/null || true)"
  if [[ "${version}" == 17 || "${version}" == 17.* ]]; then
    echo "PASS: JAVA_HOME is a JDK 17 (${version})"
  else
    echo "FAIL: JAVA_HOME '${env_java_home}' reports JAVA_VERSION '${version}', not 17"
    fail=1
  fi
else
  echo "SKIP: JAVA_HOME unset, so there is no version to check"
fi

exit "${fail}"
