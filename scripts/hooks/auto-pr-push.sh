#!/usr/bin/env bash

# Shared PostToolUse hook. Pushes work branches for owned GitHub organizations
# and opens a draft pull request when the branch has no open PR.

set -uo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=hook-common.sh
. "$script_dir/hook-common.sh"

log_dir="${HARNESS_HOOK_LOG_DIR:-$HOME/.cache/codex-harness}"
log="$log_dir/auto-pr-push.log"
# Failures only. The main log is append-only across every repo on the machine
# and interleaves raw git/gh output; by 2026-08-14 it was 30k lines, which is
# where a rejected push went unnoticed for a full day. One line per failure,
# nothing else, so `cat` answers "did anything not make it to GitHub?".
faillog="$log_dir/auto-pr-push-failures.log"
allowed_owners="${HARNESS_PR_OWNERS:-}"
[ -n "$allowed_owners" ] || exit 0

input="$(cat 2>/dev/null || true)"
hook_resolve_cwd "$input"
hook_load_branch_context || exit 0

owner="$(printf '%s' "$HOOK_ORIGIN_URL" \
  | sed -E 's#^git@[^:]+:##; s#^ssh://git@[^/]+/##; s#^https?://[^/]+/##' \
  | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
[ -n "$owner" ] || exit 0
case " $allowed_owners " in
  *" $owner "*) : ;;
  *) exit 0 ;;
esac

gitdir="$(git rev-parse --git-dir 2>/dev/null || echo .git)"
if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] \
   || [ -f "$gitdir/MERGE_HEAD" ] || [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then
  exit 0
fi

lock_key="$(printf '%s#%s' "$HOOK_TOP" "$HOOK_BRANCH" | tr '/ .' '___')"
lockdir="${TMPDIR:-/tmp}/autoprpush-${lock_key}.lock"
mkdir "$lockdir" 2>/dev/null || exit 0
mkdir -p "$log_dir" 2>/dev/null || { rmdir "$lockdir" 2>/dev/null; exit 0; }

(
  trap 'rmdir "$lockdir" 2>/dev/null' EXIT
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Guards against re-proposing work that has already landed.
  #
  # The PR check below asks for `--state open`. After a SQUASH merge the PR for
  # this branch is MERGED rather than open, so that count comes back 0 and the
  # hook opens a second PR for work already on the base -- while the push above
  # re-creates the remote branch the merge just deleted. Squash-merged commits
  # are not ancestors of the base, so HOOK_AHEAD stays > 0 and cannot catch it
  # either. Observed live on 2026-07-31: Screddyice/llm-jury#18 appeared ten
  # seconds after #17 squash-merged, with an empty diff against main.
  head_oid="$(git rev-parse HEAD 2>/dev/null || true)"

  # (a) Local and free: the base already contains this exact tree. Only fires
  #     once the local base ref has caught up, so it is the cheap case, not the
  #     load-bearing one.
  if [ -n "${HOOK_BASE:-}" ] && git diff --quiet "$HOOK_BASE" HEAD 2>/dev/null; then
    printf '%s [skip] %s@%s adds nothing over %s (already landed)\n' \
      "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$HOOK_BASE" >>"$log" 2>&1
    exit 0
  fi

  # (b) This exact commit was already merged. Load-bearing for the race above,
  #     where the local base ref is still pre-merge so (a) cannot see it yet.
  #     Keyed on the merged head SHA, so a branch reused for NEW commits has a
  #     different HEAD and correctly proceeds to a fresh PR.
  if [ -n "$head_oid" ]; then
    merged_oid="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
      --head "$HOOK_BRANCH" --state merged \
      --json headRefOid --jq '.[0].headRefOid // empty' 2>>"$log")"
    if hook_head_within_merged "$head_oid" "${merged_oid:-}"; then
      printf '%s [skip] %s@%s already merged as %s\n' \
        "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$(printf '%.12s' "$merged_oid")" >>"$log" 2>&1
      exit 0
    fi
  fi

  # (c) These exact commits are already under review on a DIFFERENT branch,
  #     which happens whenever HEAD was pushed somewhere other than the branch
  #     currently checked out. Checked before the push, not just before
  #     `gh pr create`: pushing would publish a redundant remote branch that the
  #     Stop hook then demands a PR for, so skipping only the create leaves the
  #     duplicate half-made.
  if hook_head_has_pr_elsewhere; then
    printf '%s [skip] %s@%s head already under review as %s\n' \
      "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$HOOK_PR_ELSEWHERE" >>"$log" 2>&1
    exit 0
  fi

  if [ "${AUTO_PR_PUSH_DRYRUN:-0}" = "1" ]; then
    printf '%s [DRYRUN] %s@%s (owner=%s, base=%s, ahead=%s) -> would push + ensure draft PR --base %s\n' \
      "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$owner" "$HOOK_BASE_BRANCH" "$HOOK_AHEAD" \
      "$HOOK_BASE_BRANCH" >>"$log" 2>&1
    exit 0
  fi

  # Check the push. This used to be a bare `git push …` whose exit status was
  # discarded, after which the tail of this function reported `[ok] pushed`
  # unconditionally. A rejected push therefore produced this, verbatim, in the
  # log on 2026-08-14:
  #
  #   ! [rejected]  HEAD -> feat/be-icp-scoring-rubric (non-fast-forward)
  #   error: failed to push some refs to …/nebos-v2.git
  #   [ok] pushed nebos-v2@feat/be-icp-scoring-rubric (PR already open)
  #
  # Nothing reached GitHub and the log said it had. That is the worst shape a
  # failure can take: the one place you would look to check reassures you.
  push_output="$(git push -u origin "HEAD:$HOOK_BRANCH" 2>&1)"
  push_rc=$?
  printf '%s\n' "$push_output" >>"$log" 2>&1

  if [ "$push_rc" -ne 0 ]; then
    # Name the likely cause. "push failed" alone sends you to a 30,000-line log
    # to find out which of several very different problems you have.
    detail="git push exited $push_rc"
    case "$push_output" in
      *non-fast-forward*|*"tip of your current branch is behind"*)
        detail="REJECTED (non-fast-forward) — origin/$HOOK_BRANCH has commits this checkout does not, so nothing was uploaded. Reconcile with 'git pull --rebase origin $HOOK_BRANCH' before trusting any PR on this branch" ;;
      *"Permission denied"*|*"denied to"*|*403*)
        detail="REJECTED — no write access to $HOOK_REPO_SLUG" ;;
      *"could not read Username"*|*"Authentication failed"*|*"Invalid username or password"*)
        detail="FAILED — git has no usable credentials for $HOOK_REPO_SLUG" ;;
      *"Could not resolve host"*|*"unable to access"*|*"Connection refused"*)
        detail="FAILED — network unreachable" ;;
      *"protected branch"*|*"pre-receive hook declined"*)
        detail="REJECTED by a server-side rule" ;;
    esac

    printf '%s [FAIL] %s@%s %s\n' \
      "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$detail" >>"$log" 2>&1
    # Also to a short, dedicated file. The main log interleaves raw git and gh
    # output across every repo on the machine, so a failure in it is findable
    # only if you already suspect one.
    printf '%s %s@%s %s\n' \
      "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" "$detail" >>"$faillog" 2>&1
    exit 1
  fi

  pr_count="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
    --head "$HOOK_BRANCH" --state open --json number --jq 'length' 2>>"$log")"
  if [ "${pr_count:-0}" = "0" ]; then
    # --base is explicit on purpose. Omitting it let GitHub fall back to the repo
    # DEFAULT branch, which is a different ref from the one HOOK_AHEAD was measured
    # against -- so the precondition and the PR disagreed (nebos-v2#365).
    if gh pr create ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
      --draft --fill --head "$HOOK_BRANCH" --base "$HOOK_BASE_BRANCH" >>"$log" 2>&1; then
      printf '%s [ok] opened draft PR for %s@%s\n' "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$log" 2>&1
    else
      # Reachable now only with a genuinely successful push, so this message can
      # finally claim it. It could not before.
      printf '%s [FAIL] %s@%s pushed, but gh pr create failed — branch is on GitHub with no PR\n' \
        "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$log" 2>&1
      printf '%s %s@%s pushed, but gh pr create failed — branch is on GitHub with no PR\n' \
        "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$faillog" 2>&1
    fi
  else
    printf '%s [ok] pushed %s@%s (PR already open)\n' "$timestamp" "$HOOK_REPO_DIR" "$HOOK_BRANCH" >>"$log" 2>&1

    # Put a fixed PR back in front of the person who rejected it.
    #
    # GitHub does not clear CHANGES_REQUESTED when the author pushes a fix, and
    # it does not re-notify the reviewer either. So the PR sits: the work is
    # done, the review request is spent, and nothing on either side says so.
    # On 2026-08-31 a sweep of the teamnebula-ai org found ELEVEN PRs holding
    # CHANGES_REQUESTED, and roughly two thirds of them had already been fixed
    # in an earlier session and were waiting on nothing but this call.
    #
    # Deliberately narrow, because a review request is a notification to a
    # person:
    #   * only the reviewers whose CURRENT state is CHANGES_REQUESTED, not the
    #     default roster. A rejection is a conversation with one person; routing
    #     the fix elsewhere makes someone else re-derive context that reviewer
    #     already has, and leaves the original request looking ignored.
    #   * never the PR author. GitHub 422s a self-request, and a self-rejection
    #     would otherwise ping Shawn about his own branch.
    #   * once per head SHA. This hook fires after every Bash call, so without
    #     the stamp a single session would re-notify on every no-op push.
    pr_meta="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
      --head "$HOOK_BRANCH" --state open --json number,author,headRefOid \
      --jq '.[0] | "\(.number) \(.author.login) \(.headRefOid)"' 2>>"$log")"
    set -- ${pr_meta:-}
    pr_num="${1:-}"; pr_author="${2:-}"; pr_head="${3:-}"

    stamp="$log_dir/rerequested-$(printf '%s' "$HOOK_REPO_SLUG" | tr '/' '_')-${pr_num}-${pr_head}"
    if [ -n "$pr_num" ] && [ -n "$pr_head" ] && [ ! -f "$stamp" ]; then
      hook_load_change_requesters "$pr_num"
      to_request=""
      for who in ${HOOK_CHANGE_REQUESTERS:-}; do
        [ "$who" = "$pr_author" ] && continue
        to_request="$to_request $who"
      done

      if [ -n "$to_request" ]; then
        args=()
        for who in $to_request; do args+=(-f "reviewers[]=$who"); done
        if gh api -X POST "repos/$HOOK_REPO_SLUG/pulls/$pr_num/requested_reviewers" \
          "${args[@]}" --silent >>"$log" 2>&1; then
          : > "$stamp"
          printf '%s [ok] re-requested review on %s#%s from%s (fix pushed over CHANGES_REQUESTED)\n' \
            "$timestamp" "$HOOK_REPO_SLUG" "$pr_num" "$to_request" >>"$log" 2>&1
        else
          # Loud, because the silent version of this failure is the whole bug:
          # a fixed PR that nobody has been told about looks identical to one
          # nobody has fixed.
          printf '%s %s#%s fix pushed over CHANGES_REQUESTED but re-request FAILED for%s — the reviewer has not been told\n' \
            "$timestamp" "$HOOK_REPO_SLUG" "$pr_num" "$to_request" >>"$faillog" 2>&1
        fi
      fi
    fi
  fi
) >/dev/null 2>&1 &
disown 2>/dev/null || true

exit 0
