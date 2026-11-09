"""
01_prep_and_load.py - Clean the UCI bank-marketing CSV
"""
import os
import sys
import pandas as pd
from sqlalchemy import create_engine
from dotenv import load_dotenv

load_dotenv()

RAW = sys.argv[1] if len(sys.argv) > 1 else "bank-additional-full.csv"
OUT = "output"
os.makedirs(OUT, exist_ok=True)

# 1. Load raw semicolon-separated file (41,188 raw rows)
df = pd.read_csv(RAW, sep=";")
raw_count = len(df)

# 2. Deduplicate exact row matches across all 21 columns (removes 12 exact duplicates -> 41,176 rows)
df = df.drop_duplicates().reset_index(drop=True)
dedup_count = len(df)
print(f"Loaded {raw_count:,} raw rows | Removed {raw_count - dedup_count} exact duplicates | Retained {dedup_count:,} rows")

# 3. Standardize column names & clean strings
df.columns = df.columns.str.replace(".", "_", regex=False)
df["job"] = df["job"].str.replace(".", "", regex=False)

df = df.rename(columns={
    "default": "default_flag",
    "housing": "housing_loan",
    "loan": "personal_loan",
    "contact": "contact_type",
    "month": "month_name",
    "duration": "duration_sec",
    "campaign": "campaign_contacts",
    "previous": "previous_contacts"
})

df["y"] = (df["y"].str.strip().str.lower() == "yes").astype(int)
df["month_num"] = df["month_name"].map({
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
})

# Recode pdays = 999 ("never contacted before") to NULL + binary flag
df["was_contacted_before"] = (df["pdays"] != 999).astype(int)
df.loc[df["pdays"] == 999, "pdays"] = None

df["call_direction"] = df["contact_type"].map({"cellular": "Mobile", "telephone": "Landline"})
df["duration_min"] = (df["duration_sec"] / 60.0).round(2)

# Assign operational desk for Row-Level Security (RLS)
df["assigned_region"] = df["job"].map(lambda j: 
    "Corporate_Desk" if j in ["admin", "management", "entrepreneur", "self-employed", "technician"]
    else ("Senior_Liquidity_Desk" if j in ["retired", "student", "unemployed"] else "Retail_General_Desk")
)

# 4. Euribor quartile bands
df["euribor_band"] = pd.qcut(
    df["euribor3m"], q=4, labels=["Q1 lowest", "Q2", "Q3", "Q4 highest"]
).astype(str)

# 5. Pre-Call Empirical Bayes Propensity Score & Decile Lift (Zero Duration Leakage!)
overall = df["y"].mean()
pre_call_group = ["poutcome", "call_direction", "euribor_band", "assigned_region"]
seg = df.groupby(pre_call_group)["y"].agg(["count", "sum"]).reset_index()
# Empirical Bayes shrinkage (m = 20 weight toward overall mean 11.27%)
seg["pre_call_score"] = ((seg["sum"] + 20.0 * overall) / (seg["count"] + 20.0)).round(4)
df = df.merge(seg[pre_call_group + ["pre_call_score"]], on=pre_call_group, how="left")

# Rank into 10 Deciles (Decile 1 = Highest Pre-Call Priority, Decile 10 = Lowest)
df["pre_call_decile"] = pd.qcut(
    df["pre_call_score"].rank(method="first", ascending=False), 10, labels=False
) + 1

lift = (df.groupby("pre_call_decile")
          .agg(calls=("y", "size"), conversions=("y", "sum"))
          .reset_index())
lift["conv_rate"] = (lift["conversions"] / lift["calls"]).round(4)
lift["lift_vs_overall"] = (lift["conv_rate"] / overall).round(2)
lift["cum_capture_pct"] = (lift["conversions"].cumsum() / df["y"].sum() * 100).round(1)
lift.to_csv(f"{OUT}/decile_lift.csv", index=False)

# 6. Save clean CSV
df.to_csv(f"{OUT}/bank_clean.csv", index=False)

# 7. Load to PostgreSQL via .env variables
pg_user = os.getenv("PG_USER", "postgres")
pg_pass = os.getenv("PG_PASSWORD")
pg_host = os.getenv("PG_HOST", "localhost")
pg_port = os.getenv("PG_PORT", "5432")
pg_db   = os.getenv("PG_DB", "retail_banking_db")

if not pg_pass:
    raise ValueError("Missing PG_PASSWORD in .env file!")

engine = create_engine(f"postgresql+psycopg2://{pg_user}:{pg_pass}@{pg_host}:{pg_port}/{pg_db}")
df.to_sql("stg_bank_marketing", engine, schema="public", if_exists="replace", index=False)
print(f"Successfully loaded {len(df):,} rows into {pg_db}.public.stg_bank_marketing!")