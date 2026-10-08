#!/bin/bash
B="/Users/macbook/Library/Application Support/singbox-launcher/bin/sing-box"
cd "$(dirname "$0")"; n=0
one() { # name cfg port
  n=$((n+1))
  "$B" run -c $2 > log_${n}_$1.txt 2>&1 & pid=$!
  sleep 1.5; t0=$(date +%s.%N)
  out=$(curl -s -m 12 -x socks5://127.0.0.1:$3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E "^(colo|warp)=" | tr '\n' ' ')
  t1=$(date +%s.%N); ms=$(python3 -c "print(int(($t1-$t0)*1000))")
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  if echo "$out" | grep -q "warp=on"; then echo "RESULT #$n $1 PASS ${ms}ms $out"; else echo "RESULT #$n $1 FAIL ${ms}ms"; fi
  sleep 5
}
echo "START $(date +%T)"
for r in 1 2 3; do
  one P_plain cfg_P.json 18305
  one C_apteka cfg_C_apteka.json 18303
  one M_apteka cfg_M_apteka.json 18301
  one C_wartune cfg_C_wartune.json 18304
  one M_wartune cfg_M_wartune.json 18302
done
one M_apteka cfg_M_apteka.json 18301
one M_wartune cfg_M_wartune.json 18302
echo "END $(date +%T)"
