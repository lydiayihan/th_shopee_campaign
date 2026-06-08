CREATE TABLE raw_orders (
    order_id              INT           PRIMARY KEY,
    order_date            DATE          NOT NULL,
    customer_id           VARCHAR(20)   NOT NULL,
    -- order_day and year_month OMITTED (Fix 2 — redundant)
    subtotal_amount       NUMERIC(14,2),
    shipping_fee_total    NUMERIC(10,2),
    commission_total      NUMERIC(12,2),
    maintenance_total     NUMERIC(12,2),
    total_amount          NUMERIC(14,2),
    campaign_id           VARCHAR(10)   -- NULL = non-campaign order (expected)
);

CREATE TABLE raw_campaigns (
    campaign_id     VARCHAR(10)  PRIMARY KEY,
    campaign_name   VARCHAR(100),           -- 5 event names, same name reused each year
    start_date      DATE,
    end_date        DATE,
    campaign_type   VARCHAR(50)             -- changes per year — never group by name alone
);

CREATE TABLE raw_order_items (
    order_item_id              INT           PRIMARY KEY,
    order_id                   INT           NOT NULL REFERENCES raw_orders(order_id),
    product_id                 VARCHAR(20)   NOT NULL,
    quantity                   INT,
    unit_price                 NUMERIC(12,2),
    unit_price_after_discount  NUMERIC(12,2),
    line_total                 NUMERIC(14,2),
    discount_percent           NUMERIC(6,2),
    commission_amount          NUMERIC(12,2),
    maintenance_amount         NUMERIC(12,2),
    shipping_fee_item          NUMERIC(10,2),
    estimated_delivery_start   DATE,
    estimated_delivery_end     DATE,         -- Fix 1: strips 00:00:00 on import
    item_status                VARCHAR(20),  -- Completed | Cancelled | Refunded
    is_campaign                SMALLINT,     -- 1=flagged, but unreliable alone (Issue M1)
    product_campaign_id        VARCHAR(20)   -- NULL for 97.8% of rows (expected)
);
CREATE TABLE raw_product_campaign (
    product_campaign_id  VARCHAR(20)  PRIMARY KEY,
    product_id           VARCHAR(20)  NOT NULL,
    campaign_id          VARCHAR(10)  NOT NULL REFERENCES raw_campaigns(campaign_id),
    discount_percent     NUMERIC(6,2)
);
CREATE TABLE raw_products (
    product_id          VARCHAR(20)  PRIMARY KEY,
    seller_id           VARCHAR(10)  NOT NULL,
    category            VARCHAR(50),
    product_name        VARCHAR(200), -- Fix 5: only 50 unique — type label, not unique name
    maintenance_rate    NUMERIC(6,4),
    commission_rate     NUMERIC(6,4),
    weight              NUMERIC(8,3),
    created_at          DATE
);

CREATE TABLE raw_website_sessions (
    session_id          VARCHAR(50)   PRIMARY KEY,
    user_id             VARCHAR(20)   NOT NULL,
    session_date        DATE          NOT NULL,
    session_start_time  TIMESTAMP     NOT NULL,
    session_end_time    TIMESTAMP,
    utm_source          VARCHAR(100), -- 98% NULL = mostly direct/organic traffic
    campaign_id         VARCHAR(10),  -- NULL for non-campaign sessions
    device_type         VARCHAR(20),  -- Mobile / Desktop / Tablet (~33% each)
    order_id            VARCHAR(20)   -- NULL = no conversion; populated = converted
);

CREATE TABLE raw_session_activities (
    activity_id         INT           PRIMARY KEY,
    session_id          VARCHAR(50)   NOT NULL
                        REFERENCES raw_website_sessions(session_id),
    page_url            VARCHAR(500)  NOT NULL,
    session_start_time  TIMESTAMP,    -- activity timestamp within session
    session_end_time    TIMESTAMP
);

-- Performance indexes
CREATE INDEX idx_oi_order_id   ON raw_order_items(order_id);
CREATE INDEX idx_oi_product_id ON raw_order_items(product_id);
CREATE INDEX idx_oi_campaign   ON raw_order_items(is_campaign);
CREATE INDEX idx_ord_campaign  ON raw_orders(campaign_id);
CREATE INDEX idx_ord_date      ON raw_orders(order_date);
CREATE INDEX idx_pc_campaign   ON raw_product_campaign(campaign_id);
CREATE INDEX idx_ws_user_id   ON raw_website_sessions(user_id);
CREATE INDEX idx_ws_campaign  ON raw_website_sessions(campaign_id);
CREATE INDEX idx_ws_date      ON raw_website_sessions(session_date);
CREATE INDEX idx_ws_order_id  ON raw_website_sessions(order_id);
CREATE INDEX idx_ws_device    ON raw_website_sessions(device_type);
CREATE INDEX idx_sa_session_id  ON raw_session_activities(session_id);
CREATE INDEX idx_sa_page_url    ON raw_session_activities(page_url);










