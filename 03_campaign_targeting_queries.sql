-- 03_campaign_targeting_queries.sql
-- Validation and profiling queries for the Power BI targeting model

-- 1. Client profile distribution,
SELECT c.job,
       c.age_band,
       COUNT(*) AS contacts,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS contact_share_pct,
       COUNT(*) FILTER (WHERE c.has_housing_ln = 'yes') AS housing_ln_cnt,
       COUNT(*) FILTER (WHERE c.has_personal_ln = 'yes') AS personal_ln_cnt,
       COUNT(*) FILTER (WHERE c.has_credit_def IN ('unknown', 'yes')) AS credit_risk_cnt
FROM fact_calls f
JOIN dim_client c ON c.client_key = f.client_key
GROUP BY c.job, c.age_band
ORDER BY contacts DESC;

-- 2. Conversion by job
SELECT c.job,
       COUNT(*) AS contacts,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS contact_share_pct,
       SUM(f.contacts_this_call) AS total_dials,
       COUNT(*) FILTER (WHERE f.subscribed = 1) AS conversions,
       ROUND(AVG(f.subscribed::NUMERIC) * 100, 2) AS conv_rate_pct,
       ROUND(
           (AVG(f.subscribed::NUMERIC) - (SELECT AVG(subscribed::NUMERIC) FROM fact_calls)) * 100,
           2
       ) AS rate_vs_baseline_pp
FROM fact_calls f
JOIN dim_client c ON c.client_key = f.client_key
GROUP BY c.job
ORDER BY conv_rate_pct DESC;

-- 3. Job x age band matrix
SELECT c.job,
       c.age_band,
       COUNT(*) AS contacts,
       COUNT(*) FILTER (WHERE f.subscribed = 1) AS conversions,
       ROUND(AVG(f.subscribed::NUMERIC) * 100, 2) AS conv_rate_pct
FROM fact_calls f
JOIN dim_client c ON c.client_key = f.client_key
GROUP BY c.job, c.age_band
ORDER BY c.job, c.age_band;

-- 4. Risk overlay: conversion crossed with credit default and active loans
SELECT c.job,
       c.age_band,
       c.has_credit_def,
       c.has_housing_ln,
       c.has_personal_ln,
       COUNT(*) AS contacts,
       COUNT(*) FILTER (WHERE f.subscribed = 1) AS conversions,
       ROUND(AVG(f.subscribed::NUMERIC) * 100, 2) AS conv_rate_pct
FROM fact_calls f
JOIN dim_client c ON c.client_key = f.client_key
GROUP BY c.job, c.age_band, c.has_credit_def, c.has_housing_ln, c.has_personal_ln
HAVING COUNT(*) >= 50
ORDER BY conv_rate_pct DESC;

-- 5. Priority call queue (Empirical Bayes k=50, min 100 contacts, with cumulative capture)
WITH baseline AS (
    SELECT AVG(subscribed::NUMERIC) AS base_rate,
           COUNT(*) AS total_contacts,
           SUM(subscribed) AS total_conversions
    FROM fact_calls
),
seg AS (
    SELECT c.job,
           c.age_band,
           cam.previous_outcome,
           cam.contact_direction,
           COUNT(*) AS contacts,
           SUM(f.contacts_this_call) AS dials,
           COUNT(*) FILTER (WHERE f.subscribed = 1) AS conversions,
           AVG(f.subscribed::NUMERIC) AS raw_rate,
           ROUND(
               COUNT(*) FILTER (WHERE c.has_credit_def IN ('unknown', 'yes')) * 100.0 / COUNT(*),
               1
           ) AS credit_risk_pct
    FROM fact_calls f
    JOIN dim_client c     ON c.client_key = f.client_key
    JOIN dim_campaign cam ON cam.campaign_key = f.campaign_key
    GROUP BY c.job, c.age_band, cam.previous_outcome, cam.contact_direction
    HAVING COUNT(*) >= 100
),
scored AS (
    SELECT DENSE_RANK() OVER (
               ORDER BY (s.conversions + 50.0 * b.base_rate) / (s.contacts + 50.0) DESC
           ) AS priority_rank,
           s.job,
           s.age_band,
           s.previous_outcome,
           s.contact_direction,
           s.contacts,
           s.dials,
           s.conversions,
           s.raw_rate,
           (s.conversions + 50.0 * b.base_rate) / (s.contacts + 50.0) AS priority_score,
           s.raw_rate / b.base_rate AS segment_lift,
           s.credit_risk_pct
    FROM seg s
    CROSS JOIN baseline b
)
SELECT priority_rank,
       job,
       age_band,
       previous_outcome,
       contact_direction,
       contacts,
       conversions,
       ROUND(raw_rate * 100, 2) AS conv_rate_pct,
       ROUND(priority_score * 100, 2) AS priority_score_pct,
       ROUND(segment_lift, 2) AS segment_lift,
       credit_risk_pct,
       ROUND(SUM(contacts) OVER (ORDER BY priority_rank, job, age_band, previous_outcome, contact_direction) * 100.0 / (SELECT total_contacts FROM baseline), 1) AS cum_contact_share_pct,
       ROUND(SUM(conversions) OVER (ORDER BY priority_rank, job, age_band, previous_outcome, contact_direction) * 100.0 / (SELECT total_conversions FROM baseline), 1) AS cum_capture_pct,
       CASE WHEN priority_score >= 0.25 THEN 'High'
            WHEN priority_score >= 0.12 THEN 'Medium'
            ELSE 'Low' END AS priority_tier
FROM scored
ORDER BY priority_rank, contacts DESC
LIMIT 25;

-- 6. Dial cap simulator check (reconciles Excess Dials Saved and Conversion Retention %)
WITH caps AS (
    SELECT generate_series(1, 10) AS dial_cap
)
SELECT c.dial_cap,
       SUM(f.contacts_this_call) AS total_dials,
       SUM(LEAST(f.contacts_this_call, c.dial_cap)) AS dials_under_cap,
       SUM(GREATEST(f.contacts_this_call - c.dial_cap, 0)) AS excess_dials_saved,
       ROUND(
           SUM(GREATEST(f.contacts_this_call - c.dial_cap, 0)) * 100.0 / SUM(f.contacts_this_call),
           1
       ) AS dials_saved_pct,
       COUNT(*) FILTER (WHERE f.subscribed = 1 AND f.contacts_this_call <= c.dial_cap) AS conversions_kept,
       COUNT(*) FILTER (WHERE f.subscribed = 1 AND f.contacts_this_call > c.dial_cap) AS est_conversions_lost,
       ROUND(
           COUNT(*) FILTER (WHERE f.subscribed = 1 AND f.contacts_this_call <= c.dial_cap) * 100.0
           / COUNT(*) FILTER (WHERE f.subscribed = 1),
           1
       ) AS conv_retention_pct
FROM caps c
CROSS JOIN fact_calls f
GROUP BY c.dial_cap
ORDER BY c.dial_cap;

-- 7. Decile lift curve (pre-call Empirical Bayes score, 10 equal buckets)
WITH base AS (
    SELECT AVG(subscribed::NUMERIC) AS base_rate FROM fact_calls
),
scored AS (
    SELECT f.call_key,
           f.subscribed,
           f.contacts_this_call,
           (
               SUM(f.subscribed) OVER (PARTITION BY c.job, c.age_band, cam.previous_outcome, cam.contact_direction)
               + 50.0 * b.base_rate
           ) / (
               COUNT(*) OVER (PARTITION BY c.job, c.age_band, cam.previous_outcome, cam.contact_direction)
               + 50.0
           ) AS eb_score
    FROM fact_calls f
    JOIN dim_client c     ON c.client_key = f.client_key
    JOIN dim_campaign cam ON cam.campaign_key = f.campaign_key
    CROSS JOIN base b
),
binned AS (
    SELECT call_key,
           subscribed,
           contacts_this_call,
           NTILE(10) OVER (ORDER BY eb_score DESC, call_key) AS decile
    FROM scored
),
summary AS (
    SELECT decile,
           COUNT(*) AS contacts,
           SUM(contacts_this_call) AS dials,
           SUM(subscribed) AS conversions,
           AVG(subscribed::NUMERIC) AS conv_rate
    FROM binned
    GROUP BY decile
)
SELECT decile,
       contacts,
       dials,
       conversions,
       ROUND(conv_rate * 100, 2) AS conv_rate_pct,
       ROUND(conv_rate / (SELECT AVG(subscribed::NUMERIC) FROM fact_calls), 2) AS lift,
       ROUND(SUM(contacts) OVER (ORDER BY decile) * 100.0 / SUM(contacts) OVER (), 1) AS cum_contacts_pct,
       ROUND(SUM(conversions) OVER (ORDER BY decile) * 100.0 / SUM(conversions) OVER (), 1) AS cum_capture_pct
FROM summary
ORDER BY decile;