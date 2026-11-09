 --Check the records sucessfully imported
SELECT COUNT(*) as total_imported_records 
FROM bank_marketing;
-- Audit for Inconsistent Text or Nulls
SELECT 'job' AS column_name, COUNT(*) AS issue_count
FROM bank_marketing
WHERE job IS NULL OR TRIM(job)='' OR LOWER(job)='unknown'

SELECT 'marital', COUNT(*)
FROM bank_marketing
WHERE marital IS NULL OR TRIM(marital)='' OR LOWER(marital)='unknown'

SELECT 'education', COUNT(*)
FROM bank_marketing
WHERE education IS NULL OR TRIM(education)='' OR LOWER(education)='unknown';

SELECT DISTINCT job FROM bank_marketing ORDER BY job;

-- Categorical Distributions
SELECT job, COUNT(*)
FROM bank_marketing
GROUP BY job
ORDER BY COUNT(*) DESC;
-- Numerical Summaries 
SELECT MIN(age), MAX(age), AVG(age)
FROM bank_marketing;
-- Target Distribution
SELECT subscribed, COUNT(*)
FROM bank_marketing
GROUP BY subscribed;
-- Outliers
SELECT *
FROM bank_marketing
WHERE age > 90;
-- Relationships
SELECT job, subscribed, COUNT(*)
FROM bank_marketing
GROUP BY job, subscribed;
--baseline conversion
SELECT COUNT(*) AS total_contacts,
    SUM(CASE WHEN subscribed='yes' THEN 1 ELSE 0 END) AS total_subscriptions,
    ROUND(
        (SUM(CASE WHEN subscribed='yes' THEN 1 ELSE 0 END)::numeric / COUNT(*))*100,
        2
    ) AS conversion_rate_pct
FROM bank_marketing;
--highest-performing age bracket
WITH age_cte AS (
  SELECT CASE
    WHEN age BETWEEN 18 AND 30 THEN '18-30'
    WHEN age BETWEEN 31 AND 45 THEN '31-45'
    WHEN age BETWEEN 46 AND 60 THEN '46-60'
    ELSE '60+'
  END AS age_bracket,
  subscribed
  FROM bank_marketing
)
SELECT age_bracket,
  COUNT(*) AS total_contacts,
  SUM(CASE WHEN subscribed='yes' THEN 1 ELSE 0 END) AS total_subscriptions,
  ROUND(SUM(CASE WHEN subscribed='yes' THEN 1 ELSE 0 END)::numeric / COUNT(*) * 100, 2) AS conversion_rate_pct
FROM age_cte
GROUP BY age_bracket
ORDER BY conversion_rate_pct DESC;
-- highest-ranked job sector/job category
WITH job_conversion AS (
    SELECT
        job,
        COUNT(*) AS total_contacts,
        SUM(CASE WHEN subscribed = 'yes' THEN 1 ELSE 0 END) AS total_subscriptions,
        ROUND(
            SUM(CASE WHEN subscribed = 'yes' THEN 1 ELSE 0 END)::numeric
            / COUNT(*) * 100,
            2
        ) AS conversion_rate_pct
    FROM bank_marketing
    GROUP BY job
)

SELECT
    job,
    conversion_rate_pct,
    DENSE_RANK() OVER (
        ORDER BY conversion_rate_pct DESC
    ) AS job_rank
FROM job_conversion
ORDER BY job_rank;
-- Sample Size
SELECT
    job,
    COUNT(*) AS total_contacts,
    SUM(CASE WHEN subscribed='yes' THEN 1 ELSE 0 END) AS subscriptions
FROM bank_marketing
GROUP BY job
ORDER BY total_contacts DESC;
-- aggregated jobs into sectors and calculated conversion rates for those sectors
WITH dim_job_sector AS (
    SELECT DISTINCT
        job,
        CASE
            WHEN job IN ('admin.', 'management', 'technician', 'services')
                THEN 'Corporate'

            WHEN job IN ('blue-collar', 'housemaid')
                THEN 'Labor'

            WHEN job IN ('retired', 'student', 'unemployed')
                THEN 'Out of Workforce'

            ELSE 'Other'
        END AS job_sector
    FROM bank_marketing
)

SELECT
    d.job_sector,
    COUNT(*) AS total_contacts,
    SUM(CASE WHEN b.subscribed = 'yes' THEN 1 ELSE 0 END) AS total_subscriptions,
    ROUND(
        SUM(CASE WHEN b.subscribed = 'yes' THEN 1 ELSE 0 END)::numeric
        / COUNT(*) * 100,
        2
    ) AS conversion_rate_pct
FROM bank_marketing b
LEFT JOIN dim_job_sector d
    ON b.job = d.job
GROUP BY d.job_sector
ORDER BY conversion_rate_pct DESC;
-- the jobs present in the dataset 
SELECT DISTINCT job
FROM bank_marketing
ORDER BY job;
-- CONVERSION rate decline
WITH call_buckets AS (
    SELECT
        CASE
            WHEN campaign_contacts = 1 THEN '1 call'
            WHEN campaign_contacts = 2 THEN '2 calls'
            WHEN campaign_contacts = 3 THEN '3 calls'
            WHEN campaign_contacts = 4 THEN '4 calls'
            WHEN campaign_contacts = 5 THEN '5 calls'
            ELSE '6+ calls'
        END AS call_bucket,
        subscribed
    FROM bank_marketing
)

SELECT
    call_bucket,
    COUNT(*) AS total_contacts,
    SUM(CASE WHEN subscribed = 'yes' THEN 1 ELSE 0 END) AS total_subscriptions,
    ROUND(
        SUM(CASE WHEN subscribed = 'yes' THEN 1 ELSE 0 END)::numeric
        / COUNT(*) * 100,
        2
    ) AS conversion_rate_pct
FROM call_buckets
GROUP BY call_bucket
ORDER BY
    CASE call_bucket
        WHEN '1 call' THEN 1
        WHEN '2 calls' THEN 2
        WHEN '3 calls' THEN 3
        WHEN '4 calls' THEN 4
        WHEN '5 calls' THEN 5
        WHEN '6+ calls' THEN 6
    END;
