-- ============================================================
-- DATA-QUALITY CHECKS (run after 01, 02 and 03)
-- ============================================================
-- Each query states the expected result in its comment.

USE CATALOG invest2_catalog;

-- 1) Row counts per layer (Bronze accumulates all 3 days; Silver consolidates)
SELECT 'bronze_dimcliente'  AS table_name, COUNT(*) AS row_count FROM invest2_bronze.bronze_dimcliente
UNION ALL SELECT 'silver_dimcliente',  COUNT(*) FROM invest2_silver.silver_dimcliente
UNION ALL SELECT 'gold_dimcliente',    COUNT(*) FROM invest2_gold.gold_dimcliente
UNION ALL SELECT 'bronze_factventas',  COUNT(*) FROM invest2_bronze.bronze_factventas
UNION ALL SELECT 'silver_factventas',  COUNT(*) FROM invest2_silver.silver_factventas
UNION ALL SELECT 'gold_factventas',    COUNT(*) FROM invest2_gold.gold_factventas;
-- Expected: gold_factventas = silver_factventas. If silver is lower than bronze
-- for facts, the difference is rows dropped by DISTINCT or by NULL keys.

-- 2) SCD2: every customer must have EXACTLY one active version
SELECT ClienteKey, COUNT(*) AS active_versions
FROM invest2_silver.silver_dimcliente
WHERE Activo = true
GROUP BY ClienteKey
HAVING COUNT(*) <> 1;
-- Expected: 0 rows.

-- 3) SCD2: the active version has no end date, closed versions do
SELECT COUNT(*) AS inconsistent_rows
FROM invest2_silver.silver_dimcliente
WHERE (Activo = true AND FechaFin IS NOT NULL)
   OR (Activo = false AND FechaFin IS NULL);
-- Expected: 0.

-- 4) SCD2: versions of the same customer must not overlap
SELECT a.ClienteKey, a.ClienteSK AS version_a, b.ClienteSK AS version_b
FROM invest2_silver.silver_dimcliente AS a
JOIN invest2_silver.silver_dimcliente AS b
  ON a.ClienteKey = b.ClienteKey AND a.ClienteSK < b.ClienteSK
WHERE a.FechaInicio < COALESCE(b.FechaFin, DATE'9999-12-31')
  AND b.FechaInicio < COALESCE(a.FechaFin, DATE'9999-12-31');
-- Expected: 0 rows.

-- 5) Facts without a customer version (sales outside every validity range)
SELECT COUNT(*) AS facts_without_customer_version
FROM invest2_gold.gold_factventas
WHERE ClienteSK IS NULL;
-- Expected: 0. If not, check silver_config_cargas (validity dates) and the
-- FechaKey format.

-- 6) Amounts must reconcile across layers
SELECT
    (SELECT SUM(MontoVenta) FROM invest2_silver.silver_factventas) AS total_silver
  , (SELECT SUM(MontoVenta) FROM invest2_gold.gold_factventas)     AS total_gold;
-- Expected: both totals are equal.

-- 7) SCD3: products whose brand changed
SELECT ProductoKey, Marca, MarcaAnterior
FROM invest2_gold.gold_dimproducto
WHERE MarcaAnterior IS NOT NULL;
-- Expected: only the products that changed brand.

-- 8) Idempotency (manual test): re-run the "PROCESS ONE DAY" block of the latest
--    day in 02_silver_scd.sql and repeat checks 2 to 4. Results must be identical
--    to the ones before the re-run.
