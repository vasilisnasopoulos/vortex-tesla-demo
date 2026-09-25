#!/usr/bin/env python3
"""One 'Tesla': produces fleet-telemetry Payload records with Tesla's own proto
(teslamotors/fleet-telemetry, Apache-2.0) and hands each one to
  (a) its OWN Vortex device (POST /tx on localhost)      -- no server anywhere
  (b) optionally Tesla's reference server over WebSocket+mTLS -- the way it works today
Records are also kept locally (records_<vin>.jsonl) so the demo can decode the ledger."""
import sys, os, json, time, math, random, hashlib, urllib.request
sys.path.insert(0, os.path.dirname(__file__))
import vehicle_data_pb2 as v

vin      = sys.argv[1]
rpc_port = int(sys.argv[2])
n        = int(sys.argv[3])
period   = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
ws_url   = os.environ.get("TESLA_WS")          # e.g. wss://127.0.0.1:4443
certdir  = os.environ.get("TESLA_CERTS")
outdir   = os.environ.get("OUT", ".")

random.seed(int(vin[-3:]))
lat, lon, soc, odo = 37.39 + random.random()/10, -122.15 - random.random()/10, 80.0, 12000.0

ws = None
if ws_url:
    import ssl, asyncio, websockets
    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=f"{certdir}/certsvehicle_device.CA.cert")
    ctx.load_cert_chain(f"{certdir}/certsvehicle_device.{vin}.cert", f"{certdir}/certsvehicle_device.{vin}.key")
    ctx.check_hostname = False
    loop = asyncio.new_event_loop()
    ws = loop.run_until_complete(websockets.connect(ws_url, ssl=ctx, additional_headers={"X-Network-Interface": "wifi"}))

def record(i):
    global lat, lon, soc, odo
    speed = max(0.0, 60 + 25*math.sin(i/7.0) + random.uniform(-3, 3))
    lat += speed*1e-6; lon += speed*0.7e-6; soc -= 0.02; odo += speed/3600*0.5
    p = v.Payload(vin=vin)
    d = p.data.add(); d.key = v.Field.Value("VehicleSpeed");  d.value.float_value = round(speed, 1)
    d = p.data.add(); d.key = v.Field.Value("Location");      d.value.location_value.latitude = round(lat, 6); d.value.location_value.longitude = round(lon, 6)
    d = p.data.add(); d.key = v.Field.Value("Soc");           d.value.float_value = round(soc, 2)
    d = p.data.add(); d.key = v.Field.Value("Odometer");      d.value.float_value = round(odo, 2)
    p.created_at.GetCurrentTime()
    return p

sent = 0; lost = 0
with open(f"{outdir}/records_{vin}.jsonl", "a") as rec:
    for i in range(n):
        p = record(i); body = p.SerializeToString()
        if body.endswith(b"\x00"): body += b"\x01"            # ledger dump trims trailing zeros; keep decodable
        nonce = int(vin[-3:]) * 1_000_000 + i
        # (a) the car's own Vortex device
        req = urllib.request.Request(f"http://127.0.0.1:{rpc_port}/tx",
                                     data=json.dumps({"nonce": nonce, "data": body.hex()}).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=2).read()
        except Exception:
            lost += 1          # my own device is down: this record is not written anywhere
        # (b) Tesla's server, if asked
        if ws is not None:
            msg = v.Payload.FromString(body)  # same record
            loop.run_until_complete(ws.send(body))
        rec.write(json.dumps({"i": i, "nonce": nonce, "vin": vin, "hex": body.hex(),
                              "speed": p.data[0].value.float_value, "soc": p.data[2].value.float_value}) + "\n")
        sent += 1
        time.sleep(period)
print(f"[{vin}] produced {sent} records; {sent-lost} handed to its own device" + (f", {lost} lost while its device was OFF" if lost else ""))
