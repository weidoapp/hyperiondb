#!/usr/bin/env bash
set -uo pipefail

B="${PGBIN:-$HOME/.pgrx/18.4/pgrx-install/bin}"
R="${ROOT:-/tmp/hyperion-repl}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
P1=54340 P2=54341 P3=54342
CPU_WINDOW="${CPU_WINDOW:-8}"
PERF_DUR="${PERF_DUR:-10}"
PERF_CLIENTS="${PERF_CLIENTS:-8}"
PERF_JOBS="${PERF_JOBS:-4}"
MEM_LIMIT_KB="${MEM_LIMIT_KB:-10240}"
CPU_LIMIT="${CPU_LIMIT:-20.0}"
FAILOVER_LIMIT="${FAILOVER_LIMIT:-30}"
CLK="$(getconf CLK_TCK)"

q() { PGCONNECT_TIMEOUT=2 "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -tAc "$2" 2>/dev/null; }
try_write() { PGCONNECT_TIMEOUT=1 "$B/psql" -h 127.0.0.1 -p "$1" -U postgres -v ON_ERROR_STOP=1 -tAc "INSERT INTO perf VALUES (-1)" >/dev/null 2>&1; }
primary_port() { for p in $P1 $P2 $P3; do [ "$(q "$p" 'SELECT pg_is_in_recovery()')" = "f" ] && { echo "$p"; return; }; done; }
now_ms() { date +%s%3N; }

supervisor_pid() {
  local pm pid
  pm="$(head -1 "$R/n$1/postmaster.pid" 2>/dev/null)"
  [ -z "$pm" ] && return 1
  for pid in $(pgrep -P "$pm" 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "pg_replica supervisor"; then
      echo "$pid"; return 0
    fi
  done
  return 1
}
cpu_ticks() {
  local st; st="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  st="${st#*) }"; set -- $st; echo $(( ${12} + ${13} ))
}
rss_kb()  { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }
pss_kb()  { awk '/^Pss:/{print $2; exit}' "/proc/$1/smaps_rollup" 2>/dev/null; }
priv_kb() { awk '/^Private_Clean|^Private_Dirty/{s+=$2} END{print s+0}' "/proc/$1/smaps_rollup" 2>/dev/null; }

echo "=== bring up fresh cluster (asynchronous mode) ==="
bash "$SCRIPT_DIR/cluster-repl.sh" up >/dev/null 2>&1
for i in $(seq 1 80); do
  q "$P1" "SELECT replica.status()" | grep -q "decided_primary=1 seq=1 quorum=true read_only=false" && break
  sleep 0.5
done
for i in $(seq 1 30); do [ "$(q $P2 'SELECT pg_is_in_recovery()')" = "t" ] && [ "$(q $P3 'SELECT pg_is_in_recovery()')" = "t" ] && break; sleep 0.5; done
q "$P1" "CREATE TABLE perf (id bigint)" >/dev/null
echo "  primary=$(primary_port) status: $(q $P1 'SELECT replica.status()' | sed 's/.*| //')"

declare -A PID
for n in 1 2 3; do PID[$n]="$(supervisor_pid $n)"; done
echo "  supervisor pids: n1=${PID[1]:-?} n2=${PID[2]:-?} n3=${PID[3]:-?}"

echo
echo "=== A. MEMORY footprint of the supervisor bgworker (idle, converged) ==="
echo "     target: private resident overhead < $((MEM_LIMIT_KB/1024)) MB beyond Postgres (README validation target)"
MEM_OK=1; MEM_MAX_PRIV=0
for n in 1 2 3; do
  pid="${PID[$n]}"
  if [ -z "$pid" ]; then echo "  node$n: supervisor pid NOT found"; MEM_OK=0; continue; fi
  rss="$(rss_kb "$pid")"; pss="$(pss_kb "$pid")"; priv="$(priv_kb "$pid")"
  printf '  node%s pid=%s  RSS=%s kB  PSS=%s kB  PRIVATE=%s kB\n' "$n" "$pid" "${rss:-?}" "${pss:-?}" "${priv:-?}"
  [ -n "$priv" ] && [ "$priv" -gt "$MEM_MAX_PRIV" ] && MEM_MAX_PRIV="$priv"
  { [ -z "$priv" ] || [ "$priv" -ge "$MEM_LIMIT_KB" ]; } && MEM_OK=0
done
echo "  -> max private overhead across nodes: ${MEM_MAX_PRIV} kB (limit ${MEM_LIMIT_KB} kB)"

echo
echo "=== B. CPU usage of the supervisor bgworker (idle steady state, ${CPU_WINDOW}s window) ==="
CPU_OK=1; CPU_MAX="0.0"
declare -A T0
for n in 1 2 3; do [ -n "${PID[$n]}" ] && T0[$n]="$(cpu_ticks ${PID[$n]})"; done
sleep "$CPU_WINDOW"
for n in 1 2 3; do
  pid="${PID[$n]}"
  if [ -z "$pid" ] || [ -z "${T0[$n]:-}" ]; then echo "  node$n: no sample"; CPU_OK=0; continue; fi
  t1="$(cpu_ticks "$pid")"
  pct="$(awk -v d=$(( t1 - ${T0[$n]} )) -v clk="$CLK" -v w="$CPU_WINDOW" 'BEGIN{printf "%.2f", 100*d/(clk*w)}')"
  printf '  node%s pid=%s  CPU=%s%% over %ss (%d ticks)\n' "$n" "$pid" "$pct" "$CPU_WINDOW" "$(( t1 - ${T0[$n]} ))"
  awk -v p="$pct" -v m="$CPU_MAX" 'BEGIN{exit !(p>m)}' && CPU_MAX="$pct"
  awk -v p="$pct" -v l="$CPU_LIMIT" 'BEGIN{exit !(p>=l)}' && CPU_OK=0
done
echo "  -> peak idle CPU across nodes: ${CPU_MAX}% (limit ${CPU_LIMIT}%)"

echo
echo "=== C1. WRITE throughput on the primary (pgbench, single-row INSERT, async) ==="
PB=/tmp/pgr-perf.sql
printf '\\set v random(1, 1000000000)\nINSERT INTO perf (id) VALUES (:v);\n' > "$PB"
PGOUT="$(PGPASSFILE="$HOME/.pgpass" "$B/pgbench" -n -T "$PERF_DUR" -c "$PERF_CLIENTS" -j "$PERF_JOBS" \
  -f "$PB" -h 127.0.0.1 -p "$P1" -U postgres postgres 2>&1)"
TPS="$(echo "$PGOUT" | awk '/^tps/{print $3; exit}')"
LAT="$(echo "$PGOUT" | awk '/latency average/{print $4; exit}')"
echo "  ${PERF_CLIENTS} clients / ${PERF_JOBS} jobs for ${PERF_DUR}s: tps=${TPS:-?}  latency_avg=${LAT:-?} ms"
PERF_ROWS="$(q $P1 'SELECT count(*) FROM perf WHERE id >= 0')"
echo "  rows committed during run: ${PERF_ROWS:-?}"
TPS_OK=0; awk -v t="${TPS:-0}" 'BEGIN{exit !(t>0)}' && TPS_OK=1

echo
echo "=== C2. FAILOVER latency (kill -9 primary -> new primary accepts a write) ==="
KP="$(primary_port)"; KN=$(( KP - P1 + 1 ))
echo "  killing primary node$KN (port $KP) with -m immediate..."
T_KILL="$(now_ms)"
"$B/pg_ctl" -D "$R/n$KN" stop -m immediate >/dev/null 2>&1
NP=""; T_WRITABLE=""
for i in $(seq 1 $(( FAILOVER_LIMIT * 10 ))); do
  for p in $P1 $P2 $P3; do
    [ "$p" = "$KP" ] && continue
    if try_write "$p"; then NP="$p"; T_WRITABLE="$(now_ms)"; break; fi
  done
  [ -n "$NP" ] && break
  sleep 0.1
done
if [ -n "$T_WRITABLE" ]; then
  FAILOVER_MS=$(( T_WRITABLE - T_KILL ))
  echo "  new primary on port $NP became writable in ${FAILOVER_MS} ms"
  FAILOVER_OK=1
  awk -v ms="$FAILOVER_MS" -v lim="$FAILOVER_LIMIT" 'BEGIN{exit !(ms <= lim*1000)}' || FAILOVER_OK=0
else
  echo "  no node became writable within ${FAILOVER_LIMIT}s"
  FAILOVER_MS="?"; FAILOVER_OK=0
fi

echo
echo "=== performance / cpu / memory result ==="
if [ "$MEM_OK" = 1 ] && [ "$CPU_OK" = 1 ] && [ "$TPS_OK" = 1 ] && [ "$FAILOVER_OK" = 1 ]; then
  echo "  PASS: private mem ${MEM_MAX_PRIV}kB < ${MEM_LIMIT_KB}kB, idle CPU peak ${CPU_MAX}% < ${CPU_LIMIT}%, ${TPS} tps (${LAT}ms), failover ${FAILOVER_MS}ms"
else
  echo "  CHECK: mem_ok=$MEM_OK(${MEM_MAX_PRIV}kB) cpu_ok=$CPU_OK(${CPU_MAX}%) tps_ok=$TPS_OK(${TPS:-?}) failover_ok=$FAILOVER_OK(${FAILOVER_MS}ms)"
fi
