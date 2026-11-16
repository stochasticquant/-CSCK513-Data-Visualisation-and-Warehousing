/*  10_create_staging.sql
    Creates the gravity_staging database.
    Staging tables mirror the source tables 1:1 with NO keys or constraints,
    so the extract never fails on dirty data. Cleansing happens later, in the
    transform step. Each table records when its rows were loaded.
*/
IF DB_ID('gravity_staging') IS NULL
    CREATE DATABASE gravity_staging;
GO
USE gravity_staging;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO

DROP TABLE IF EXISTS stg.book, stg.book_language, stg.publisher, stg.customer,
    stg.address, stg.country, stg.cust_order, stg.order_line, stg.order_history,
    stg.order_status, stg.shipping_method, stg.survey, stg.country_region;
GO

/* ---------- Operational database (gravity_books) ---------- */
CREATE TABLE stg.book (
    book_id          INT,
    title            VARCHAR(400),
    isbn13           VARCHAR(13),
    language_id      INT,
    num_pages        INT,
    publication_date DATE,
    publisher_id     INT,
    load_datetime    DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.book_language (
    language_id   INT,
    language_code VARCHAR(8),
    language_name VARCHAR(50),
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.publisher (
    publisher_id   INT,
    publisher_name VARCHAR(400),
    load_datetime  DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.customer (
    customer_id   INT,
    first_name    VARCHAR(200),
    last_name     VARCHAR(200),
    email         VARCHAR(350),
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.address (
    address_id    INT,
    street_number VARCHAR(10),
    street_name   VARCHAR(200),
    city          VARCHAR(100),
    country_id    INT,
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.country (
    country_id    INT,
    country_name  VARCHAR(200),
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.cust_order (
    order_id           INT,
    order_date         DATETIME,
    customer_id        INT,
    shipping_method_id INT,
    dest_address_id    INT,
    load_datetime      DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.order_line (
    line_id       INT,
    order_id      INT,
    book_id       INT,
    price         DECIMAL(5, 2),
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.order_history (
    history_id    INT,
    order_id      INT,
    status_id     INT,
    status_date   DATETIME,
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.order_status (
    status_id     INT,
    status_value  VARCHAR(20),
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

CREATE TABLE stg.shipping_method (
    method_id     INT,
    method_name   VARCHAR(100),
    cost          DECIMAL(6, 2),
    load_datetime DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

/* ---------- Flat files ---------- */
-- bookstore survey.csv: kept as text; converted and validated in the transform step
CREATE TABLE stg.survey (
    customer_id       VARCHAR(50),
    heard_about       VARCHAR(100),
    preferred_channel VARCHAR(100),
    load_datetime     DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);

-- reference/country_region.csv: country -> region lookup and country-name cleansing map
CREATE TABLE stg.country_region (
    country_id         VARCHAR(10),
    country_name       VARCHAR(200),
    clean_country_name VARCHAR(200),
    region             VARCHAR(50),
    country_status     VARCHAR(20),
    cleansing_note     VARCHAR(200),
    load_datetime      DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
