#!/data/data/com.termux/files/usr/bin/bash
# lb-test.sh — exit-IP distribution probe for load-balancing verification.
#
# Fires N requests at a rotating set of "what's my IP" services and aggregates
# the exit IPs that come back. A healthy load balancer spreads the requests
# across several node IPs; a single IP for every request means no balancing
# (or sticky/session-affinity routing).
#
# Why rotate across many services: a single destination can get pinned to one
# node by session affinity, hiding the spread. Hitting several distinct
# services makes the real per-connection distribution visible.
#
# Runs anywhere bash + curl exist (built for Termux, also fine on Linux/macOS).
#
# Usage:
#   ./lb-test.sh                 # 50 requests, concurrency 8
#   ./lb-test.sh 100 10          # 100 requests, 10 in flight at once
#   PROXY=http://127.0.0.1:2080 ./lb-test.sh 100 10   # probe a specific node port
set -u

N="${1:-50}"            # total number of requests
CONC="${2:-8}"          # how many run concurrently
TIMEOUT="${TIMEOUT:-8}" # per-request timeout (seconds)
PROXY="${PROXY:-}"      # optional curl proxy, e.g. http://127.0.0.1:2080

# Plain-text IP endpoints, verified to return a clean address.
# (ifconfig.com is intentionally omitted: it answers 406 via Mod Security.)
SERVICES=(
  https://wtfismyip.com/text
  https://checkip.amazonaws.com
  https://ipecho.net/plain
  https://ident.me
  https://ipinfo.io/ip
  https://icanhazip.com
  https://ifconfig.me
  https://ifconfig.co
  https://2ip.ru
)

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

# Fetch one IP from a randomly chosen service; emit FAIL on timeout/garbage.
one() {
  local svc="${SERVICES[$((RANDOM % ${#SERVICES[@]}))]}" ip
  ip="$(curl -s ${PROXY:+-x "$PROXY"} --max-time "$TIMEOUT" "$svc" | tr -d '[:space:]')"
  # Keep only things shaped like an IPv4/IPv6 address; drop HTML error pages.
  [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || ip="FAIL"
  printf '%s\n' "${ip:-FAIL}"
}

echo "-> $N requests, concurrency $CONC${PROXY:+, via $PROXY} ..."
for ((i = 1; i <= N; i++)); do
  one >>"$RESULTS" &
  # Cap the number of in-flight jobs at CONC.
  while (($(jobs -r | wc -l) >= CONC)); do wait -n; done
done
wait

echo
echo "=== exit-IP distribution ==="
sort "$RESULTS" | uniq -c | sort -rn |
  awk -v n="$N" '{ printf "  %4d  %5.1f%%  %s\n", $1, 100*$1/n, $2 }'
echo "unique IPs: $(sort -u "$RESULTS" | grep -vc FAIL)  /  total: $N"
