-- ============================================================
-- GOLD LAYER: Final star schema and business reports
-- ============================================================
-- Key design decision:
--   gold_dimcliente keeps ALL customer versions (SCD2), and every fact is joined
--   to the version that was valid on the sale date (point-in-time join):
--       FechaInicio <= FechaVenta < FechaFin    (FechaFin NULL = current version)
--   The result is stored in gold_factventas.ClienteSK. If facts were joined only
--   to the current customer row, a January sale would show the customer's CURRENT
--   city and the SCD2 history would be lost in the analysis.
--
-- Table and column names stay in Spanish because they come from the course dataset.

USE CATALOG invest2_catalog;
USE SCHEMA invest2_gold;

-- ---------- Dimensions ----------
CREATE OR REPLACE TABLE gold_dimsucursal AS
SELECT SucursalKey, NombreSucursal, Region, Gerente
FROM invest2_silver.silver_dimsucursal;

-- Customer: all versions, each with its validity range
CREATE OR REPLACE TABLE gold_dimcliente AS
SELECT ClienteSK, ClienteKey, NombreCliente, Ciudad, Region, Pais, Email,
       FechaInicio, FechaFin, Activo
FROM invest2_silver.silver_dimcliente;

-- Product: MarcaAnterior is kept for traceability (SCD3)
CREATE OR REPLACE TABLE gold_dimproducto AS
SELECT ProductoKey, NombreProducto, Subcategoria, Categoria, Marca, MarcaAnterior
FROM invest2_silver.silver_dimproducto;

-- ---------- Fact table: each sale points to the correct customer version ----------
-- LEFT JOIN: a sale that falls outside every validity range (for example, earlier
-- than the first FechaInicio) keeps a NULL ClienteSK instead of disappearing.
-- 04_validaciones.sql counts those cases.
CREATE OR REPLACE TABLE gold_factventas AS
SELECT
    f.FechaKey
  , f.FechaVenta
  , f.ProductoKey
  , c.ClienteSK
  , f.ClienteKey
  , f.SucursalKey
  , f.CantidadVendida
  , f.MontoVenta
FROM invest2_silver.silver_factventas AS f
LEFT JOIN invest2_gold.gold_dimcliente AS c
  ON  c.ClienteKey = f.ClienteKey
  AND f.FechaVenta >= c.FechaInicio
  AND (c.FechaFin IS NULL OR f.FechaVenta < c.FechaFin);

-- ============================================================
-- REPORT 1: sales by product category, region and branch
-- ============================================================
SELECT
    dp.Categoria           AS Category
  , ds.Region              AS Region
  , ds.NombreSucursal      AS Branch
  , SUM(f.CantidadVendida) AS TotalUnitsSold
  , SUM(f.MontoVenta)      AS TotalSales
FROM gold_factventas AS f
JOIN gold_dimproducto  AS dp ON f.ProductoKey = dp.ProductoKey
JOIN gold_dimsucursal  AS ds ON f.SucursalKey = ds.SucursalKey
GROUP BY dp.Categoria, ds.Region, ds.NombreSucursal
ORDER BY TotalSales DESC;

-- ============================================================
-- REPORT 2: sales by customer country (why SCD2 matters)
-- ============================================================
-- "CountryAtSale" uses the customer version valid on the purchase date.
-- "CurrentCountry" uses the customer's current version. If a customer moved,
-- each earlier sale is counted in the country where the customer lived back then.
SELECT
    COALESCE(c.Pais, 'No valid version') AS CountryAtSale
  , SUM(f.CantidadVendida)               AS TotalUnitsSold
  , SUM(f.MontoVenta)                    AS TotalSales
FROM gold_factventas AS f
LEFT JOIN gold_dimcliente AS c ON f.ClienteSK = c.ClienteSK
GROUP BY COALESCE(c.Pais, 'No valid version')
ORDER BY TotalSales DESC;

SELECT
    COALESCE(a.Pais, 'No current customer') AS CurrentCountry
  , SUM(f.CantidadVendida)                  AS TotalUnitsSold
  , SUM(f.MontoVenta)                       AS TotalSales
FROM gold_factventas AS f
LEFT JOIN gold_dimcliente AS a
  ON a.ClienteKey = f.ClienteKey AND a.Activo = true
GROUP BY COALESCE(a.Pais, 'No current customer')
ORDER BY TotalSales DESC;
-- If the two reports differ, the SCD2 history is adding value.
