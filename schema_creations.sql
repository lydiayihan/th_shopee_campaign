/*The dashboard uses a fact constellation schema with two fact tables at different grains 
sharing one dimension. 

fact_campaign_performance holds campaign-level metrics (one row per campaign) 
and fact_category_performance holds category-level metrics (one row per campaign x category). 
Both join to dim_campaign on campaign_id. 

Three standalone tables, fact_funnel, fact_new_buyers, and fact_monthly_gmv, 
sit outside the constellation with no relationships to dim_campaign 
because their metrics are platform-wide and should not be filtered by campaign slicers. 
fact_daily_baseline is a single-row constants table used for reference lines across all dashboard 
pages. */

SET search_path TO th_shopee_campaign;


-- STEP 1 — DIMENSIONS
CREATE TABLE dim_campaign AS
SELECT DISTINCT ON (c.campaign_id)
    c.campaign_id,
    c.campaign_name,
    c.campaign_type,
    c.start_date,
    c.end_date,
    EXTRACT(YEAR  FROM c.start_date)::INT           AS campaign_year,
    EXTRACT(MONTH FROM c.start_date)::INT           AS campaign_month,
    (c.end_date - c.start_date + 1)                 AS duration_days,
    COUNT(DISTINCT pc.product_id)                   AS total_products_enrolled,
    COUNT(DISTINCT p.seller_id)                     AS total_sellers_enrolled,
    ROUND(AVG(pc.discount_percent)::NUMERIC, 2)     AS avg_seller_discount_offered_pct
FROM raw_campaigns c
LEFT JOIN raw_product_campaign pc ON c.campaign_id = pc.campaign_id
LEFT JOIN raw_products          p  ON pc.product_id  = p.product_id
GROUP BY
    c.campaign_id, c.campaign_name, c.campaign_type,
    c.start_date, c.end_date
ORDER BY c.campaign_id;

-- ── dim_category


CREATE TABLE dim_category AS
SELECT DISTINCT category
FROM raw_products
ORDER BY category;

-- STEP 2 — CENTRAL FACT TABLE
CREATE TABLE fact_campaign_performance AS
WITH baseline AS (
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP
            (ORDER BY daily_gmv)                    AS median_gmv
    FROM (
        SELECT
            o.order_date,
            SUM(oi.line_total)                      AS daily_gmv
        FROM raw_order_items oi
        JOIN raw_orders o ON oi.order_id = o.order_id
        WHERE o.campaign_id IS NULL
        GROUP BY o.order_date
        HAVING COUNT(oi.order_item_id) >= 18
    ) d
),
cvr_by_campaign AS (
    SELECT
        ws.campaign_id,
        ROUND(
            COUNT(DISTINCT ws.session_id)
                FILTER (WHERE ws.order_id IS NOT NULL)::NUMERIC
            / NULLIF(COUNT(DISTINCT ws.session_id), 0) * 100,
        2)                                          AS cvr_pct,
        COUNT(DISTINCT ws.session_id)               AS total_sessions
    FROM raw_website_sessions ws
    WHERE ws.campaign_id IS NOT NULL
    GROUP BY ws.campaign_id
),
campaign_agg AS (
    SELECT
        c.campaign_id,
        c.campaign_name,
        EXTRACT(YEAR FROM c.start_date)::INT        AS campaign_year,
        COUNT(DISTINCT o.order_id)                  AS total_orders,
        COUNT(DISTINCT o.customer_id)               AS unique_buyers,
        ROUND(SUM(oi.line_total), 0)                AS total_gmv,
        ROUND(SUM(CASE WHEN oi.item_status = 'Completed'
            THEN oi.line_total ELSE 0 END), 0)      AS realized_gmv,
        ROUND(SUM(CASE WHEN oi.item_status
            IN ('Cancelled','Refunded')
            THEN oi.line_total ELSE 0 END), 0)      AS leaked_gmv,
        ROUND(SUM(oi.commission_amount)
            + SUM(oi.maintenance_amount), 0)        AS platform_revenue,
        ROUND(SUM(oi.line_total)
            / (c.end_date - c.start_date + 1), 0)  AS gmv_per_day,
        ROUND((
            SUM(oi.line_total)
            / (c.end_date - c.start_date + 1)
            / b.median_gmv
        )::NUMERIC, 2)                              AS corrected_lift,
        ROUND(
            SUM(CASE WHEN oi.item_status
                IN ('Cancelled','Refunded')
                THEN oi.line_total ELSE 0 END)
            / NULLIF(SUM(oi.line_total), 0) * 100,
        2)                                          AS leakage_pct,
        ROUND(AVG(oi.discount_percent)::NUMERIC, 2) AS avg_discount_pct
    FROM raw_order_items oi
    JOIN raw_orders    o  ON oi.order_id   = o.order_id
    JOIN raw_campaigns c  ON o.campaign_id = c.campaign_id
    CROSS JOIN baseline b
    WHERE o.campaign_id IS NOT NULL
    GROUP BY
        c.campaign_id, c.campaign_name, c.start_date, c.end_date, b.median_gmv
)
SELECT
    ca.campaign_id,
    ca.campaign_name,
    ca.campaign_year,
    ca.total_orders,
    ca.unique_buyers,
    ca.total_gmv,
    ca.realized_gmv,
    ca.leaked_gmv,
    ca.platform_revenue,
    ca.gmv_per_day,
    ca.corrected_lift,
    ca.leakage_pct,
    ca.avg_discount_pct,
    cv.cvr_pct,
    cv.total_sessions,
    LAG(ca.total_gmv) OVER (
        PARTITION BY ca.campaign_name
        ORDER BY ca.campaign_year)                  AS prev_year_gmv,
    ROUND((
        ca.total_gmv
        - LAG(ca.total_gmv) OVER (
            PARTITION BY ca.campaign_name
            ORDER BY ca.campaign_year)
    ) / NULLIF(LAG(ca.total_gmv) OVER (
        PARTITION BY ca.campaign_name
        ORDER BY ca.campaign_year), 0) * 100, 1)   AS yoy_gmv_growth_pct,
    ROUND((
        ca.total_orders
        - LAG(ca.total_orders) OVER (
            PARTITION BY ca.campaign_name
            ORDER BY ca.campaign_year)
    )::NUMERIC / NULLIF(LAG(ca.total_orders) OVER (
        PARTITION BY ca.campaign_name
        ORDER BY ca.campaign_year), 0) * 100, 1)   AS yoy_orders_growth_pct
FROM campaign_agg ca
LEFT JOIN cvr_by_campaign cv ON ca.campaign_id = cv.campaign_id
ORDER BY ca.campaign_year, ca.campaign_id;

-- STEP 3 — SUPPORTING FACT TABLES

CREATE TABLE fact_category_performance AS
SELECT
    o.campaign_id,
    p.category,
    EXTRACT(YEAR FROM c.start_date)::INT            AS campaign_year,
    COUNT(oi.order_item_id)                         AS total_items,
    COUNT(DISTINCT o.order_id)                      AS total_orders,
    ROUND(SUM(oi.line_total), 0)                    AS total_gmv,
    ROUND(SUM(CASE WHEN oi.item_status = 'Completed'
        THEN oi.line_total ELSE 0 END), 0)          AS realized_gmv,
    ROUND(SUM(CASE WHEN oi.item_status
        IN ('Cancelled','Refunded')
        THEN oi.line_total ELSE 0 END), 0)          AS leaked_gmv,
    ROUND(
        SUM(CASE WHEN oi.item_status
            IN ('Cancelled','Refunded')
            THEN oi.line_total ELSE 0 END)
        / NULLIF(SUM(oi.line_total), 0) * 100,
    2)                                              AS leakage_pct,
    ROUND(AVG(oi.discount_percent)::NUMERIC, 2)     AS avg_discount_pct,
    -- median_item_value: PERCENTILE_CONT not AVG
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY oi.line_total)                    AS median_item_value,
    ROUND(
        SUM(oi.commission_amount)
        / NULLIF(COUNT(oi.order_item_id), 0),
    2)                                              AS commission_per_item,
    -- GMV share within this campaign (for F3 visualisation)
    ROUND(
        SUM(oi.line_total)
        / SUM(SUM(oi.line_total)) OVER (
            PARTITION BY o.campaign_id
        ) * 100,
    1)                                              AS gmv_pct_within_campaign,
    -- Order share within this campaign
    ROUND(
        COUNT(DISTINCT o.order_id)::NUMERIC
        / SUM(COUNT(DISTINCT o.order_id)) OVER (
            PARTITION BY o.campaign_id
        ) * 100,
    1)                                              AS orders_pct_within_campaign
FROM raw_order_items oi
JOIN raw_products  p ON oi.product_id = p.product_id
JOIN raw_orders    o ON oi.order_id   = o.order_id
JOIN raw_campaigns c ON o.campaign_id = c.campaign_id
WHERE o.campaign_id IS NOT NULL
GROUP BY o.campaign_id, p.category, c.start_date
ORDER BY o.campaign_id, p.category;

-- fact_funnel ───────

CREATE TABLE fact_funnel AS
WITH funnel_flags AS (
    SELECT
        ws.session_id,
        ws.campaign_id,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%home%'
            THEN 1 ELSE 0 END)                      AS reached_home,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%product%'
            THEN 1 ELSE 0 END)                      AS reached_product,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%cart%'
            THEN 1 ELSE 0 END)                      AS reached_cart,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%checkout%'
            THEN 1 ELSE 0 END)                      AS reached_checkout,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%billing%'
            THEN 1 ELSE 0 END)                      AS reached_billing,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%thank%'
            THEN 1 ELSE 0 END)                      AS reached_purchase
    FROM raw_website_sessions ws
    JOIN raw_session_activities sa
        ON ws.session_id = sa.session_id
    GROUP BY ws.session_id, ws.campaign_id
)
SELECT
    CASE WHEN ff.campaign_id IS NOT NULL
         THEN 'Campaign'
         ELSE 'Non-campaign'
    END                                             AS session_type,
    COUNT(*)                                        AS total_sessions,
    ROUND(SUM(ff.reached_product)::NUMERIC
        / NULLIF(SUM(ff.reached_home), 0) * 100, 1)   AS home_to_product_pct,
    ROUND(SUM(ff.reached_cart)::NUMERIC
        / NULLIF(SUM(ff.reached_product), 0) * 100, 1) AS product_to_cart_pct,
    ROUND(SUM(ff.reached_checkout)::NUMERIC
        / NULLIF(SUM(ff.reached_cart), 0) * 100, 1)   AS cart_to_checkout_pct,
    ROUND(SUM(ff.reached_billing)::NUMERIC
        / NULLIF(SUM(ff.reached_checkout), 0) * 100, 1) AS checkout_to_billing_pct,
    ROUND(SUM(ff.reached_purchase)::NUMERIC
        / NULLIF(SUM(ff.reached_billing), 0) * 100, 1) AS billing_to_purchase_pct,
    ROUND(SUM(ff.reached_purchase)::NUMERIC
        / NULLIF(COUNT(*), 0) * 100, 2)             AS overall_cvr_pct,
    ROUND(AVG(
        EXTRACT(EPOCH FROM ws.session_end_time
            - ws.session_start_time) / 60
    )::NUMERIC, 1)                                  AS mean_session_minutes,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY
        EXTRACT(EPOCH FROM ws.session_end_time
            - ws.session_start_time) / 60
    )                                               AS median_session_minutes
FROM funnel_flags ff
JOIN raw_website_sessions ws ON ff.session_id = ws.session_id
GROUP BY
    CASE WHEN ff.campaign_id IS NOT NULL
         THEN 'Campaign'
         ELSE 'Non-campaign' END
ORDER BY session_type DESC;

-- ── fact_new_buyers ──
CREATE TABLE fact_new_buyers AS
WITH first_order AS (
    SELECT
        customer_id,
        MIN(order_date)                             AS first_order_date
    FROM raw_orders
    GROUP BY customer_id
),
daily_new AS (
    SELECT
        o.order_date,
        EXTRACT(YEAR FROM o.order_date)::INT        AS order_year,
        CASE WHEN o.campaign_id IS NOT NULL
             THEN 'Campaign'
             ELSE 'Non-campaign'
        END                                         AS period_type,
        COUNT(DISTINCT o.customer_id)               AS new_buyers
    FROM raw_orders o
    JOIN first_order f ON o.customer_id = f.customer_id
    WHERE o.order_date = f.first_order_date
    GROUP BY o.order_date, o.campaign_id
)
SELECT
    order_year,
    period_type,
    COUNT(DISTINCT order_date)                      AS total_days,
    SUM(new_buyers)                                 AS total_new_buyers,
    ROUND(AVG(new_buyers)::NUMERIC, 1)              AS mean_new_buyers_per_day,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY new_buyers)                       AS median_new_buyers_per_day,
    MIN(new_buyers)                                 AS min_daily_new_buyers,
    MAX(new_buyers)                                 AS max_daily_new_buyers
FROM daily_new
GROUP BY 1, 2
ORDER BY 1, 2 DESC;

-- ── fact_monthly_gmv ────
CREATE TABLE fact_monthly_gmv AS
SELECT
    EXTRACT(YEAR  FROM o.order_date)::INT           AS order_year,
    EXTRACT(MONTH FROM o.order_date)::INT           AS order_month,
    COUNT(DISTINCT o.order_id)                      AS total_orders,
    ROUND(SUM(oi.line_total), 0)                    AS total_gmv,
    ROUND(SUM(CASE WHEN oi.item_status = 'Completed'
        THEN oi.line_total ELSE 0 END), 0)          AS realized_gmv,
    COUNT(DISTINCT o.order_date)                    AS days_in_month,
    ROUND(SUM(oi.line_total)
        / COUNT(DISTINCT o.order_date), 0)          AS avg_daily_gmv
FROM raw_order_items oi
JOIN raw_orders o ON oi.order_id = o.order_id
GROUP BY
    EXTRACT(YEAR  FROM o.order_date),
    EXTRACT(MONTH FROM o.order_date)
ORDER BY order_year, order_month;

-- ── fact_daily_baseline ──────
CREATE TABLE fact_daily_baseline AS
SELECT
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY daily_gmv)                        AS median_daily_gmv,
    ROUND(AVG(daily_gmv), 0)                        AS mean_daily_gmv,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY daily_leakage)                    AS median_leakage_rate_pct,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY daily_cancel)                     AS median_cancel_rate_pct,
    COUNT(*)                                        AS days_used
FROM (
    SELECT
        o.order_date,
        SUM(oi.line_total)                          AS daily_gmv,
        AVG(CASE WHEN oi.item_status
            IN ('Cancelled','Refunded')
            THEN 1.0 ELSE 0 END) * 100              AS daily_leakage,
        AVG(CASE WHEN oi.item_status = 'Cancelled'
            THEN 1.0 ELSE 0 END) * 100              AS daily_cancel
    FROM raw_order_items oi
    JOIN raw_orders o ON oi.order_id = o.order_id
    WHERE o.campaign_id IS NULL
    GROUP BY o.order_date
    HAVING COUNT(oi.order_item_id) >= 18
) d;




 

 

