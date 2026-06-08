-- SHOPEE THAILAND CAMPAIGN QUERIES 

SET search_path TO th_shopee_campaign;

-- NOTE ON MINIMUM DAILY VOLUME THRESHOLD (HAVING COUNT >= 18)
/* All baseline CTEs filter non-campaign days to those with COUNT(oi.order_item_id) >= 18 ORDER LINE ITEMS. */
/* order_item_id is a row in raw_order_items — one per product line within an order. This is NOT the same as 18 orders.
   With ~1.9 line items per order on average, 18 line items corresponds to approximately 9-10 orders on that day.
   The line-item count is used (not order count) because the baseline sums line_total from raw_order_items, so item-level
   volume is the appropriate activity measure.*/

-- Why 18: derived from the 5th percentile of daily line item
/* counts across all non-campaign days. The bottom 5% of trading days are excluded as they represent anomalous low-volume days
   that would distort the median baseline downward.*/

-- Impact: 
/*removing the filter lowers the baseline and inflates
all lift multipliers upward (e.g. discount median lift rises
from 3.19x to 3.36x without the filter — a 5.5% overstatement).
The filter produces conservative, defensible lift figures.*/

WITH daily_items AS (
    SELECT
        o.order_date,
        COUNT(oi.order_item_id)                      AS daily_line_items
    FROM raw_order_items oi
    JOIN raw_orders o ON oi.order_id = o.order_id
    WHERE o.campaign_id IS NULL
    GROUP BY o.order_date
)
SELECT
    -- Method 1: p5 percentile (VALID — returns 18)
    PERCENTILE_CONT(0.05) WITHIN GROUP
        (ORDER BY daily_line_items)                  AS p5_threshold,

    -- Method 2: IQR lower fence Q1 - 1.5*IQR (INVALID — returns negative)
    PERCENTILE_CONT(0.25) WITHIN GROUP
        (ORDER BY daily_line_items)
    - 1.5 * (
        PERCENTILE_CONT(0.75) WITHIN GROUP
            (ORDER BY daily_line_items)
        - PERCENTILE_CONT(0.25) WITHIN GROUP
            (ORDER BY daily_line_items)
    )                                                AS iqr_lower_fence,

    -- Method 3: mean - 2SD (INVALID — returns negative)
    ROUND(AVG(daily_line_items)
        - 2 * STDDEV(daily_line_items), 0)           AS mean_minus_2sd,

    -- Supporting distribution stats
    COUNT(*)                                         AS total_days,
    MIN(daily_line_items)                            AS min_daily_items,
    ROUND(AVG(daily_line_items), 1)                  AS mean_daily_items,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY daily_line_items)                  AS median_daily_items,
    MAX(daily_line_items)                            AS max_daily_items,
    PERCENTILE_CONT(0.25) WITHIN GROUP
        (ORDER BY daily_line_items)                  AS q1,
    PERCENTILE_CONT(0.75) WITHIN GROUP
        (ORDER BY daily_line_items)                  AS q3
FROM daily_items;


-- ASSUMPTIONS & CAVEATS — DISTRIBUTION CHECKS

-- 1. GMV Baseline: prove right skew, justify median
WITH daily_non_camp AS (
    SELECT
        o.order_date,
        SUM(oi.line_total)      AS daily_gmv,
        COUNT(oi.order_item_id) AS daily_items
    FROM raw_order_items oi
    JOIN raw_orders o ON oi.order_id = o.order_id
    WHERE o.campaign_id IS NULL
    GROUP BY o.order_date
    HAVING COUNT(oi.order_item_id) >= 18
)
SELECT
    ROUND(AVG(daily_gmv), 0)                                AS mean_daily_gmv,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY daily_gmv)  AS median_daily_gmv,
    ROUND(MIN(daily_gmv), 0)                                AS min_daily_gmv,
    ROUND(MAX(daily_gmv), 0)                                AS max_daily_gmv,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY daily_gmv) AS p25,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY daily_gmv) AS p75,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY daily_gmv) AS p90,
    COUNT(*)                                                AS days_used
FROM daily_non_camp;


-- 2. Leakage & cancellation baseline: near-symmetric, median for consistency
-- median applied for methodological consistency with GMV baseline
WITH daily_rates AS (
    SELECT
        o.order_date,
        AVG(CASE WHEN oi.item_status = 'Cancelled'
            THEN 1.0 ELSE 0 END) * 100                     AS cancel_rate,
        AVG(CASE WHEN oi.item_status IN ('Cancelled','Refunded')
            THEN 1.0 ELSE 0 END) * 100                     AS leakage_rate
    FROM raw_order_items oi
    JOIN raw_orders o ON oi.order_id = o.order_id
    WHERE o.campaign_id IS NULL
    GROUP BY o.order_date
    HAVING COUNT(oi.order_item_id) >= 18
)
SELECT
    ROUND(AVG(cancel_rate), 3)                                   AS cancel_mean,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cancel_rate)     AS cancel_median,
    ROUND(AVG(leakage_rate), 3)                                  AS leakage_mean,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY leakage_rate)    AS leakage_median
FROM daily_rates;


-- 3. Campaign attribution: prove is_campaign flag unreliability
-- fully_attributed=10,347 / partial=9,626 / unattributable=23,393
-- Conclusion: use orders.campaign_id IS NOT NULL as sole filter
SELECT
    COUNT(*) FILTER (
        WHERE oi.is_campaign = 1
        AND o.campaign_id IS NOT NULL
        AND oi.product_campaign_id IS NOT NULL
    )                           AS fully_attributed,
    COUNT(*) FILTER (
        WHERE oi.is_campaign = 1
        AND o.campaign_id IS NOT NULL
        AND oi.product_campaign_id IS NULL
    )                           AS partial,
    COUNT(*) FILTER (
        WHERE oi.is_campaign = 1
        AND o.campaign_id IS NULL
    )                           AS unattributable,
    COUNT(*) FILTER (
        WHERE oi.is_campaign = 1
    )                           AS total_flagged
FROM raw_order_items oi
JOIN raw_orders o ON oi.order_id = o.order_id;

-- Insights Deep Dive

-- FINDING: CAMPAIGN EFFECTIVENESS
-- F1a.1 : Lift by campaign type — median vs mean comparison
WITH baseline AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY daily_gmv) AS median_gmv
    FROM (
        SELECT o.order_date, SUM(oi.line_total) AS daily_gmv
        FROM raw_order_items oi
        JOIN raw_orders o ON oi.order_id = o.order_id
        WHERE o.campaign_id IS NULL
        GROUP BY o.order_date
        HAVING COUNT(oi.order_item_id) >= 18  -- 18 order line items, not 18 orders
    ) d
),
campaign_lift AS (
    SELECT
        c.campaign_id,
        c.campaign_name,
        c.campaign_type,
        EXTRACT(YEAR FROM c.start_date)::INT                    AS campaign_year,
        ROUND((
            SUM(oi.line_total)
            / (c.end_date - c.start_date + 1)
            / b.median_gmv
        )::NUMERIC, 2)                                          AS corrected_lift
    FROM raw_order_items oi
    JOIN raw_orders    o ON oi.order_id   = o.order_id
    JOIN raw_campaigns c ON o.campaign_id = c.campaign_id
    CROSS JOIN baseline b
    WHERE o.campaign_id IS NOT NULL
    GROUP BY c.campaign_id, c.campaign_name, c.campaign_type,
             c.start_date, c.end_date, b.median_gmv
)
SELECT
    campaign_type,
    COUNT(*)                                                     AS n_campaigns,
    ROUND(AVG(corrected_lift)::NUMERIC, 2)                      AS mean_lift,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY corrected_lift) AS median_lift,
    ROUND(MIN(corrected_lift)::NUMERIC, 2)                      AS min_lift,
    ROUND(MAX(corrected_lift)::NUMERIC, 2)                      AS max_lift
FROM campaign_lift
GROUP BY campaign_type
ORDER BY median_lift DESC;

-- F1a.2 : Lift per individual campaign 
-- Backs the claim that flash-sale mean is driven by two 2025 outliers.
WITH baseline AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY daily_gmv) AS median_gmv
    FROM (
        SELECT o.order_date, SUM(oi.line_total) AS daily_gmv
        FROM raw_order_items oi
        JOIN raw_orders o ON oi.order_id = o.order_id
        WHERE o.campaign_id IS NULL
        GROUP BY o.order_date
        HAVING COUNT(oi.order_item_id) >= 18
    ) d
)
SELECT
    c.campaign_name,
    c.campaign_type,
    EXTRACT(YEAR FROM c.start_date)::INT             AS campaign_year,
    ROUND((
        SUM(oi.line_total)
        / (c.end_date - c.start_date + 1)
        / b.median_gmv
    )::NUMERIC, 2)                                   AS gmv_lift
FROM raw_order_items oi
JOIN raw_orders    o ON oi.order_id   = o.order_id
JOIN raw_campaigns c ON o.campaign_id = c.campaign_id
CROSS JOIN baseline b
WHERE o.campaign_id IS NOT NULL
GROUP BY c.campaign_id, c.campaign_name, c.campaign_type,
         c.start_date, c.end_date, b.median_gmv
ORDER BY campaign_type, gmv_lift DESC;


-- F1b.1 : CVR and lift by campaign name and year
WITH baseline AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY daily_gmv) AS median_gmv
    FROM (
        SELECT o.order_date, SUM(oi.line_total) AS daily_gmv
        FROM raw_order_items oi
        JOIN raw_orders o ON oi.order_id = o.order_id
        WHERE o.campaign_id IS NULL
        GROUP BY o.order_date
        HAVING COUNT(oi.order_item_id) >= 18
    ) d
)
SELECT
    c.campaign_name,
    c.campaign_type,
    EXTRACT(YEAR FROM c.start_date)::INT                        AS campaign_year,
    COUNT(DISTINCT ws.session_id)                               AS total_sessions,
    COUNT(DISTINCT ws.session_id)
        FILTER (WHERE ws.order_id IS NOT NULL)                  AS converted_sessions,
    ROUND(
        COUNT(DISTINCT ws.session_id)
            FILTER (WHERE ws.order_id IS NOT NULL)::NUMERIC
        / NULLIF(COUNT(DISTINCT ws.session_id), 0) * 100,
    2)                                                          AS cvr_pct,
    ROUND(SUM(oi.line_total), 0)                                AS total_gmv,
    ROUND(SUM(oi.commission_amount + oi.maintenance_amount), 0) AS platform_revenue,
    ROUND((
        SUM(oi.line_total)
        / (c.end_date - c.start_date + 1)
        / b.median_gmv
    )::NUMERIC, 2)                                              AS corrected_lift
FROM raw_website_sessions ws
JOIN raw_campaigns c ON ws.campaign_id = c.campaign_id
LEFT JOIN raw_orders o ON ws.order_id::INT = o.order_id
LEFT JOIN raw_order_items oi ON o.order_id = oi.order_id
CROSS JOIN baseline b
WHERE ws.campaign_id IS NOT NULL
GROUP BY c.campaign_name, c.campaign_type, c.start_date, c.end_date, b.median_gmv
ORDER BY c.campaign_name;

--flb.2 :  gmv over months trend each year -- 
SELECT
    EXTRACT(YEAR FROM o.order_date)::INT             AS order_year,
    EXTRACT(MONTH FROM o.order_date)::INT            AS order_month,
    COUNT(DISTINCT o.order_id)                       AS total_orders,
    ROUND(SUM(oi.line_total), 0)                     AS total_gmv,
    ROUND(SUM(oi.line_total) / COUNT(DISTINCT o.order_date), 0) AS avg_daily_gmv
FROM raw_order_items oi
JOIN raw_orders o ON oi.order_id = o.order_id
GROUP BY
    EXTRACT(YEAR FROM o.order_date),
    EXTRACT(MONTH FROM o.order_date)
ORDER BY order_year, order_month;


-- F1c.1 : Platform revenue trend and buyer acquistionsvby year
-- Key finding: 249K (2022) → 1.25M (2023) → 2.02M (2024) → 5.72M (2025)
-- Buyer base: 271 → 1,309 → 2,269 → 6,151
WITH all_orders AS (
    SELECT
        EXTRACT(YEAR FROM o.order_date)::INT                    AS year,
        ROUND(SUM(oi.commission_amount + oi.maintenance_amount), 0) AS total_platform_revenue
    FROM raw_order_items oi
    JOIN raw_orders o ON oi.order_id = o.order_id
    GROUP BY EXTRACT(YEAR FROM o.order_date)
),
campaign_orders AS (
    SELECT
        EXTRACT(YEAR FROM c.start_date)::INT                    AS year,
        COUNT(DISTINCT c.campaign_id)                           AS campaigns,
        COUNT(DISTINCT o.customer_id)                           AS unique_buyers,
        ROUND(SUM(oi.commission_amount + oi.maintenance_amount), 0) AS campaign_revenue,
        LAG(ROUND(SUM(oi.commission_amount + oi.maintenance_amount), 0))
            OVER (ORDER BY EXTRACT(YEAR FROM c.start_date))     AS prev_year_rev
    FROM raw_order_items oi
    JOIN raw_orders    o ON oi.order_id   = o.order_id
    JOIN raw_campaigns c ON o.campaign_id = c.campaign_id
    WHERE o.campaign_id IS NOT NULL
    GROUP BY EXTRACT(YEAR FROM c.start_date)
)
SELECT
    co.year,
    co.campaigns,
    co.unique_buyers,
    co.campaign_revenue,
    ao.total_platform_revenue,
    ROUND((co.campaign_revenue - co.prev_year_rev)
        / NULLIF(co.prev_year_rev, 0) * 100, 1)                AS yoy_revenue_growth_pct
FROM campaign_orders co
JOIN all_orders ao ON co.year = ao.year
ORDER BY co.year;

-- f1c.2: median new buyers daily
WITH first_order AS (
    SELECT
        customer_id,
        MIN(order_date) AS first_order_date
    FROM raw_orders
    GROUP BY customer_id
),
daily_new_buyers AS (
    SELECT
        o.order_date,
        EXTRACT(YEAR FROM o.order_date)::INT         AS order_year,
        CASE WHEN MAX(o.campaign_id) IS NOT NULL
             THEN 'Campaign'
             ELSE 'Non-campaign'
        END                                          AS period_type,
        COUNT(DISTINCT o.customer_id)                AS new_buyers
    FROM raw_orders o
    JOIN first_order f ON o.customer_id = f.customer_id
    WHERE o.order_date = f.first_order_date
    GROUP BY o.order_date
)
SELECT
    order_year,
    period_type,
    COUNT(DISTINCT order_date)                       AS total_days,
    SUM(new_buyers)                                  AS total_new_buyers,
    ROUND(AVG(new_buyers), 1)                        AS mean_new_buyers_per_day,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY new_buyers)                        AS median_new_buyers_per_day,
    MIN(new_buyers)                                  AS min_daily_new_buyers,
    MAX(new_buyers)                                  AS max_daily_new_buyers
FROM daily_new_buyers
GROUP BY 1, 2
ORDER BY 1, 2 DESC;

-- FINDING: REVENUE LEAKAGE

-- F2: Campaign leakage vs non-campaign baseline 
-- Key finding: campaign median 25.77% vs baseline 25.00% 
-- Leakage is structural and platform-wide, not campaign-caused
WITH campaign_leakage AS (
    SELECT
        c.campaign_id,
        c.campaign_name,
        c.campaign_type,
        EXTRACT(YEAR FROM c.start_date)::INT                    AS campaign_year,
        ROUND(
            SUM(CASE WHEN oi.item_status IN ('Cancelled','Refunded')
                THEN oi.line_total ELSE 0 END)
            / NULLIF(SUM(oi.line_total), 0) * 100,
        2)                                                      AS leakage_pct,
        ROUND(
            SUM(oi.line_total)
            - SUM(CASE WHEN oi.item_status = 'Completed'
                THEN oi.line_total ELSE 0 END),
        0)                                                      AS leaked_gmv_thb
    FROM raw_order_items oi
    JOIN raw_orders    o ON oi.order_id   = o.order_id
    JOIN raw_campaigns c ON o.campaign_id = c.campaign_id
    WHERE o.campaign_id IS NOT NULL
    GROUP BY c.campaign_id, c.campaign_name, c.campaign_type, c.start_date
),
baseline_leakage AS (
    SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY daily_leak) AS baseline_median
    FROM (
        SELECT
            o.order_date,
            AVG(CASE WHEN oi.item_status IN ('Cancelled','Refunded')
                THEN 1.0 ELSE 0 END) * 100                     AS daily_leak
        FROM raw_order_items oi
        JOIN raw_orders o ON oi.order_id = o.order_id
        WHERE o.campaign_id IS NULL
        GROUP BY o.order_date
        HAVING COUNT(oi.order_item_id) >= 18  -- 18 order line items, not 18 orders
    ) d
)
SELECT
    ROUND(AVG(cl.leakage_pct), 2)                              AS campaign_mean_leakage,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cl.leakage_pct) AS campaign_median_leakage,
    MIN(cl.leakage_pct)                                        AS min_leakage,
    MAX(cl.leakage_pct)                                        AS max_leakage,
    bl.baseline_median                                         AS baseline_median_leakage,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cl.leakage_pct)
        - bl.baseline_median                                   AS median_gap_pp,
    ROUND(SUM(cl.leaked_gmv_thb), 0)                          AS total_leaked_gmv
FROM campaign_leakage cl
CROSS JOIN baseline_leakage bl
GROUP BY bl.baseline_median;

-- F2: Total GMV vs realized GMV
-- Key finding: 128.4M total, 96.5M realized, 31.9M leaked, 9.24M platform revenue
SELECT
    ROUND(SUM(oi.line_total), 0)                                AS total_campaign_gmv,
    ROUND(SUM(CASE WHEN oi.item_status = 'Completed'
        THEN oi.line_total ELSE 0 END), 0)                     AS realized_gmv,
    ROUND(SUM(oi.line_total)
        - SUM(CASE WHEN oi.item_status = 'Completed'
            THEN oi.line_total ELSE 0 END), 0)                 AS total_leaked_gmv,
    ROUND(SUM(oi.commission_amount + oi.maintenance_amount), 0) AS platform_revenue
FROM raw_order_items oi
JOIN raw_orders o ON oi.order_id = o.order_id
WHERE o.campaign_id IS NOT NULL;

-- F2: GMV, Realized GMV, Leakage and Platform Revenue by Campaign
SELECT
    c.campaign_name,
    c.campaign_type,
    EXTRACT(YEAR FROM c.start_date)::INT                        AS campaign_year,
    ROUND(SUM(oi.line_total), 0)                                AS total_gmv,
    ROUND(SUM(CASE WHEN oi.item_status = 'Completed'
        THEN oi.line_total ELSE 0 END), 0)                     AS realized_gmv,
    ROUND(SUM(CASE WHEN oi.item_status IN ('Cancelled','Refunded')
        THEN oi.line_total ELSE 0 END), 0)                     AS leaked_gmv,
    ROUND(
        SUM(CASE WHEN oi.item_status IN ('Cancelled','Refunded')
            THEN oi.line_total ELSE 0 END)
        / NULLIF(SUM(oi.line_total), 0) * 100,
    2)                                                          AS leakage_pct,
    ROUND(SUM(oi.commission_amount + oi.maintenance_amount), 0) AS platform_revenue
FROM raw_order_items oi
JOIN raw_orders    o ON oi.order_id   = o.order_id
JOIN raw_campaigns c ON o.campaign_id = c.campaign_id
WHERE o.campaign_id IS NOT NULL
GROUP BY c.campaign_id, c.campaign_name, c.campaign_type, c.start_date
ORDER BY campaign_year, c.campaign_name;

-- FINDING: CATEGORY PERFORMANCE

-- F3: Category item value distribution — prove median needed
SELECT
    p.category,
    COUNT(DISTINCT o.order_id)                                  AS total_orders,
    ROUND(AVG(order_val.order_value), 0)                        AS mean_order_value,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY order_val.order_value)                        AS median_order_value,
    PERCENTILE_CONT(0.9) WITHIN GROUP
        (ORDER BY order_val.order_value)                        AS p90_order_value,
    ROUND(MAX(order_val.order_value), 0)                        AS max_order_value
FROM raw_orders o
JOIN (
    SELECT
        oi.order_id,
        p2.category,
        SUM(oi.line_total) AS order_value
    FROM raw_order_items oi
    JOIN raw_products p2 ON oi.product_id = p2.product_id
    GROUP BY oi.order_id, p2.category
) order_val ON o.order_id = order_val.order_id
JOIN raw_products p ON p.category = order_val.category
WHERE o.campaign_id IS NOT NULL
GROUP BY p.category
ORDER BY median_order_value DESC;

-- F3b: Category GMV vs orders share 
SELECT
    p.category,
    COUNT(DISTINCT o.order_id)                                  AS total_orders,
    ROUND(
        COUNT(DISTINCT o.order_id)::NUMERIC
        / SUM(COUNT(DISTINCT o.order_id)) OVER () * 100,
    1)                                                          AS orders_pct,
    ROUND(SUM(oi.line_total), 0)                                AS total_gmv,
    ROUND(
        SUM(oi.line_total)
        / SUM(SUM(oi.line_total)) OVER () * 100,
    1)                                                          AS gmv_pct,
    ROUND(
        SUM(CASE WHEN oi.item_status = 'Completed'
            THEN oi.line_total ELSE 0 END)
        / SUM(SUM(oi.line_total)) OVER () * 100,
    1)                                                          AS realized_gmv_pct,
    PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY oi.line_total)                                AS median_item_value,
    ROUND(AVG(oi.commission_amount), 2)                         AS commission_per_item
FROM raw_order_items oi
JOIN raw_products p ON oi.product_id = p.product_id
JOIN raw_orders   o ON oi.order_id   = o.order_id
WHERE o.campaign_id IS NOT NULL
GROUP BY p.category
ORDER BY total_gmv DESC;

-- FINDING: CONVERSION FUNNEL

-- F4: Overall campaign vs non-campaign CVR 
-- Key finding: 96.57% campaign vs 59.20% non-campaign
SELECT
    CASE WHEN ws.campaign_id IS NOT NULL
         THEN 'Campaign' ELSE 'Non-campaign' END                AS session_type,
    COUNT(DISTINCT ws.session_id)                               AS total_sessions,
    COUNT(DISTINCT ws.session_id)
        FILTER (WHERE ws.order_id IS NOT NULL)                  AS converted,
    ROUND(
        COUNT(DISTINCT ws.session_id)
            FILTER (WHERE ws.order_id IS NOT NULL)::NUMERIC
        / NULLIF(COUNT(DISTINCT ws.session_id), 0) * 100,
    2)                                                          AS cvr_pct
FROM raw_website_sessions ws
GROUP BY CASE WHEN ws.campaign_id IS NOT NULL
              THEN 'Campaign' ELSE 'Non-campaign' END;

-- F4: Funnel stage drop-off — campaign vs non-campaign 
WITH funnel AS (
    SELECT
        ws.session_id,
        ws.campaign_id,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%home%'
            THEN 1 ELSE 0 END)                                  AS h,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%product%'
            THEN 1 ELSE 0 END)                                  AS pr,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%cart%'
            THEN 1 ELSE 0 END)                                  AS ca,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%checkout%'
            THEN 1 ELSE 0 END)                                  AS ch,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%billing%'
            THEN 1 ELSE 0 END)                                  AS bi,
        MAX(CASE WHEN LOWER(sa.page_url) LIKE '%thank%'
            THEN 1 ELSE 0 END)                                  AS ty
    FROM raw_website_sessions ws
    JOIN raw_session_activities sa ON ws.session_id = sa.session_id
    GROUP BY ws.session_id, ws.campaign_id
)
SELECT
    CASE WHEN campaign_id IS NOT NULL
         THEN 'Campaign' ELSE 'Non-campaign' END                AS session_type,
    COUNT(*)                                                    AS sessions,
    ROUND(SUM(pr)::NUMERIC / NULLIF(SUM(h),  0) * 100, 1)      AS home_to_product_pct,
    ROUND(SUM(ca)::NUMERIC / NULLIF(SUM(pr), 0) * 100, 1)      AS product_to_cart_pct,
    ROUND(SUM(ch)::NUMERIC / NULLIF(SUM(ca), 0) * 100, 1)      AS cart_to_checkout_pct,
    ROUND(SUM(bi)::NUMERIC / NULLIF(SUM(ch), 0) * 100, 1)      AS checkout_to_billing_pct,
    ROUND(SUM(ty)::NUMERIC / NULLIF(SUM(bi), 0) * 100, 1)      AS billing_to_purchase_pct,
    ROUND(SUM(ty)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 2)     AS overall_cvr_pct
FROM funnel
GROUP BY CASE WHEN campaign_id IS NOT NULL
              THEN 'Campaign' ELSE 'Non-campaign' END
ORDER BY session_type DESC;

-- F4: Session duration distribution — prove symmetric 
SELECT
    CASE WHEN ws.campaign_id IS NOT NULL
         THEN 'Campaign' ELSE 'Non-campaign' END                AS session_type,
    COUNT(*)                                                    AS sessions,
    ROUND(AVG(
        EXTRACT(EPOCH FROM ws.session_end_time - ws.session_start_time) / 60
    )::NUMERIC, 1)                                              AS mean_minutes,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY
        EXTRACT(EPOCH FROM ws.session_end_time - ws.session_start_time) / 60
    )                                                           AS median_minutes,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY
        EXTRACT(EPOCH FROM ws.session_end_time - ws.session_start_time) / 60
    )                                                           AS p25_minutes,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY
        EXTRACT(EPOCH FROM ws.session_end_time - ws.session_start_time) / 60
    )                                                           AS p75_minutes
FROM raw_website_sessions ws
WHERE ws.session_end_time > ws.session_start_time
GROUP BY CASE WHEN ws.campaign_id IS NOT NULL
              THEN 'Campaign' ELSE 'Non-campaign' END
ORDER BY session_type DESC;


