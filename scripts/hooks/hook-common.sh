#!/usr/bin/env bash

# Shared helpers for Codex lifecycle hooks.

hook_resolve_cwd() {
  local input="${1:-}"
  local cwd

  # Accept the Codex cwd payload.
  cwd="$(printf '%s' "$input" | python3 -c 'import json, sys
try:
    j = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
print(j.get("cwd") or "")' 2>/dev/null)"
  [ -z "$cwd" ] && cwd="${CODEX_PROJECT_DIR:-}"
  [ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true
}

hook_load_branch_context() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  HOOK_BRANCH="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$HOOK_BRANCH" ] || return 1
  case "$HOOK_BRANCH" in main|master) return 1 ;; esac

  # Branches the PR rule does not apply to. EMPTY BY DEFAULT, and that is the
  # whole design: "every branch gets a PR" is only worth anything if the machine
  # cannot quietly decide a branch does not count. A pattern list guessed here
  # (`*-check`, `*-tmp`) would silently exempt `feat/add-health-check`, and the
  # branch that stops being enforced is exactly the one nobody notices.
  #
  # So the exemption is opt-in and per-shell: set the variable when you know the
  # branch is disposable. Space-separated shell globs, matched whole.
  #
  #   HARNESS_PR_SKIP_BRANCHES='scratch/* tmp/*' codex
  #
  # For the far more common accident — an integration branch whose commits you
  # already pushed somewhere else — you do not need this at all. That case is
  # caught automatically by hook_head_has_pr_elsewhere().
  local skip_pattern
  for skip_pattern in ${HARNESS_PR_SKIP_BRANCHES:-}; do
    # shellcheck disable=SC2254  # the glob is the point
    case "$HOOK_BRANCH" in $skip_pattern) return 1 ;; esac
  done

  HOOK_ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  [ -n "$HOOK_ORIGIN_URL" ] || return 1

  # owner/repo for ORIGIN specifically. Every gh call below must be pinned to
  # this, because bare `gh` picks a remote by its own precedence and prefers
  # `upstream` when one exists — so in a fork it answers about the PARENT repo.
  # Observed 2026-08-12 in Screddyice/retired router (a fork of ajsai47/retired router):
  # an open PR on origin was reported as "no open pull request", and the Stop
  # hook blocked every single stop with no way to satisfy it. The PR existed
  # the whole time; the hook was asking the wrong repository.
  #
  # Derived with awk rather than a non-greedy regex: BSD sed rejects `+?`.
  # Handles both https://host/owner/repo(.git) and git@host:owner/repo(.git).
  HOOK_REPO_SLUG="$(printf '%s' "$HOOK_ORIGIN_URL" \
    | sed -e 's|\.git$||' -e 's|:|/|g' \
    | awk -F/ 'NF>=2 {print $(NF-1)"/"$NF}')"

  # Passed as an ARRAY, never as an unquoted ${VAR:+--repo "$VAR"}. That form
  # depends on word-splitting an unquoted expansion, which bash does and zsh
  # does not — so it silently becomes the single argument `--repo owner/name`
  # and gh rejects it with "unknown flag". These files carry a bash shebang but
  # are also sourced, and a helper that only works under one shell is a trap.
  # Expanded at every call site as ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"},
  # not the plain "${HOOK_GH_REPO_ARGS[@]}". /bin/bash on macOS is 3.2, where an
  # EMPTY array expanded under `set -u` aborts with "unbound variable" — and
  # auto-pr-push.sh runs `set -uo pipefail`. A slug that fails to parse would
  # otherwise turn a cosmetic miss into a dead hook.
  HOOK_GH_REPO_ARGS=()
  [ -n "$HOOK_REPO_SLUG" ] && HOOK_GH_REPO_ARGS=(--repo "$HOOK_REPO_SLUG")

  HOOK_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$HOOK_TOP" ] || return 1
  HOOK_REPO_DIR="$(basename "$HOOK_TOP")"

  local repo_identity
  repo_identity="$(printf '%s %s' "$HOOK_ORIGIN_URL" "$HOOK_REPO_DIR" | tr '[:upper:]' '[:lower:]')"
  case "$repo_identity" in *rs21*) return 1 ;; esac

  # The integration branch THIS branch forked from -- not a guessed default.
  #
  # This used to take the first of main/master that existed, which is wrong two
  # different ways. A repo whose integration branch is something else (nebos-v2
  # deploys `dev`; teamnebula.ai defaults to `staging`) had its "commits ahead"
  # measured against a ref the work does not belong on, and because `gh pr create`
  # was called with no --base, the PR then targeted the repo DEFAULT -- a third
  # ref, agreeing with neither. teamnebula-ai/nebos-v2#365 opened against `main`
  # in a repo where every PR targets `dev`.
  #
  # Scored by TOTAL DIVERGENCE, not by commits ahead. Derived per branch, so one
  # repo can serve both a `dev` flow and a `main` flow.
  #
  # "Fewest commits ahead" is the obvious metric and it ties constantly: a branch
  # cut from `main` with one commit is 1 ahead of `main` AND 1 ahead of `dev`, so
  # the tie falls to list order and half the repos get the wrong answer.
  #
  # Divergence separates them, because it also counts what the candidate has that
  # we do not:
  #
  #                        ahead  behind  total
  #   cut from main:  main    1      0       1   <- forked here
  #                   dev     1      1       2
  #   cut from dev:   dev     1      0       1   <- forked here
  #                   main    2      0       2
  #
  # The fork point is the candidate we have diverged from least in both
  # directions, which is exactly what a human reads off the network graph.
  # Remote-tracking refs are scored ALONE whenever any exist, and local branch
  # names are a fallback for a repo that has none.
  #
  # Mixing the two tiers is a correctness bug, not a style choice. A local `main`
  # can be arbitrarily stale, and a stale ref looks CLOSER on divergence than the
  # remote one precisely when it matters most: after a squash merge, origin/main
  # carries a commit this branch lacks (+1 behind) while the untouched local main
  # does not, so the local ref wins the score and the "base already contains this
  # tree" guard stops firing. That guard is what stops a second PR being opened for
  # already-merged work, so losing it re-opens the llm-jury#18 duplicate.
  local ref default_ref candidates remote_candidates counts ahead behind total best_total
  default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  remote_candidates=""
  # Order is the tie-break, and only the tie-break: divergence decides outright
  # whenever the branch really did fork from one of these. Trunk leads, because a
  # tie means "equally far from both" and trunk is the safer place to aim then.
  # origin/HEAD is first so a repo whose default is not named here still wins.
  for ref in $default_ref origin/main origin/master origin/dev origin/develop origin/staging; do
    [ -n "$ref" ] || continue
    git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 && remote_candidates="$remote_candidates $ref"
  done
  if [ -n "$remote_candidates" ]; then
    candidates="$remote_candidates"
  else
    candidates="main master dev develop staging"
  fi

  HOOK_BASE=""
  best_total=""
  for ref in $candidates; do
    [ -n "$ref" ] || continue
    git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
    # "<behind>\t<ahead>": commits on ref we lack, then commits on HEAD it lacks.
    counts="$(git rev-list --left-right --count "${ref}...HEAD" 2>/dev/null || true)"
    [ -n "$counts" ] || continue
    behind="$(printf '%s' "$counts" | awk '{print $1}')"
    ahead="$(printf '%s' "$counts" | awk '{print $2}')"
    case "$behind$ahead" in ''|*[!0-9]*) continue ;; esac
    total=$((behind + ahead))
    if [ -z "$best_total" ] || [ "$total" -lt "$best_total" ]; then
      best_total="$total"
      HOOK_BASE="$ref"
    fi
  done
  [ -n "$HOOK_BASE" ] || return 1

  # The branch name a PR can target: refs/remotes/origin/dev -> dev.
  HOOK_BASE_BRANCH="${HOOK_BASE#origin/}"

  # Divergence found where the branch FORKED. That is not always where a PR may
  # LAND, and the two differ in exactly the repos that matter most. See
  # hook_resolve_pr_base.
  hook_resolve_pr_base

  HOOK_AHEAD="$(git rev-list --count "${HOOK_BASE}..HEAD" 2>/dev/null || echo 0)"
  [ "${HOOK_AHEAD:-0}" -gt 0 ] 2>/dev/null || return 1
  return 0
}

# Retarget onto the branch this one is stacked on, when there is one.
#
# The fork-point scorer only considers trunk and the integration branches, so a branch
# cut from another FEATURE branch scores dev or main and the PR then shows the parent's
# commits alongside its own. That is the "foreign commits" on nebos-v2 #531.
#
# The test is the oldest commit the PR would carry. A commit that another remote branch
# already contains is that branch's work, not this one's, so that branch is the base.
# Cheap on purpose: one --contains, then a count per surviving candidate, which is
# almost always zero or one.
#
# Leaves the base alone unless the candidate is strictly tighter, so a branch that
# forked straight off dev is untouched.
hook_tighten_base_to_parent() {
  local range_oldest candidate best best_ahead ahead self_ref
  self_ref="origin/$HOOK_BRANCH"

  range_oldest="$(git rev-list "${HOOK_BASE}..HEAD" 2>/dev/null | tail -1)"
  [ -n "$range_oldest" ] || return 0

  best=""
  best_ahead="$(git rev-list --count "${HOOK_BASE}..HEAD" 2>/dev/null || echo 0)"
  [ "${best_ahead:-0}" -gt 0 ] 2>/dev/null || return 0

  for candidate in $(git branch -r --contains "$range_oldest" --format='%(refname:short)' 2>/dev/null); do
    case "$candidate" in
      "$self_ref"|"$HOOK_BASE"|*HEAD) continue ;;
    esac
    # Only ever move FORWARD: the candidate must still leave this branch something of
    # its own to propose, or the PR would be empty.
    ahead="$(git rev-list --count "${candidate}..HEAD" 2>/dev/null || echo 0)"
    case "$ahead" in ''|*[!0-9]*) continue ;; esac
    [ "$ahead" -gt 0 ] || continue
    if [ "$ahead" -lt "$best_ahead" ]; then
      best_ahead="$ahead"
      best="$candidate"
    fi
  done

  [ -n "$best" ] || return 0
  HOOK_BASE="$best"
  HOOK_BASE_BRANCH="${best#origin/}"
  return 0
}

# Where a PR from this branch is allowed to LAND, which is not always where it forked.
#
# In a repo that keeps an integration branch, trunk is a deploy branch and takes work
# only after it has been through that branch. nebos-v2 says so outright in
# guard-main-base.yml: only `dev`, `promote/*` and `hotfix/*` may target `main`,
# because main and dev once forked 85/43 commits apart when nothing stopped PRs being
# opened against both. A branch cut from main — a stale checkout, a rebase onto the
# wrong ref — still scores main as its fork point, so the hook aimed there and CI
# rejected it on arrival: nebos-v2 #531 and #532, and #365 before them.
#
# Precedence, most specific first:
#   1. HOOK_PR_BASE in the environment — a one-off, or a wrapper that knows better.
#   2. .codex-harness/pr-base in the repo — the repo declaring its own policy, which
#      beats this hook inferring it.
#   3. The integration-branch rule below.
#
# A silent no-op for a repo with no integration branch, which is most of them.
hook_resolve_pr_base() {
  local declared integration fork_point
  declared="${HOOK_PR_BASE:-}"
  if [ -z "$declared" ] && [ -r .codex-harness/pr-base ]; then
    declared="$(tr -d '[:space:]' < .codex-harness/pr-base 2>/dev/null || true)"
  fi
  if [ -n "$declared" ]; then
    HOOK_BASE_BRANCH="$declared"
    git rev-parse --verify --quiet "origin/$declared" >/dev/null 2>&1 \
      && HOOK_BASE="origin/$declared"
    return 0
  fi

  # A branch stacked on another branch has no correct base in the candidate list
  # above, which only knows trunk and the integration branches. The fork-point score
  # then lands on dev or main, and the PR carries the PARENT branch's commits as its
  # own — three of them on nebos-v2 #531, ten on the branch behind #508.
  #
  # Detected from the OLDEST commit the PR would carry: if some other remote branch
  # already contains it, that commit is not this branch's work and that branch is the
  # real base. One `git branch -r --contains` rather than a count per remote, because
  # this runs after every Bash call and nebos-v2 carries ~50 branches.
  hook_tighten_base_to_parent

  # Only trunk is ever wrong this way. A branch already aimed at dev is aimed right.
  case "$HOOK_BASE_BRANCH" in
    main|master) ;;
    *) return 0 ;;
  esac

  # The escape hatches, matching guard-main-base.yml. release/* is included because a
  # release branch merging to trunk is the same shape of exception.
  case "$HOOK_BRANCH" in
    dev|develop|promote/*|hotfix/*|release/*) return 0 ;;
  esac

  # A same-tip integration branch is a harmless landing preference. Once the
  # integration branch diverges, do not retarget main-based work merely because
  # both refs share a fork point. Repositories with another landing policy can
  # declare it in .codex-harness/pr-base.
  for integration in dev develop; do
    git rev-parse --verify --quiet "origin/$integration" >/dev/null 2>&1 || continue
    [ "$(git rev-parse "origin/$integration")" = "$(git rev-parse "$HOOK_BASE")" ] || continue
    HOOK_BASE="origin/$integration"
    HOOK_BASE_BRANCH="$integration"
    return 0
  done
  return 0
}

# True when this branch's CURRENT head is exactly what a merged PR landed.
#
# A squash merge produces one commit on the base that is an ancestor of nothing
# on the branch, so HOOK_AHEAD stays > 0 forever, while the PR is MERGED rather
# than open and an --state open lookup returns nothing. The branch then looks
# identical to work that never had a PR, and the Stop hook blocks every stop with
# no action that can satisfy it — deleting the local branch is the only exit, and
# nothing tells you that. Observed 2026-08-12 on Screddyice/jarvis after #18
# squash-merged.
#
# Keyed on the head SHA, exactly as auto-pr-push.sh does for the same reason: a
# branch REUSED for new commits has a different HEAD, so it correctly still
# needs a PR rather than coasting on the old merge.
hook_branch_already_merged() {
  local head_oid merged_oid
  head_oid="$(git rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head_oid" ] || return 1

  merged_oid="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
    --head "$HOOK_BRANCH" --state merged \
    --json headRefOid --jq '.[0].headRefOid // empty' 2>/dev/null)"

  hook_head_within_merged "$head_oid" "$merged_oid"
}

# True when HEAD is the merged PR's head, or an ancestor of it.
#
# The ancestor case is a checkout that stopped pulling before the PR merged:
# the PR gained commits on the remote, landed, and this clone still sits on an
# older commit of the same branch. Everything it has is inside the merged head,
# so there is nothing to open, yet the exact-SHA test failed and the Stop hook
# demanded a PR it could never satisfy. Observed 2026-09-17 on
# teamnebula-ai/teamnebula.ai feat/fe-nebos-team-login, 25 commits behind its
# remote after #425 merged. Local objects only: if the merged head was never
# fetched this stays false rather than touching the network. A branch reused for
# new commits has a HEAD that is not an ancestor of the old merge, so it still
# needs its own PR.
hook_head_within_merged() {
  local head_oid="$1" merged_oid="$2"
  [ -n "$head_oid" ] && [ -n "$merged_oid" ] || return 1
  [ "$merged_oid" = "$head_oid" ] && return 0
  git cat-file -e "${merged_oid}^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$head_oid" "$merged_oid" 2>/dev/null
}

# True when THIS exact commit is already the head of a PR on another branch.
#
# The duplicate this prevents has nothing to do with merging. Push a local
# branch's HEAD to a *different* remote branch — `git push origin HEAD:feat/real`
# while sitting on a throwaway integration branch — and the work now has a PR,
# but under a name this checkout has never heard of. hook_branch_already_merged()
# cannot see it: that asks `--head "$HOOK_BRANCH"`, and the PR is on `feat/real`.
# So the auto-PR hook pushes the scratch name too and opens a second PR for
# commits already under review. Observed 2026-08-25 in Screddyice/retired router, where
# #51 and #52 appeared for the `pr47-check` and `pr44-check` branches used to
# test-merge #47 and #44.
#
# Keyed on the head SHA rather than the tree, matching the two guards that
# already exist. A branch that gains a NEW commit has a new HEAD and correctly
# needs its own PR, so this cannot strand real work behind a stale match.
#
# Searches open and merged PRs in one call. A CLOSED (unmerged) PR is deliberately
# not a match: that work was rejected, and rejected work has no review surface.
hook_head_has_pr_elsewhere() {
  local head_oid

  command -v gh >/dev/null 2>&1 || return 1
  head_oid="$(git rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head_oid" ] || return 1

  HOOK_PR_ELSEWHERE="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
    --state all --limit 100 \
    --json number,headRefName,headRefOid,state \
    --jq "[.[] | select(.headRefOid == \"$head_oid\")
             | select(.headRefName != \"$HOOK_BRANCH\")
             | select(.state != \"CLOSED\")][0]
          | if . then \"#\(.number) \(.headRefName)\" else empty end" 2>/dev/null)"

  # Shape-checked, not just non-empty. This guard SUPPRESSES a pull request, so
  # every way it can be wrong costs review coverage, and "gh printed something"
  # is not evidence a PR exists. A mocked or older gh answering an unrecognised
  # query with `0`, a deprecation notice on stdout, or a jq expression that stops
  # matching after a schema change would all read as a match and silently stop
  # proposing PRs for real work. Demand `#<number> <branch>` and treat anything
  # else as no match, so an unexpected answer fails toward opening the PR.
  case "${HOOK_PR_ELSEWHERE:-}" in
    '#'[0-9]*' '?*)
      case "${HOOK_PR_ELSEWHERE%% *}" in
        '#'*[!0-9#]*) HOOK_PR_ELSEWHERE="" ;;
      esac
      ;;
    *) HOOK_PR_ELSEWHERE="" ;;
  esac

  [ -n "${HOOK_PR_ELSEWHERE:-}" ]
}

hook_load_pr_status() {
  HOOK_PR_STATUS=""
  HOOK_PR_COUNT="0"

  if ! command -v gh >/dev/null 2>&1; then
    HOOK_PR_STATUS="gh_missing"
    return 0
  fi

  HOOK_PR_COUNT="$(gh pr list ${HOOK_GH_REPO_ARGS[@]+"${HOOK_GH_REPO_ARGS[@]}"} \
    --head "$HOOK_BRANCH" --state open --json number --jq 'length' 2>/dev/null)"
  if [ $? -ne 0 ]; then
    HOOK_PR_STATUS="gh_error"
  elif [ "${HOOK_PR_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    HOOK_PR_STATUS="has_pr"
  elif hook_branch_already_merged; then
    # Distinct from has_pr on purpose. "Landed already" and "has a review surface
    # open" are different facts, and a consumer that logs or reports should be
    # able to tell them apart.
    HOOK_PR_STATUS="merged_pr"
  elif hook_head_has_pr_elsewhere; then
    # Same commits, different branch name. HOOK_PR_ELSEWHERE names the PR so a
    # blocked stop can say WHERE the work is instead of demanding a second one.
    HOOK_PR_STATUS="pr_elsewhere"
  else
    HOOK_PR_STATUS="needs_pr"
  fi
}

# Humans whose CURRENT review state on this PR is CHANGES_REQUESTED.
#
# GitHub keeps a CHANGES_REQUESTED review in force until the same person
# APPROVES or the review is DISMISSED, so "latest state per person" is the only
# reading that matches what the merge box enforces. Counting raw review events
# instead would keep naming someone who has since approved.
#
# Bots are excluded. Re-requesting a review bot after its own auto-fix is a
# loop, not a review. The PR author is excluded by the caller, because a
# self-rejection re-requesting the author is a no-op GitHub rejects with 422.
#
# Sets HOOK_CHANGE_REQUESTERS to a space-separated list, empty when none.
hook_load_change_requesters() {
  HOOK_CHANGE_REQUESTERS=""
  [ -n "${HOOK_REPO_SLUG:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0

  HOOK_CHANGE_REQUESTERS="$(gh api --paginate \
    "repos/$HOOK_REPO_SLUG/pulls/$1/reviews" \
    --jq '.[] | select(.user.type != "Bot")
              | select(.user.login | endswith("[bot]") | not)
              | select(.state == "CHANGES_REQUESTED" or .state == "APPROVED" or .state == "DISMISSED")
              | "\(.user.login) \(.state)"' 2>/dev/null \
    | python3 -c '
import sys
latest = {}
for line in sys.stdin:
    parts = line.split()
    if len(parts) != 2:
        continue
    # Reviews arrive oldest-first, so the last write per login wins.
    latest[parts[0]] = parts[1]
print(" ".join(sorted(u for u, s in latest.items() if s == "CHANGES_REQUESTED")))' 2>/dev/null)"
}

hook_json_string() {
  local value="$1"
  VALUE="$value" python3 -c 'import json, os; print(json.dumps(os.environ["VALUE"]))'
}
