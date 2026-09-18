package parityprobe

import (
 "bufio"
 "context"
 "fmt"
 "io"
 "net"
 "net/http"
 "strconv"
 "strings"
 "testing"
 "time"

 box "github.com/sagernet/sing-box"
 "github.com/sagernet/sing-box/option"
 "github.com/sagernet/sing/common/json"
 mdns "github.com/miekg/dns"
)

// All listeners, clients and DNS answers are loopback-only. Two HTTP servers
// on the same port but different IPs distinguish preservation from override.
func TestSniffDestinationBehavior(t *testing.T) {
 original, err := net.Listen("tcp", "127.0.0.1:0")
 if err != nil { t.Fatal(err) }
 port := original.Addr().(*net.TCPAddr).Port
 alternate, err := net.Listen("tcp", fmt.Sprintf("127.0.0.2:%d", port))
 if err != nil { original.Close(); t.Fatal(err) }
 for _, endpoint := range []struct{ listener net.Listener; body string }{{original,"original-ip"},{alternate,"sniffed-host"}} {
  body := endpoint.body
  server := &http.Server{Handler:http.HandlerFunc(func(w http.ResponseWriter, r *http.Request){ io.WriteString(w,body) }), ReadHeaderTimeout:3*time.Second}
  go server.Serve(endpoint.listener)
  t.Cleanup(func(){ server.Close() })
 }
 udp, err := net.ListenPacket("udp", "127.0.0.1:0")
 if err != nil { t.Fatal(err) }
 dnsServer := &mdns.Server{PacketConn:udp, Handler:mdns.HandlerFunc(func(w mdns.ResponseWriter, q *mdns.Msg){
  response := new(mdns.Msg); response.SetReply(q)
  for _, question := range q.Question {
   if question.Name == "sniff.parity.test." && question.Qtype == mdns.TypeA {
    response.Answer = append(response.Answer,&mdns.A{Hdr:mdns.RR_Header{Name:question.Name,Rrtype:mdns.TypeA,Class:mdns.ClassINET,Ttl:1},A:net.ParseIP("127.0.0.2")})
   }
  }
  w.WriteMsg(response)
 })}
 go dnsServer.ActivateAndServe()
 t.Cleanup(func(){ dnsServer.Shutdown(); udp.Close() })
 for _, mode := range []struct{ name string; override bool; want string }{{"route",false,"original-ip"},{"override",true,"sniffed-host"}} {
  t.Run(mode.name,func(t *testing.T){
   // Reserve an ephemeral proxy port, release immediately before box starts.
   reservation, err := net.Listen("tcp","127.0.0.1:0"); if err != nil {t.Fatal(err)}
   proxyPort := reservation.Addr().(*net.TCPAddr).Port; reservation.Close()
   cfg := fmt.Sprintf(`{"log":{"level":"panic"},"dns":{"servers":[{"type":"udp","tag":"test-dns","server":"127.0.0.1","server_port":%d}],"final":"test-dns"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":%d}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"inbound":["mixed-in"],"action":"sniff","sniffer":["http"],"override_destination":%t}],"final":"direct","default_domain_resolver":{"server":"test-dns","strategy":"ipv4_only"},"auto_detect_interface":false}}`,udp.LocalAddr().(*net.UDPAddr).Port,proxyPort,mode.override)
   ctx := leanProbeContext(context.Background())
   options,err := json.UnmarshalExtendedContext[option.Options](ctx,[]byte(cfg)); if err != nil {t.Fatal(err)}
   instance,err := box.New(box.Options{Context:ctx,Options:options}); if err != nil {t.Fatal(err)}
   defer instance.Close(); if err=instance.Start(); err != nil {t.Fatal(err)}
   conn,err := net.DialTimeout("tcp",net.JoinHostPort("127.0.0.1",strconv.Itoa(proxyPort)),3*time.Second); if err != nil {t.Fatal(err)}
   defer conn.Close(); conn.SetDeadline(time.Now().Add(5*time.Second))
   // HTTP CONNECT preserves the original destination independently of Host.
   fmt.Fprintf(conn,"CONNECT 127.0.0.1:%d HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n",port,port)
   reader := bufio.NewReader(conn)
   response,err := http.ReadResponse(reader,&http.Request{Method:"CONNECT"}); if err != nil {t.Fatal(err)}
   if response.StatusCode != 200 {t.Fatalf("CONNECT status %s",response.Status)}
   fmt.Fprintf(conn,"GET / HTTP/1.1\r\nHost: sniff.parity.test:%d\r\nConnection: close\r\n\r\n",port)
   response,err = http.ReadResponse(reader,&http.Request{Method:"GET"}); if err != nil {t.Fatal(err)}
   defer response.Body.Close(); body,err := io.ReadAll(response.Body); if err != nil {t.Fatal(err)}
   if strings.TrimSpace(string(body)) != mode.want {t.Fatalf("destination response = %q, want %q",body,mode.want)}
   t.Logf("%s reached %s",mode.name,body)
  })
 }
}
