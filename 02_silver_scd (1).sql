-- ============================================================
-- SILVER LAYER: Cleaning, typing and Slowly Changing Dimensions (SCD)
-- ============================================================
-- Technique per dimension, depending on how the data changes over time:
--   - Branch   (Sucursal) -> SCD1: overwrite (no history kept)
--   - Customer (Cliente)  -> SCD2: full history with validity range [start, end)
--   - Product  (Producto) -> SCD3: keep only the immediately previous value (brand)
--
-- Table and column names stay in Spanish because they come from the course dataset.
--
-- How to run (incremental load, one day at a time):
--   1) Run the "SETUP" section once (it resets the Silver tables).
--   2) Run the "PROCESS ONE DAY" section with process_day = 1, then 2, then 3:
--        SET VAR process_day = 2;   -- then run the three MERGE statements again
--      Each day can be re-run without creating duplicates (idempotent), as long
--      as days are processed IN ORDER. To reprocess from scratch, re-run SETUP.
--
-- Design notes:
--   * Validity dates come from the silver_config_cargas table, not from
--     hard-coded literals inside each statement.
--   * SCD2 uses a single MERGE that closes the old version and inserts the new one.
--   * Change detection is null-safe (<=>), so a change to or from NULL is detected.
--   * Each customer version has its own surrogate key (ClienteSK), which Gold
--     uses to join facts to the correct version.
--   * Silver reads from Bronze only the rows of the day being processed (dia_carga).

USE CATALOG invest2_catalog;
USE SCHEMA invest2_silver;

-- ============================================================
-- SETUP (run once)
-- ============================================================

-- Validity date associated with each daily load.
-- Day 3 (2025-03-01) is an assumption: adjust it to the real date of your data.
-- In a real system this date would come from the source file or the load time.
CREATE OR REPLACE TABLE silver_config_cargas (
    dia_carga      INT
  , fecha_vigencia DATE
);
INSERT INTO silver_config_cargas VALUES
    (1, DATE'2025-01-01')
  , (2, DATE'2025-02-01')
  , (3, DATE'2025-03-01');

-- SCD1: Branch (no validity columns)
CREATE OR REPLACE TABLE silver_dimsucursal (
    SucursalKey    BIGINT
  , NombreSucursal STRING
  , Region         STRING
  , Gerente        STRING
);

-- SCD2: Customer. ClienteSK identifies each VERSION; ClienteKey is the natural key.
CREATE OR REPLACE TABLE silver_dimcliente (
    ClienteSK     BIGINT GENERATED ALWAYS AS IDENTITY
  , ClienteKey    BIGINT
  , NombreCliente STRING
  , Ciudad        STRING
  , Region        STRING
  , Pais          STRING
  , Email         STRING
  , FechaInicio   DATE      -- start date, inclusive
  , FechaFin      DATE      -- end date, exclusive; NULL = current version
  , Activo        BOOLEAN
);

-- SCD3: Product (extra column holding the previous brand)
CREATE OR REPLACE TABLE silver_dimproducto (
    ProductoKey    BIGINT
  , NombreProducto STRING
  , Subcategoria   STRING
  , Categoria      STRING
  , Marca          STRING
  , MarcaAnterior  STRING
);

-- ============================================================
-- PROCESS ONE DAY (run with process_day = 1, then 2, then 3)
-- ============================================================
-- If your runtime does not support session variables, replace process_day with
-- the day number directly in the three statements below.
DECLARE OR REPLACE VARIABLE process_day INT DEFAULT 1;
-- SET VAR process_day = 2;
-- SET VAR process_day = 3;

-- ---------- SCD1 on Branch: overwrite when anything changes ----------
MERGE INTO silver_dimsucursal AS destino
USING (
  SELECT
      CAST(SucursalKey AS BIGINT)  AS SucursalKey
    , CAST(NombreSucursal AS STRING) AS NombreSucursal
    , CAST(Region AS STRING)       AS Region
    , CAST(Gerente AS STRING)      AS Gerente
  FROM invest2_catalog.invest2_bronze.bronze_dimsucursal
  WHERE dia_carga = process_day
  QUALIFY ROW_NUMBER() OVER (PARTITION BY SucursalKey ORDER BY ingestado_en DESC) = 1
) AS origen
ON destino.SucursalKey = origen.SucursalKey
WHEN MATCHED AND NOT (
      destino.NombreSucursal <=> origen.NombreSucursal
  AND destino.Region         <=> origen.Region
  AND destino.Gerente        <=> origen.Gerente
) THEN
  UPDATE SET
    destino.NombreSucursal = origen.NombreSucursal,
    destino.Region         = origen.Region,
    destino.Gerente        = origen.Gerente
WHEN NOT MATCHED THEN
  INSERT (SucursalKey, NombreSucursal, Region, Gerente)
  VALUES (origen.SucursalKey, origen.NombreSucursal, origen.Region, origen.Gerente);


-- ---------- SCD2 on Customer: close the old version + insert the new version ----------
-- Classic single-MERGE technique: when a customer changed, the source contributes
-- that customer TWICE:
--   * row with merge_key = ClienteKey -> matches the active version and CLOSES it.
--   * row with merge_key = NULL       -> never matches, so it is INSERTED as the new version.
-- Attributes that trigger a new version: Ciudad, Region, Pais, Email.
-- (NombreCliente does not version: a name-only change does not create a new version.)
MERGE INTO silver_dimcliente AS destino
USING (
  WITH stg AS (
    SELECT
        CAST(b.ClienteKey AS BIGINT)  AS ClienteKey
      , CAST(b.NombreCliente AS STRING) AS NombreCliente
      , CAST(b.Ciudad AS STRING)      AS Ciudad
      , CAST(b.Region AS STRING)      AS Region
      , CAST(b.Pais AS STRING)        AS Pais
      , CAST(b.Email AS STRING)       AS Email
      , c.fecha_vigencia              AS fecha_vigencia
    FROM invest2_catalog.invest2_bronze.bronze_dimcliente AS b
    JOIN silver_config_cargas AS c ON c.dia_carga = b.dia_carga
    WHERE b.dia_carga = process_day
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.ClienteKey ORDER BY b.ingestado_en DESC) = 1
  )
  SELECT s.ClienteKey AS merge_key, s.* FROM stg AS s
  UNION ALL
  SELECT CAST(NULL AS BIGINT) AS merge_key, s.*
  FROM stg AS s
  JOIN silver_dimcliente AS a
    ON a.ClienteKey = s.ClienteKey AND a.Activo = true
  WHERE NOT (
        a.Ciudad <=> s.Ciudad AND a.Region <=> s.Region
    AND a.Pais   <=> s.Pais   AND a.Email  <=> s.Email
  )
) AS origen
ON destino.ClienteKey = origen.merge_key AND destino.Activo = true
WHEN MATCHED AND NOT (
      destino.Ciudad <=> origen.Ciudad AND destino.Region <=> origen.Region
  AND destino.Pais   <=> origen.Pais   AND destino.Email  <=> origen.Email
) THEN
  UPDATE SET
    destino.FechaFin = origen.fecha_vigencia,
    destino.Activo   = false
WHEN NOT MATCHED THEN
  INSERT (ClienteKey, NombreCliente, Ciudad, Region, Pais, Email, FechaInicio, FechaFin, Activo)
  VALUES (origen.ClienteKey, origen.NombreCliente, origen.Ciudad, origen.Region, origen.Pais,
          origen.Email, origen.fecha_vigencia, NULL, true);


-- ---------- SCD3 on Product: keep only the previous brand ----------
MERGE INTO silver_dimproducto AS destino
USING (
  SELECT
      CAST(ProductoKey AS BIGINT)    AS ProductoKey
    , CAST(NombreProducto AS STRING) AS NombreProducto
    , CAST(Subcategoria AS STRING)   AS Subcategoria
    , CAST(Categoria AS STRING)      AS Categoria
    , CAST(Marca AS STRING)          AS Marca
  FROM invest2_catalog.invest2_bronze.bronze_dimproducto
  WHERE dia_carga = process_day
  QUALIFY ROW_NUMBER() OVER (PARTITION BY ProductoKey ORDER BY ingestado_en DESC) = 1
) AS origen
ON destino.ProductoKey = origen.ProductoKey
WHEN MATCHED AND NOT (destino.Marca <=> origen.Marca) THEN
  UPDATE SET
    destino.MarcaAnterior  = destino.Marca,
    destino.Marca          = origen.Marca,
    destino.NombreProducto = origen.NombreProducto,
    destino.Subcategoria   = origen.Subcategoria,
    destino.Categoria      = origen.Categoria
WHEN MATCHED AND NOT (
      destino.NombreProducto <=> origen.NombreProducto
  AND destino.Subcategoria   <=> origen.Subcategoria
  AND destino.Categoria      <=> origen.Categoria
) THEN
  UPDATE SET
    destino.NombreProducto = origen.NombreProducto,
    destino.Subcategoria   = origen.Subcategoria,
    destino.Categoria      = origen.Categoria
WHEN NOT MATCHED THEN
  INSERT (ProductoKey, NombreProducto, Subcategoria, Categoria, Marca, MarcaAnterior)
  VALUES (origen.ProductoKey, origen.NombreProducto, origen.Subcategoria, origen.Categoria,
          origen.Marca, NULL);


-- ============================================================
-- FACTS (rebuilt in full; no SCD, cleaning only)
-- ============================================================
-- Assumption: FechaKey is formatted as yyyyMMdd (e.g. 20250115).
-- If your FechaKey is already a date (yyyy-MM-dd), use CAST(FechaKey AS DATE) instead.
-- DISTINCT removes identical rows; if the source could contain legitimately repeated
-- sales (there is no transaction ID), replace it with a real business key.
CREATE OR REPLACE TABLE silver_factventas AS
SELECT DISTINCT
    CAST(FechaKey AS BIGINT)            AS FechaKey
  , to_date(CAST(FechaKey AS STRING), 'yyyyMMdd') AS FechaVenta
  , CAST(ProductoKey AS BIGINT)         AS ProductoKey
  , CAST(ClienteKey AS BIGINT)          AS ClienteKey
  , CAST(SucursalKey AS BIGINT)         AS SucursalKey
  , CAST(CantidadVendida AS INT)        AS CantidadVendida
  , CAST(MontoVenta AS DECIMAL(12,2))   AS MontoVenta
FROM invest2_catalog.invest2_bronze.bronze_factventas
WHERE FechaKey IS NOT NULL AND ProductoKey IS NOT NULL
  AND ClienteKey IS NOT NULL AND SucursalKey IS NOT NULL;
