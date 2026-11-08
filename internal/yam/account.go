package yam

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"
)

var ErrNoPlus = errors.New("для скачивания нужна активная подписка Яндекс Плюс")

type Account struct {
	UID     int64
	Login   string
	Name    string
	HasPlus bool
}

func (c *Client) Status(ctx context.Context) (Account, error) {
	if c.token == "" {
		return Account{}, ErrUnauthorized
	}
	var r struct {
		Account struct {
			UID         int64  `json:"uid"`
			Login       string `json:"login"`
			FullName    string `json:"fullName"`
			DisplayName string `json:"displayName"`
		} `json:"account"`
		Plus struct {
			HasPlus bool `json:"hasPlus"`
		} `json:"plus"`
	}
	if err := c.api(ctx, http.MethodGet, "/account/status", nil, &r); err != nil {
		var ae *APIError
		if errors.As(err, &ae) && ae.Status == http.StatusForbidden {
			return Account{}, ErrUnauthorized
		}
		return Account{}, err
	}

	if r.Account.UID == 0 {
		return Account{}, ErrUnauthorized
	}
	name := strings.TrimSpace(r.Account.DisplayName)
	if name == "" {
		name = strings.TrimSpace(r.Account.FullName)
	}
	if name == "" {
		name = r.Account.Login
	}
	return Account{
		UID:     r.Account.UID,
		Login:   r.Account.Login,
		Name:    name,
		HasPlus: r.Plus.HasPlus,
	}, nil
}

type Session struct {
	*Client

	mu      sync.Mutex
	account Account
	checked time.Time

	covers coverCache
}

const statusTTL = 30 * time.Minute

func Open(ctx context.Context, token string) (*Session, Account, error) {
	c := New(token)
	acc, err := c.Status(ctx)
	if err != nil {
		return nil, Account{}, err
	}
	if !acc.HasPlus {
		return nil, acc, ErrNoPlus
	}
	return &Session{Client: c, account: acc, checked: time.Now()}, acc, nil
}

func (s *Session) Account() Account {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.account
}

func (s *Session) Verify(ctx context.Context) error {
	s.mu.Lock()
	fresh := time.Since(s.checked) < statusTTL
	s.mu.Unlock()
	if fresh {
		return nil
	}
	_, err := s.Refresh(ctx)
	return err
}

func (s *Session) Refresh(ctx context.Context) (Account, error) {
	acc, err := s.Status(ctx)
	if err != nil {
		return Account{}, err
	}
	s.mu.Lock()
	s.account = acc
	s.checked = time.Now()
	s.mu.Unlock()
	if !acc.HasPlus {
		return acc, ErrNoPlus
	}
	return acc, nil
}
