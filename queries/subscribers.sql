-- subscribers
-- name: get-subscriber
-- Get a single subscriber by id or UUID or email.
SELECT * FROM subscribers WHERE
    CASE
        WHEN $1 > 0 THEN id = $1
        WHEN $2 != '' THEN uuid = $2::UUID
        WHEN $3 != '' THEN email = $3
    END;

-- name: has-subscriber-list
-- Used for checking access permission by list.
SELECT s.id AS subscriber_id,
    CASE
        WHEN EXISTS (SELECT 1 FROM subscriber_lists sl WHERE sl.subscriber_id = s.id AND sl.list_id = ANY($2))
        THEN TRUE
        ELSE FALSE
    END AS has
FROM subscribers s WHERE s.id = ANY($1);

-- name: get-subscribers-by-emails
-- Get subscribers by emails.
SELECT * FROM subscribers WHERE email=ANY($1);

-- name: get-subscriber-lists
WITH sub AS (
    SELECT id FROM subscribers WHERE CASE WHEN $1 > 0 THEN id = $1 ELSE uuid = $2 END
)
SELECT * FROM lists
    LEFT JOIN subscriber_lists ON (lists.id = subscriber_lists.list_id)
    WHERE subscriber_id = (SELECT id FROM sub)
    -- Optional list IDs or UUIDs to filter.
    AND (CASE WHEN CARDINALITY($3::INT[]) > 0 THEN id = ANY($3::INT[])
          WHEN CARDINALITY($4::UUID[]) > 0 THEN uuid = ANY($4::UUID[])
          ELSE TRUE
    END)
    AND (CASE WHEN $5 != '' THEN subscriber_lists.status = $5::subscription_status ELSE TRUE END)
    AND (CASE WHEN $6 != '' THEN lists.optin = $6::list_optin ELSE TRUE END)
    ORDER BY id;

-- name: get-subscriber-lists-lazy
-- Get lists associations of subscribers given a list of subscriber IDs.
-- This query is used to lazy load given a list of subscriber IDs.
-- The query returns results in the same order as the given subscriber IDs, and for non-existent subscriber IDs,
-- the query still returns a row with 0 values. Thus, for lazy loading, the application simply iterate on the results in
-- the same order as the list of campaigns it would've queried and attach the results.
WITH subs AS (
    SELECT subscriber_id, JSON_AGG(
        ROW_TO_JSON(
            (SELECT l FROM (
                SELECT
                    subscriber_lists.status AS subscription_status,
                    subscriber_lists.created_at AS subscription_created_at,
                    subscriber_lists.updated_at AS subscription_updated_at,
                    subscriber_lists.meta AS subscription_meta,
                    lists.*
            ) l)
        )
    ) AS lists FROM lists
    LEFT JOIN subscriber_lists ON (subscriber_lists.list_id = lists.id)
    WHERE subscriber_lists.subscriber_id = ANY($1)
    GROUP BY subscriber_id
)
SELECT id as subscriber_id,
    COALESCE(s.lists, '[]') AS lists
    FROM (SELECT id FROM UNNEST($1) AS id) x
    LEFT JOIN subs AS s ON (s.subscriber_id = id)
    ORDER BY ARRAY_POSITION($1, id);

-- name: get-subscriptions
-- Retrieves all lists a subscriber is attached to.
-- if $3 is set to true, all lists are fetched including the subscriber's subscriptions.
-- subscription_status, and subscription_created_at are null in that case.
WITH sub AS (
    SELECT id FROM subscribers WHERE CASE WHEN $1 > 0 THEN id = $1 ELSE uuid = $2 END
)
SELECT lists.*,
    subscriber_lists.status as subscription_status,
    subscriber_lists.created_at as subscription_created_at,
    subscriber_lists.meta as subscription_meta
    FROM lists LEFT JOIN subscriber_lists
    ON (subscriber_lists.list_id = lists.id AND subscriber_lists.subscriber_id = (SELECT id FROM sub))
    WHERE CASE WHEN $3 = TRUE THEN TRUE ELSE subscriber_lists.status IS NOT NULL END
    ORDER BY subscriber_lists.status;

-- name: insert-subscriber
WITH sub AS (
    INSERT INTO subscribers (uuid, email, name, status, attribs)
    VALUES($1, $2, $3, $4, $5)
    RETURNING id, status
),
listIDs AS (
    SELECT id FROM lists WHERE
        (CASE WHEN CARDINALITY($6::INT[]) > 0 THEN id=ANY($6)
              ELSE uuid=ANY($7::UUID[]) END)
),
subs AS (
    INSERT INTO subscriber_lists (subscriber_id, list_id, status)
    VALUES(
        (SELECT id FROM sub),
        UNNEST(ARRAY(SELECT id FROM listIDs)),
        (CASE WHEN $4='blocklisted' THEN 'unsubscribed'::subscription_status ELSE $8::subscription_status END)
    )
    ON CONFLICT (subscriber_id, list_id) DO UPDATE
        SET updated_at=NOW(),
            status=(
                CASE WHEN $4='blocklisted' OR (SELECT status FROM sub)='blocklisted'
                THEN 'unsubscribed'::subscription_status
                ELSE $8::subscription_status END
            )
)
SELECT id from sub;

-- name: upsert-subscriber
-- Upserts a subscriber where existing subscribers get their names and attributes overwritten.
-- If $7 = true, update name/attribs. If $8 = true, update subscription status.
WITH sub AS (
    INSERT INTO subscribers as s (uuid, email, name, attribs, status)
    VALUES($1, $2, $3, $4, 'enabled')
    ON CONFLICT (email)
    DO UPDATE SET
        name=(CASE WHEN $7 THEN $3 ELSE s.name END),
        attribs=(CASE WHEN $7 THEN $4 ELSE s.attribs END),
        updated_at=NOW()
    RETURNING uuid, id, status
),
subs AS (
    INSERT INTO subscriber_lists (subscriber_id, list_id, status)
    SELECT sub.id, listID, CASE WHEN sub.status = 'blocklisted' THEN 'unsubscribed' ELSE $6::subscription_status END
    FROM sub, UNNEST($5::INT[]) AS listID
    ON CONFLICT (subscriber_id, list_id) DO UPDATE
    SET updated_at = NOW(),
        status = CASE WHEN $8 THEN EXCLUDED.status ELSE subscriber_lists.status END
)
SELECT uuid, id from sub;

-- name: upsert-blocklist-subscriber
-- Upserts a subscriber where the update will only set the status to blocklisted
-- unlike upsert-subscribers where name and attributes are updated. In addition, all
-- existing subscriptions are marked as 'unsubscribed'.
-- This is used in the bulk importer.
WITH sub AS (
    INSERT INTO subscribers (uuid, email, name, attribs, status)
    VALUES($1, $2, $3, $4, 'blocklisted')
    ON CONFLICT (email) DO UPDATE SET status='blocklisted', updated_at=NOW()
    RETURNING id
)
UPDATE subscriber_lists SET status='unsubscribed', updated_at=NOW()
    WHERE subscriber_id = (SELECT id FROM sub);

-- name: update-subscriber
UPDATE subscribers SET
    email=(CASE WHEN $2 != '' THEN $2 ELSE email END),
    name=(CASE WHEN $3 != '' THEN $3 ELSE name END),
    status=(CASE WHEN $4 != '' THEN $4::subscriber_status ELSE status END),
    attribs=(CASE WHEN $5 != '' THEN $5::JSONB ELSE attribs END),
    updated_at=NOW()
WHERE id = $1;

-- name: update-subscriber-with-lists
-- Updates a subscriber's data, and given a list of list_ids, inserts subscriptions
-- for them while deleting existing subscriptions not in the list.
WITH s AS (
    UPDATE subscribers SET
        email=(CASE WHEN $2 != '' THEN $2 ELSE email END),
        name=(CASE WHEN $3 != '' THEN $3 ELSE name END),
        status=(CASE WHEN $4 != '' THEN $4::subscriber_status ELSE status END),
        attribs=(CASE WHEN $5 != '' THEN $5::JSONB ELSE attribs END),
        updated_at=NOW()
    WHERE id = $1 RETURNING id
),
listIDs AS (
    SELECT id FROM lists WHERE
        (CASE WHEN CARDINALITY($6::INT[]) > 0 THEN id=ANY($6)
              ELSE uuid=ANY($7::UUID[]) END)
),
d AS (
    DELETE FROM subscriber_lists WHERE $9 = TRUE AND subscriber_id = $1
        AND list_id != ALL(SELECT id FROM listIDs)
        AND (CARDINALITY($10::INT[]) = 0 OR list_id = ANY($10::INT[]))
)
INSERT INTO subscriber_lists (subscriber_id, list_id, status)
    VALUES(
        (SELECT id FROM s),
        UNNEST(ARRAY(SELECT id FROM listIDs)),
        (CASE WHEN $4='blocklisted' THEN 'unsubscribed'::subscription_status ELSE $8::subscription_status END)
    )
    ON CONFLICT (subscriber_id, list_id) DO UPDATE
    SET status = (
        CASE
            WHEN $4='blocklisted' THEN 'unsubscribed'::subscription_status
            -- When $11 (allow resubscribe) is true, override existing statuses except confirmed (used by
            -- public subscription form).
            WHEN subscriber_lists.status = 'confirmed' THEN 'confirmed'
            WHEN $11 = TRUE THEN $8::subscription_status
            -- When subscriber is edited from the admin form, retain the status. Otherwise, a blocklisted
            -- subscriber when being re-enabled, their subscription statuses change.
            WHEN subscriber_lists.status = 'unsubscribed' THEN 'unsubscribed'::subscription_status
            ELSE $8::subscription_status
        END
    );

-- name: delete-subscribers
-- Delete one or more subscribers by ID or UUID.
DELETE FROM subscribers WHERE CASE WHEN ARRAY_LENGTH($1::INT[], 1) > 0 THEN id = ANY($1) ELSE uuid = ANY($2::UUID[]) END;

-- name: delete-blocklisted-subscribers
DELETE FROM subscribers WHERE status = 'blocklisted';

-- name: delete-orphan-subscribers
DELETE FROM subscribers a WHERE NOT EXISTS
    (SELECT 1 FROM subscriber_lists b WHERE b.subscriber_id = a.id);

-- name: blocklist-subscribers
WITH b AS (
    UPDATE subscribers SET status='blocklisted', updated_at=NOW()
    WHERE id = ANY($1::INT[])
)
UPDATE subscriber_lists SET status='unsubscribed', updated_at=NOW()
    WHERE subscriber_id = ANY($1::INT[]);

-- name: add-subscribers-to-lists
INSERT INTO subscriber_lists (subscriber_id, list_id, status)
    (SELECT a, b, (CASE WHEN $3 != '' THEN $3::subscription_status ELSE 'unconfirmed' END) FROM UNNEST($1::INT[]) a, UNNEST($2::INT[]) b)
    ON CONFLICT (subscriber_id, list_id) DO UPDATE SET status=(CASE WHEN $3 != '' THEN $3::subscription_status ELSE subscriber_lists.status END);

-- name: delete-subscriptions
DELETE FROM subscriber_lists
    WHERE (subscriber_id, list_id) = ANY(SELECT a, b FROM UNNEST($1::INT[]) a, UNNEST($2::INT[]) b);

-- name: confirm-subscription-optin
WITH subID AS (
    SELECT id FROM subscribers WHERE uuid = $1::UUID
),
listIDs AS (
    SELECT id FROM lists WHERE uuid = ANY($2::UUID[])
)
UPDATE subscriber_lists SET status='confirmed', meta=meta || $3, updated_at=NOW()
    WHERE subscriber_id = (SELECT id FROM subID) AND list_id = ANY(SELECT id FROM listIDs);

-- name: unsubscribe-subscribers-from-lists
WITH listIDs AS (
    SELECT ARRAY(
        SELECT id FROM lists WHERE
        (CASE WHEN CARDINALITY($2::INT[]) > 0 THEN id=ANY($2) ELSE uuid=ANY($3::UUID[]) END)
    ) id
)
UPDATE subscriber_lists SET status='unsubscribed', updated_at=NOW()
    WHERE (subscriber_id, list_id) = ANY(SELECT a, b FROM UNNEST($1::INT[]) a, UNNEST((SELECT id FROM listIDs)) b);

-- name: unsubscribe-by-campaign
-- Unsubscribes a subscriber given a campaign UUID (from all the lists in the campaign) and the subscriber UUID.
-- If $3 is TRUE, then all subscriptions of the subscriber is blocklisted
-- and all existing subscriptions, irrespective of lists, unsubscribed.
WITH lists AS (
    SELECT list_id FROM campaign_lists
    LEFT JOIN campaigns ON (campaign_lists.campaign_id = campaigns.id)
    WHERE campaigns.uuid = $1
),
sub AS (
    UPDATE subscribers SET status = (CASE WHEN $3 IS TRUE THEN 'blocklisted' ELSE status END)
    WHERE uuid = $2 RETURNING id
)
UPDATE subscriber_lists SET status = 'unsubscribed', updated_at=NOW() WHERE
    subscriber_id = (SELECT id FROM sub) AND status != 'unsubscribed' AND
    -- If $3 is false, unsubscribe from the campaign's lists, otherwise all lists.
    CASE WHEN $3 IS FALSE THEN list_id = ANY(SELECT list_id FROM lists) ELSE list_id != 0 END;

-- name: delete-unconfirmed-subscriptions
WITH optins AS (
    SELECT id FROM lists WHERE optin = 'double'
)
DELETE FROM subscriber_lists
    WHERE status = 'unconfirmed' AND list_id IN (SELECT id FROM optins) AND created_at < $1;


-- Partial and RAW queries used to construct arbitrary subscriber
-- queries for segmentation follow.

-- name: query-subscribers
-- raw: true
-- Unprepared statement for issuring arbitrary WHERE conditions for
-- searching subscribers. While the results are sliced using offset+limit,
-- there's a COUNT() OVER() that still returns the total result count
-- for pagination in the frontend, albeit being a field that'll repeat
-- with every resultant row.
SELECT subscribers.* FROM subscribers
    LEFT JOIN subscriber_lists
    ON (
        -- Optional list filtering.
        (CASE WHEN CARDINALITY($1::INT[]) > 0 THEN true ELSE false END)
        AND subscriber_lists.subscriber_id = subscribers.id
        AND ($2 = '' OR subscriber_lists.status = $2::subscription_status)
    )
    WHERE (CARDINALITY($1) = 0 OR subscriber_lists.list_id = ANY($1::INT[]))
    AND (CASE WHEN $3 != '' THEN name ~* $3 OR email ~* $3 ELSE TRUE END)
    AND %query%
    ORDER BY %order% OFFSET $4 LIMIT (CASE WHEN $5 < 1 THEN NULL ELSE $5 END);

-- name: query-subscribers-count
-- Replica of query-subscribers for obtaining the results count.
SELECT COUNT(*) AS total FROM subscribers
    LEFT JOIN subscriber_lists
    ON (
        -- Optional list filtering.
        (CASE WHEN CARDINALITY($1::INT[]) > 0 THEN true ELSE false END)
        AND subscriber_lists.subscriber_id = subscribers.id
        AND ($2 = '' OR subscriber_lists.status = $2::subscription_status)
    )
    WHERE (CARDINALITY($1) = 0 OR subscriber_lists.list_id = ANY($1::INT[]))
    AND (CASE WHEN $3 != '' THEN name ~* $3 OR email ~* $3 ELSE TRUE END)
    AND %query%;

-- name: query-subscribers-count-all
-- Cached query for getting the "all" subscriber count without arbitrary conditions.
SELECT COALESCE(SUM(subscriber_count), 0) AS total FROM mat_list_subscriber_stats
    WHERE list_id = ANY(CASE WHEN CARDINALITY($1::INT[]) > 0 THEN $1 ELSE '{0}' END)
    AND ($2 = '' OR status = $2::subscription_status);

-- name: query-subscribers-for-export
-- raw: true
-- Unprepared statement for issuring arbitrary WHERE conditions for
-- searching subscribers to do bulk CSV export.
SELECT subscribers.id,
       subscribers.uuid,
       subscribers.email,
       subscribers.name,
       subscribers.status,
       subscribers.attribs,
       subscribers.created_at,
       subscribers.updated_at
       FROM subscribers
    LEFT JOIN subscriber_lists
    ON (
        -- Optional list filtering.
        (CASE WHEN CARDINALITY($1::INT[]) > 0 THEN true ELSE false END)
        AND subscriber_lists.subscriber_id = subscribers.id
        AND ($4 = '' OR subscriber_lists.status = $4::subscription_status)
    )
    WHERE subscriber_lists.list_id = ALL($1::INT[]) AND id > $2
    AND (CASE WHEN CARDINALITY($3::INT[]) > 0 THEN id=ANY($3) ELSE true END)
    AND (CASE WHEN $5 != '' THEN name ~* $5 OR email ~* $5 ELSE TRUE END)
    AND %query%
    ORDER BY subscribers.id ASC LIMIT (CASE WHEN $6 < 1 THEN NULL ELSE $6 END);

-- name: query-subscribers-template
-- raw: true
-- This raw query is reused in multiple queries (blocklist, add to list, delete)
-- etc., so it's kept has a raw template to be injected into other raw queries,
-- and for the same reason, it is not terminated with a semicolon.
--
-- All queries that embed this query should expect
-- $1=true/false (dry-run or not) and $2=[]INT (option list IDs).
-- That is, their positional arguments should start from $4.
SELECT subscribers.id FROM subscribers
LEFT JOIN subscriber_lists
ON (
    -- Optional list filtering.
    (CASE WHEN CARDINALITY($2::INT[]) > 0 THEN true ELSE false END)
    AND subscriber_lists.subscriber_id = subscribers.id
    AND ($3 = '' OR subscriber_lists.status = $3::subscription_status)
)
WHERE subscriber_lists.list_id = ALL($2::INT[])
    AND (CASE WHEN $4 != '' THEN name ~* $4 OR email ~* $4 ELSE TRUE END)
    AND %query%
LIMIT (CASE WHEN $1 THEN 1 END)

-- name: delete-subscribers-by-query
-- raw: true
WITH subs AS (%query%)
DELETE FROM subscribers WHERE id=ANY(SELECT id FROM subs);

-- name: blocklist-subscribers-by-query
-- raw: true
WITH subs AS (%query%),
b AS (
    UPDATE subscribers SET status='blocklisted', updated_at=NOW()
    WHERE id = ANY(SELECT id FROM subs)
)
UPDATE subscriber_lists SET status='unsubscribed', updated_at=NOW()
    WHERE subscriber_id = ANY(SELECT id FROM subs);

-- name: add-subscribers-to-lists-by-query
-- raw: true
WITH subs AS (%query%)
INSERT INTO subscriber_lists (subscriber_id, list_id, status)
    (SELECT a, b, (CASE WHEN $6 != '' THEN $6::subscription_status ELSE 'unconfirmed' END) FROM UNNEST(ARRAY(SELECT id FROM subs)) a, UNNEST($5::INT[]) b)
    ON CONFLICT (subscriber_id, list_id) DO NOTHING;

-- name: delete-subscriptions-by-query
-- raw: true
WITH subs AS (%query%)
DELETE FROM subscriber_lists
    WHERE (subscriber_id, list_id) = ANY(SELECT a, b FROM UNNEST(ARRAY(SELECT id FROM subs)) a, UNNEST($5::INT[]) b);

-- name: unsubscribe-subscribers-from-lists-by-query
-- raw: true
WITH subs AS (%query%)
UPDATE subscriber_lists SET status='unsubscribed', updated_at=NOW()
    WHERE (subscriber_id, list_id) = ANY(SELECT a, b FROM UNNEST(ARRAY(SELECT id FROM subs)) a, UNNEST($5::INT[]) b);


-- privacy
-- name: export-subscriber-data
WITH prof AS (
    SELECT id, uuid, email, name, attribs, status, created_at, updated_at FROM subscribers WHERE
    CASE WHEN $1 > 0 THEN id = $1 ELSE uuid = $2 END
),
subs AS (
    SELECT subscriber_lists.status AS subscription_status,
            (CASE WHEN lists.type = 'private' THEN 'Private list' ELSE lists.name END) as name,
            lists.type, subscriber_lists.created_at
    FROM lists
    LEFT JOIN subscriber_lists ON (subscriber_lists.list_id = lists.id)
    WHERE subscriber_lists.subscriber_id = (SELECT id FROM prof)
),
views AS (
    SELECT subject as campaign, COUNT(subscriber_id) as views FROM campaign_views
        LEFT JOIN campaigns ON (campaigns.id = campaign_views.campaign_id)
        WHERE subscriber_id = (SELECT id FROM prof)
        GROUP BY campaigns.id ORDER BY campaigns.id
),
clicks AS (
    SELECT url, COUNT(subscriber_id) as clicks FROM link_clicks
        LEFT JOIN links ON (links.id = link_clicks.link_id)
        WHERE subscriber_id = (SELECT id FROM prof)
        GROUP BY links.id ORDER BY links.id
)
SELECT (SELECT email FROM prof) as email,
        COALESCE((SELECT JSON_AGG(t) FROM prof t), '{}') AS profile,
        COALESCE((SELECT JSON_AGG(t) FROM subs t), '[]') AS subscriptions,
        COALESCE((SELECT JSON_AGG(t) FROM views t), '[]') AS campaign_views,
        COALESCE((SELECT JSON_AGG(t) FROM clicks t), '[]') AS link_clicks;

-- name: get-subscriber-activity
-- Gets the subscriber's campaign views and link clicks with detailed information
-- for display in the Activity tab
WITH views AS (
    SELECT
        c.id,
        c.uuid,
        c.name,
        c.subject,
        COUNT(*) as view_count,
        MAX(cv.created_at) as last_viewed_at
    FROM campaign_views cv
    LEFT JOIN campaigns c ON c.id = cv.campaign_id
    WHERE cv.subscriber_id = $1 AND NOT cv.is_bot
    GROUP BY c.id, c.uuid, c.name, c.subject
    ORDER BY last_viewed_at DESC
),
clicks AS (
    SELECT
        l.id as link_id,
        l.url,
        c.id as campaign_id,
        c.uuid as campaign_uuid,
        c.name as campaign_name,
        c.subject as campaign_subject,
        COUNT(*) as click_count,
        MAX(lc.created_at) as last_clicked_at
    FROM link_clicks lc
    LEFT JOIN links l ON l.id = lc.link_id
    LEFT JOIN campaigns c ON c.id = lc.campaign_id
    WHERE lc.subscriber_id = $1 AND NOT lc.is_bot
    GROUP BY l.id, l.url, c.id, c.uuid, c.name, c.subject
    ORDER BY last_clicked_at DESC
)
SELECT
    COALESCE((SELECT JSON_AGG(v) FROM views v), '[]') as campaign_views,
    COALESCE((SELECT JSON_AGG(c) FROM clicks c), '[]') as link_clicks;

-- name: get-subscribers-activity
-- One row per subscriber across all campaigns, ranked by engagement. Empty date bounds mean all time.
-- $1 is the list IDs the user is permitted to see; an empty array means unrestricted.
WITH views AS (
    SELECT subscriber_id, COUNT(*) AS num,
           MIN(created_at) AS first_at, MAX(created_at) AS last_at
    FROM campaign_views
    WHERE subscriber_id IS NOT NULL AND NOT is_bot
      AND created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY subscriber_id
),
clicks AS (
    SELECT subscriber_id, COUNT(*) AS num, COUNT(DISTINCT link_id) AS links,
           MIN(created_at) AS first_at, MAX(created_at) AS last_at
    FROM link_clicks
    WHERE subscriber_id IS NOT NULL AND NOT is_bot
      AND created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY subscriber_id
),
bounced AS (
    SELECT subscriber_id, COUNT(*) AS num,
           (ARRAY_AGG(type ORDER BY created_at DESC))[1]::TEXT AS last_type,
           MAX(created_at) AS last_at
    FROM bounces
    WHERE created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY subscriber_id
)
SELECT COUNT(*) OVER () AS total,
       subscribers.id AS subscriber_id,
       subscribers.email,
       subscribers.name AS subscriber_name,
       subscribers.status::TEXT AS subscriber_status,
       COALESCE(views.num, 0) AS views,
       COALESCE(clicks.num, 0) AS clicks,
       COALESCE(clicks.links, 0) AS links,
       COALESCE(bounced.num, 0) AS bounces,
       COALESCE(bounced.last_type, '') AS bounce_type,
       LEAST(views.first_at, clicks.first_at) AS first_at,
       GREATEST(views.last_at, clicks.last_at, bounced.last_at) AS last_at
    FROM subscribers
    LEFT JOIN views ON (views.subscriber_id = subscribers.id)
    LEFT JOIN clicks ON (clicks.subscriber_id = subscribers.id)
    LEFT JOIN bounced ON (bounced.subscriber_id = subscribers.id)
    WHERE (views.subscriber_id IS NOT NULL OR clicks.subscriber_id IS NOT NULL OR bounced.subscriber_id IS NOT NULL)
      AND (CARDINALITY($1::INT[]) = 0 OR EXISTS (
             SELECT 1 FROM subscriber_lists
             WHERE subscriber_lists.subscriber_id = subscribers.id AND subscriber_lists.list_id = ANY($1::INT[])
           ))
      AND (CASE $4::TEXT
             WHEN 'opened'  THEN views.subscriber_id IS NOT NULL
             WHEN 'clicked' THEN clicks.subscriber_id IS NOT NULL
             WHEN 'bounced' THEN bounced.subscriber_id IS NOT NULL
             ELSE TRUE
           END)
      AND ($5::TEXT = '' OR subscribers.email ILIKE $5 OR subscribers.name ILIKE $5)
    ORDER BY (COALESCE(views.num, 0) + COALESCE(clicks.num, 0)) DESC, last_at DESC NULLS LAST, subscribers.id
    OFFSET $6 LIMIT (CASE WHEN $7 < 1 THEN NULL ELSE $7 END);

-- name: get-subscribers-activity-charts
-- Aggregate engagement shape across all subscribers. $1 is the permitted list IDs; empty means unrestricted.
WITH perm AS (
    SELECT id, created_at FROM subscribers
    WHERE CARDINALITY($1::INT[]) = 0 OR EXISTS (
             SELECT 1 FROM subscriber_lists
             WHERE subscriber_lists.subscriber_id = subscribers.id
               AND subscriber_lists.list_id = ANY($1::INT[])
           )
),
-- Subscribers added after the last campaign went out were never mailed, so counting them
-- as unengaged would be wrong. They get their own bucket.
last_send AS (
    SELECT MAX(started_at) AS at FROM campaigns WHERE started_at IS NOT NULL
),
events AS (
    SELECT subscriber_id, created_at, FALSE AS is_click FROM campaign_views WHERE subscriber_id IS NOT NULL AND NOT is_bot
    UNION ALL
    SELECT subscriber_id, created_at, TRUE AS is_click FROM link_clicks WHERE subscriber_id IS NOT NULL AND NOT is_bot
),
-- Recency ignores the date filter on purpose. "Days since last activity" is only meaningful
-- against the present, and the LEFT JOIN keeps subscribers with no activity at all.
last_activity AS (
    SELECT perm.id, perm.created_at, MAX(events.created_at) AS last_at
    FROM perm LEFT JOIN events ON events.subscriber_id = perm.id
    GROUP BY perm.id, perm.created_at
),
recency AS (
    SELECT CASE WHEN last_at IS NULL AND created_at > COALESCE((SELECT at FROM last_send), '-infinity') THEN 'notsent'
                WHEN last_at IS NULL THEN 'never'
                WHEN last_at >= NOW() - INTERVAL '7 days' THEN 'd7'
                WHEN last_at >= NOW() - INTERVAL '30 days' THEN 'd30'
                WHEN last_at >= NOW() - INTERVAL '90 days' THEN 'd90'
                WHEN last_at >= NOW() - INTERVAL '180 days' THEN 'd180'
                ELSE 'older' END AS bucket,
           COUNT(*) AS num
    FROM last_activity GROUP BY 1
),
-- Bucket width follows the selected window. Fixed monthly buckets collapse a 7 or 30 day
-- range into one or two points, which draws an empty chart.
granularity AS (
    SELECT CASE
        WHEN NULLIF($2, '') IS NULL THEN 'month'
        WHEN EXTRACT(EPOCH FROM (COALESCE(NULLIF($3, '')::TIMESTAMPTZ, NOW()) - $2::TIMESTAMPTZ)) / 86400 > 92
            THEN 'month'
        ELSE 'day'
    END AS unit
),
-- Unique subscribers per bucket, not raw event counts, so the trend shows audience decay.
timeline AS (
    SELECT DATE_TRUNC((SELECT unit FROM granularity), events.created_at) AS period,
           COUNT(DISTINCT events.subscriber_id) FILTER (WHERE NOT is_click) AS views,
           COUNT(DISTINCT events.subscriber_id) FILTER (WHERE is_click) AS clicks
    FROM events JOIN perm ON perm.id = events.subscriber_id
    WHERE events.created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND events.created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY 1
)
SELECT
    (SELECT unit FROM granularity) AS granularity,
    COALESCE((SELECT JSON_AGG(JSON_BUILD_OBJECT('bucket', bucket, 'count', num)
              ORDER BY ARRAY_POSITION(ARRAY['d7', 'd30', 'd90', 'd180', 'older', 'never', 'notsent'], bucket))
              FROM recency), '[]') AS recency,
    COALESCE((SELECT JSON_AGG(JSON_BUILD_OBJECT('period', period, 'views', views, 'clicks', clicks) ORDER BY period)
              FROM timeline), '[]') AS timeline;

-- name: get-subscriber-campaign-activity
-- One row per campaign for a single subscriber. Empty when privacy.individual_tracking is off.
WITH views AS (
    SELECT campaign_id, COUNT(*) AS num,
           MIN(created_at) AS first_at, MAX(created_at) AS last_at
    FROM campaign_views
    WHERE subscriber_id = $1 AND NOT is_bot
      AND created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY campaign_id
),
clicks AS (
    SELECT campaign_id, COUNT(*) AS num, COUNT(DISTINCT link_id) AS links,
           MIN(created_at) AS first_at, MAX(created_at) AS last_at
    FROM link_clicks
    WHERE subscriber_id = $1 AND campaign_id IS NOT NULL AND NOT is_bot
      AND created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY campaign_id
),
bounced AS (
    SELECT campaign_id, COUNT(*) AS num,
           (ARRAY_AGG(type ORDER BY created_at DESC))[1]::TEXT AS last_type,
           MAX(created_at) AS last_at
    FROM bounces
    WHERE subscriber_id = $1 AND campaign_id IS NOT NULL
      AND created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
      AND created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
    GROUP BY campaign_id
),
clicked_links AS (
    SELECT campaign_id,
           JSON_AGG(JSON_BUILD_OBJECT('url', url, 'count', num, 'last_at', last_at)
                    ORDER BY num DESC, url) AS items
    FROM (
        SELECT link_clicks.campaign_id, links.url,
               COUNT(*) AS num, MAX(link_clicks.created_at) AS last_at
        FROM link_clicks
        JOIN links ON (links.id = link_clicks.link_id)
        WHERE link_clicks.subscriber_id = $1 AND link_clicks.campaign_id IS NOT NULL AND NOT link_clicks.is_bot
          AND link_clicks.created_at >= COALESCE(NULLIF($2, '')::TIMESTAMPTZ, '-infinity'::TIMESTAMPTZ)
          AND link_clicks.created_at <= COALESCE(NULLIF($3, '')::TIMESTAMPTZ, 'infinity'::TIMESTAMPTZ)
        GROUP BY link_clicks.campaign_id, links.url
    ) t
    GROUP BY campaign_id
)
SELECT COUNT(*) OVER () AS total,
       campaigns.id AS campaign_id,
       campaigns.name AS campaign_name,
       campaigns.subject AS campaign_subject,
       COALESCE(views.num, 0) AS views,
       COALESCE(clicks.num, 0) AS clicks,
       COALESCE(clicks.links, 0) AS links,
       COALESCE(bounced.num, 0) AS bounces,
       COALESCE(bounced.last_type, '') AS bounce_type,
       COALESCE(clicked_links.items, '[]') AS clicked_links,
       LEAST(views.first_at, clicks.first_at) AS first_at,
       GREATEST(views.last_at, clicks.last_at, bounced.last_at) AS last_at
    FROM campaigns
    LEFT JOIN views ON (views.campaign_id = campaigns.id)
    LEFT JOIN clicks ON (clicks.campaign_id = campaigns.id)
    LEFT JOIN bounced ON (bounced.campaign_id = campaigns.id)
    LEFT JOIN clicked_links ON (clicked_links.campaign_id = campaigns.id)
    WHERE (views.campaign_id IS NOT NULL OR clicks.campaign_id IS NOT NULL OR bounced.campaign_id IS NOT NULL)
      AND (CASE $4::TEXT
             WHEN 'opened'  THEN views.campaign_id IS NOT NULL
             WHEN 'clicked' THEN clicks.campaign_id IS NOT NULL
             WHEN 'bounced' THEN bounced.campaign_id IS NOT NULL
             ELSE TRUE
           END)
    ORDER BY last_at DESC, campaigns.id
    OFFSET $5 LIMIT (CASE WHEN $6 < 1 THEN NULL ELSE $6 END);
