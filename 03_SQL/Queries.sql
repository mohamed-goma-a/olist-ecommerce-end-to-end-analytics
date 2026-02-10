-- 1) How many orders and how much revenue are generated each month?
SELECT
    YEAR(o.order_purchase_timestamp)  AS order_year,
    MONTH(o.order_purchase_timestamp) AS order_month,
    COUNT(DISTINCT o.order_id)        AS orders_count,
    ROUND(SUM(op.payment_value), 2)   AS monthly_revenue
FROM dbo.orders_clean o
JOIN dbo.order_payments_clean op
    ON o.order_id = op.order_id
WHERE o.order_stage = 'completed'
GROUP BY
    YEAR(o.order_purchase_timestamp),
    MONTH(o.order_purchase_timestamp)
ORDER BY
    order_year, order_month;


-- 2) Are late deliveries associated with lower customer review scores?
SELECT
    CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 'Late'
        ELSE 'On-Time'
    END AS delivery_status,
    COUNT(*) AS orders_count,
    ROUND(AVG(CAST(r.review_score AS FLOAT)), 2) AS avg_review_score
FROM dbo.orders_clean o
JOIN dbo.order_reviews_clean r
    ON o.order_id = r.order_id
WHERE
    o.order_stage = 'completed'
    AND o.timeline_issue_flag <> 1
    AND o.order_delivered_customer_date IS NOT NULL
    AND o.order_estimated_delivery_date IS NOT NULL
    AND r.review_score IS NOT NULL
GROUP BY
    CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 'Late'
        ELSE 'On-Time'
    END
ORDER BY delivery_status;


-- 3) What percentage of completed orders are delivered late ?
SELECT
    ROUND(
        100.0 * SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS late_delivery_rate_pct
FROM dbo.orders_clean
WHERE
    order_stage = 'completed'
    AND timeline_issue_flag <> 1
    AND order_delivered_customer_date IS NOT NULL
    AND order_estimated_delivery_date IS NOT NULL;


-- 4) Which product categories have the highest delivery delay rates ?
-- DISTINCT order_id to avoid counting an order many times if it has many items.
WITH CategoryLateStats AS (
    SELECT 
        c.product_category_name_english AS category,
        SUM(CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 1 ELSE 0 END) AS late_orders_count
    FROM dbo.order_items_clean oi
    JOIN dbo.products_clean p ON oi.product_id = p.product_id
    JOIN dbo.category_clean c ON p.product_category_name = c.product_category_name
    JOIN dbo.orders_clean o ON oi.order_id = o.order_id
    WHERE 
        o.order_stage = 'completed'
        AND o.timeline_issue_flag <> 1
        AND o.order_delivered_customer_date IS NOT NULL
        AND o.order_estimated_delivery_date IS NOT NULL
    GROUP BY c.product_category_name_english
)
SELECT TOP 5
    category,
    late_orders_count,
    
    SUM(late_orders_count) OVER() AS total_late_orders_marketwide,
    ROUND(
        100.0 * late_orders_count / SUM(late_orders_count) OVER(), 
        2
    ) AS contribution_to_total_delays_pct
FROM CategoryLateStats
WHERE late_orders_count > 0
ORDER BY contribution_to_total_delays_pct DESC;


-- 5) Which sellers contribute the most to delivery delays ?
-- DISTINCT (seller_id, order_id) so each seller-order counts once.
WITH seller_orders AS (
    SELECT DISTINCT
        oi.seller_id,
        o.order_id,
        CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date THEN 1 ELSE 0 END AS is_late
    FROM dbo.orders_clean o
    JOIN dbo.order_items_clean oi
        ON o.order_id = oi.order_id
WHERE
    o.order_stage = 'completed'
    AND o.timeline_issue_flag <> 1
    AND o.order_delivered_customer_date IS NOT NULL
    AND o.order_estimated_delivery_date IS NOT NULL
)
SELECT TOP 10
    seller_id,
    COUNT(*) AS total_orders,
    SUM(is_late) AS late_orders,
    ROUND(100.0 * SUM(is_late) / COUNT(*), 2) AS late_rate_pct
FROM seller_orders
GROUP BY seller_id
HAVING COUNT(*) >=300
ORDER BY late_rate_pct DESC, late_orders DESC;


-- 6) What percentage of customers make repeat purchases ?
SELECT
    ROUND(
        100.0 * COUNT(DISTINCT CASE WHEN t.order_count >= 2 THEN t.customer_unique_id END)
        / COUNT(DISTINCT t.customer_unique_id),
        2
    ) AS repeat_customers_percentage
FROM (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS order_count
    FROM dbo.orders_clean o
    JOIN dbo.customers_clean c
        ON o.customer_id = c.customer_id
    WHERE o.order_stage = 'completed'
    GROUP BY c.customer_unique_id
) t;


-- 7) Do customers who experience late deliveries return to purchase less often ?

SELECT
    CASE WHEN t.had_late_delivery = 1 THEN 'Had Late Delivery' ELSE 'On-Time Only' END AS customer_group,
    COUNT(*) AS total_customers,
    SUM(CASE WHEN t.orders_count >= 2 THEN 1 ELSE 0 END) AS repeat_customers,
    ROUND(100.0 * SUM(CASE WHEN t.orders_count >= 2 THEN 1 ELSE 0 END) / COUNT(*), 2) AS repeat_rate_pct
FROM (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id) AS orders_count,
        MAX(CASE WHEN o.delivery_delay_days > 0 THEN 1 ELSE 0 END) AS had_late_delivery
    FROM dbo.orders_clean o
    JOIN dbo.customers_clean c
        ON o.customer_id = c.customer_id
    WHERE
        o.order_stage = 'completed'
        AND o.timeline_issue_flag <> 1
        AND o.delivery_delay_days IS NOT NULL 
    GROUP BY c.customer_unique_id
) t
GROUP BY CASE WHEN t.had_late_delivery = 1 THEN 'Had Late Delivery' ELSE 'On-Time Only' END
ORDER BY repeat_rate_pct ASC;

SELECT 
    CASE WHEN t.had_late_delivery = 1 THEN 'Had Late Delivery' ELSE ' On-Time' END AS customer_experience,
    COUNT(t.customer_unique_id) AS repeat_customers_count,
    
    ROUND(
        100.0 * COUNT(t.customer_unique_id) / SUM(COUNT(t.customer_unique_id)) OVER(), 
        2
    ) AS contribution_to_loyalty_pct
FROM (
    SELECT 
        c.customer_unique_id,
        MAX(CASE WHEN o.delivery_delay_days > 0 THEN 1 ELSE 0 END) AS had_late_delivery
    FROM dbo.orders_clean o
    JOIN dbo.customers_clean c ON o.customer_id = c.customer_id
    WHERE o.order_stage = 'completed'
    GROUP BY c.customer_unique_id
    HAVING COUNT(o.order_id) > 1 
) t
GROUP BY CASE WHEN t.had_late_delivery = 1 THEN 'Had Late Delivery' ELSE ' On-Time' END
ORDER BY contribution_to_loyalty_pct DESC;

-- 8) Which months show the highest delivery delay rates ?
SELECT TOP 10
    YEAR(CAST(order_approved_at AS DATE))  AS order_year,
    MONTH(CAST(order_approved_at AS DATE)) AS order_month,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) AS late_orders,
    ROUND(
        100.0 * SUM(CASE WHEN order_delivered_customer_date > order_estimated_delivery_date THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS late_rate_pct
FROM dbo.orders_clean
WHERE
    order_stage = 'completed'
    AND timeline_issue_flag <> 1
    AND order_approved_at IS NOT NULL
    AND order_delivered_customer_date IS NOT NULL
    AND order_estimated_delivery_date IS NOT NULL
GROUP BY
    YEAR(CAST(order_approved_at AS DATE)),
    MONTH(CAST(order_approved_at AS DATE))
HAVING COUNT(*) >= 500
ORDER BY late_rate_pct DESC, late_orders DESC;

-- 9) Are non-completion or cancellation rates associated with payment method


SELECT 
    p.payment_type,
    COUNT(DISTINCT o.order_id) AS total_orders,

    SUM(CASE WHEN o.order_status IN ('canceled', 'unavailable') THEN 1 ELSE 0 END) AS non_completed_orders,
    ROUND(
        100.0 * SUM(CASE WHEN o.order_status IN ('canceled', 'unavailable') THEN 1 ELSE 0 END) 
        / COUNT(DISTINCT o.order_id), 
        2
    ) AS cancellation_rate
FROM dbo.orders_clean o
JOIN dbo.order_payments_clean p ON o.order_id = p.order_id
GROUP BY p.payment_type
ORDER BY cancellation_rate DESC;



-- 10) Are delivery delays disproportionately concentrated in specific customer cities?
SELECT TOP 10
    c.customer_city,
    COUNT(DISTINCT o.order_id) AS total_orders,
    COUNT(DISTINCT CASE
        WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN o.order_id
    END) AS late_orders,
    ROUND(
        100.0 * COUNT(DISTINCT CASE
            WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
            THEN o.order_id
        END)
        / COUNT(DISTINCT o.order_id),
        2
    ) AS late_rate_pct
FROM dbo.customers_clean c
JOIN dbo.orders_clean o
    ON c.customer_id = o.customer_id
WHERE
    o.order_stage = 'completed'
    AND o.timeline_issue_flag <> 1
    AND o.order_delivered_customer_date IS NOT NULL
    AND o.order_estimated_delivery_date IS NOT NULL
GROUP BY
    c.customer_city
HAVING
    COUNT(DISTINCT o.order_id) >= 300
ORDER BY
    late_rate_pct DESC;