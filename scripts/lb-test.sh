#!/data/data/com.termux/files/usr/bin/bash
# lb-test.sh — exit-IP probe for load-balancing verification.
#
# Sends exactly ONE request to each "what's my IP" service and reports the exit
# IP per domain, then the overall distribution. The number of distinct exit IPs
# tells you how many nodes the balancer spreads across.
#
# Why one request per server (and many distinct servers): a sticky /
# consistent-hashing balancer pins a connection to a node BY DESTINATION, so
# repeating requests to the SAME domain always exits the same node and tells you
# nothing. Hitting many DIFFERENT domains once each is what reveals the real
# spread of nodes. More domains in the list => more nodes revealed.
#
# Runs anywhere bash + curl exist (built for Termux, also fine on Linux/macOS).
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
  https://api.my-ip.io/ip
  https://ipof.in/txt
  https://whatismyip.akamai.com
  https://2ip.ru
)

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

# Query one service; emit "<ip>\t<service>" ("FAIL" on timeout / non-IP body).
one() {
  local svc="$1" ip
  ip="$(curl -s ${PROXY:+-x "$PROXY"} --max-time "$TIMEOUT" "$svc" | tr -d '[:space:]')"
  # Keep only things shaped like an IPv4/IPv6 address; drop HTML error pages.
  [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || ip="FAIL"
  printf '%s\t%s\n' "${ip:-FAIL}" "$svc"
}

echo "-> ${#SERVICES[@]} services, one request each, concurrency $CONC${PROXY:+, via $PROXY} ..."
for svc in "${SERVICES[@]}"; do
  one "$svc" >>"$RESULTS" &
  # Cap the number of in-flight jobs at CONC.
  while (($(jobs -r | wc -l) >= CONC)); do wait -n; done
done
wait

echo
echo "=== exit IP per service ==="
sort -t$'\t' -k2 "$RESULTS" |
  awk -F'\t' '{ printf "  %-34s %s\n", $2, $1 }'

echo
echo "=== exit-IP distribution ==="
total="${#SERVICES[@]}"
cut -f1 "$RESULTS" | sort | uniq -c | sort -rn |
  awk -v n="$total" '{ printf "  %3d  %5.1f%%  %s\n", $1, 100*$1/n, $2 }'
echo "unique IPs: $(cut -f1 "$RESULTS" | sort -u | grep -vc FAIL)  /  services: $total"
