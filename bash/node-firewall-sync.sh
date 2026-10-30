#!/bin/bash
# Firewall entries for Homebrew node (dev-env#235). Root-owned copy, never a symlink: bash/README.md

# bash 3.2: the shell root gets.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [ "${EUID}" -eq 0 ]; then
  # As root, ignore the environment: these paths are fixed.
  fw=/usr/libexec/ApplicationFirewall/socketfilterfw
  cellar=/opt/homebrew/Cellar/node
elif [ -n "${NODE_FW_SOCKETFILTERFW:-}" ] && [ -n "${NODE_FW_CELLAR:-}" ]; then
  # Tests only: a stub firewall tool and a fixture Cellar.
  fw="${NODE_FW_SOCKETFILTERFW}"
  cellar="${NODE_FW_CELLAR}"
else
  echo "node-firewall-sync: must run as root (sudo)" >&2
  exit 2
fi

# Only this exact shape is ever passed to the firewall tool.
is_node_path() {
  case "$1" in
    "${cellar}"/*/bin/node) ;;
    *) return 1 ;;
  esac
  local version="${1#"${cellar}"/}"
  version="${version%/bin/node}"
  case "${version}" in
    "" | */* | *[!0-9A-Za-z._-]*) return 1 ;;
    [0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

listing="$("${fw}" --listapps)" || {
  echo "node-firewall-sync: --listapps failed" >&2
  exit 1
}
# Lines look like "1 : /opt/homebrew/Cellar/node/26.13.0/bin/node ".
listed="$(printf '%s\n' "${listing}" | sed -n 's/^[0-9][0-9]* : \(.*[^ ]\) *$/\1/p')"

rc=0
for path in "${cellar}"/*/bin/node; do
  [ -f "${path}" ] || continue
  is_node_path "${path}" || continue
  if printf '%s\n' "${listed}" | grep -qxF -- "${path}"; then
    continue
  fi
  echo "node-firewall-sync: allowing ${path}"
  "${fw}" --add "${path}" || rc=1
  "${fw}" --unblockapp "${path}" || rc=1
done

while IFS= read -r path; do
  [ -n "${path}" ] || continue
  is_node_path "${path}" || continue
  [ -e "${path}" ] && continue
  echo "node-firewall-sync: removing stale ${path}"
  "${fw}" --remove "${path}" || rc=1
done <<EOF
${listed}
EOF

exit "${rc}"
