package remote

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"time"
)

const (
	BeaconPort  = 47390
	beaconMagic = "yamp-remote"
	beaconMax   = 1024
)

type Beacon struct {
	Magic string `json:"yamp"`
	V     int    `json:"v"`
	ID    string `json:"id"`
	Name  string `json:"name"`
	Port  int    `json:"port"`
	Login string `json:"login,omitempty"`
}

func encodeBeacon(b Beacon) []byte {
	b.Magic, b.V = beaconMagic, 1
	out, _ := json.Marshal(b)
	return out
}

func decodeBeacon(data []byte) (Beacon, bool) {
	var b Beacon
	if len(data) > beaconMax || json.Unmarshal(data, &b) != nil {
		return Beacon{}, false
	}
	if b.Magic != beaconMagic || b.ID == "" || b.Port <= 0 || b.Port > 65535 {
		return Beacon{}, false
	}
	return b, true
}

func broadcastTargets(port int) []*net.UDPAddr {
	out := []*net.UDPAddr{{IP: net.IPv4bcast, Port: port}}
	for _, ipn := range localNets() {
		ip := ipn.IP.To4()
		mask := ipn.Mask
		if len(mask) == net.IPv6len {
			mask = mask[12:]
		}
		if ip == nil || len(mask) != net.IPv4len {
			continue
		}
		bc := make(net.IP, net.IPv4len)
		for i := range bc {
			bc[i] = ip[i] | ^mask[i]
		}
		out = append(out, &net.UDPAddr{IP: bc, Port: port})
	}
	return out
}

func localNets() []*net.IPNet {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []*net.IPNet
	for _, ifc := range ifaces {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok || ipn.IP.To4() == nil || ipn.IP.IsLinkLocalUnicast() || ipn.IP.IsLoopback() {
				continue
			}
			out = append(out, ipn)
		}
	}
	return out
}

func LocalHosts(limit int) []string {
	var private, other []string
	for _, ipn := range localNets() {
		ip := ipn.IP.To4()
		if ip.IsPrivate() {
			if ip[0] == 192 && ip[1] == 168 {
				private = append([]string{ip.String()}, private...)
			} else {
				private = append(private, ip.String())
			}
		} else {
			other = append(other, ip.String())
		}
	}
	all := append(private, other...)
	if len(all) > limit {
		all = all[:limit]
	}
	return all
}

func Announce(ctx context.Context, every time.Duration, beacon func() Beacon) error {
	return announce(ctx, every, beacon, func() []*net.UDPAddr { return broadcastTargets(BeaconPort) })
}

func announce(ctx context.Context, every time.Duration, beacon func() Beacon, targets func() []*net.UDPAddr) error {
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return err
	}
	defer conn.Close()
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		msg := encodeBeacon(beacon())
		for _, to := range targets() {
			_, _ = conn.WriteToUDP(msg, to)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

func Listen(ctx context.Context, found func(Beacon, netip.Addr)) error {
	return listen(ctx, BeaconPort, found)
}

func listen(ctx context.Context, port int, found func(Beacon, netip.Addr)) error {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{Port: port})
	if err != nil {
		return err
	}
	go func() {
		<-ctx.Done()
		conn.Close()
	}()
	buf := make([]byte, beaconMax+1)
	for {
		n, from, err := conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if b, ok := decodeBeacon(buf[:n]); ok {
			found(b, from.Addr().Unmap())
		}
	}
}
