package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	l2tpPort = "1701"

	msgSCCRQ   = 1
	msgSCCRP   = 2
	msgSCCCN   = 3
	msgStopCCN = 4
	msgHELLO   = 6
	msgICRQ    = 10
	msgICRP    = 11
	msgICCN    = 12
	msgCDN     = 14

	avpMessageType     = 0
	avpProtocolVersion = 2
	avpFramingCap      = 3
	avpBearerCap       = 4
	avpHostName        = 7
	avpVendorName      = 8
	avpTunnelID        = 9
	avpRxWindowSize    = 10
	avpChallenge       = 11
	avpChallengeReply  = 13
	avpSessionID       = 14
	avpCallSerial      = 15
	avpBearerType      = 18
	avpFramingType     = 19
	avpConnectSpeed    = 24
	avpRxConnectSpeed  = 38
)

type l2tpClient struct {
	conn          *net.UDPConn
	remote        *net.UDPAddr
	log           *log.Logger
	localTunnel   uint16
	peerTunnel    uint16
	localSession  uint16
	peerSession   uint16
	ns            uint16
	nr            uint16
	ackMu         sync.Mutex
	establishedCh chan struct{}
}

type controlPacket struct {
	tunnelID  uint16
	sessionID uint16
	ns        uint16
	nr        uint16
	msgType   uint16
	avps      map[uint16][]byte
	rawAvps   []avp
}

type avp struct {
	typ  uint16
	data []byte
}

func main() {
	server := flag.String("server", "", "L2TP server hostname or IP")
	logPath := flag.String("log", "/tmp/l2tp-office-app.log", "log path")
	flag.Parse()

	f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	logger := log.New(f, "helper: ", log.LstdFlags)

	if *server == "" {
		logger.Print("server is empty")
		os.Exit(2)
	}

	c, err := newL2TPClient(*server, logger)
	if err != nil {
		logger.Printf("l2tp init failed: %v", err)
		os.Exit(2)
	}
	defer c.conn.Close()

	if err := c.handshake(); err != nil {
		logger.Printf("l2tp handshake failed: %v", err)
		os.Exit(2)
	}
	logger.Printf("l2tp session established: local tunnel/session %d/%d, peer %d/%d", c.localTunnel, c.localSession, c.peerTunnel, c.peerSession)

	frames := make(chan []byte, 64)
	errs := make(chan error, 2)
	go readPPP(os.Stdin, frames, errs, logger)
	go c.readLoop(os.Stdout, errs)

	for {
		select {
		case frame, ok := <-frames:
			if !ok {
				return
			}
			if err := c.sendData(frame); err != nil {
				logger.Printf("send data failed: %v", err)
				return
			}
		case err := <-errs:
			if err != nil && err != io.EOF {
				logger.Printf("bridge stopped: %v", err)
			}
			return
		}
	}
}

func newL2TPClient(server string, logger *log.Logger) (*l2tpClient, error) {
	addr, err := net.ResolveUDPAddr("udp4", net.JoinHostPort(server, l2tpPort))
	if err != nil {
		return nil, err
	}
	conn, err := net.DialUDP("udp4", nil, addr)
	if err != nil {
		return nil, err
	}
	logger.Printf("udp connected: local=%s remote=%s", conn.LocalAddr(), addr)
	return &l2tpClient{
		conn:          conn,
		remote:        addr,
		log:           logger,
		localTunnel:   randomID(),
		localSession:  randomID(),
		establishedCh: make(chan struct{}),
	}, nil
}

func randomID() uint16 {
	var b [2]byte
	_, _ = rand.Read(b[:])
	v := binary.BigEndian.Uint16(b[:])
	if v == 0 {
		return 1
	}
	return v
}

func (c *l2tpClient) handshake() error {
	if err := c.sendControl(0, 0, []avp{
		avpU16(avpMessageType, msgSCCRQ),
		avpBytes(avpProtocolVersion, []byte{1, 0}),
		avpU32(avpFramingCap, 3),
		avpU32(avpBearerCap, 0),
		avpString(avpHostName, "L2TP Office"),
		avpString(avpVendorName, "L2TP Office"),
		avpU16(avpTunnelID, c.localTunnel),
		avpU16(avpRxWindowSize, 4),
	}); err != nil {
		return err
	}

	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		_ = c.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		cp, err := c.readControl()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return err
		}
		c.log.Printf("control received: msg=%d tid=%d sid=%d ns=%d nr=%d", cp.msgType, cp.tunnelID, cp.sessionID, cp.ns, cp.nr)
		switch cp.msgType {
		case msgSCCRP:
			c.peerTunnel = u16(cp.avps[avpTunnelID])
			c.setNR(cp.ns + 1)
			if err := c.sendControl(c.peerTunnel, 0, []avp{avpU16(avpMessageType, msgSCCCN)}); err != nil {
				return err
			}
			if err := c.sendControl(c.peerTunnel, 0, []avp{
				avpU16(avpMessageType, msgICRQ),
				avpU16(avpSessionID, c.localSession),
				avpU32(avpCallSerial, uint32(c.localSession)),
			}); err != nil {
				return err
			}
		case msgICRP:
			c.peerSession = u16(cp.avps[avpSessionID])
			c.setNR(cp.ns + 1)
			if c.peerSession == 0 {
				return fmt.Errorf("peer did not assign session id")
			}
			if err := c.sendControl(c.peerTunnel, c.peerSession, []avp{
				avpU16(avpMessageType, msgICCN),
				avpU32(avpConnectSpeed, 100000000),
				avpU32(avpFramingType, 3),
			}); err != nil {
				return err
			}
			_ = c.conn.SetReadDeadline(time.Time{})
			return nil
		case msgStopCCN, msgCDN:
			return fmt.Errorf("peer closed control/session during handshake")
		case msgHELLO:
			c.setNR(cp.ns + 1)
			_ = c.sendAck(c.peerTunnel)
		default:
			if cp.msgType != 0 {
				c.setNR(cp.ns + 1)
				_ = c.sendAck(c.peerTunnel)
			}
		}
	}
	return fmt.Errorf("timeout")
}

func (c *l2tpClient) readLoop(pppOut io.Writer, errs chan<- error) {
	buf := make([]byte, 4096)
	for {
		n, err := c.conn.Read(buf)
		if err != nil {
			errs <- err
			return
		}
		pkt := append([]byte(nil), buf[:n]...)
		if isControl(pkt) {
			cp, err := parseControl(pkt)
			if err != nil {
				c.log.Printf("bad control packet: %v", err)
				continue
			}
			if cp.msgType != 0 {
				c.setNR(cp.ns + 1)
				if cp.msgType == msgHELLO {
					_ = c.sendAck(c.peerTunnel)
				} else if cp.msgType == msgStopCCN || cp.msgType == msgCDN {
					errs <- fmt.Errorf("peer closed l2tp session")
					return
				} else {
					_ = c.sendAck(c.peerTunnel)
				}
			}
			continue
		}
		payload, ok := c.parseData(pkt)
		if !ok || len(payload) == 0 {
			continue
		}
		if _, err := pppOut.Write(encodePPP(payload)); err != nil {
			errs <- err
			return
		}
	}
}

func (c *l2tpClient) sendControl(tid, sid uint16, avps []avp) error {
	c.ackMu.Lock()
	defer c.ackMu.Unlock()

	var body bytes.Buffer
	for _, a := range avps {
		body.Write(encodeAVP(a))
	}
	length := 12 + body.Len()
	var pkt bytes.Buffer
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0xc802))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(length))
	_ = binary.Write(&pkt, binary.BigEndian, tid)
	_ = binary.Write(&pkt, binary.BigEndian, sid)
	_ = binary.Write(&pkt, binary.BigEndian, c.ns)
	_ = binary.Write(&pkt, binary.BigEndian, c.nr)
	pkt.Write(body.Bytes())
	c.ns++
	return c.writePacket(pkt.Bytes())
}

func (c *l2tpClient) sendAck(tid uint16) error {
	c.ackMu.Lock()
	defer c.ackMu.Unlock()

	var pkt bytes.Buffer
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0xc802))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(12))
	_ = binary.Write(&pkt, binary.BigEndian, tid)
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0))
	_ = binary.Write(&pkt, binary.BigEndian, c.ns)
	_ = binary.Write(&pkt, binary.BigEndian, c.nr)
	return c.writePacket(pkt.Bytes())
}

func (c *l2tpClient) setNR(nr uint16) {
	c.ackMu.Lock()
	c.nr = nr
	c.ackMu.Unlock()
}

func (c *l2tpClient) readControl() (*controlPacket, error) {
	buf := make([]byte, 2048)
	for {
		n, err := c.conn.Read(buf)
		if err != nil {
			return nil, err
		}
		pkt := append([]byte(nil), buf[:n]...)
		if !isControl(pkt) {
			continue
		}
		return parseControl(pkt)
	}
}

func (c *l2tpClient) sendData(payload []byte) error {
	var pkt bytes.Buffer
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0x0002))
	_ = binary.Write(&pkt, binary.BigEndian, c.peerTunnel)
	_ = binary.Write(&pkt, binary.BigEndian, c.peerSession)
	pkt.Write(payload)
	return c.writePacket(pkt.Bytes())
}

func (c *l2tpClient) writePacket(pkt []byte) error {
	var lastErr error
	for attempt := 1; attempt <= 12; attempt++ {
		_, err := c.conn.Write(pkt)
		if err == nil {
			return nil
		}
		lastErr = err
		if !isTransientUDPWriteError(err) {
			return err
		}
		c.log.Printf("udp write failed, retrying (%d/12): %v", attempt, err)
		time.Sleep(500 * time.Millisecond)
	}
	return lastErr
}

func isTransientUDPWriteError(err error) bool {
	s := strings.ToLower(err.Error())
	return strings.Contains(s, "can't assign requested address") ||
		strings.Contains(s, "network is unreachable") ||
		strings.Contains(s, "no route to host")
}

func (c *l2tpClient) parseData(pkt []byte) ([]byte, bool) {
	if len(pkt) < 6 {
		return nil, false
	}
	flags := binary.BigEndian.Uint16(pkt[0:2])
	if flags&0x8000 != 0 || flags&0x000f != 2 {
		return nil, false
	}
	off := 2
	if flags&0x4000 != 0 {
		if len(pkt) < off+2 {
			return nil, false
		}
		ln := int(binary.BigEndian.Uint16(pkt[off : off+2]))
		if ln <= len(pkt) {
			pkt = pkt[:ln]
		}
		off += 2
	}
	if len(pkt) < off+4 {
		return nil, false
	}
	tid := binary.BigEndian.Uint16(pkt[off : off+2])
	sid := binary.BigEndian.Uint16(pkt[off+2 : off+4])
	off += 4
	if tid != c.localTunnel || sid != c.localSession {
		return nil, false
	}
	if flags&0x0800 != 0 {
		if len(pkt) < off+4 {
			return nil, false
		}
		off += 4
	}
	if flags&0x0200 != 0 {
		if len(pkt) < off+2 {
			return nil, false
		}
		off += 2 + int(binary.BigEndian.Uint16(pkt[off:off+2]))
	}
	if off > len(pkt) {
		return nil, false
	}
	return pkt[off:], true
}

func isControl(pkt []byte) bool {
	return len(pkt) >= 2 && binary.BigEndian.Uint16(pkt[0:2])&0x8000 != 0
}

func parseControl(pkt []byte) (*controlPacket, error) {
	if len(pkt) < 12 {
		return nil, fmt.Errorf("short control packet")
	}
	flags := binary.BigEndian.Uint16(pkt[0:2])
	if flags&0x8000 == 0 || flags&0x4000 == 0 || flags&0x0800 == 0 {
		return nil, fmt.Errorf("not a sequenced control packet")
	}
	length := int(binary.BigEndian.Uint16(pkt[2:4]))
	if length > 0 && length <= len(pkt) {
		pkt = pkt[:length]
	}
	cp := &controlPacket{
		tunnelID:  binary.BigEndian.Uint16(pkt[4:6]),
		sessionID: binary.BigEndian.Uint16(pkt[6:8]),
		ns:        binary.BigEndian.Uint16(pkt[8:10]),
		nr:        binary.BigEndian.Uint16(pkt[10:12]),
		avps:      map[uint16][]byte{},
	}
	off := 12
	for off < len(pkt) {
		if off+6 > len(pkt) {
			return nil, fmt.Errorf("short avp")
		}
		fl := binary.BigEndian.Uint16(pkt[off : off+2])
		alen := int(fl & 0x03ff)
		if alen < 6 || off+alen > len(pkt) {
			return nil, fmt.Errorf("bad avp length")
		}
		vendor := binary.BigEndian.Uint16(pkt[off+2 : off+4])
		typ := binary.BigEndian.Uint16(pkt[off+4 : off+6])
		data := append([]byte(nil), pkt[off+6:off+alen]...)
		if vendor == 0 {
			cp.avps[typ] = data
			cp.rawAvps = append(cp.rawAvps, avp{typ: typ, data: data})
			if typ == avpMessageType && len(data) >= 2 {
				cp.msgType = binary.BigEndian.Uint16(data[:2])
			}
		}
		off += alen
	}
	return cp, nil
}

func encodeAVP(a avp) []byte {
	var pkt bytes.Buffer
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0x8000|uint16(6+len(a.data))))
	_ = binary.Write(&pkt, binary.BigEndian, uint16(0))
	_ = binary.Write(&pkt, binary.BigEndian, a.typ)
	pkt.Write(a.data)
	return pkt.Bytes()
}

func avpU16(t uint16, v uint16) avp {
	var b [2]byte
	binary.BigEndian.PutUint16(b[:], v)
	return avp{typ: t, data: b[:]}
}

func avpU32(t uint16, v uint32) avp {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	return avp{typ: t, data: b[:]}
}

func avpBytes(t uint16, b []byte) avp {
	return avp{typ: t, data: b}
}

func avpString(t uint16, s string) avp {
	return avp{typ: t, data: []byte(s)}
}

func u16(b []byte) uint16 {
	if len(b) < 2 {
		return 0
	}
	return binary.BigEndian.Uint16(b[:2])
}

func readPPP(r io.Reader, frames chan<- []byte, errs chan<- error, logger *log.Logger) {
	defer close(frames)
	buf := make([]byte, 512)
	var frame []byte
	escaped := false
	for {
		n, err := r.Read(buf)
		if err != nil {
			errs <- err
			return
		}
		for _, c := range buf[:n] {
			switch c {
			case 0x7e:
				if len(frame) >= 4 {
					if pkt, ok := decodePPPFrame(frame); ok {
						frames <- pkt
					} else {
						logger.Printf("bad ppp frame len=%d", len(frame))
					}
				}
				frame = frame[:0]
				escaped = false
			case 0x7d:
				escaped = true
			default:
				if escaped {
					c ^= 0x20
					escaped = false
				}
				frame = append(frame, c)
				if len(frame) > 4096 {
					frame = frame[:0]
					escaped = false
				}
			}
		}
	}
}

func decodePPPFrame(frame []byte) ([]byte, bool) {
	if len(frame) < 2 {
		return nil, false
	}
	if pppFCS(frame) != 0xf0b8 {
		return nil, false
	}
	return append([]byte(nil), frame[:len(frame)-2]...), true
}

func encodePPP(payload []byte) []byte {
	withFCS := append([]byte(nil), payload...)
	fcs := ^pppFCS(payload)
	withFCS = append(withFCS, byte(fcs), byte(fcs>>8))
	out := []byte{0x7e}
	for _, c := range withFCS {
		if c < 0x20 || c == 0x7d || c == 0x7e {
			out = append(out, 0x7d, c^0x20)
		} else {
			out = append(out, c)
		}
	}
	out = append(out, 0x7e)
	return out
}

func pppFCS(data []byte) uint16 {
	fcs := uint16(0xffff)
	for _, b := range data {
		fcs ^= uint16(b)
		for i := 0; i < 8; i++ {
			if fcs&1 != 0 {
				fcs = (fcs >> 1) ^ 0x8408
			} else {
				fcs >>= 1
			}
		}
	}
	return fcs
}
