package remote

import (
	"crypto/subtle"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"time"
)

type Client struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	KeyHash string `json:"keyHash"`
	Added   int64  `json:"added"`
}

type PairedHost struct {
	ID    string   `json:"id"`
	Name  string   `json:"name"`
	Login string   `json:"login,omitempty"`
	Hosts []string `json:"hosts"`
	Port  int      `json:"port"`
	FP    string   `json:"fp"`
	Key   string   `json:"key"`
	Added int64    `json:"added"`
}

type Store struct {
	ID      string       `json:"id"`
	Port    int          `json:"port,omitempty"`
	Clients []Client     `json:"clients,omitempty"`
	Hosts   []PairedHost `json:"hosts,omitempty"`
}

func LoadStore(path string) Store {
	var s Store
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &s)
	}
	if s.ID == "" {
		s.ID = RandomToken(12)
	}
	return s
}

func (s Store) Save(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *Store) AddClient(id, name string) string {
	key := RandomToken(32)
	s.RemoveClient(id)
	s.Clients = append(s.Clients, Client{ID: id, Name: name, KeyHash: HashKey(key), Added: time.Now().Unix()})
	return key
}

func (s *Store) RemoveClient(id string) bool {
	n := len(s.Clients)
	s.Clients = slices.DeleteFunc(s.Clients, func(c Client) bool { return c.ID == id })
	return len(s.Clients) != n
}

func (s *Store) Authorize(id, key string) bool {
	if id == "" || key == "" {
		return false
	}
	want := HashKey(key)
	for _, c := range s.Clients {
		if c.ID == id && subtle.ConstantTimeCompare([]byte(c.KeyHash), []byte(want)) == 1 {
			return true
		}
	}
	return false
}

func (s *Store) PutHost(h PairedHost) {
	s.RemoveHost(h.ID)
	s.Hosts = append(s.Hosts, h)
}

func (s *Store) RemoveHost(id string) bool {
	n := len(s.Hosts)
	s.Hosts = slices.DeleteFunc(s.Hosts, func(h PairedHost) bool { return h.ID == id })
	return len(s.Hosts) != n
}

func (s *Store) Host(id string) (PairedHost, bool) {
	for _, h := range s.Hosts {
		if h.ID == id {
			return h, true
		}
	}
	return PairedHost{}, false
}
