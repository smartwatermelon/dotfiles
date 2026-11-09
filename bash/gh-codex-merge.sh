#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced only for Codex merges by gh-wrapper.sh, after App identity routing.
# Authorize one immediate merge of a live, human-approved GitHub PR head.

_gh_codex_merge_block() {
  echo "[gh] Codex merge blocked: $*" >&2
  return 1
}

_gh_codex_merge_authorize() {
  local repo="" url_repo="" number="" method="" expected="" delete_branch=0 stage=0 arg value
  local -a original=("$@")
  # A small explicit command grammar avoids accidentally authorizing another
  # repo, an interactive selection, an override, or a future auto-merge.
  while (($#)); do
    arg="$1"
    shift
    case "${arg}" in
      -R | --repo | --match-head-commit)
        (($#)) || {
          _gh_codex_merge_block "${arg} needs a value."
          return 1
        }
        value="$1"
        shift
        [[ -n "${value}" ]] || {
          _gh_codex_merge_block "${arg} needs a nonempty value."
          return 1
        }
        if [[ "${arg}" == --match-head-commit ]]; then
          [[ -z "${expected}" ]] || {
            _gh_codex_merge_block 'Duplicate head constraint.'
            return 1
          }
          expected="${value}"
        else
          [[ -z "${repo}" ]] || {
            _gh_codex_merge_block 'Duplicate repository selector.'
            return 1
          }
          repo="${value}"
        fi
        ;;
      --repo=* | -R?*)
        [[ -z "${repo}" ]] || {
          _gh_codex_merge_block 'Duplicate repository selector.'
          return 1
        }
        [[ "${arg}" == --repo=* ]] && repo="${arg#--repo=}" || repo="${arg:2}"
        [[ -n "${repo}" ]] || {
          _gh_codex_merge_block 'Repository selector is empty.'
          return 1
        }
        ;;
      --match-head-commit=*)
        [[ -z "${expected}" ]] || {
          _gh_codex_merge_block 'Duplicate head constraint.'
          return 1
        }
        expected="${arg#*=}"
        [[ -n "${expected}" ]] || {
          _gh_codex_merge_block 'Head constraint is empty.'
          return 1
        }
        ;;
      --squash | -s | --merge | -m | --rebase | -r)
        [[ -z "${method}" ]] || {
          _gh_codex_merge_block 'Select exactly one merge method.'
          return 1
        }
        case "${arg}" in
          --squash | -s) method=--squash ;;
          --merge | -m) method=--merge ;;
          --rebase | -r) method=--rebase ;;
          *) return 1 ;;
        esac
        ;;
      --delete-branch | -d) delete_branch=1 ;;
      -*)
        _gh_codex_merge_block "Unsupported merge option: ${arg}. Admin/auto modes are not authorized."
        return 1
        ;;
      *)
        if [[ "${stage}" == 0 && "${arg}" == pr ]]; then
          stage=1
        elif [[ "${stage}" == 1 && "${arg}" == merge ]]; then
          stage=2
        elif [[ "${stage}" == 2 && -z "${number}" ]]; then
          if [[ "${arg}" =~ ^[1-9][0-9]*$ ]]; then
            number="${arg}"
          elif [[ "${arg}" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/pull/([1-9][0-9]*)/?$ ]]; then
            url_repo="${BASH_REMATCH[1]}"
            number="${BASH_REMATCH[2]}"
          else
            _gh_codex_merge_block 'Use an explicit PR number or canonical github.com PR URL.'
            return 1
          fi
        else
          _gh_codex_merge_block 'Ambiguous merge command.'
          return 1
        fi
        ;;
    esac
  done
  if [[ "${stage}" != 2 || -z "${number}" || -z "${method}" ]]; then
    _gh_codex_merge_block 'Use: gh pr merge NUMBER --repo OWNER/REPO --squash (or --merge/--rebase).'
    return 1
  fi
  if [[ -n "${expected}" && ! "${expected}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    _gh_codex_merge_block 'The head constraint must be a full commit SHA.'
    return 1
  fi
  if [[ -n "${repo}" ]]; then
    repo="$(_gh_wrapper_norm_repo "${repo}")"
    [[ -n "${repo}" ]] || {
      _gh_codex_merge_block 'Invalid github.com repository.'
      return 1
    }
  fi
  if [[ -n "${url_repo}" ]]; then
    url_repo="${url_repo,,}"
    [[ -z "${repo}" || "${repo}" == "${url_repo}" ]] || {
      _gh_codex_merge_block 'PR URL and repository disagree.'
      return 1
    }
    repo="${url_repo}"
  fi
  if [[ -z "${repo}" ]]; then
    repo="$(_gh_wrapper_norm_repo "$(_gh_wrapper_resolve_target "${original[@]}")")"
  fi
  [[ -n "${repo}" ]] || {
    _gh_codex_merge_block 'Cannot resolve the target repository.'
    return 1
  }
  # The same selected installation token is used for every read and the merge.
  # No personal-token fallback can supply the second key.
  if [[ "${_gh_wrapper_token_var:-}" != _gh_wrapper_app_token || -z "${_gh_wrapper_app_token:-}" ]]; then
    _gh_codex_merge_block 'The repository must use an existing GitHub App route; personal-token merges are not authorized.'
    return 1
  fi
  command -v jq >/dev/null || {
    _gh_codex_merge_block 'jq is required.'
    return 1
  }
  local real_gh human permission pr head base rules reviews checks latest branch
  real_gh="$(_gh_wrapper_find_real_gh)" || return 1
  human="$(_gh_wrapper_identity_for_owner "${repo%%/*}")"
  [[ -n "${human}" ]] || {
    _gh_codex_merge_block 'No routed human reviewer.'
    return 1
  }
  if ! permission="$(_gh_wrapper_real_gh_selected "${real_gh}" api --hostname github.com --method GET \
    "repos/${repo}/collaborators/${human}/permission")" \
    || ! jq -e --arg human "${human,,}" '
      (.user.login | ascii_downcase) == $human and .user.type == "User"
      and (.permission == "write" or .permission == "admin")
    ' <<<"${permission}" >/dev/null; then
    _gh_codex_merge_block "Cannot confirm ${human} has current write permission."
    return 1
  fi
  local fields=number,url,state,isDraft,headRefOid,baseRefName,reviewDecision,mergeable,mergeStateStatus
  if ! pr="$(_gh_wrapper_real_gh_selected "${real_gh}" pr view "${number}" --repo "github.com/${repo}" --json "${fields}")"; then
    _gh_codex_merge_block 'Cannot read PR state.'
    return 1
  fi
  if ! jq -e --arg url "https://github.com/${repo}/pull/${number}" --argjson number "${number}" '
    type == "object" and .number == $number and (.url | ascii_downcase) == $url
    and .state == "OPEN" and .isDraft == false and .reviewDecision == "APPROVED"
    and .mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN"
    and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))
    and (.baseRefName | type == "string" and length > 0)
  ' <<<"${pr}" >/dev/null; then
    _gh_codex_merge_block 'PR is not open, ready, approved, and cleanly mergeable.'
    return 1
  fi
  head="$(jq -r '.headRefOid' <<<"${pr}")"
  base="$(jq -r '.baseRefName' <<<"${pr}")"
  if [[ -n "${expected}" && "${expected,,}" != "${head}" ]]; then
    _gh_codex_merge_block 'Requested head differs from the live PR head.'
    return 1
  fi
  branch="$(jq -rn --arg branch "${base}" '$branch | @uri')"
  if ! rules="$(_gh_wrapper_real_gh_selected "${real_gh}" api --hostname github.com --method GET \
    "repos/${repo}/rules/branches/${branch}?per_page=100" --paginate --slurp)"; then
    _gh_codex_merge_block 'Cannot read active branch rules.'
    return 1
  fi
  # Server enforcement closes approval-withdrawal races between preflight and
  # merge. Missing protection is not a reason to fall back to local checks.
  if ! jq -e '
    type == "array" and length > 0 and all(.[]; type == "array")
    and any(.[][]; .type == "pull_request"
      and (.parameters.required_approving_review_count | type == "number" and . >= 1)
      and .parameters.require_last_push_approval == true)
  ' <<<"${rules}" >/dev/null; then
    _gh_codex_merge_block 'Active rules must require approval and approval of the last push.'
    return 1
  fi
  if ! reviews="$(_gh_wrapper_real_gh_selected "${real_gh}" api --hostname github.com --method GET \
    "repos/${repo}/pulls/${number}/reviews?per_page=100" --paginate --slurp)"; then
    _gh_codex_merge_block 'Cannot read complete review history.'
    return 1
  fi
  if ! jq -e --arg human "${human,,}" --arg head "${head}" '
    type == "array" and length > 0 and all(.[]; type == "array") and
    ([.[][] | select((.user.login | ascii_downcase) == $human and .user.type == "User")
      | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
      | sort_by(.submitted_at, .id) | last
      | .state == "APPROVED" and .commit_id == $head
        and (.submitted_at | type == "string" and length > 0))
  ' <<<"${reviews}" >/dev/null; then
    _gh_codex_merge_block "${human} must have an undismissed approval of head ${head}."
    return 1
  fi
  if ! checks="$(_gh_wrapper_real_gh_selected "${real_gh}" pr checks "${number}" --repo "github.com/${repo}" \
    --required --json name,bucket,state)"; then
    _gh_codex_merge_block 'Required checks are unavailable, pending, or failing.'
    return 1
  fi
  if ! jq -e 'type == "array" and length > 0
    and all(.[]; (.name | type == "string" and length > 0) and .bucket == "pass")' <<<"${checks}" >/dev/null; then
    _gh_codex_merge_block 'Required checks must be present and every required check must pass.'
    return 1
  fi
  if ! latest="$(_gh_wrapper_real_gh_selected "${real_gh}" pr view "${number}" --repo "github.com/${repo}" --json "${fields}")" \
    || ! jq -e --arg head "${head}" --arg base "${base}" --argjson number "${number}" \
      --arg url "https://github.com/${repo}/pull/${number}" '
      .number == $number and (.url | ascii_downcase) == $url
      and .headRefOid == $head and .baseRefName == $base and .state == "OPEN"
      and .isDraft == false and .reviewDecision == "APPROVED"
      and .mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN"
    ' <<<"${latest}" >/dev/null; then
    _gh_codex_merge_block 'PR state changed during authorization; refresh and review before retrying.'
    return 1
  fi
  # Consumed by the caller in gh-wrapper.sh through Bash dynamic scope.
  # shellcheck disable=SC2034
  _gh_wrapper_codex_merge_args=(pr merge "${number}" --repo "github.com/${repo}" "${method}" --match-head-commit "${head}")
  [[ "${delete_branch}" == 1 ]] && _gh_wrapper_codex_merge_args+=(--delete-branch)
  echo "[gh] Codex merge authorized: ${repo}#${number}, human ${human}, head ${head}." >&2
}
