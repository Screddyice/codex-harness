#!/usr/bin/env bash

# Find your open pull requests that a human has rejected, and say which of them
# are actually waiting on work.
#
# WHY THIS EXISTS
#
# `gh search prs` cannot filter or return `reviewDecision` — the field is not in
# its schema, and a GraphQL search that reaches for it alongside `reviews` and
# `statusCheckRollup` times out on a few dozen PRs. So the working shape is:
# search for the repositories cheaply, then ask each repository separately.
#
# WHAT IT TELLS YOU THAT `gh pr list` DOES NOT
#
# `CHANGES_REQUESTED` is not a to-do item. GitHub keeps that state in force
# until the same reviewer approves or the review is dismissed, so a PR whose fix
# landed weeks ago still reads exactly like one nobody has touched. On
# 2026-08-31 a sweep of teamnebula-ai found eleven rejected PRs, and roughly two
# thirds of them were already fixed — they were waiting on a re-request, not on
# code. Two sessions also independently wrote the same fix for one of them,
# because neither could see that the work was done.
#
# So each PR is classified by what happened AFTER the rejection:
#
#   needs-work    no commits since the rejection. Real work is outstanding.
#   fixed?        commits landed after it, but the rejecter has not been asked
#                 to look again. Read the diff before rewriting anything.
#   resubmitted   commits landed and the rejecter has a live review request.
#                 Waiting on them, not on you.
#
# `fixed?` keeps its question mark on purpose: commits after a rejection are
# evidence that someone worked, not proof they addressed the review.
#
# Usage:
#   rejected-prs.sh                 # your open PRs, every repo
#   rejected-prs.sh teamnebula-ai   # limit to one owner
#   rejected-prs.sh --author noya   # someone else's PRs

set -uo pipefail

author="@me"
owner_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --author) author="${2:-@me}"; shift 2 ;;
    -h|--help) sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) owner_filter="$1"; shift ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "rejected-prs: gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "rejected-prs: gh is not authenticated" >&2; exit 1; }

# Step 1 — which repositories have open PRs at all. Search is fine for this and
# is one request; it just cannot answer the review question.
repos="$(gh search prs --author="$author" --state=open --limit 500 \
  --json repository --jq '.[].repository.nameWithOwner' 2>/dev/null | sort -u)"
[ -n "$repos" ] || { echo "No open pull requests found for $author."; exit 0; }
if [ -n "$owner_filter" ]; then
  repos="$(printf '%s\n' "$repos" | grep -i "^${owner_filter}/" || true)"
  [ -n "$repos" ] || { echo "No open pull requests under '$owner_filter'."; exit 0; }
fi

printf '%-34s %-6s %-12s %-22s %s\n' REPO PR STATE REJECTED-BY TITLE
printf '%.0s-' $(seq 1 110); printf '\n'

total=0; needs_work=0; fixed=0; resubmitted=0

for repo in $repos; do
  # Step 2 — reviewDecision, per repository. This is the part search cannot do.
  rejected="$(gh pr list --repo "$repo" --author "$author" --state open --limit 100 \
    --json number,title,reviewDecision,reviewRequests \
    --jq '.[] | select(.reviewDecision == "CHANGES_REQUESTED")
              | "\(.number)\t\([.reviewRequests[].login] | join(","))\t\(.title)"' 2>/dev/null)"
  [ -n "$rejected" ] || continue

  while IFS="$(printf '\t')" read -r num pending title; do
    [ -n "$num" ] || continue
    total=$((total + 1))

    # Latest state per human reviewer. Counting raw review events instead would
    # keep naming someone who has since approved, because GitHub records every
    # submission rather than replacing the previous one.
    standing="$(gh api --paginate "repos/$repo/pulls/$num/reviews" \
      --jq '.[] | select(.user.type != "Bot")
                | select(.user.login | endswith("[bot]") | not)
                | select(.state == "CHANGES_REQUESTED" or .state == "APPROVED" or .state == "DISMISSED")
                | "\(.user.login)\t\(.state)\t\(.submitted_at)"' 2>/dev/null \
      | python3 -c '
import sys
latest = {}
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3:
        continue
    latest[parts[0]] = (parts[1], parts[2])
who = sorted(u for u, (s, _) in latest.items() if s == "CHANGES_REQUESTED")
when = max((t for u, (s, t) in latest.items() if s == "CHANGES_REQUESTED"), default="")
print("\t".join([",".join(who), when]))' 2>/dev/null)"

    rejecters="$(printf '%s' "$standing" | cut -f1)"
    since="$(printf '%s' "$standing" | cut -f2)"
    # reviewDecision said CHANGES_REQUESTED, so an empty set here means the
    # rejection is a bot's or the API disagreed. Show it rather than hide it.
    [ -n "$rejecters" ] || rejecters="(bot/unknown)"

    state="needs-work"
    if [ -n "$since" ]; then
      # Commits authored onto the PR after the review was submitted.
      # The timestamp goes through the environment, not `--arg`: `gh api` has
      # no --arg flag, and passing one made jq read "$since" as a filter and
      # return nothing — which reads as "no commits since the review" and
      # classified every fixed PR as needing work.
      newer="$(SINCE="$since" gh api "repos/$repo/pulls/$num/commits" --paginate \
        --jq '[.[] | select(.commit.committer.date > env.SINCE)] | length' 2>/dev/null \
        | awk '{t += $1} END {print t + 0}')"
      if [ "${newer:-0}" -gt 0 ] 2>/dev/null; then
        # Is any rejecter currently holding a live review request?
        state="fixed?"
        for r in $(printf '%s' "$rejecters" | tr ',' ' '); do
          case ",$pending," in *",$r,"*) state="resubmitted"; break ;; esac
        done
      fi
    fi

    case "$state" in
      needs-work)  needs_work=$((needs_work + 1)) ;;
      "fixed?")    fixed=$((fixed + 1)) ;;
      resubmitted) resubmitted=$((resubmitted + 1)) ;;
    esac

    printf '%-34s #%-5s %-12s %-22s %.44s\n' "$repo" "$num" "$state" "$rejecters" "$title"
  done <<EOF
$rejected
EOF
done

printf '\n'
if [ "$total" -eq 0 ]; then
  echo "Nothing rejected. Every open PR is approved, pending, or unreviewed."
  exit 0
fi
printf '%s rejected: %s need work, %s look fixed but were never resubmitted, %s already back with the reviewer.\n' \
  "$total" "$needs_work" "$fixed" "$resubmitted"
[ "$fixed" -gt 0 ] && printf 'Read the diff on the "fixed?" ones before rewriting anything — commits after a rejection mean someone worked, not that they addressed the review.\n'
exit 0
