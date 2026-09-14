-- links
-- name: create-link
INSERT INTO links (uuid, url) VALUES($1, $2) ON CONFLICT (url) DO UPDATE SET url=EXCLUDED.url RETURNING uuid;

-- name: get-link-url
SELECT url FROM links WHERE uuid = $1;

-- name: register-link-click
-- $4 is the caller's user-agent verdict. $5/$6 are the burst thresholds: a hit is
-- also treated as machine traffic when it is the $5-th click the subscriber has
-- registered on the campaign within the preceding $6 seconds, which is how link
-- scanners that spoof a browser user-agent give themselves away. The count is
-- inclusive of the row being inserted, matching --flag-bot-activity.
WITH link AS(
    SELECT id, url FROM links WHERE uuid = $1
),
camp AS (
    SELECT id FROM campaigns WHERE uuid = $2
),
sub AS (
    SELECT id FROM subscribers WHERE
        (CASE WHEN $3::TEXT != '' THEN subscribers.uuid = $3::UUID ELSE FALSE END)
),
burst AS (
    SELECT ($4::BOOLEAN OR ((COUNT(*) + 1) >= $5::INT)) AS is_bot
    FROM link_clicks
    WHERE subscriber_id = (SELECT id FROM sub)
        AND campaign_id = (SELECT id FROM camp)
        AND created_at >= NOW() - MAKE_INTERVAL(secs => $6::INT)
)
INSERT INTO link_clicks (campaign_id, subscriber_id, link_id, is_bot) VALUES(
    (SELECT id FROM camp),
    (SELECT id FROM sub),
    (SELECT id FROM link),
    (SELECT is_bot FROM burst)
) RETURNING (SELECT url FROM link);
