# Serverless Log Processing Pipeline

This project implements a **serverless data processing pipeline** on AWS.  
It ingests raw log files, validates them with data quality checks (including **zero-byte file tests**), transforms them using AWS Glue ETL, and catalogs the output for querying with Athena.

## 🚀 Architecture

Producer → S3 (raw) → Lambda (validations) → Step Functions → Glue ETL → S3 (processed) → Glue Catalog/Athena


**AWS Services Used:**
- **S3** – stores raw and processed data  
- **Lambda** – validates data, rejects zero-byte files, triggers ETL  
- **Glue** – ETL transformation and schema cataloging  
- **Step Functions** – orchestrates pipeline steps  
- **CloudWatch** – logging, metrics, and alarms  
- **IAM** – fine-grained permissions for security  

---

## 2. Repository Structure

terraform/ or infrastructure/ → Terraform IaC code

lambda_src/ → Lambda function (Python, validations, DQ checks)

glue_job/ → Glue ETL scripts

tests/ → Local/unit tests

artifacts/ → zipped Lambda packages, build artifacts


## 3. Getting Started

### Prerequisites
- Terraform >= 1.5  
- AWS CLI v2 configured (`aws configure`)  
- Python 3.10+ for Lambda packaging  
- (Optional) GitHub CLI (`gh`) for repo creation  

## Directories
- **lambda_src/**  
  Python source code for the AWS Lambda function.  
  - Performs zero-byte and schema validation  
  - Handles data quality checks and routing of files  
  - Includes basic error handling with try/except  

- **glue_job/**  
  PySpark scripts used in AWS Glue ETL job.  
  - Transforms validated data  
  - Writes curated output into the processed S3 bucket  
  - Updates Glue Catalog for Athena queries  

- **tests/**  
  Unit tests for Lambda and ETL components (optional).  
  Used to validate logic locally before deployment.  

- **artifacts/**  
  Stores packaged Lambda zip files and other build outputs.  
  Typically generated during deployment steps.  

- **env/**  
  Contains Terraform variable files (`dev.tfvars`, `test.tfvars`, `prod.tfvars`) for managing multiple environments.  

- **README.md**  
  Documentation of the project, setup instructions, and usage details.  

## AWS Services and their uses

- **Amazon S3**  
  - Stores incoming raw log files (Raw Zone)  
  - Stores transformed/processed data (Processed Zone)  
  - Acts as the main data lake  

- **AWS Lambda**  
  - Triggered when new files arrive in S3  
  - Validates zero-byte files and schema structure  
  - Routes valid files into the pipeline or quarantines invalid ones  

- **AWS Glue**  
  - Runs ETL (Extract, Transform, Load) jobs using PySpark  
  - Cleans, transforms, and enriches log data  
  - Writes curated output back to S3  

- **AWS Glue Data Catalog**  
  - Maintains schema definitions of raw and processed data  
  - Enables querying with Athena and other analytics tools  

- **AWS Step Functions**  
  - Orchestrates the serverless workflow  
  - Ensures Lambda → Glue job execution happens in sequence  
  - Handles retries and error states  

- **Amazon CloudWatch**  
  - Captures logs from Lambda and Glue  
  - Tracks custom metrics (e.g., `FilesProcessed`, `ZeroByteRejected`)  
  - Triggers alarms for failures or anomalies  

- **AWS IAM**  
  - Provides least-privilege access via roles and policies  
  - Ensures secure communication between Lambda, Glue, Step Functions, and S3  

  ### Deploy with Terraform
```bash
cd infrastructure
terraform init
terraform plan 
terraform apply 
```

## Data flow and logic

This pipeline moves data from **raw ingestion → validation → ETL → curated outputs → analytics** with strong observability and failure handling.

### 1) Ingestion (Producer → S3 Raw)
- Producers (apps, services, batch jobs) write objects to:  
  `s3://<data-lake-bucket>/raw/<source>/<yyyy>/<mm>/<dd>/<hh>/<file>.json`
- S3 **ObjectCreated** event triggers the Lambda validator.

### 2) Validation (Lambda)
**Trigger:** S3 event (per object)

**Checks performed:**
1. **Zero-byte guard** – if `ContentLength == 0`, object is moved to  
   `s3://<data-lake-bucket>/quarantine/zero_byte/...` and metric `ZeroByteRejected` is emitted.
2. **File type & parse** – validate extension and parse JSON/CSV (best-effort with try/except).
3. **Schema check** – verify required fields exist (e.g., `timestamp`, `source`, `message`).
4. **Optional dedupe** – compute a content hash (e.g., SHA-256) and skip if already seen.
5. **Routing** – only valid objects are placed in **validated** zone.

**Outputs:**
- Valid → `s3://<data-lake-bucket>/validated/<source>/dt=<yyyy-mm-dd>/hour=<hh>/file.json`
- Invalid → `s3://<data-lake-bucket>/quarantine/schema_invalid/...`
- Metrics → CloudWatch (`FilesProcessed`, `DQFailures`, `ZeroByteRejected`)
- Logs → CloudWatch Logs (with correlation IDs)

### 3) Orchestration (Step Functions)
- Kicks off after successful validation (or on a schedule/batch).
- Steps:
  1. Collect recent **validated** objects for a time window.
  2. Start **Glue Job** with input/output S3 paths and run parameters.
  3. Monitor Glue state; on failure, retry with exponential backoff.
  4. If permanently failed, send to DLQ / create alarm.

### 4) Transformation (Glue ETL – PySpark)
**Read:**  
`validated/<source>/dt=<yyyy-mm-dd>/hour=<hh>/*` (auto-infers partition columns: `dt`, `hour`)

**Transform (common patterns):**
- **Normalize/cleanse**: trim strings, fix casing, standardize timestamps (UTC).
- **Enrich**: derive columns (e.g., `event_date`, `event_hour`, severity levels).
- **Cast & align schema**: ensure proper types for downstream analytics.
- **Drop duplicates**: on composite keys (e.g., `event_id`, `timestamp`).
- **Assertions** (DQ in ETL): non-null for critical fields, valid ranges/sets.

## ✅ Data Quality (DQ) Checks

The pipeline enforces data quality at **two levels**: ingestion (Lambda) and transformation (Glue ETL).

---

### 1. Ingestion-Level Checks (Lambda)
Performed when files land in the **raw S3 bucket**:
- **Zero-byte file check**  
  - Any file with `ContentLength = 0` is rejected.  
  - Quarantined to `s3://<bucket>/quarantine/zero_byte/`.  
  - A CloudWatch metric `ZeroByteRejected` is emitted.  

- **File format validation**  
  - Ensures only allowed extensions (`.json`, `.csv`, etc.) are processed.  
  - Unexpected formats are moved to `quarantine/unsupported_format/`.  

- **Schema validation**  
  - Checks for required fields (e.g., `timestamp`, `source`, `message`).  
  - Files missing mandatory fields go to `quarantine/schema_invalid/`.  

- **Duplicate detection (optional)**  
  - Content hash (SHA-256) or S3 ETag used to skip duplicate files.  

---

### 2. Transformation-Level Checks (Glue ETL)
Performed inside the **Glue PySpark job**:
- **Null/empty field check**  
  - Ensures critical columns (`timestamp`, `message`, `event_id`) are non-null.  

- **Type enforcement**  
  - Casts fields into expected types (e.g., `timestamp` → `TIMESTAMP`, `event_id` → `STRING`).  
  - Invalid rows are logged and sent to quarantine dataset.  

- **Range checks**  
  - Validates timestamp ranges (not in the future, not older than allowed retention).  
  - Example: drop/flag records older than 90 days.  

- **Deduplication**  
  - Removes duplicate records using composite keys (`event_id`, `timestamp`).  

---

### 3. Observability of DQ
- **Metrics** emitted to CloudWatch:
  - `FilesProcessed`  
  - `ZeroByteRejected`  
  - `DQFailures` (schema/type errors)  
- **Logs**: Detailed logs of failures stored in CloudWatch Logs.  
- **Quarantine**: Failed records stored in S3 under `quarantine/` by reason category.  

---

### 4. Benefits
- Prevents **bad data** (empty, malformed, duplicates) from polluting the processed dataset.  
- Improves **query reliability** in Athena/Redshift/Snowflake.  
- Enables **auditing and debugging** with quarantined data zones.  
- Provides **visibility** via metrics and alarms for proactive monitoring.  






