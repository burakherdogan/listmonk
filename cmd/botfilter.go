package main

import (
	"fmt"

	"github.com/jmoiron/sqlx"
	"github.com/knadh/listmonk/internal/bot"
)

// Historical rows carry no User-Agent, so reclassification is purely
// behavioural. Two signatures separate mail security scanners from readers:
//
//   - Burst: the subscriber registers bot.BurstClickLimit hits on one campaign
//     inside bot.BurstWindowSecs. Gateways walk every link in a message in
//     seconds.
//   - Repetition: the subscriber accumulates repeatClickFactor hits per unique
//     link on one campaign. Gateways re-scan the same links for days, so the
//     hit-to-link ratio climbs far past anything a reader produces.
//
// The repetition rule only applies past repeatClickFloor hits so that small,
// genuinely re-read campaigns are left alone.
const (
	repeatClickFactor = 4
	repeatClickFloor  = 20
)

// flagBotActivity reclassifies existing clicks and views that match the
// scanner signatures. It is idempotent: rows already flagged are skipped, and
// the verdict is derived from the full history each run, so it is safe to
// re-run on a schedule. Nothing is deleted; clearing `is_bot` restores the
// original counts.
func flagBotActivity(db *sqlx.DB) {
	clicks, err := flagBotClicks(db)
	if err != nil {
		lo.Fatalf("error flagging bot clicks: %v", err)
	}

	views, err := flagBotViews(db)
	if err != nil {
		lo.Fatalf("error flagging bot views: %v", err)
	}

	lo.Printf("flagged %d link click(s) and %d campaign view(s) as bot activity", clicks, views)
}

func flagBotClicks(db *sqlx.DB) (int64, error) {
	res, err := db.Exec(fmt.Sprintf(`
		WITH burst AS (
			SELECT id, COUNT(*) OVER (
				PARTITION BY subscriber_id, campaign_id ORDER BY created_at
				RANGE BETWEEN INTERVAL '%d seconds' PRECEDING AND CURRENT ROW
			) AS num
			FROM link_clicks
			WHERE subscriber_id IS NOT NULL AND campaign_id IS NOT NULL
		),
		repeated AS (
			SELECT subscriber_id, campaign_id
			FROM link_clicks
			WHERE subscriber_id IS NOT NULL AND campaign_id IS NOT NULL
			GROUP BY subscriber_id, campaign_id
			HAVING COUNT(*) >= %d AND COUNT(*) >= %d * COUNT(DISTINCT link_id)
		),
		target AS (
			SELECT id FROM burst WHERE num >= %d
			UNION
			SELECT lc.id FROM link_clicks lc JOIN repeated USING (subscriber_id, campaign_id)
		)
		UPDATE link_clicks lc SET is_bot = TRUE
		FROM target WHERE target.id = lc.id AND NOT lc.is_bot;
	`, bot.BurstWindowSecs, repeatClickFloor, repeatClickFactor, bot.BurstClickLimit))
	if err != nil {
		return 0, err
	}

	return res.RowsAffected()
}

// flagBotViews applies only the burst rule. Views carry no link, so there is no
// repetition ratio to measure, and a subscriber legitimately re-opening a
// campaign over time must not be penalised.
func flagBotViews(db *sqlx.DB) (int64, error) {
	res, err := db.Exec(fmt.Sprintf(`
		WITH burst AS (
			SELECT id, COUNT(*) OVER (
				PARTITION BY subscriber_id, campaign_id ORDER BY created_at
				RANGE BETWEEN INTERVAL '%d seconds' PRECEDING AND CURRENT ROW
			) AS num
			FROM campaign_views
			WHERE subscriber_id IS NOT NULL
		)
		UPDATE campaign_views cv SET is_bot = TRUE
		FROM burst WHERE burst.id = cv.id AND burst.num >= %d AND NOT cv.is_bot;
	`, bot.BurstWindowSecs, bot.BurstClickLimit))
	if err != nil {
		return 0, err
	}

	return res.RowsAffected()
}
