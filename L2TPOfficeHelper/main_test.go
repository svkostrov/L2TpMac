package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"net"
	"testing"
)

func TestPPPFrameDecodeAndEncode(t *testing.T) {
	payload := []byte{0xff, 0x03, 0xc0, 0x21, 0x7e, 0x7d, 0x00, 0x11}
	fcs := ^pppFCS(payload)
	frame := append(append([]byte{}, payload...), byte(fcs), byte(fcs>>8))

	decoded, ok := decodePPPFrame(frame)
	if !ok {
		t.Fatal("expected valid PPP frame")
	}
	if !bytes.Equal(decoded, payload) {
		t.Fatalf("decoded payload mismatch: got %x want %x", decoded, payload)
	}

	encoded := encodePPP(payload)
	if encoded[0] != 0x7e || encoded[len(encoded)-1] != 0x7e {
		t.Fatalf("encoded PPP frame is not HDLC-delimited: %x", encoded)
	}
	inner := unescapePPPForTest(t, encoded[1:len(encoded)-1])
	decoded, ok = decodePPPFrame(inner)
	if !ok || !bytes.Equal(decoded, payload) {
		t.Fatalf("encoded frame did not round-trip: ok=%v got=%x", ok, decoded)
	}
}

func TestDecodeRejectsBadPPPFrame(t *testing.T) {
	if _, ok := decodePPPFrame([]byte{0xff, 0x03, 0x00, 0x00}); ok {
		t.Fatal("expected frame with bad FCS to be rejected")
	}
}

func TestParseControlPacket(t *testing.T) {
	var body bytes.Buffer
	body.Write(encodeAVP(avpU16(avpMessageType, msgSCCRP)))
	body.Write(encodeAVP(avpU16(avpTunnelID, 42)))

	var pkt bytes.Buffer
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0xc802))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(12+body.Len()))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(7))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(3))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(2))
	pkt.Write(body.Bytes())

	cp, err := parseControl(pkt.Bytes())
	if err != nil {
		t.Fatalf("parseControl failed: %v", err)
	}
	if cp.msgType != msgSCCRP || cp.tunnelID != 7 || cp.ns != 3 || u16(cp.avps[avpTunnelID]) != 42 {
		t.Fatalf("unexpected control packet: %+v", cp)
	}
}

func TestParseDataPacket(t *testing.T) {
	client := &l2tpClient{localTunnel: 10, localSession: 20}
	payload := []byte{0xff, 0x03, 0x00, 0x21, 0x45}
	var pkt bytes.Buffer
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0x4002))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(10+len(payload)))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(10))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(20))
	pkt.Write(payload)

	got, ok := client.parseData(pkt.Bytes())
	if !ok || !bytes.Equal(got, payload) {
		t.Fatalf("parseData mismatch: ok=%v got=%x want=%x", ok, got, payload)
	}

	client.localSession = 21
	if _, ok := client.parseData(pkt.Bytes()); ok {
		t.Fatal("expected packet for another session to be ignored")
	}
}

func TestTransientUDPWriteErrors(t *testing.T) {
	cases := []error{
		errors.New("sendto: can't assign requested address"),
		&net.OpError{Op: "write", Err: errors.New("network is unreachable")},
		errors.New("write udp: no route to host"),
	}
	for _, err := range cases {
		if !isTransientUDPWriteError(err) {
			t.Fatalf("expected transient error: %v", err)
		}
	}
	if isTransientUDPWriteError(errors.New("permission denied")) {
		t.Fatal("permission denied must not be treated as transient")
	}
}

func unescapePPPForTest(t *testing.T, data []byte) []byte {
	t.Helper()
	out := make([]byte, 0, len(data))
	escaped := false
	for _, b := range data {
		if escaped {
			out = append(out, b^0x20)
			escaped = false
			continue
		}
		if b == 0x7d {
			escaped = true
			continue
		}
		out = append(out, b)
	}
	if escaped {
		t.Fatal("dangling PPP escape byte")
	}
	return out
}
