#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lb-test.sh — exit-IP probe for load-balancing verification.
#
# WHAT:  Sends exactly ONE request to each of ~28 distinct "what's my IP"
#        services and reports the exit IP per domain, a grouped view, the
#        distribution, and the Shannon entropy of that distribution. The set of
#        distinct exit IPs = the nodes your load balancer is actually spreading
#        traffic across; the entropy says how evenly (1.0 = perfectly even).
#
# WHY:   To confirm an outbound load balancer is really distributing across
#        nodes — and not silently pinning everything to one. One request per
#        server, across MANY different servers, because a sticky /
#        consistent-hashing balancer pins a connection to a node BY
#        DESTINATION: hammering one domain always exits the same node and
#        proves nothing. Many distinct destinations are what reveal the spread;
#        more domains in the list => more nodes revealed.
#
# Runs anywhere bash + curl exist (built for Termux, also fine on Linux/macOS).
# =============================================================================
#
# Usage:
#   ./lb-test.sh                       # one request per server, concurrency 8
#   ./lb-test.sh 4                     # same, 4 requests in flight at once
#   PROXY=http://127.0.0.1:2080 ./lb-test.sh   # probe a specific node port
set -u

CONC="${1:-8}"          # how many requests run concurrently
TIMEOUT="${TIMEOUT:-8}" # per-request timeout (seconds)
PROXY="${PROXY:-}"      # optional curl proxy, e.g. http://127.0.0.1:2080

# Plain-text IP endpoints on DISTINCT domains, one request each. The more
# distinct destinations, the more nodes a consistent-hashing balancer reveals.
# The FAIL filter tolerates any that are down or rate-limiting on the day.
SERVICES=(
  https://ifconfig.me
  https://ifconfig.co
  https://ifconfig.io
  https://icanhazip.com
  https://ident.me
  https://tnedi.me
  https://ipecho.net/plain
  https://checkip.amazonaws.com
  https://api.ipify.org
  https://ipinfo.io/ip
  https://wtfismyip.com/text
  https://myexternalip.com/raw
  https://l2.io/ip
  https://eth0.me
  https://api.seeip.org
  https://api.ip.sb/ip
  https://ipof.in/txt
  https://whatismyip.akamai.com
  https://2ip.ru
  https://wgetip.com
  https://myip.dnsomatic.com
  https://www.trackip.net/ip
  https://ipapi.co/ip
  https://api64.ipify.org
  https://canhazip.com
  # Cloudflare / trace endpoints: reply "ip=<addr>" amid key=value lines.
  # Parsed below. Rarely down or blocked, so good extra balancing samples.
  https://cdnjs.cloudflare.com/cdn-cgi/trace
  https://one.one.one.one/cdn-cgi/trace
  https://cloudflare-dns.com/cdn-cgi/trace
)

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

# Query one service; print "<service>  <ip>" live as it answers, and record
# "<ip>\t<service>" to RESULTS for the summary. "FAIL" = timeout / non-IP body.
one() {
  local svc="$1" body ip
  body="$(curl -s ${PROXY:+-x "$PROXY"} --max-time "$TIMEOUT" "$svc")"
  if [[ "$body" == *"ip="* ]]; then
    # cdn-cgi/trace style: extract the value of the ip= line.
    ip="$(printf '%s\n' "$body" | sed -n 's/^ip=//p')"
  else
    ip="$body"
  fi
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
  # Keep only things shaped like an IPv4/IPv6 address; drop HTML error pages.
  [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || ip="FAIL"
  # IP first (fixed column) so it never wraps off a narrow phone screen; strip
  # the https:// scheme and the /cdn-cgi/trace path to keep the line short.
  local show="${svc#https://}"; show="${show%/cdn-cgi/trace}"
  printf '  %-15s %s\n' "${ip:-FAIL}" "$show"          # live line to stdout
  printf '%s\t%s\n' "${ip:-FAIL}" "$svc" >>"$RESULTS"  # record for summary
}

echo "-> ${#SERVICES[@]} services, one request each, concurrency $CONC${PROXY:+, via $PROXY}"
echo
echo "exit IP          service (live)"
echo "---------------  --------------"
for svc in "${SERVICES[@]}"; do
  one "$svc" &
  # Cap the number of in-flight jobs at CONC.
  while (($(jobs -r | wc -l) >= CONC)); do wait -n; done
done
wait

total="${#SERVICES[@]}"

echo
echo "grouped by exit IP"
echo "---------------------------------------------"
# List each exit IP once, with the domains that came out of it.
cut -f1 "$RESULTS" | sort -u | grep -v FAIL | while read -r ipaddr; do
  printf '  %s\n' "$ipaddr"
  awk -F'\t' -v ip="$ipaddr" '$1==ip { sub(/^https:\/\//,"",$2); sub(/\/cdn-cgi\/trace$/,"",$2); printf "      %s\n", $2 }' "$RESULTS"
done

echo
echo "distribution"
echo "---------------------------------------------"
cut -f1 "$RESULTS" | sort | uniq -c | sort -rn |
  awk -v n="$total" '{ printf "  %3d  %5.1f%%  %s\n", $1, 100*$1/n, $2 }'
echo
echo "unique exit IPs: $(cut -f1 "$RESULTS" | sort -u | grep -vc FAIL)  /  services: $total"

# Shannon entropy of the exit-IP distribution (FAILs excluded). High entropy =
# evenly spread across nodes; low = one node dominating. Normalized to [0,1]
# against a perfectly uniform spread; 2^H is the effective number of nodes.
cut -f1 "$RESULTS" | grep -v FAIL | sort | uniq -c |
  awk '{ c[NR] = $1; tot += $1 }
       END {
         if (tot == 0) { print "\nentropy: n/a (no successful responses)"; exit }
         for (i = 1; i <= NR; i++) { p = c[i] / tot; H -= p * log(p) / log(2) }
         maxH = (NR > 1) ? log(NR) / log(2) : 0
         printf "\nbalance (Shannon entropy)\n"
         printf "---------------------------------------------\n"
         printf "  entropy:          %.3f bits (max %.3f for %d nodes)\n", H, maxH, NR
         printf "  normalized:       %.3f  (1.0 = perfectly even)\n", (maxH > 0 ? H / maxH : 0)
         printf "  effective nodes:  %.2f / %d\n", 2 ^ H, NR
       }'
