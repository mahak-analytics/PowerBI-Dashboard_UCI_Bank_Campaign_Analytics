--   02_star_schema_and_analysis.sql (PostgreSQL 17)
--   Builds dim_client, dim_campaign, dim_calendar, dim_economy,
--   fact_calls and RLS security mapping.

DROP VIEW IF EXISTS v_client_segments CASCADE;
DROP VIEW IF EXISTS v_euribor_bands CASCADE;
DROP VIEW IF EXISTS v_conversion_monthly CASCADE;
DROP TABLE IF EXISTS fact_calls CASCADE;
DROP TABLE IF EXISTS dim_client CASCADE;
DROP TABLE IF EXISTS dim_campaign CASCADE;
DROP TABLE IF EXISTS dim_calendar CASCADE;
DROP TABLE IF EXISTS dim_economy CASCADE;
DROP TABLE IF EXISTS security_agent_region CASCADE;

-- 1. dim_client
CREATE TABLE dim_client (
    client_key      SERIAL PRIMARY KEY,
    age             INT NOT NULL,
    age_band        VARCHAR(20) NOT NULL,
    job             VARCHAR(30) NOT NULL,
    marital_status  VARCHAR(15) NOT NULL,
    education       VARCHAR(30) NOT NULL,
    has_credit_def  VARCHAR(10),
    has_housing_ln  VARCHAR(10),
    has_personal_ln VARCHAR(10),
    assigned_region VARCHAR(30),
    client_profile  VARCHAR(60)
);

INSERT INTO dim_client (age, age_band, job, marital_status, education,
                        has_credit_def, has_housing_ln, has_personal_ln, assigned_region, client_profile)
SELECT DISTINCT
    s.age,
    CASE WHEN s.age < 25 THEN 'Under 25'
         WHEN s.age < 35 THEN '25-34'
         WHEN s.age < 45 THEN '35-44'
         WHEN s.age < 55 THEN '45-54'
         WHEN s.age < 65 THEN '55-64'
         ELSE '65+' END,
    s.job, s.marital, s.education,
    s.default_flag, s.housing_loan, s.personal_loan,
    s.assigned_region,
    s.job || ' | ' || s.education
FROM stg_bank_marketing s;

-- 2. dim_campaign 
CREATE TABLE dim_campaign (
    campaign_key         SERIAL PRIMARY KEY,
    contact_direction    VARCHAR(10),
    month_name           VARCHAR(5),
    day_of_week          VARCHAR(5),
    contacts_this_call   INT,
    call_bucket          VARCHAR(15),
    call_bucket_order    INT,
    previously_contacted INT,
    previous_outcome     VARCHAR(15),
    campaign_summary     VARCHAR(60)
);

INSERT INTO dim_campaign (contact_direction, month_name, day_of_week,
                          contacts_this_call, call_bucket, call_bucket_order,
                          previously_contacted, previous_outcome, campaign_summary)
SELECT DISTINCT
    s.call_direction, s.month_name, s.day_of_week,
    s.campaign_contacts,
    CASE WHEN s.campaign_contacts = 1 THEN '1'
         WHEN s.campaign_contacts = 2 THEN '2'
         WHEN s.campaign_contacts = 3 THEN '3'
         WHEN s.campaign_contacts BETWEEN 4 AND 5 THEN '4-5'
         WHEN s.campaign_contacts BETWEEN 6 AND 10 THEN '6-10'
         ELSE '11+' END,
    CASE WHEN s.campaign_contacts = 1 THEN 1
         WHEN s.campaign_contacts = 2 THEN 2
         WHEN s.campaign_contacts = 3 THEN 3
         WHEN s.campaign_contacts BETWEEN 4 AND 5 THEN 4
         WHEN s.campaign_contacts BETWEEN 6 AND 10 THEN 5
         ELSE 6 END,
    s.was_contacted_before, s.poutcome,
    COALESCE(s.poutcome, 'none') || ' / ' || s.call_direction
FROM stg_bank_marketing s;

-- 3. dim_calendar (Removed constant is_weekend column)
CREATE TABLE dim_calendar (
    calendar_key    SERIAL PRIMARY KEY,
    month_num       INT,
    month_name      VARCHAR(5),
    quarter_label   VARCHAR(2),
    day_of_week     VARCHAR(5)
);

INSERT INTO dim_calendar (month_num, month_name, quarter_label, day_of_week)
SELECT DISTINCT 
    s.month_num, 
    s.month_name,
    'Q' || CEIL(s.month_num / 3.0)::INT,
    s.day_of_week
FROM stg_bank_marketing s;

-- 4. dim_economy
CREATE TABLE dim_economy (
    economy_key     SERIAL PRIMARY KEY,
    emp_var_rate    NUMERIC(5,2),
    cons_price_idx  NUMERIC(6,3),
    cons_conf_idx   NUMERIC(6,3),
    euribor3m       NUMERIC(6,3),
    nr_employed     NUMERIC(8,1),
    euribor_band    VARCHAR(15)
);

INSERT INTO dim_economy (emp_var_rate, cons_price_idx, cons_conf_idx,
                         euribor3m, nr_employed, euribor_band)
SELECT DISTINCT 
    s.emp_var_rate, s.cons_price_idx, s.cons_conf_idx,
    s.euribor3m, s.nr_employed, s.euribor_band
FROM stg_bank_marketing s;

-- 5. fact_calls
CREATE TABLE fact_calls (
    call_key            BIGSERIAL PRIMARY KEY,
    client_key          INT NOT NULL REFERENCES dim_client(client_key),
    campaign_key        INT NOT NULL REFERENCES dim_campaign(campaign_key),
    calendar_key        INT NOT NULL REFERENCES dim_calendar(calendar_key),
    economy_key         INT NOT NULL REFERENCES dim_economy(economy_key),
    contacts_this_call  INT NOT NULL,
    duration_sec        INT,
    duration_min        NUMERIC(6,2),
    pre_call_score      NUMERIC(6,4),
    pre_call_decile     INT,
    subscribed          INT NOT NULL
);

INSERT INTO fact_calls (client_key, campaign_key, calendar_key, economy_key,
                        contacts_this_call, duration_sec, duration_min,
                        pre_call_score, pre_call_decile, subscribed)
SELECT c.client_key, cam.campaign_key, cal.calendar_key, e.economy_key,
       s.campaign_contacts, s.duration_sec, s.duration_min,
       s.pre_call_score, s.pre_call_decile, s.y
FROM stg_bank_marketing s
JOIN dim_client c    ON c.age = s.age AND c.job = s.job
                    AND c.marital_status = s.marital
                    AND c.education = s.education
                    AND c.has_credit_def = s.default_flag
                    AND c.has_housing_ln = s.housing_loan
                    AND c.has_personal_ln = s.personal_loan
JOIN dim_campaign cam ON cam.contact_direction = s.call_direction
                     AND cam.month_name = s.month_name
                     AND cam.day_of_week = s.day_of_week
                     AND cam.contacts_this_call = s.campaign_contacts
                     AND cam.previously_contacted = s.was_contacted_before
                     AND cam.previous_outcome = s.poutcome
JOIN dim_calendar cal ON cal.month_num = s.month_num
                     AND cal.month_name = s.month_name
                     AND cal.day_of_week = s.day_of_week
JOIN dim_economy e    ON e.emp_var_rate = s.emp_var_rate
                     AND e.cons_price_idx = s.cons_price_idx
                     AND e.cons_conf_idx = s.cons_conf_idx
                     AND e.euribor3m = s.euribor3m
                     AND e.nr_employed = s.nr_employed;

CREATE INDEX ix_fact_client ON fact_calls(client_key);
CREATE INDEX ix_fact_cam    ON fact_calls(campaign_key);
CREATE INDEX ix_fact_cal    ON fact_calls(calendar_key);
CREATE INDEX ix_fact_econ   ON fact_calls(economy_key);

-- 6. Row-Level Security (RLS) Mapping Table
CREATE TABLE security_agent_region (
    user_email      VARCHAR(100) PRIMARY KEY,
    assigned_region VARCHAR(30) NOT NULL
);

INSERT INTO security_agent_region (user_email, assigned_region) VALUES
    ('agent.corporate@bank.com', 'Corporate_Desk'),
    ('agent.senior@bank.com',    'Senior_Liquidity_Desk'),
    ('agent.retail@bank.com',    'Retail_General_Desk');