package remote

import (
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
)

const linkScheme = "yamp"

type PairLink struct {
	ID     string
	Name   string
	Hosts  []string
	Port   int
	FP     string
	Secret string
}

var ErrBadLink = errors.New("это не код связывания YAMP")

func (l PairLink) String() string {
	q := url.Values{}
	q.Set("i", l.ID)
	q.Set("n", l.Name)
	q.Set("h", strings.Join(l.Hosts, ","))
	q.Set("p", strconv.Itoa(l.Port))
	q.Set("f", l.FP)
	q.Set("s", l.Secret)
	return linkScheme + "://pair?" + q.Encode()
}

func ParseLink(s string) (PairLink, error) {
	u, err := url.Parse(strings.TrimSpace(s))
	if err != nil || u.Scheme != linkScheme || u.Host != "pair" {
		return PairLink{}, ErrBadLink
	}
	q := u.Query()
	l := PairLink{ID: q.Get("i"), Name: q.Get("n"), FP: q.Get("f"), Secret: q.Get("s")}
	l.Port, err = strconv.Atoi(q.Get("p"))
	if err != nil || l.Port <= 0 || l.Port > 65535 {
		return PairLink{}, ErrBadLink
	}
	for _, h := range strings.Split(q.Get("h"), ",") {
		if ip := net.ParseIP(strings.TrimSpace(h)); ip != nil {
			l.Hosts = append(l.Hosts, ip.String())
		}
	}
	if l.ID == "" || l.FP == "" || l.Secret == "" || len(l.Hosts) == 0 {
		return PairLink{}, ErrBadLink
	}
	return l, nil
}

func (l PairLink) Addrs() []string {
	out := make([]string, 0, len(l.Hosts))
	for _, h := range l.Hosts {
		out = append(out, net.JoinHostPort(h, strconv.Itoa(l.Port)))
	}
	return out
}
