#!/usr/bin/env bash
# dns-postflight.sh — did the cutover actually land, and did mail survive?
#
#   ./dns-postflight.sh <domain> [options]
#
#     --expect-ip <ip>            the origin the domain should now resolve to
#     --dkim-fingerprint <sha256> value printed by dns-preflight.sh before the move
#     --acme-host <ssh-alias>     host running the TLS terminator, to clear its backoff
#     --acme-service <name>       systemd unit on that host (default: caddy)
#     --wait <seconds>            how long to wait for propagation (default: 900)
#
# WHY THIS EXISTS
#   Two things went wrong AFTER the reddy2help.org cutover on 2026-08-14, and
#   neither is visible from the registrar's "nameservers updated" confirmation.
#
#   1. Propagation is staged, not atomic. The NS change reached the registry
#      before the DS removal did, so for a while the registry delegated to an
#      unsigned zone while still advertising DNSSEC. Every validating resolver
#      returned SERVFAIL. Watching one resolver, or worse the registrar's own UI,
#      shows none of this.
#
#   2. The ACME client does not know DNS changed. Caddy had been failing to get a
#      certificate for three days because the domain still pointed elsewhere. By
#      cutover it was on attempt 33 with a SIX HOUR backoff and had fallen through
#      to Let's Encrypt STAGING, whose certificates browsers reject. DNS was
#      perfect, mail was perfect, and the site served nothing. A restart fixed it
#      in ten seconds — but only because someone thought to look.
#
#   3. A recursive resolver is not evidence about a zone. On 2026-08-25 this
#      script's own checks read os.reddy2help.org as NXDOMAIN on every delegated
#      nameserver, and the record had been published and serving all along: the
#      host was behind a VPN resolver that intercepts port 53 and answers from
#      cache no matter which @server dig is given. Cached answers also outlive
#      deleted records for a full TTL, so a recursor cheerfully confirms a zone
#      that no longer exists.
#
#   So this polls every major validating resolver rather than one, proves the
#   delegated nameservers are answering authoritatively before believing a word
#   they say, reads the records that matter from authority rather than cache,
#   re-proves the DKIM key rather than its presence, and treats "clear the ACME
#   backoff and confirm the cert is real" as a required step, not an afterthought.
#
# EXIT
#   0  cutover verified
#   1  something is still wrong (details above the verdict)
set -uo pipefail

DOMAIN="${1:-}"; shift 2>/dev/null || true
EXPECT_IP=""; DKIM_FP=""; ACME_HOST=""; ACME_SVC="caddy"; WAIT=900

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-ip) EXPECT_IP="${2:-}"; shift 2 ;;
    --dkim-fingerprint) DKIM_FP="${2:-}"; shift 2 ;;
    --acme-host) ACME_HOST="${2:-}"; shift 2 ;;
    --acme-service) ACME_SVC="${2:-}"; shift 2 ;;
    --wait) WAIT="${2:-900}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -z "$DOMAIN" ] && { echo "usage: dns-postflight.sh <domain> [options]" >&2; exit 2; }

RESOLVERS=(1.1.1.1 8.8.8.8 9.9.9.9 208.67.222.222)
fail=0

echo "→ DNS cutover post-flight for $DOMAIN"
echo

# ── 1. Propagation across validating resolvers ──────────────────────────
# One resolver is not evidence. They cache independently and the DS and NS
# changes land at different times.
echo "── Propagation ──"
deadline=$(( $(date +%s) + WAIT ))
while :; do
  ok=0; line=""
  for r in "${RESOLVERS[@]}"; do
    st="$(dig "$DOMAIN" A "@$r" +time=4 +tries=1 2>/dev/null | grep -oE 'status: [A-Z]+' | head -1 | awk '{print $2}')"
    [ "$st" = "NOERROR" ] && ok=$((ok+1))
    line="$line $r=${st:-timeout}"
  done
  [ "$ok" -eq "${#RESOLVERS[@]}" ] && { echo "  ✓ all resolvers NOERROR:$line"; break; }
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "  ✗ still not fully propagated after ${WAIT}s:$line"
    echo
    echo "    SERVFAIL on some resolvers usually means a stale DS is still published"
    echo "    while the new nameservers answer unsigned. Check:"
    echo "      dig +short DS $DOMAIN"
    echo "    If a DS is present and the new provider does not sign, the registrar"
    echo "    must remove it. Resolution recovers on the record's TTL, not sooner."
    fail=1; break
  fi
  echo "  … waiting:$line"
  sleep 30
done
echo

# ── 2. Where it points, and who serves it ───────────────────────────────
echo "── Delegation ──"
NS="$(dig +short NS "$DOMAIN" @1.1.1.1 2>/dev/null | sort | tr '\n' ' ')"
IP="$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | head -1)"
echo "  NS : ${NS:-none}"
echo "  A  : ${IP:-none}"
echo

# ── 2b. Authority ─ is any of the above actually evidence? ────────────
# Everything up to here came from recursive resolvers. That is right for a
# propagation check and wrong for anything else: a recursor answers from cache,
# so a record that was deleted — or never published — keeps resolving for its
# full TTL, and a record just added does not show up at all.
#
# The vantage point can also lie outright. On a host behind a VPN resolver or a
# local DNS proxy, `dig @some.nameserver` may never reach that nameserver: the
# local resolver intercepts port 53 and answers from its own cache whatever
# @server it was handed. Every nameserver then returns byte-identical answers
# and the operator draws a confident conclusion from a single stale cache entry.
#
# That happened on 2026-08-25. os.reddy2help.org was read as NXDOMAIN on all
# four delegated nameservers AND on GoDaddy's, the record was declared missing
# from the zone, and it had been published and serving the whole time.
#
# The tell is in the header flags. A nameserver that hosts the zone sets `aa` on
# a +norecurse query. An interceptor cannot forge that — it sets `ra` and omits
# `aa`. If nothing sets `aa`, this machine cannot verify DNS and must say so
# rather than produce a verdict.
echo "── Authority ──"

AUTH_NS=(); impostor=0
for ns in $NS; do
  hdr="$(dig +norecurse SOA "$DOMAIN" "@$ns" +time=5 +tries=1 2>/dev/null | grep -m1 '^;; flags:')"
  # Isolate the flag words. The line reads ";; flags: qr aa rd; QUERY: 1, ..." —
  # the last flag is followed by ';', not a space, so matching on " ra " against
  # the raw line silently never fires.
  fl="$(printf '%s' "$hdr" | sed -n 's/^;; flags:\([^;]*\);.*/\1/p')"
  if [ -z "$hdr" ]; then
    echo "  ✗ $ns — no response"
  elif [[ " $fl " == *" aa "* ]]; then
    AUTH_NS+=("$ns"); echo "  ✓ $ns — authoritative"
  elif [[ " $fl " == *" ra "* ]]; then
    echo "  ✗ $ns — no aa, ra set: a recursor answered this, not $ns"
    impostor=$((impostor+1))
  else
    echo "  ✗ $ns — not authoritative for $DOMAIN"
  fi
done

if [ "${#AUTH_NS[@]}" -eq 0 ]; then
  echo
  echo "  ✗ not one delegated nameserver answered authoritatively."
  if [ "$impostor" -gt 0 ]; then
    echo
    echo "    They all set 'ra' and omitted 'aa'. Real nameservers do not do that."
    echo "    Something on THIS HOST is intercepting port 53 and answering from its"
    echo "    own cache regardless of the @server given — a VPN resolver (Tailscale"
    echo "    MagicDNS, corporate split-DNS) or a local DNS proxy."
    echo
    echo "    Nothing this script reads here is evidence. Re-run from the origin"
    echo "    host, or anywhere off the VPN:"
    echo "      ssh <host> 'bash -s' < $0 $DOMAIN --expect-ip ${EXPECT_IP:-<ip>}"
    echo
    echo "    To see what is answering:"
    echo "      scutil --dns | grep nameserver     # macOS"
    echo "      resolvectl status                  # systemd-resolved"
  fi
  echo
  echo "✗ cutover NOT verified — this host cannot read DNS reliably." >&2
  exit 1
fi

AUTH="@${AUTH_NS[0]}"

# Ask every authoritative server the same question. They should agree; a split
# answer is a half-published zone, which one query can never show.
seen=""
for ns in "${AUTH_NS[@]}"; do
  one="$(dig +short A "$DOMAIN" "@$ns" +time=5 +tries=1 2>/dev/null | sort | tr '\n' ',')"
  seen="$seen${one:-none}\n"
done
if [ "$(printf '%b' "$seen" | sort -u | wc -l | tr -d ' ')" != "1" ]; then
  echo "  ✗ the authoritative servers disagree on the apex A record:"
  for ns in "${AUTH_NS[@]}"; do
    echo "      $ns → $(dig +short A "$DOMAIN" "@$ns" +time=5 +tries=1 2>/dev/null | tr '\n' ' ')"
  done
  fail=1
fi

AUTH_IP="$(dig +short A "$DOMAIN" "$AUTH" +time=5 +tries=1 2>/dev/null | head -1)"
echo "  A at authority : ${AUTH_IP:-none}"

# The stale-cache case this script exists to catch: the resolver still serves an
# answer the zone no longer contains, and will keep doing so for the full TTL.
if [ -n "$IP" ] && [ -n "$AUTH_IP" ] && [ "$IP" != "$AUTH_IP" ]; then
  echo "  ! resolver says $IP, authority says $AUTH_IP"
  echo "    the resolver is serving a cached answer the zone no longer contains"
  fail=1
fi

if [ -n "$EXPECT_IP" ]; then
  if [ "$AUTH_IP" = "$EXPECT_IP" ]; then
    echo "  ✓ authority resolves to the expected origin"
  else
    echo "  ✗ expected $EXPECT_IP at authority, got ${AUTH_IP:-none}"; fail=1
  fi
fi
echo

# ── 3. Mail ─────────────────────────────────────────────────────────────
# Presence is not enough. A DKIM key that is present but rejoined wrong is
# well-formed and cryptographically junk: mail keeps sending and silently fails
# authentication, which nobody notices until replies stop arriving.
echo "── Mail ──"
MX="$(dig +short MX "$DOMAIN" "$AUTH" 2>/dev/null | tr '\n' ' ')"
SPF="$(dig +short TXT "$DOMAIN" "$AUTH" 2>/dev/null | tr -d '"' | grep -i '^v=spf1' || true)"
[ -n "$MX" ]  && echo "  ✓ MX  : $MX"  || { echo "  ✗ MX  : MISSING — inbound mail is down"; fail=1; }
[ -n "$SPF" ] && echo "  ✓ SPF : present" || { echo "  ✗ SPF : MISSING"; fail=1; }

if [ -n "$DKIM_FP" ]; then
  found=0
  for sel in google default selector1 selector2 s1 s2 k1 mail dkim; do
    raw="$(dig +short TXT "${sel}._domainkey.$DOMAIN" "$AUTH" 2>/dev/null)"
    [ -z "$raw" ] && continue
    now_fp="$(DKIM_RAW="$raw" python3 - <<'PY' 2>/dev/null
import base64, os, re, subprocess
joined = "".join(re.findall(r'"([^"]*)"', os.environ["DKIM_RAW"])) or os.environ["DKIM_RAW"].strip()
m = re.search(r'p=([A-Za-z0-9+/=]+)', joined)
if not m: raise SystemExit
try: der = base64.b64decode(m.group(1), validate=True)
except Exception: raise SystemExit
pub = subprocess.run(["openssl","rsa","-pubin","-inform","DER","-outform","DER","-pubout"],
                     input=der, capture_output=True)
if pub.returncode: raise SystemExit
print(subprocess.run(["openssl","dgst","-sha256"], input=pub.stdout,
                     capture_output=True).stdout.decode().split()[-1])
PY
)"
    found=1
    if [ "$now_fp" = "$DKIM_FP" ]; then
      echo "  ✓ DKIM: selector '$sel' matches the pre-move key byte-for-byte"
    else
      echo "  ✗ DKIM: selector '$sel' does NOT match the pre-move key"
      echo "          expected ${DKIM_FP:0:16}… got ${now_fp:0:16}…"
      echo "          almost always the split TXT strings rejoined wrong"
      fail=1
    fi
    break
  done
  [ "$found" = "0" ] && { echo "  ✗ DKIM: no key found at the destination"; fail=1; }
else
  echo "  ! DKIM: no pre-move fingerprint given, cannot prove the key is unchanged"
  echo "          pass --dkim-fingerprint from the pre-flight next time"
fi
echo

# ── 4. TLS — the step everyone forgets ──────────────────────────────────
echo "── TLS ──"

# A proxy in the environment silently rewrites this test. curl honours
# HTTPS_PROXY and resolves the name AT THE PROXY, so --resolve is ignored and a
# proxy that cannot resolve returns 502 — indistinguishable from the origin being
# down, with nothing in the message naming the proxy as the cause. Bypass it:
# the point here is to test the origin, not the operator's egress path.
CURL=(curl)
_proxy="${HTTPS_PROXY:-${https_proxy:-}}"
if [ -n "$_proxy" ]; then
  echo "  ! HTTPS_PROXY is set ($_proxy) — bypassing it for these checks"
  CURL=(env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy curl)
fi

code="$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/" 2>/dev/null)"

if [ "$code" != "200" ] && [ -n "$ACME_HOST" ]; then
  echo "  HTTPS returned ${code:-000} — clearing the ACME backoff on $ACME_HOST"
  echo "    (an ACME client cannot observe that DNS changed; after repeated failures"
  echo "     it backs off for hours and may fall through to a staging endpoint)"
  ssh -o ConnectTimeout=15 "$ACME_HOST" "systemctl restart $ACME_SVC" 2>/dev/null \
    || echo "  ! could not restart $ACME_SVC on $ACME_HOST"
  for i in 1 2 3 4 5 6; do
    sleep 10
    code="$("${CURL[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null)"
    echo "    +$((i*10))s HTTPS: ${code:-000}"
    [ "$code" = "200" ] && break
  done
fi

if [ "$code" = "200" ]; then
  echo "  ✓ HTTPS 200"
else
  echo "  ✗ HTTPS ${code:-000}"
  [ -z "$ACME_HOST" ] && echo "    pass --acme-host <ssh-alias> to clear a stuck ACME backoff automatically"
  fail=1
fi

# A staging certificate is the failure that looks like success in curl but is
# rejected by every browser.
issuer="$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
          | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
if [ -n "$issuer" ]; then
  if printf '%s' "$issuer" | grep -qiE 'staging|fake|test'; then
    echo "  ✗ certificate is from a STAGING issuer — browsers will reject it"
    echo "    issuer: $issuer"
    fail=1
  else
    echo "  ✓ issuer: $issuer"
    exp="$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
           | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
    [ -n "$exp" ] && echo "    valid until $exp"
  fi
fi

# Serving the real site, not the old host's placeholder. A parking page answers
# 200 too, which is how a retired host once passed a status-code check.
title="$("${CURL[@]}" -s --max-time 10 "https://$DOMAIN/" 2>/dev/null | grep -oE '<title>[^<]*</title>' | head -1)"
[ -n "$title" ] && echo "  serving: $title"
echo

# ── verdict ─────────────────────────────────────────────────────────────
if [ "$fail" != "0" ]; then
  echo "✗ cutover NOT verified — see the failures above." >&2
  exit 1
fi
cat <<EOF
✓ cutover verified: propagated, mail intact, TLS real.

  Still worth checking by hand:
    - if DNSSEC was disabled to permit this move, restoring it is a separate
      operation with its own ordering rule: sign the zone first, publish the DS
      second. Publishing a DS before the zone is signed repeats the outage.
    - send a test mail both directions; DNS being right is necessary, not sufficient.
EOF
