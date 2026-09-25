#!/usr/bin/env bash
# Tesla fleet-telemetry × Vortex device mode — the two architectures side by side.
#
#  A) Tesla → Tesla → Tesla   three "cars", each with its OWN Vortex device, no server.
#                              Car 3 drops off the network mid-run and comes back.
#  B) Tesla → server → Tesla  the SAME records replayed to Tesla's reference server
#                              (their code, mTLS WebSocket, their envelope). Needs go.
#
# Usage: ./run_demo.sh            (part A, and part B if `go` is installed)
#        N=60 PERIOD=0.2 ./run_demo.sh
set -u
cd "$(dirname "$0")"; ROOT=$PWD
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) BIN=$ROOT/bin/vortex_dse_full3-linux-x86_64 ;;
  Darwin-arm64) BIN=$ROOT/bin/vortex_dse_full3-macos-arm64 ;;
  *) echo "no prebuilt binary for this platform — use the GitHub Actions workflow"; exit 2 ;;
esac
[ -f demo/vehicle_data_pb2.py ] || { echo "run ./setup.sh first"; exit 2; }
N=${N:-40}; PERIOD=${PERIOD:-0.3}
VINS=(5YJ3E1EA1NF000001 5YJ3E1EA1NF000002 5YJ3E1EA1NF000003)
W=$ROOT/run; rm -rf "$W"; mkdir -p "$W"
printf "node 0 127.0.0.1 23600\nnode 1 127.0.0.1 23601\nnode 2 127.0.0.1 23602\n" > "$W/peers.txt"

dev() { k=$1
  "$BIN" --peers "$W/peers.txt" --role device --device-ix $k --devices 3 --continuous 1 --slot-period-s 3 \
     --no-inject 1 --rpc-port $((8600+k)) --log-dir "$W/d$k" --failover-ms 600000 \
     --nack 1 --durable 1 --anti-entropy 1 >> "$W/d$k.out" 2>&1 &
  echo $! > "$W/d$k.pid"; disown; }

echo "══════════════════════════════════════════════════════════════════════"
echo " A) three cars, three Vortex devices, NO server  (Tesla → Tesla → Tesla)"
echo "══════════════════════════════════════════════════════════════════════"
for k in 0 1 2; do dev $k; done; sleep 4
for k in 0 1 2; do OUT=$W python3 demo/car.py ${VINS[$k]} $((8600+k)) $N $PERIOD > "$W/car$k.out" 2>&1 & echo $! > "$W/car$k.pid"; done
OFF=$(python3 -c "print(round($N*$PERIOD/3,1))"); sleep $OFF
kill -TERM $(cat "$W/d2.pid"); echo "   [t+${OFF}s] car 3's device went OFF the network"
sleep 6; dev 2;                echo "   [+6s]    car 3's device is BACK"
for k in 0 1 2; do wait $(cat "$W/car$k.pid") 2>/dev/null; done
grep -h "produced" "$W"/car?.out
echo "   … letting the devices reconcile (anti-entropy every 10 s) …"; sleep 15
for k in 0 1 2; do kill -TERM $(cat "$W/d$k.pid") 2>/dev/null; done; sleep 4
echo
for k in 0 1 2; do grep -h "slot .* committed" "$W/d$k.out" | tail -1 | sed -E "s/.*(admit=[0-9]+).*(witnesses=[0-9]+).*/   device $k: \1 \2/"; done
grep -h "resuming own count" "$W/d2.out" | tail -1 | sed 's/^/   /'
echo
python3 demo/read_ledger.py "$W"; A_RC=$?

if command -v go >/dev/null 2>&1 && [ -d fleet-telemetry ]; then
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo " B) the SAME records the way it works today: Tesla's reference server"
  echo "══════════════════════════════════════════════════════════════════════"
  FT=$ROOT/fleet-telemetry
  if [ ! -f "$FT/certsvehicle_device.CA.cert" ]; then
    ( cd "$FT" && GOFLAGS=-mod=mod go run ./tools -directory "$FT/certs" -server-ids app \
        -client-ids 5YJ3E1EA1NF000001,5YJ3E1EA1NF000002,5YJ3E1EA1NF000003 -san-ip-address 127.0.0.1 -san-domain localhost,app >/dev/null 2>&1 )
  fi
  mkdir -p "$FT/tools/vortexdemo_vehicle"; cp demo/vehicle_client.go "$FT/tools/vortexdemo_vehicle/main.go"
  ( cd "$FT" && GOFLAGS=-mod=mod go build -o "$W/vehicle" ./tools/vortexdemo_vehicle && GOFLAGS=-mod=mod go build -o "$W/tesla-server" ./cmd ) 2>&1 | grep -v "^go: downloading" | tail -3
  if [ -x "$W/tesla-server" ]; then
    pkill -f "$W/tesla-server" 2>/dev/null; pkill -f "fleet-telemetry-server" 2>/dev/null; sleep 1   # a server left over from an earlier run has other certs
    sed "s|CERTDIR|$FT|g" demo/server_config.json > "$W/server_config.json"
    "$W/tesla-server" -config "$W/server_config.json" > "$W/tesla_server.log" 2>&1 & echo $! > "$W/srv.pid"; disown; sleep 2
    VP=""; for k in 0 1 2; do "$W/vehicle" -vin ${VINS[$k]} -certs "$FT" -records "$W/records_${VINS[$k]}.jsonl" -period 50ms 2>&1 | tail -1 & VP="$VP $!"; done; wait $VP
    sleep 1; kill $(cat "$W/srv.pid") 2>/dev/null
    echo "   Tesla's server logged, per VIN (connect + records + disconnect):"
    for v in "${VINS[@]}"; do echo "     $v: $(grep -c "$v" "$W/tesla_server.log") lines"; done
    echo "   → there, the server is the only holder of the whole picture; the cars never talk to each other."
  else
    echo "   (Tesla server build failed — needs pkg-config + libzmq; part A above is the result)"
  fi
else
  echo; echo "(part B skipped: needs go and ./setup.sh's clone of teslamotors/fleet-telemetry)"
fi
exit $A_RC
