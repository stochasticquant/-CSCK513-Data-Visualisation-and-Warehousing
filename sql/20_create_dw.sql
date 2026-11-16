/*  20_create_dw.sql
    Creates the gravity_dw data warehouse: a star schema with one fact table
    (fact_sales, grain = one order line) and five dimensions.

    Schemas
      dbo  - star schema (dim_* and fact_sales), which Power BI reads
      etl  - ETL control: config (campaign date) and audit log
      dq   - data-quality check results and rejected rows

    Every dimension has an "Unknown" member with key -1, so fact rows whose
    lookups fail still load and can be counted, instead of being lost.
*/
IF DB_ID('gravity_dw') IS NULL
    CREATE DATABASE gravity_dw;
GO
USE gravity_dw;
GO
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
IF SCHEMA_ID('dq')  IS NULL EXEC('CREATE SCHEMA dq');
GO

DROP TABLE IF EXISTS dbo.fact_sales;
DROP TABLE IF EXISTS dbo.dim_date, dbo.dim_customer, dbo.dim_book,
    dbo.dim_location, dbo.dim_shipping_method;
DROP TABLE IF EXISTS etl.config, etl.audit, dq.check_log, dq.fact_rejects;
GO

/* ======================= Dimensions ======================= */

CREATE TABLE dbo.dim_date (
    date_key        INT          NOT NULL,   -- yyyymmdd; -1 = unknown
    full_date       DATE         NULL,
    day_of_month    TINYINT      NULL,
    day_name        VARCHAR(10)  NULL,
    month_num       TINYINT      NULL,
    month_name      VARCHAR(10)  NULL,
    quarter_num     TINYINT      NULL,
    quarter_label   CHAR(2)      NULL,       -- Q1..Q4
    year_num        SMALLINT     NULL,
    year_month      CHAR(7)      NULL,       -- 2025-10
    year_quarter    CHAR(7)      NULL,       -- 2025-Q4
    campaign_period VARCHAR(20)  NOT NULL,   -- Pre-campaign / Post-campaign
    CONSTRAINT pk_dim_date PRIMARY KEY (date_key)
);

CREATE TABLE dbo.dim_customer (
    customer_key      INT IDENTITY(1,1) NOT NULL,
    customer_id       INT           NOT NULL,   -- business key
    first_name        VARCHAR(200)  NULL,
    last_name         VARCHAR(200)  NULL,
    full_name         VARCHAR(401)  NULL,
    email             VARCHAR(350)  NULL,
    email_domain      VARCHAR(200)  NULL,
    heard_about       VARCHAR(50)   NOT NULL,   -- from survey
    preferred_channel VARCHAR(50)   NOT NULL,   -- from survey
    survey_responded  BIT           NOT NULL,
    CONSTRAINT pk_dim_customer PRIMARY KEY (customer_key),
    CONSTRAINT uq_dim_customer_bk UNIQUE (customer_id)
);

CREATE TABLE dbo.dim_book (
    book_key         INT IDENTITY(1,1) NOT NULL,
    book_id          INT           NOT NULL,    -- business key
    title            VARCHAR(400)  NULL,
    isbn13           CHAR(13)      NULL,
    num_pages        INT           NULL,        -- NULL where source had 0
    publication_date DATE          NULL,
    publication_year SMALLINT      NULL,
    publisher_name   VARCHAR(400)  NULL,
    language_code    VARCHAR(8)    NULL,
    language_name    VARCHAR(50)   NULL,
    language_group   VARCHAR(20)   NOT NULL,    -- English / Non-English
    CONSTRAINT pk_dim_book PRIMARY KEY (book_key),
    CONSTRAINT uq_dim_book_bk UNIQUE (book_id)
);

CREATE TABLE dbo.dim_location (
    location_key   INT IDENTITY(1,1) NOT NULL,
    address_id     INT           NOT NULL,      -- business key (order destination address)
    street_number  VARCHAR(10)   NULL,
    street_name    VARCHAR(200)  NULL,
    city           VARCHAR(100)  NULL,
    country_id     INT           NULL,
    country_name   VARCHAR(200)  NOT NULL,      -- cleansed name (see reference/country_region.csv)
    region         VARCHAR(50)   NOT NULL,      -- continent
    country_status VARCHAR(20)   NOT NULL,      -- Current / Historical / Invalid
    CONSTRAINT pk_dim_location PRIMARY KEY (location_key),
    CONSTRAINT uq_dim_location_bk UNIQUE (address_id)
);

CREATE TABLE dbo.dim_shipping_method (
    shipping_key INT IDENTITY(1,1) NOT NULL,
    method_id    INT           NOT NULL,        -- business key
    method_name  VARCHAR(100)  NOT NULL,
    cost         DECIMAL(6,2)  NULL,
    CONSTRAINT pk_dim_shipping PRIMARY KEY (shipping_key),
    CONSTRAINT uq_dim_shipping_bk UNIQUE (method_id)
);

/* ======================= Fact ======================= */

CREATE TABLE dbo.fact_sales (
    sales_key               BIGINT IDENTITY(1,1) NOT NULL,
    order_date_key          INT          NOT NULL,
    customer_key            INT          NOT NULL,
    book_key                INT          NOT NULL,
    location_key            INT          NOT NULL,
    shipping_key            INT          NOT NULL,
    order_id                INT          NOT NULL,   -- degenerate dimension
    line_id                 INT          NOT NULL,   -- degenerate dimension
    sales_amount            DECIMAL(7,2) NOT NULL,
    quantity                INT          NOT NULL CONSTRAINT df_fact_qty DEFAULT 1,
    latest_order_status     VARCHAR(20)  NOT NULL,
    is_cancelled_or_returned BIT         NOT NULL,
    CONSTRAINT pk_fact_sales PRIMARY KEY (sales_key),
    CONSTRAINT uq_fact_sales_line UNIQUE (line_id),
    CONSTRAINT fk_fact_date     FOREIGN KEY (order_date_key) REFERENCES dbo.dim_date (date_key),
    CONSTRAINT fk_fact_customer FOREIGN KEY (customer_key)   REFERENCES dbo.dim_customer (customer_key),
    CONSTRAINT fk_fact_book     FOREIGN KEY (book_key)       REFERENCES dbo.dim_book (book_key),
    CONSTRAINT fk_fact_location FOREIGN KEY (location_key)   REFERENCES dbo.dim_location (location_key),
    CONSTRAINT fk_fact_shipping FOREIGN KEY (shipping_key)   REFERENCES dbo.dim_shipping_method (shipping_key)
);
CREATE INDEX ix_fact_date     ON dbo.fact_sales (order_date_key);
CREATE INDEX ix_fact_book     ON dbo.fact_sales (book_key);
CREATE INDEX ix_fact_location ON dbo.fact_sales (location_key);
GO

/* ======================= ETL control & data quality ======================= */

CREATE TABLE etl.config (
    config_key   VARCHAR(50)  NOT NULL PRIMARY KEY,
    config_value VARCHAR(200) NOT NULL,
    description  VARCHAR(400) NULL
);
INSERT INTO etl.config VALUES
('campaign_start_date', '2025-10-01', 'Assumed start of the marketing campaign (not in source data)'),
('dim_date_start',      '2023-01-01', 'First date generated in dim_date'),
('dim_date_end',        '2026-12-31', 'Last date generated in dim_date');

CREATE TABLE etl.audit (
    audit_id      INT IDENTITY(1,1) PRIMARY KEY,
    package_name  VARCHAR(100) NOT NULL,
    task_name     VARCHAR(100) NOT NULL,
    table_name    VARCHAR(100) NULL,
    rows_read     INT          NULL,
    rows_written  INT          NULL,
    rows_rejected INT          NULL,
    start_time    DATETIME2    NOT NULL DEFAULT SYSDATETIME(),
    end_time      DATETIME2    NULL,
    status        VARCHAR(20)  NOT NULL DEFAULT 'Running'
);

CREATE TABLE dq.check_log (
    check_id     INT IDENTITY(1,1) PRIMARY KEY,
    run_time     DATETIME2    NOT NULL,
    check_name   VARCHAR(100) NOT NULL,
    dq_dimension VARCHAR(20)  NOT NULL,   -- Completeness / Validity / Uniqueness / Integrity / Consistency
    table_name   VARCHAR(100) NOT NULL,
    failed_rows  INT          NOT NULL,
    severity     VARCHAR(10)  NOT NULL,   -- High / Medium / Low
    treatment    VARCHAR(300) NULL
);

CREATE TABLE dq.fact_rejects (
    reject_id     INT IDENTITY(1,1) PRIMARY KEY,
    line_id       INT          NULL,
    order_id      INT          NULL,
    book_id       INT          NULL,
    price         DECIMAL(7,2) NULL,
    reject_reason VARCHAR(200) NOT NULL,
    reject_time   DATETIME2    NOT NULL DEFAULT SYSDATETIME()
);
GO

/* ======================= Unknown members (key -1) ======================= */

INSERT INTO dbo.dim_date (date_key, campaign_period) VALUES (-1, 'Unknown');

SET IDENTITY_INSERT dbo.dim_customer ON;
INSERT INTO dbo.dim_customer (customer_key, customer_id, full_name, heard_about, preferred_channel, survey_responded)
VALUES (-1, -1, 'Unknown', 'Unknown', 'Unknown', 0);
SET IDENTITY_INSERT dbo.dim_customer OFF;

SET IDENTITY_INSERT dbo.dim_book ON;
INSERT INTO dbo.dim_book (book_key, book_id, title, language_group) VALUES (-1, -1, 'Unknown', 'Unknown');
SET IDENTITY_INSERT dbo.dim_book OFF;

SET IDENTITY_INSERT dbo.dim_location ON;
INSERT INTO dbo.dim_location (location_key, address_id, city, country_name, region, country_status)
VALUES (-1, -1, 'Unknown', 'Unknown', 'Unknown', 'Invalid');
SET IDENTITY_INSERT dbo.dim_location OFF;

SET IDENTITY_INSERT dbo.dim_shipping_method ON;
INSERT INTO dbo.dim_shipping_method (shipping_key, method_id, method_name) VALUES (-1, -1, 'Unknown');
SET IDENTITY_INSERT dbo.dim_shipping_method OFF;
GO
