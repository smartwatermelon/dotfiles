#!/usr/bin/env bash
# ~/.config/bash/gh-app-token.sh
# shellcheck shell=bash

# GitHub App tokens for routed repos (claude-config#659). Design: dev-env specs/2026-10-01-agent-github-app-design.md
# The key comes from 1Password, or from the macOS login Keychain on a machine with no op vault (see --help).

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
  gh-app-token.sh repo <spec>
      Print <spec> as lowercase owner/repo; exit 1 if it names no github.com repo.
  gh-app-token.sh ensure <op-item>
      Mint or reuse the item's token without printing it. Exit 0 when a token is available.
  gh-app-token.sh git-credential <op-item> get
      git credential helper. Answers only https://github.com/<path> where <path> routes
      to <op-item>, so git must send path= (credential.useHttpPath=true).
  gh-app-token.sh check <spec>
      Show the route and how long its token has left, minting one if none is cached.
      Never prints the token.

Route file: $GH_APP_ROUTES_FILE, else gh-app-routes.conf beside this script's real
path. One route per line: owner/repo, a TAB, op://vault/item, then optionally
TAB-separated app_id=N and installation_id=N. Unlisted repos are not routed. Any
other trailing field makes the route malformed (exit 2), so a typo fails closed.

Sources: app_id and installation_id come from the route line's fields when present,
else from `op read <item>/<field>`. The private_key comes from `op read` first; if op
is missing or cannot read it, from the login Keychain: a generic password with
service = the item minus op://<vault>/ (op://Automation/my app -> "my app") and
account = the current user (id -un). security -w prints a multi-line PEM as hex;
that is decoded.

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

# Route value -> _GH_APP_ITEM, _GH_APP_FIELDS. 2 on a bad field. No arrays: bash 3.2 + set -u.
_gh_app_split() {
  local rest="$1" f
  while [[ "${rest}" == $'\t'* ]]; do rest="${rest#?}"; done
  _GH_APP_ITEM="${rest%%$'\t'*}"
  _GH_APP_FIELDS=""
  [[ "${rest}" == *$'\t'* ]] || return 0
  rest="${rest#*$'\t'}"
  while [[ -n "${rest}" ]]; do
    f="${rest%%$'\t'*}"
    if [[ "${rest}" == *$'\t'* ]]; then rest="${rest#*$'\t'}"; else rest=""; fi
    [[ -z "${f}" ]] && continue
    [[ "${f}" =~ ^(app_id|installation_id)=[0-9]+$ ]] || return 2
    _GH_APP_FIELDS+="${f}"$'\n'
  done
  return 0
}

# _gh_app_route <owner/repo | owner:NAME>: print the routed item. 0 routed, 1 not, 2 malformed (fail closed).
_gh_app_route() {
  local want="$1" file line key
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
    if [[ "${key}" == "${want}" || "owner:${key%%/*}" == "${want}" ]]; then
      if ! _gh_app_split "${line#*$'\t'}"; then
        _gh_app_err "route for ${key} in ${file} has a field that is not app_id=N or installation_id=N"
        return 2
      fi
      if [[ "${_GH_APP_ITEM}" != op://* ]]; then
        _gh_app_err "route for ${key} in ${file} does not name an op:// item"
        return 2
      fi
      printf '%s\n' "${_GH_APP_ITEM}"
      return 0
    fi
  done <"${file}"
  return 1
}

# <op-item> <name>: print the field from its route lines. 0 found, 1 none, 2 malformed or conflicting.
_gh_app_item_field() {
  local want="$1" name="$2" file line f val=""
  file="$(_gh_app_routes_file)"
  [[ -r "${file}" ]] || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# || "${line}" != *$'\t'* ]] && continue
    if ! _gh_app_split "${line#*$'\t'}"; then
      if [[ "${_GH_APP_ITEM}" == "${want}" ]]; then
        _gh_app_err "a route for ${want} in ${file} has a field that is not app_id=N or installation_id=N"
        return 2
      fi
      continue
    fi
    [[ "${_GH_APP_ITEM}" == "${want}" ]] || continue
    while IFS= read -r f; do
      [[ -n "${f}" && "${f%%=*}" == "${name}" ]] || continue
      if [[ -n "${val}" && "${val}" != "${f#*=}" ]]; then
        _gh_app_err "routes for ${want} in ${file} disagree on ${name}"
        return 2
      fi
      val="${f#*=}"
    done <<<"${_GH_APP_FIELDS}"
  done <"${file}"
  [[ -n "${val}" ]] || return 1
  printf '%s\n' "${val}"
}

# An ID for an item: the route line's field when present, else op read. Fails closed on a malformed field.
_gh_app_id() {
  local item="$1" name="$2" v rc=0
  v="$(_gh_app_item_field "${item}" "${name}")" || rc=$?
  ((rc == 2)) && return 2
  if ((rc != 0)); then
    v="$(_gh_app_op_read "${item}/${name}")" || return 1
  fi
  [[ "${v}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${v}"
}

_gh_app_op_read() {
  command -v op >/dev/null 2>&1 || return 1
  op read "$1" 2>/dev/null
}

# Keychain service for an item: the item with op://<vault>/ removed.
_gh_app_keychain_service() {
  local s="${1#op://}"
  printf '%s\n' "${s#*/}"
}

# Print the key from the login Keychain. security -w prints data with newlines as hex: decode it.
_gh_app_keychain_key() {
  local svc acct out
  command -v security >/dev/null 2>&1 || return 1
  svc="$(_gh_app_keychain_service "$1")"
  acct="$(id -un)" || return 1
  out="$(security find-generic-password -s "${svc}" -a "${acct}" -w 2>/dev/null)" || return 1
  if [[ "${out}" != -----BEGIN* && "${out}" =~ ^[0-9a-fA-F]+$ ]]; then
    out="$(xxd -r -p <<<"${out}")" || return 1
  fi
  printf '%s\n' "${out}"
  out=""
}

# Keyed on a hash of the whole item, so two items can never share a cache file.
_gh_app_cache_file() {
  local key
  key="$(printf '%s' "$1" | openssl dgst -sha256 -r)" || return 1
  key="${key%% *}"
  [[ "${key}" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s/gh-app-tokens/%s\n' "${XDG_CACHE_HOME:-${HOME}/.cache}" "${key}"
}

# Print the cached token for an item if it has more than the margin left.
_gh_app_cached_token() {
  local file exp="" tok="" now
  file="$(_gh_app_cache_file "$1")" || return 1
  [[ -f "${file}" && -O "${file}" ]] || return 1
  { IFS= read -r exp && IFS= read -r tok; } <"${file}" || return 1
  [[ "${exp}" =~ ^[0-9]+$ && "${tok}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  now="$(date +%s)"
  ((exp - now > _GH_APP_TOKEN_MARGIN)) || return 1
  printf '%s\n' "${tok}"
}

_gh_app_write_cache() {
  local item="$1" exp="$2" tok="$3" file dir tmp
  file="$(_gh_app_cache_file "${item}")" || return 1
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
  local item="$1" app_id inst_id raw keyfile now header payload sig jwt resp tok status msg rc=0 svc acct
  app_id="$(_gh_app_id "${item}" app_id)" || rc=$?
  if ((rc != 0)); then
    _gh_app_err "cannot read app_id from ${item} (route line or 1Password)"
    return "${rc}"
  fi
  inst_id="$(_gh_app_id "${item}" installation_id)" || rc=$?
  if ((rc != 0)); then
    _gh_app_err "cannot read installation_id from ${item} (route line or 1Password)"
    return "${rc}"
  fi
  # 1Password first; where op is missing or cannot read the item, the login Keychain.
  if ! raw="$(_gh_app_op_read "${item}/private_key")" || [[ "${raw}" != -----BEGIN* ]]; then
    if ! raw="$(_gh_app_keychain_key "${item}")" || [[ "${raw}" != -----BEGIN* ]]; then
      raw=""
      svc="$(_gh_app_keychain_service "${item}")" || svc="?"
      acct="$(id -un)" || acct="?"
      _gh_app_err "cannot read a PEM private_key from ${item} (1Password) or from the macOS Keychain" \
        "(service '${svc}', account '${acct}')"
      return 1
    fi
  fi
  keyfile="$(umask 077 && mktemp "${TMPDIR:-/tmp}/gh-app-key.XXXXXX")" || return 1
  trap 'rm -f "${keyfile}"; exit 130' INT TERM HUP
  now="$(date +%s)"
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | _gh_app_b64url)"
  # iat 60 s back for clock drift; exp 9 min ahead (GitHub caps a JWT at 10).
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "${app_id}" | _gh_app_b64url)"
  sig=""
  if _gh_app_write_pem "${raw}" "${keyfile}"; then
    sig="$(printf '%s.%s' "${header}" "${payload}" | openssl dgst -sha256 -sign "${keyfile}" 2>/dev/null | _gh_app_b64url)"
  fi
  rm -f "${keyfile}"
  trap - INT TERM HUP
  raw=""
  if [[ -z "${sig}" ]]; then
    _gh_app_err "could not sign the App JWT (bad private_key in ${item}?)"
    return 1
  fi
  jwt="${header}.${payload}.${sig}"
  # The status rides on the last line, so a 401 (bad key), a 404 (not installed) and no network read differently.
  if ! resp="$(printf 'header = "Authorization: Bearer %s"\n' "${jwt}" | curl -sS --max-time 30 -K - -X POST \
    -w '\n%{http_code}' -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/app/installations/${inst_id}/access_tokens")"; then
    _gh_app_err "could not reach GitHub to mint a token for installation ${inst_id}"
    return 1
  fi
  status="${resp##*$'\n'}"
  resp="${resp%$'\n'*}"
  if [[ "${status}" != 201 ]]; then
    msg="$(jq -r '.message // empty' <<<"${resp}" 2>/dev/null)" || msg=""
    _gh_app_err "GitHub answered HTTP ${status} for installation ${inst_id}: ${msg:-no message}"
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
  local cmd="${1:-}" item="" spec repo rc=0 tok line host="" proto="" path="" file exp now
  case "${cmd}" in
    route)
      repo="$(_gh_app_spec_repo "${2:-}")"
      [[ -n "${repo}" ]] || return 1
      _gh_app_route "${repo}"
      return
      ;;
    repo)
      repo="$(_gh_app_spec_repo "${2:-}")"
      [[ -n "${repo}" ]] || return 1
      printf '%s\n' "${repo}"
      return 0
      ;;
    ensure)
      [[ "${2:-}" == op://* ]] || return 2
      _gh_app_token "$2" >/dev/null
      return
      ;;
    git-credential)
      item="${2:-}"
      # Answer only a get for https://github.com/<path> whose repo routes to this item; ignore store/erase.
      while IFS= read -r line && [[ -n "${line}" ]]; do
        case "${line}" in
          host=*) host="${line#host=}" ;;
          protocol=*) proto="${line#protocol=}" ;;
          path=*) path="${line#path=}" ;;
          *) ;;
        esac
      done
      [[ "${3:-}" == "get" ]] || return 0
      [[ "${proto}" == "https" && "${host}" == "github.com" && "${item}" == op://* ]] || return 0
      # The git wrapper sets credential.useHttpPath, so git sends path=; without it, refuse rather than guess.
      repo="$(_gh_app_spec_repo "${path}")"
      [[ -n "${repo}" ]] || return 0
      spec="$(_gh_app_route "${repo}" 2>/dev/null)" || return 0
      [[ "${spec}" == "${item}" ]] || return 0
      tok="$(_gh_app_token "${item}")" || return 1
      printf 'username=x-access-token\npassword=%s\n' "${tok}"
      return 0
      ;;
    check)
      repo="$(_gh_app_spec_repo "${2:-}")"
      item="$(_gh_app_route "${repo:-none}")" || rc=$?
      if ((rc != 0)); then
        file="$(_gh_app_routes_file)" || file="?"
        [[ "${rc}" -eq 2 ]] && printf '%s: malformed route (route file %s)\n' "${repo}" "${file}" && return 2
        printf '%s: not routed (route file %s)\n' "${repo:-${2:-}}" "${file}"
        return "${rc}"
      fi
      _gh_app_token "${item}" >/dev/null || return 1
      file="$(_gh_app_cache_file "${item}")" || return 1
      exp="$(head -1 "${file}" 2>/dev/null)" || exp=""
      now="$(date +%s)"
      if [[ "${exp}" =~ ^[0-9]+$ ]]; then
        printf '%s: routed to %s; token cached, %s min left\n' "${repo}" "${item}" "$(((exp - now) / 60))"
      else
        printf '%s: routed to %s; token minted but not cached (each call mints)\n' "${repo}" "${item}"
      fi
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
