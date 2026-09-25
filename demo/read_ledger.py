#!/usr/bin/env python3
"""Read each device's ledger_nodeK.txt (cslot hash64 seq payload_hex) back as Tesla
fleet-telemetry Payload records, in ledger order, and compare the devices.
A device that restarted appends again after restore, so records are keyed by seq."""
import sys, os, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vehicle_data_pb2 as v

root = sys.argv[1]; devs = [0, 1, 2]
ledgers = {}
for k in devs:
    m = {}
    with open(f"{root}/d{k}/ledger_node{k}.txt") as f:
        for line in f:
            cslot, h, seq, hx = line.split()
            m[int(seq)] = (h, hx)
    ledgers[k] = m

def digest(m): return hashlib.sha256("\n".join(f"{s} {m[s][0]} {m[s][1]}" for s in sorted(m)).encode()).hexdigest()[:16]
print("device  records  digest(seq, hash, body)")
for k in devs: print(f"  {k}      {len(ledgers[k]):5d}   {digest(ledgers[k])}")
same = all(ledgers[k] == ledgers[0] for k in devs)
print("SAME LEDGER, BODY INCLUDED, ON ALL DEVICES:", "YES" if same else "NO")
for k in devs[1:]:
    lack = [s for s in ledgers[0] if s not in ledgers[k]]
    if lack: print(f"  device {k} lacks {len(lack)} records that device 0 has")

print("\nfirst 6 records as Tesla fleet-telemetry Payloads, in ledger order (device 0):")
per_vin, shown = {}, 0
for s in sorted(ledgers[0]):
    h, hx = ledgers[0][s]
    try:
        p = v.Payload.FromString(bytes.fromhex(hx))
    except Exception as e:
        print(f"  seq {s}: undecodable ({e})"); continue
    per_vin[p.vin] = per_vin.get(p.vin, 0) + 1
    if shown < 6:
        f = {}
        for d in p.data:
            name = v.Field.Name(d.key)
            f[name] = (round(d.value.location_value.latitude, 4), round(d.value.location_value.longitude, 4)) \
                      if d.value.HasField("location_value") else round(d.value.float_value, 2)
        print(f"  seq {s:>4}  vin {p.vin}  speed {f.get('VehicleSpeed', 0):5.1f}  soc {f.get('Soc', 0):5.2f}  loc {f.get('Location')}")
        shown += 1
print("\nrecords per VIN in the shared ledger:", per_vin)
sys.exit(0 if same else 1)
