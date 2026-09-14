package migrations

import (
	"log"

	"github.com/jmoiron/sqlx"
	"github.com/knadh/koanf/v2"
	"github.com/knadh/stuffbin"
)

func V6_3_0(db *sqlx.DB, fs stuffbin.FileSystem, ko *koanf.Koanf, lo *log.Logger) error {
	// Flag tracking hits that come from mail security scanners and link
	// pre-fetchers so that analytics can exclude them. Existing rows default to
	// FALSE, preserving historical counts as-is.
	if _, err := db.Exec(`
		ALTER TABLE campaign_views ADD COLUMN IF NOT EXISTS is_bot BOOLEAN NOT NULL DEFAULT FALSE;
	`); err != nil {
		return err
	}

	if _, err := db.Exec(`
		ALTER TABLE link_clicks ADD COLUMN IF NOT EXISTS is_bot BOOLEAN NOT NULL DEFAULT FALSE;
	`); err != nil {
		return err
	}

	// Supports the burst heuristic, which counts a subscriber's recent clicks on
	// a campaign at insert time.
	if _, err := db.Exec(`
		CREATE INDEX IF NOT EXISTS idx_clicks_sub_camp_date ON link_clicks(subscriber_id, campaign_id, created_at);
	`); err != nil {
		return err
	}

	return nil
}
