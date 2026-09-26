# Tesla → Tesla → Tesla

Three cars. Each one keeps its own copy of the fleet's ledger. No server.
One car drops off the network and comes back — and ends up with the same ledger,
byte for byte, body of every record included.

The records are real Tesla fleet-telemetry `Payload` messages
([teslamotors/fleet-telemetry](https://github.com/teslamotors/fleet-telemetry),
Apache-2.0), produced with their own `vehicle_data.proto`. Part B replays the
same records through Tesla's reference server — their code, their mTLS
WebSocket, their envelope — so the two architectures sit side by side.

![the demo](results/demo.gif)

```
device  records  digest(seq, hash, body)
  0        100   c27920cdb8c42e7a
  1        100   c27920cdb8c42e7a
  2        100   c27920cdb8c42e7a      ← the car that left and came back
SAME LEDGER, BODY INCLUDED, ON ALL DEVICES: YES

first records, in ledger order, decoded back as Tesla Payloads:
  seq 0  vin …001  speed 61.6  soc 79.98  loc (37.4035, -122.2347)
  seq 1  vin …002  speed 57.3  soc 79.98  loc (37.4857, -122.2447)
  seq 2  vin …003  speed 59.2  soc 79.98  loc (37.4139, -122.2044)
```

Today (part B) the car talks only to the server — Tesla's README: *"vehicles
communicate only with the server"* — so the server is the one holder of the
whole picture. Here (part A) all three cars hold it.

## Across three continents — over the real internet (26 Sep 2026)

The run above is on one machine. This one is not: each car and its device run
on an ordinary 1-vCPU server in a **different continent**, and the devices talk
to each other over the public internet.

![three cars on three continents](results/wan_demo.gif)

### What ran

| | |
|---|---|
| **Car 1** | a server in **Frankfurt** |
| **Car 2** | a server in **Tokyo** |
| **Car 3** | a server in **Los Angeles** |

- On each server: one "car" process and **its own** Vortex device. The car
  hands each record only to its own device, over HTTP on the same machine. It
  never talks to another car, and there is no server, broker or leader anywhere.
- Each car sends **60 real Tesla fleet-telemetry `Payload` messages**
  (speed, location, state of charge, odometer), about 3 per second. The bytes
  are the same ones the one-machine demo uses.
- **Car 3 (Los Angeles) leaves.** About 9 s in, its device is stopped
  (`SIGTERM`), and about 9 s later it is started again. While it is off, car 3
  cannot record anything: in a real vehicle the device and the car are one.
- When the cars finish, the network gets 20 s to settle. Then the three
  ledgers are compared.

### What came out

```
device                records   digest(seq, hash, body)
car 1 Frankfurt         155     a1269930925ffad4
car 2 Tokyo             155     a1269930925ffad4
car 3 Los Angeles       155     a1269930925ffad4
SAME LEDGER, BODY INCLUDED, ON ALL THREE CONTINENTS: YES · records the car that left lacks: 0

car 1 Frankfurt     own device p50 4.8 ms · held by ALL THREE p50 135.6 ms   p90 9704.6 ms
car 2 Tokyo         own device p50 3.7 ms · held by ALL THREE p50 121.3 ms   p90 9656.9 ms
car 3 Los Angeles   own device p50 3.7 ms · held by ALL THREE p50  73.3 ms   p90   75.2 ms
```

Full text of the recorded run: [`results/wan_demo_output.txt`](results/wan_demo_output.txt).

### How to read it

- **`digest`** is a SHA-256 over every record's position, hash **and body**.
  Three equal digests mean that three machines on three continents hold the
  same ledger **byte for byte**, not just the same count.
- **`records the car that left lacks: 0`**: car 3 came back and got from the
  other two everything they recorded while it was away, through retransmission
  and anti-entropy. Nobody resent anything by hand.
- **155 = 60 + 60 + 35.** Cars 1 and 2 got all 60 in. Car 3's device was off
  for part of the run: 23 of its sends were refused, and those records exist
  nowhere. That is the expected behaviour — see the note below on the other 2.
- **`own device` (~4 ms)** is how long a car waits for its own device to accept
  a record.
- **`held by ALL THREE` p50 (~70–135 ms)** is how long until the record is on
  all three continents. This is roughly the one-way time a packet needs between
  those cities. A record is "held by all three" only when it reaches the
  farthest one, so each car's figure is its slowest route. For cars 1 and 2
  that route is Frankfurt–Tokyo. For car 3 it is Los Angeles–Frankfurt, which
  is faster.
- **`p90` of ~9.7 s for cars 1 and 2**: these are records they made while car 3
  was away. They reached car 3 when it came back, which is the point of the demo.
- **The timestamps come from three different machines**, synchronised with
  NTP. Trust them to a few milliseconds, not to fractions of one.

### What this does not show

- **No Tesla server over the internet yet.** Part B (Tesla's reference server)
  still runs on one machine only. The side-by-side over the internet has not
  been done.
- **Two records were lost after being accepted.** Car 3 had 37 of its sends
  accepted, but 35 reached the ledger. When a device is stopped, it can drop a
  record it has already said "OK" to but not yet sent to the others. This is
  an open issue.
- **The GitHub Actions run does not do this.** It needs three servers on three
  continents, so it cannot run on a GitHub machine. The Actions run is the
  one-machine version.
- **One recorded run.** That day there were four clean runs, and all four
  ended with the same ledger on all three: one with 40 records per car (95 in
  total), and three with 60 (152, 154, 155). The totals differ because car 3
  leaves at a slightly different moment each time. A fifth run is not counted:
  a bug in the harness made it read the previous run's files.
- No claim here of "trustless" or "fair ordering". What is shown is that there
  is **no centre**: three equal devices, and the same ledger on all of them.

## See it run

**On GitHub, live:** open [Actions → *run the demo*](../../actions). Every run is
public: the output is on the run's summary page and the three ledgers are
downloadable artifacts. It runs every Monday and on every push, so there is
always a recent one. Full text of one run: [`results/demo_output.txt`](results/demo_output.txt).

**Why you cannot just press "Run workflow" on a fork:** the Vortex node is not
in this repository. The job fetches it during the run from the project's own
server with a read-only deploy key held in this repository's secrets. Forks do
not receive secrets. This is deliberate: the node is the thing being evaluated,
not distributed.

## Pick the order yourself

The claim underneath this demo is that the ledger is a function of the *set* of
records, not of the order they arrived in. You can test that without trusting
anyone: [**Pick the order**](https://vasilisnasopoulos.github.io/pick-the-order.html)
takes any integer you choose as a shuffle seed, replays 3,000 transactions to
5 nodes in that order, and posts the resulting hash. Every seed so far has
produced the same one.

## Getting the node, to run it yourself

Ask. Evaluation copies (Linux x86_64 static, macOS arm64) are given on request
to people and teams who want to run the demo on their own machines or extend
it. Then:

```bash
./setup.sh                                   # Tesla's proto → Python, clones their repo
VORTEX_BIN=/path/to/vortex_dse_full3 ./run_demo.sh   # ~2 minutes
```

Needs `python3` and `git`; `go` (and `libzmq`) only for part B.

## What is in here

| | |
|---|---|
| `demo/car.py` | a "car": generates Tesla `Payload` records, hands each to its own Vortex device (`POST /tx` on localhost) |
| `demo/read_ledger.py` | reads each device's ledger back as Tesla records and compares the devices |
| `demo/vehicle_client.go` | a vehicle the way Tesla's server expects one (built inside their module, uses their envelope code) |
| `demo/server_config.json` | Tesla's server with the logger dispatcher |
| `.github/workflows/demo.yml` | the Actions run |
| `results/` | one recorded run: GIF and text |

## What the demo does and does not show

- It shows three peers reaching one ledger with no coordinator, and a peer that
  was away catching up from the others. It shows the record bodies inside the
  ledger, decodable with Tesla's schema.
- The 20 records car 3 produced **while its own device was off** are not in
  any ledger: a car whose node is down does not write. In a real vehicle the
  node and the vehicle are one.
- It is loopback. The same node runs on three continents in our testnet; this
  demo is the shape, not the scale.
- Tesla's server is measured as "received", not benchmarked — that was not the
  question.

## License

Everything in this repository is MIT. The Vortex node is not in this
repository; evaluation copies come with their own terms.
Tesla's `fleet-telemetry` is Apache-2.0 and is cloned by `setup.sh`, not vendored.
