-- ============================================================
-- BRONZE LAYER: Raw ingestion from CSV files
-- ============================================================
-- Purpose: create the catalog, schemas and volume, then load the source CSV
-- files into Delta tables WITHOUT transforming any business data.
--
-- Notes:
--   * Table and column names stay in Spanish because they come from the
--     course dataset (e.g. ClienteKey = CustomerKey, Sucursal = Branch).
--   * Every daily load is tagged with `dia_carga` (load day: 1, 2, 3) so that
--     Silver can process one day at a time.
--   * The script can be re-run top to bottom: day 1 uses CREATE OR REPLACE
--     (resets the table) and days 2 and 3 are inserted afterwards.
--
-- The source CSV files are NOT included in the repository. Upload them to the
-- volume (path below) with these names:
--   Dimensión Clientes d1.csv / d2.csv / d3.csv     (customers)
--   Dimensión Productos d1.csv / d2.csv             (products)
--   Dimensión Sucursales d1.csv / d2.csv            (branches)
--   Hechos Ventas d1 d2 d3.csv                      (sales facts, all 3 days)
-- If you also have a day-3 file for products or branches, add a block like the
-- customers day-3 block.

-- ---------- 1. Catalog, schemas and volume ----------
CREATE CATALOG IF NOT EXISTS invest2_catalog;

USE CATALOG invest2_catalog;
CREATE SCHEMA IF NOT EXISTS invest2_bronze;
CREATE SCHEMA IF NOT EXISTS invest2_silver;
CREATE SCHEMA IF NOT EXISTS invest2_gold;
CREATE VOLUME IF NOT EXISTS invest2_bronze.raw_data;

USE SCHEMA invest2_bronze;

-- ---------- 2. Customers dimension (days 1, 2 and 3) ----------
CREATE OR REPLACE VIEW cliente_d1 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Clientes d1.csv',
  format => 'csv', header => true, delimiter => ','
);
CREATE OR REPLACE VIEW cliente_d2 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Clientes d2.csv',
  format => 'csv', header => true, delimiter => ','
);
CREATE OR REPLACE VIEW cliente_d3 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Clientes d3.csv',
  format => 'csv', header => true, delimiter => ','
);

CREATE OR REPLACE TABLE bronze_dimcliente AS
SELECT *, 1 AS dia_carga, current_timestamp() AS ingestado_en FROM cliente_d1;
INSERT INTO bronze_dimcliente SELECT *, 2, current_timestamp() FROM cliente_d2;
INSERT INTO bronze_dimcliente SELECT *, 3, current_timestamp() FROM cliente_d3;

-- ---------- 3. Products dimension (days 1 and 2) ----------
CREATE OR REPLACE VIEW producto_d1 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Productos d1.csv',
  format => 'csv', header => true, delimiter => ','
);
CREATE OR REPLACE VIEW producto_d2 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Productos d2.csv',
  format => 'csv', header => true, delimiter => ','
);

CREATE OR REPLACE TABLE bronze_dimproducto AS
SELECT *, 1 AS dia_carga, current_timestamp() AS ingestado_en FROM producto_d1;
INSERT INTO bronze_dimproducto SELECT *, 2, current_timestamp() FROM producto_d2;

-- ---------- 4. Branches dimension (days 1 and 2) ----------
CREATE OR REPLACE VIEW sucursal_d1 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Sucursales d1.csv',
  format => 'csv', header => true, delimiter => ','
);
CREATE OR REPLACE VIEW sucursal_d2 AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Dimensión Sucursales d2.csv',
  format => 'csv', header => true, delimiter => ','
);

CREATE OR REPLACE TABLE bronze_dimsucursal AS
SELECT *, 1 AS dia_carga, current_timestamp() AS ingestado_en FROM sucursal_d1;
INSERT INTO bronze_dimsucursal SELECT *, 2, current_timestamp() FROM sucursal_d2;

-- ---------- 5. Sales fact table (the file already contains all 3 days) ----------
CREATE OR REPLACE VIEW hechos_ventas AS
SELECT * FROM read_files(
  '/Volumes/invest2_catalog/invest2_bronze/raw_data/Hechos Ventas d1 d2 d3.csv',
  format => 'csv', header => true, delimiter => ','
);

CREATE OR REPLACE TABLE bronze_factventas AS
SELECT *, current_timestamp() AS ingestado_en FROM hechos_ventas;
