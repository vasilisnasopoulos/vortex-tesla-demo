#!/usr/bin/env bash
# One-time setup: Python deps, Tesla's proto compiled to Python, Tesla's repo cloned
# (for part B). Needs: python3, git. Optional for part B: go.
set -eu
cd "$(dirname "$0")"
python3 -m pip install --user -q protobuf grpcio-tools websockets 2>/dev/null || python3 -m pip install -q protobuf grpcio-tools websockets
if [ ! -d fleet-telemetry ]; then
  git clone -q --depth 1 https://github.com/teslamotors/fleet-telemetry.git
fi
python3 -m grpc_tools.protoc -I fleet-telemetry/protos --python_out=demo vehicle_data.proto
echo "ok: demo/vehicle_data_pb2.py generated from Tesla's vehicle_data.proto"
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  echo "binary: bin/vortex_dse_full3-linux-x86_64" ;;
  Darwin-arm64)  echo "binary: bin/vortex_dse_full3-macos-arm64" ;;
  *) echo "no prebuilt binary for $(uname -s)-$(uname -m)" ;;
esac
