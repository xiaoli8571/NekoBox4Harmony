package parityprobe

import (
 stdjson "encoding/json"
 "os"
 "testing"
)

func TestProductionOutboundGraphsStart(t *testing.T) {
 data,err:=os.ReadFile("fixtures/production-graphs.json")
 if err!=nil {t.Fatal(err)}
 var fixtures []struct{Name string `json:"name"`; Config stdjson.RawMessage `json:"config"`}
 if err=stdjson.Unmarshal(data,&fixtures);err!=nil {t.Fatal(err)}
 if len(fixtures)!=2 {t.Fatalf("expected two graph fixtures, got %d",len(fixtures))}
 for _,fixture:=range fixtures {t.Run(fixture.Name,func(t *testing.T){
  if err:=startBoxRaw(t,string(fixture.Config));err!=nil {t.Fatal(err)}
 })}
}

// Regenerate with node tests/generate-dns-fixtures.cjs before running.
// This tests the actual builder's DNS graph including cross-rule interactions.
func TestProductionDNSConfigurationsStart(t *testing.T) {
 data,err:=os.ReadFile("fixtures/production-dns.json")
 if err!=nil {t.Fatal(err)}
 var fixtures []struct{Name string `json:"name"`; Config stdjson.RawMessage `json:"config"`}
 if err=stdjson.Unmarshal(data,&fixtures);err!=nil {t.Fatal(err)}
 if len(fixtures)!=8 {t.Fatalf("expected eight mode/FakeDNS combinations, got %d",len(fixtures))}
 for _,fixture:=range fixtures {t.Run(fixture.Name,func(t *testing.T){
  if err:=startBoxRaw(t,string(fixture.Config));err!=nil {t.Fatal(err)}
 })}
}
