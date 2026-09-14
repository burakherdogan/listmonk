package models

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jmoiron/sqlx"
	"github.com/jmoiron/sqlx/types"
	"github.com/lib/pq"
	null "gopkg.in/volatiletech/null.v6"
)

const (
	SubscriberStatusEnabled     = "enabled"
	SubscriberStatusDisabled    = "disabled"
	SubscriberStatusBlockListed = "blocklisted"

	SubscriptionStatusUnconfirmed  = "unconfirmed"
	SubscriptionStatusConfirmed    = "confirmed"
	SubscriptionStatusUnsubscribed = "unsubscribed"
)

// Subscribers represents a slice of Subscriber.
type Subscribers []Subscriber

// Subscriber represents an e-mail subscriber.
type Subscriber struct {
	Base

	UUID    string         `db:"uuid" json:"uuid"`
	Email   string         `db:"email" json:"email" form:"email"`
	Name    string         `db:"name" json:"name" form:"name"`
	Attribs JSON           `db:"attribs" json:"attribs"`
	Status  string         `db:"status" json:"status"`
	Lists   types.JSONText `db:"lists" json:"lists"`
}

type subLists struct {
	SubscriberID int            `db:"subscriber_id"`
	Lists        types.JSONText `db:"lists"`
}

// GetIDs returns the list of subscriber IDs.
func (subs Subscribers) GetIDs() []int {
	IDs := make([]int, len(subs))
	for i, c := range subs {
		IDs[i] = c.ID
	}

	return IDs
}

// LoadLists lazy loads the lists for all the subscribers
// in the Subscribers slice and attaches them to their []Lists property.
func (subs Subscribers) LoadLists(stmt *sqlx.Stmt) error {
	var sl []subLists
	err := stmt.Select(&sl, pq.Array(subs.GetIDs()))
	if err != nil {
		return err
	}

	if len(subs) != len(sl) {
		return errors.New("campaign stats count does not match")
	}

	for i, s := range sl {
		if s.SubscriberID == subs[i].ID {
			subs[i].Lists = s.Lists
		}
	}

	return nil
}

// FirstName splits the name by spaces and returns the first chunk
// of the name that's greater than 2 characters in length, assuming
// that it is the subscriber's first name.
func (s Subscriber) FirstName() string {
	for _, s := range strings.Split(s.Name, " ") {
		if len(s) > 2 {
			return s
		}
	}

	return s.Name
}

// LastName splits the name by spaces and returns the last chunk
// of the name that's greater than 2 characters in length, assuming
// that it is the subscriber's last name.
func (s Subscriber) LastName() string {
	chunks := strings.Split(s.Name, " ")
	for i := len(chunks) - 1; i >= 0; i-- {
		chunk := chunks[i]
		if len(chunk) > 2 {
			return chunk
		}
	}

	return s.Name
}

// Subscription represents a list attached to a subscriber.
type Subscription struct {
	List
	SubscriptionStatus    null.String     `db:"subscription_status" json:"subscription_status"`
	SubscriptionCreatedAt null.String     `db:"subscription_created_at" json:"subscription_created_at"`
	Meta                  json.RawMessage `db:"meta" json:"meta"`
}

// SubscriberExport represents a subscriber record that is exported to raw data.
type SubscriberExport struct {
	Base

	UUID    string `db:"uuid" json:"uuid"`
	Email   string `db:"email" json:"email"`
	Name    string `db:"name" json:"name"`
	Attribs string `db:"attribs" json:"attribs"`
	Status  string `db:"status" json:"status"`
}

// SubscriberExportProfile represents a subscriber's collated data in JSON for export.
type SubscriberExportProfile struct {
	Email         string          `db:"email" json:"-"`
	Profile       json.RawMessage `db:"profile" json:"profile,omitempty"`
	Subscriptions json.RawMessage `db:"subscriptions" json:"subscriptions,omitempty"`
	CampaignViews json.RawMessage `db:"campaign_views" json:"campaign_views,omitempty"`
	LinkClicks    json.RawMessage `db:"link_clicks" json:"link_clicks,omitempty"`
}

// SubscriberActivity represents a subscriber's campaign views and link clicks for the Activity tab.
type SubscriberActivity struct {
	CampaignViews json.RawMessage `db:"campaign_views" json:"campaign_views"`
	LinkClicks    json.RawMessage `db:"link_clicks" json:"link_clicks"`
}

type SubscribersActivityCharts struct {
	Granularity string          `db:"granularity" json:"granularity"`
	Recency     json.RawMessage `db:"recency" json:"recency"`
	Timeline    json.RawMessage `db:"timeline" json:"timeline"`
}

type SubscriberActivitySummary struct {
	Total            int        `db:"total" json:"-"`
	SubscriberID     int        `db:"subscriber_id" json:"subscriber_id"`
	Email            string     `db:"email" json:"email"`
	SubscriberName   string     `db:"subscriber_name" json:"name"`
	SubscriberStatus string     `db:"subscriber_status" json:"subscriber_status"`
	Views            int        `db:"views" json:"views"`
	Clicks           int        `db:"clicks" json:"clicks"`
	Links            int        `db:"links" json:"links"`
	Bounces          int        `db:"bounces" json:"bounces"`
	BounceType       string     `db:"bounce_type" json:"bounce_type"`
	FirstAt          *time.Time `db:"first_at" json:"first_at"`
	LastAt           *time.Time `db:"last_at" json:"last_at"`
}

type SubscriberCampaignActivity struct {
	Total           int             `db:"total" json:"-"`
	CampaignID      int             `db:"campaign_id" json:"campaign_id"`
	CampaignName    string          `db:"campaign_name" json:"campaign_name"`
	CampaignSubject string          `db:"campaign_subject" json:"campaign_subject"`
	Views           int             `db:"views" json:"views"`
	Clicks          int             `db:"clicks" json:"clicks"`
	Links           int             `db:"links" json:"links"`
	Bounces         int             `db:"bounces" json:"bounces"`
	BounceType      string          `db:"bounce_type" json:"bounce_type"`
	ClickedLinks    json.RawMessage `db:"clicked_links" json:"clicked_links"`
	FirstAt         *time.Time      `db:"first_at" json:"first_at"`
	LastAt          *time.Time      `db:"last_at" json:"last_at"`
}
