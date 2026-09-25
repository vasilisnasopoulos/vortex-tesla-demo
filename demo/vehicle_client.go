// A vehicle, the way Tesla's reference server expects one: WebSocket over mTLS,
// each record wrapped in Tesla's own FlatBuffers stream envelope. Reads
// records_<vin>.jsonl (hex Payloads produced by car.py) and replays them.
// Demo-only; built inside the fleet-telemetry module so it uses their code as is.
package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/gorilla/websocket"
	"github.com/teslamotors/fleet-telemetry/messages/tesla"
)

func main() {
	vin := flag.String("vin", "", "vehicle id (device id in the cert)")
	certdir := flag.String("certs", "", "directory with certsvehicle_device.* files")
	url := flag.String("url", "wss://127.0.0.1:4443/", "server")
	file := flag.String("records", "", "records_<vin>.jsonl from car.py")
	period := flag.Duration("period", 100*time.Millisecond, "send interval")
	flag.Parse()

	cert, err := tls.LoadX509KeyPair(*certdir+"/certsvehicle_device."+*vin+".cert", *certdir+"/certsvehicle_device."+*vin+".key")
	if err != nil {
		log.Fatal(err)
	}
	caPEM, err := os.ReadFile(*certdir + "/certsvehicle_device.CA.cert")
	if err != nil {
		log.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	d := websocket.Dialer{TLSClientConfig: &tls.Config{Certificates: []tls.Certificate{cert}, RootCAs: pool, InsecureSkipVerify: true}}
	conn, _, err := d.Dial(*url, nil)
	if err != nil {
		log.Fatal("dial: ", err)
	}
	defer conn.Close()

	f, err := os.Open(*file)
	if err != nil {
		log.Fatal(err)
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	n := 0
	for sc.Scan() {
		var rec struct {
			I   int    `json:"i"`
			Hex string `json:"hex"`
		}
		if err := json.Unmarshal(sc.Bytes(), &rec); err != nil {
			continue
		}
		payload, _ := hex.DecodeString(rec.Hex)
		senderID := "vehicle_device." + *vin
		msg := tesla.FlatbuffersStreamToBytes([]byte(senderID), []byte("V"), []byte(fmt.Sprintf("tx-%s-%d", *vin, rec.I)),
			payload, uint32(time.Now().Unix()), []byte(fmt.Sprintf("m-%s-%d", *vin, rec.I)), []byte("vehicle_device"), []byte(*vin),
			uint64(time.Now().UnixMilli()))
		if err := conn.WriteMessage(websocket.BinaryMessage, msg); err != nil {
			log.Fatal("write: ", err)
		}
		n++
		time.Sleep(*period)
	}
	time.Sleep(500 * time.Millisecond)
	fmt.Printf("[%s] sent %d records to Tesla's server\n", *vin, n)
}
