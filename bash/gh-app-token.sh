#!/usr/bin/env bash
# ~/.config/bash/gh-app-token.sh
# shellcheck shell=bash

# GitHub App tokens for routed repos (claude-config#659). Design: dev-env specs/2026-10-01-agent-github-app-design.md

# Usage text, printed by --help. Kept out of comments so it can say enough.
_gh_app_usage() {
  cat <<'USAGE_EOF'
gh-app-token.sh: mint GitHub App installation tokens for repos routed to an App.

  gh-app-token.sh route <spec>
      Print the 1Password item routed for <spec> (owner/repo, a git remote URL or a
      github.com URL). Exit 0 routed, 1 not routed, 2 route file malformed for it.
  gh-app-token.sh [--item <op-item>] <owner>
      Print an installation token. The item defaults to the first route for <owner>.
      This prints a secret: do not run it at a terminal.
  gh-app-token.sh git-credential <op-item> get
      git credential helper. Answers protocol=https host=github.com only.
  gh-app-token.sh check <spec>
      Show the route and how long the cached token has left. Never prints the token.

Route file: $GH_APP_ROUTES_FILE, else gh-app-routes.conf beside this script's real
path. One route per line: owner/repo, a TAB, op://vault/item. Unlisted repos are
not routed.

Cache: ${XDG_CACHE_HOME:-~/.cache}/gh-app-tokens (dir 0700, files 0600), one file per
item. A token is reused until 5 minutes before mint time + 1 hour.

The private key goes to a 0600 temp file for one openssl call and is then removed;
it is never put in an environment variable. The JWT reaches curl on stdin, not argv.
USAGE_EOF
}

_GH_APP_TOKEN_LIFETIME=3600
_GH_APP_TOKEN_MARGIN=300

_gh_app_err() { printf '[gh-app] %s\n' "$*" >&2; }

_gh_app_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# This script's directory with symlinks resolved, so the default route file is the tracked one beside it.
_gh_app_self_dir() {
  local src="${BASH_SOURCE[0]}" real
  real="$(realpath "${src}" 2>/dev/null)" || real="${src}"
  CDPATH='' cd "$(dirname "${real}")" && pwd
}

_gh_app_routes_file() {
  if [[ -n "${GH_APP_ROUTES_FILE:-}" ]]; then
    printf '%s\n' "${GH_APP_ROUTES_FILE}"
  else
    local dir
    dir="$(_gh_app_self_dir)" || return 1
    printf '%s/gh-app-routes.conf\n' "${dir}"
  fi
}

# Lowercase owner/repo of owner/repo, a github.com URL or remote (alias github.com-x too); else nothing.
_gh_app_spec_repo() {
  local v="$1" host owner repo
  if [[ "${v}" =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^/@]+@)?([^/:]+)(:[0-9]+)?/(.*)$ ]]; then
    host="${BASH_REMATCH[2]}"
    v="${BASH_REMATCH[4]}"
  elif [[ "${v}" =~ ^([^/@]+@)?([^/:]+):(.*)$ ]]; then
    host="${BASH_REMATCH[2]}"
    v="${BASH_REMATCH[3]}"
  else
    host="github.com"
    v="${v#[Gg]ithub.com/}"
  fi
  host="$(_gh_app_lower "${host}")"
  [[ "${host}" == "github.com" || "${host}" == "www.github.com" || "${host}" == github.com-* ]] || return 0
  v="${v#/}"
  [[ "${v}" == */* ]] || return 0
  owner="${v%%/*}"
  repo="${v#*/}"
  repo="${repo%%/*}"
  repo="${repo%%[?#]*}"
  repo="${repo%.git}"
  [[ "${owner}" =~ ^[A-Za-z0-9._-]+$ && "${repo}" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  _gh_app_lower "${owner}/${repo}"
  printf '\n'
}

# _gh_app_route <owner/repo | owner:NAME>: print the routed item. 0 routed, 1 not, 2 malformed (fail closed).
_gh_app_route() {
  local want="$1" file line key item
  file="$(_gh_app_routes_file)"
  [[ -r "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" != *$'\t'* ]]; then
      key="$(_gh_app_lower "${line%%[[:space:]]*}")"
      if [[ "${key}" == "${want}" || "owner:${key%%/*}" == "${want}" ]]; then
        _gh_app_err "route for ${key} in ${file} has no TAB before its item; refusing to guess"
        return 2
      fi
      continue
    fi
    key="$(_gh_app_lower "${line%%$'\t'*}")"
    item="${line#*$'\t'}"
    while [[ "${item}" == $'\t'* ]]; do item="${item#?}"; done
    if [[ "${key}" == "${want}" || "owner:${key%%/*}" == "${want}" ]]; then
      if [[ "${item}" != op://* ]]; then
        _gh_app_err "route for ${key} in ${file} does not name an op:// item"
        return 2
      fi
      printf '%s\n' "${item}"
      return 0
    fi
  done <"${file}"
  return 1
}

_gh_app_cache_file() {
  local key="${1//[^A-Za-z0-9._-]/_}"
  printf '%s/gh-app-tokens/%s\n' "${XDG_CACHE_HOME:-${HOME}/.cache}" "${key}"
}

# Print the cached token for an item if it has more than the margin left.
_gh_app_cached_token() {
  local file exp="" tok="" now
  file="$(_gh_app_cache_file "$1")"
  [[ -f "${file}" && -O "${file}" ]] || return 1
  { IFS= read -r exp && IFS= read -r tok; } <"${file}" || return 1
  [[ "${exp}" =~ ^[0-9]+$ && "${tok}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  now="$(date +%s)"
  ((exp - now > _GH_APP_TOKEN_MARGIN)) || return 1
  printf '%s\n' "${tok}"
}

_gh_app_write_cache() {
  local item="$1" exp="$2" tok="$3" file dir tmp
  file="$(_gh_app_cache_file "${item}")"
  dir="${file%/*}"
  (umask 077 && mkdir -p "${dir}") || return 1
  chmod 700 "${dir}" || return 1
  tmp="$(umask 077 && mktemp "${dir}/.tmp.XXXXXX")" || return 1
  if ! printf '%s\n%s\n' "${exp}" "${tok}" >"${tmp}" || ! mv -f "${tmp}" "${file}"; then
    rm -f "${tmp}"
    return 1
  fi
}

_gh_app_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Write the PEM to $2. 1Password may flatten a pasted PEM onto one line: rebuild header, body at 64, footer.
_gh_app_write_pem() {
  local raw="$1" out="$2" kind body
  if [[ "${raw}" == *$'\n'* ]]; then
    printf '%s\n' "${raw}" >"${out}"
    return
  fi
  kind="$(sed -E 's/^-----BEGIN ([A-Z ]+)-----.*/\1/' <<<"${raw}")"
  body="$(sed -E 's/^-----BEGIN [A-Z ]+-----//; s/-----END [A-Z ]+-----$//' <<<"${raw}" | tr -d ' ')"
  {
    printf -- '-----BEGIN %s-----\n' "${kind}"
    fold -w 64 <<<"${body}"
    printf -- '-----END %s-----\n' "${kind}"
  } >"${out}"
}

# Mint a token for an item and cache it. Prints the token.
_gh_app_mint() {
  local item="$1" app_id inst_id raw keyfile now header payload sig jwt resp tok
  if ! app_id="$(op read "${item}/app_id" 2>/dev/null)" || [[ ! "${app_id}" =~ ^[0-9]+$ ]]; then
    _gh_app_err "cannot read app_id from ${item}"
    return 1
  fi
  if ! inst_id="$(op read "${item}/installation_id" 2>/dev/null)" || [[ ! "${inst_id}" =~ ^[0-9]+$ ]]; then
    _gh_app_err "cannot read installation_id from ${item}"
    return 1
  fi
  if ! raw="$(op read "${item}/private_key" 2>/dev/null)" || [[ "${raw}" != -----BEGIN* ]]; then
    _gh_app_err "cannot read a PEM private_key from ${item}"
    return 1
  fi
  keyfile="$(umask 077 && mktemp "${TMPDIR:-/tmp}/gh-app-key.XXXXXX")" || return 1
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | _gh_app_b64url)"
  # iat 60 s back for clock drift; exp 9 min ahead (GitHub caps a JWT at 10).
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "${app_id}" | _gh_app_b64url)"
  sig=""
  if _gh_app_write_pem "${raw}" "${keyfile}"; then
    sig="$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${keyfile}" 2>/dev/null | _gh_app_b64url)"
  fi
  rm -f "${keyfile}"
  raw=""
  if [[ -z "${sig}" ]]; then
    _gh_app_err "could not sign the App JWT (bad private_key in ${item}?)"
    return 1
  fi
  jwt="${header}.${payload}.${sig}"
  if ! resp="$(printf 'header = "Authorization: Bearer %s"\n' "${jwt}" | curl -fsS --max-time 30 -K - -X POST \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${inst_id}/access_tokens" 2>/dev/null)"; then
    _gh_app_err "GitHub refused the token request for installation ${inst_id}"
    return 1
  fi
  tok="$(jq -r '.token // empty' <<<"${resp}" 2>/dev/null)" || tok=""
  if [[ ! "${tok}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    _gh_app_err "the token response for installation ${inst_id} held no token"
    return 1
  fi
  _gh_app_write_cache "${item}" $((now + _GH_APP_TOKEN_LIFETIME)) "${tok}" \
    || _gh_app_err "warning: could not cache the token; the next call mints again"
  printf '%s\n' "${tok}"
}

_gh_app_token() {
  _gh_app_cached_token "$1" || _gh_app_mint "$1"
}

_gh_app_main() {
  local cmd="${1:-}" item="" spec repo rc=0 tok line host="" proto="" file exp now
  case "${cmd}" in
    route)
      repo="$(_gh_app_spec_repo "${2:-}")"
      [[ -n "${repo}" ]] || return 1
      _gh_app_route "${repo}"
      return
      ;;
    git-credential)
      item="${2:-}"
      # git sends key=value lines; answer only a get for https://github.com, and ignore store/erase.
      while IFS= read -r line && [[ -n "${line}" ]]; do
        case "${line}" in
          host=*) host="${line#host=}" ;;
          protocol=*) proto="${line#protocol=}" ;;
          *) ;;
        esac
      done
      [[ "${3:-}" == "get" ]] || return 0
      [[ "${proto}" == "https" && "${host}" == "github.com" && "${item}" == op://* ]] || return 0
      tok="$(_gh_app_token "${item}")" || return 1
      printf 'username=x-access-token\npassword=%s\n' "${tok}"
      return 0
      ;;
    check)
      repo="$(_gh_app_spec_repo "${2:-}")"
      item="$(_gh_app_route "${repo:-none}")" || rc=$?
      if ((rc != 0)); then
        file="$(_gh_app_routes_file)" || file="?"
        printf '%s: not routed (route file %s)\n' "${repo:-${2:-}}" "${file}"
        return "${rc}"
      fi
      _gh_app_token "${item}" >/dev/null || return 1
      file="$(_gh_app_cache_file "${item}")"
      exp="$(head -1 "${file}" 2>/dev/null)"
      now="$(date +%s)"
      printf '%s: routed to %s; token cached, %s min left\n' "${repo}" "${item}" "$(((${exp:-${now}} - now) / 60))"
      return 0
      ;;
    --item)
      item="${2:-}"
      shift 2 || true
      ;;
    "" | -h | --help)
      _gh_app_usage
      [[ -n "${cmd}" ]]
      return
      ;;
    *) ;;
  esac
  spec="${1:-}"
  if [[ -z "${spec}" || "${spec}" == */* ]]; then
    _gh_app_err "usage: gh-app-token.sh [--item <op-item>] <owner>"
    return 2
  fi
  if [[ -z "${item}" ]]; then
    spec="$(_gh_app_lower "${spec}")"
    item="$(_gh_app_route "owner:${spec}")" || {
      _gh_app_err "no route names owner '${spec}'"
      return 1
    }
  fi
  _gh_app_token "${item}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  _gh_app_main "$@"
  exit $?
fi
