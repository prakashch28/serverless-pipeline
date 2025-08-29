import sys, traceback
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession, functions as F, types as T
ARGS = getResolvedOptions(sys.argv, [
  "RAW_BUCKET","RAW_PREFIX","PROCESSED_BUCKET","PROCESSED_PREFIX","RAW_DATE"
])
RAW_PATH = f"s3://{ARGS['RAW_BUCKET']}/{ARGS['RAW_PREFIX']}{ARGS['RAW_DATE']}/"

PROC_PATH = f"s3://{ARGS['PROCESSED_BUCKET']}/{ARGS['PROCESSED_PREFIX']}"


#  Explicit schema so Spark doesn’t need to infer
schema = T.StructType([
    T.StructField("event_id",   T.StringType(),  True),
    T.StructField("timestamp",  T.StringType(),  True),  # parsed later
    T.StructField("service",    T.StringType(),  True),
    T.StructField("level",      T.StringType(),  True),
    T.StructField("latency_ms", T.LongType(),    True),
    T.StructField("message",    T.StringType(),  True),
])

def main():
    spark = None
    try:
        print("[INFO] RAW_PATH =", RAW_PATH)
        print("[INFO] PROC_PATH =", PROC_PATH)
        spark = SparkSession.builder.appName("log-etl").getOrCreate()

        # ---------- READ ----------
        print("[INFO] Reading JSON with recursive lookup + explicit schema (PERMISSIVE)")
        df = (spark.read
                .option("mode", "PERMISSIVE")
                .option("multiLine", "false")
                .option("recursiveFileLookup", "true")   #  walk subfolders under raw/
                .schema(schema)                          #  avoid inference errors
                .json(RAW_PATH))

        # Guard: empty dataset is OK — exit 0 so pipeline doesn’t “fail”
        cnt = df.count()
        print(f"[INFO] Raw row count: {cnt}")
        if cnt == 0:
            print("[WARN] No rows to process at RAW_PATH. Exiting successfully.")
            return

        # Handle corrupt if present (kept by PERMISSIVE in _corrupt_record on older Spark)
        if "_corrupt_record" in df.columns:
            bad = df.filter(F.col("_corrupt_record").isNotNull()).count()
            print(f"[INFO] Corrupt rows: {bad}")
            df = df.filter(F.col("_corrupt_record").isNull()).drop("_corrupt_record")

        # ---------- TRANSFORM ----------
        df2 = (df
               .withColumn("ingest_date", F.current_date())
               .withColumn("timestamp_ts", F.to_timestamp("timestamp"))
               .dropDuplicates(["event_id"]))

        out_cnt = df2.count()
        print(f"[INFO] Output row count: {out_cnt}")
        if out_cnt == 0:
            print("[WARN] Nothing to write; exiting successfully.")
            return

        # ---------- WRITE ----------
        print("[INFO] Writing Parquet partitioned by ingest_date")
        (df2.write
            .mode("append")
            .partitionBy("ingest_date")
            .parquet(PROC_PATH))

        print("[INFO] Wrote Parquet to", PROC_PATH)

    except Exception as e:
        print("[ERROR] Glue job failed:", repr(e))
        traceback.print_exc()
        sys.exit(1)
    finally:
        if spark is not None:
            spark.stop()
            print("[INFO] Spark session stopped")

if __name__ == "__main__":
    main()
