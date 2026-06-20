CREATE DATABASE IF NOT EXISTS ventas_dw
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

USE ventas_dw;

DROP TABLE IF EXISTS DimTiempo;
CREATE TABLE DimTiempo (
    id_tiempo        INT          NOT NULL,  -- clave surrogate: YYYYMMDD
    fecha            DATE         NOT NULL,
    anio             SMALLINT     NOT NULL,
    trimestre        TINYINT      NOT NULL,  -- 1-4
    mes              TINYINT      NOT NULL,  -- 1-12
    nombre_mes       VARCHAR(20)  NOT NULL,  -- 'Enero', 'Febrero', ...
    semana_anio      TINYINT      NOT NULL,  -- 1-53 (ISO)
    dia_mes          TINYINT      NOT NULL,  -- 1-31
    dia_semana       TINYINT      NOT NULL,  -- 1=Lunes … 7=Domingo
    nombre_dia       VARCHAR(20)  NOT NULL,
    es_fin_semana    BOOLEAN      NOT NULL,
    anio_mes         CHAR(7)      NOT NULL,  -- 'YYYY-MM' para agrupar fácil

    CONSTRAINT pk_dimtiempo PRIMARY KEY (id_tiempo)
);

DROP TABLE IF EXISTS DimCliente;
CREATE TABLE DimCliente (
    id_cliente_sk    INT          NOT NULL AUTO_INCREMENT, 
    id_cliente_nk    INT          NOT NULL,                
    nombre_completo  VARCHAR(210) NOT NULL,
    email            VARCHAR(150) NOT NULL,
    telefono         VARCHAR(20)  NULL,
    direccion        VARCHAR(100) NULL,
    ciudad           VARCHAR(100) NULL,  
    fecha_registro   DATE         NOT NULL,
    anio_registro    SMALLINT     NOT NULL,
    -- Segmentación analítica (calculada en ETL)
    segmento         ENUM('VIP','FRECUENTE','OCASIONAL','NUEVO') NOT NULL DEFAULT 'NUEVO',
    fecha_carga_dw   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_dimcliente PRIMARY KEY (id_cliente_sk)
);

DROP TABLE IF EXISTS DimProducto;
CREATE TABLE DimProducto (
    id_producto_sk   INT          NOT NULL AUTO_INCREMENT,
    id_producto_nk   INT          NOT NULL,
    nombre_producto  VARCHAR(150) NOT NULL,
    descripcion      TEXT         NULL,
    -- Categoría desnormalizada (en OLTP requería JOIN con Categorias)
    id_categoria     INT          NOT NULL,
    nombre_categoria VARCHAR(100) NOT NULL,
    -- Rango de precio (calculado en ETL, útil para filtros analíticos)
    rango_precio     ENUM('ECONOMICO','MEDIO','PREMIUM') NOT NULL,
    precio_actual    DECIMAL(10,2) NOT NULL,
    activo           BOOLEAN       NOT NULL,
    fecha_carga_dw   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_dimproducto PRIMARY KEY (id_producto_sk)
);

DROP TABLE IF EXISTS HechoVentas;
CREATE TABLE HechoVentas (
    id_hecho             INT            NOT NULL AUTO_INCREMENT,
    id_tiempo            INT            NOT NULL,
    id_cliente_sk        INT            NOT NULL,
    id_producto_sk       INT            NOT NULL,
    id_venta_nk          INT            NOT NULL,
    id_cliente_nk        INT            NOT NULL,
    id_producto_nk       INT            NOT NULL,
    cantidad             INT            NOT NULL,
    precio_unitario      DECIMAL(10,2)  NOT NULL,
    monto_bruto_linea    DECIMAL(12,2)  NOT NULL,
    descuento_pct        DECIMAL(5,2)   NOT NULL DEFAULT 0.00,
    monto_descuento      DECIMAL(12,2)  NOT NULL DEFAULT 0.00,
    monto_neto_linea     DECIMAL(12,2)  NOT NULL,
    total_venta          DECIMAL(12,2)  NOT NULL,
    estado_venta         VARCHAR(20)    NOT NULL,
    anio_venta           SMALLINT       NOT NULL,
    mes_venta            TINYINT        NOT NULL,
    trimestre_venta      TINYINT        NOT NULL,

    CONSTRAINT pk_hechoventas PRIMARY KEY (id_hecho)
);

CREATE INDEX idx_hv_tiempo     ON HechoVentas (id_tiempo);
CREATE INDEX idx_hv_cliente    ON HechoVentas (id_cliente_sk);
CREATE INDEX idx_hv_producto   ON HechoVentas (id_producto_sk);
CREATE INDEX idx_hv_anio_mes   ON HechoVentas (anio_venta, mes_venta);
CREATE INDEX idx_hv_estado     ON HechoVentas (estado_venta);

DROP PROCEDURE IF EXISTS etl_cargar_dimtiempo;
DELIMITER $$

CREATE PROCEDURE etl_cargar_dimtiempo(
    IN p_fecha_inicio DATE,
    IN p_fecha_fin    DATE
)
BEGIN
    DECLARE v_fecha DATE DEFAULT p_fecha_inicio;

    WHILE v_fecha <= p_fecha_fin DO
        INSERT IGNORE INTO DimTiempo (
            id_tiempo, fecha, anio, trimestre, mes, nombre_mes,
            semana_anio, dia_mes, dia_semana, nombre_dia,
            es_fin_semana, anio_mes
        ) VALUES (
        
            YEAR(v_fecha) * 10000 + MONTH(v_fecha) * 100 + DAY(v_fecha),
            v_fecha,
            YEAR(v_fecha),
            QUARTER(v_fecha),
            MONTH(v_fecha),
            -- nombre_mes en español
            ELT(MONTH(v_fecha),
                'Enero','Febrero','Marzo','Abril','Mayo','Junio',
                'Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'),
            WEEK(v_fecha, 3),   -- modo ISO 8601
            DAY(v_fecha),
            IF(DAYOFWEEK(v_fecha) = 1, 7, DAYOFWEEK(v_fecha) - 1),
            ELT(IF(DAYOFWEEK(v_fecha)=1,7,DAYOFWEEK(v_fecha)-1),
                'Lunes','Martes','Miércoles','Jueves',
                'Viernes','Sábado','Domingo'),
            DAYOFWEEK(v_fecha) IN (1, 7),
            DATE_FORMAT(v_fecha, '%Y-%m')
        );
        SET v_fecha = DATE_ADD(v_fecha, INTERVAL 1 DAY);
    END WHILE;

    SELECT COUNT(*) AS filas_dimtiempo FROM DimTiempo;
END $$

DELIMITER ;

CALL etl_cargar_dimtiempo('2024-01-01', '2026-12-31');

DROP PROCEDURE IF EXISTS etl_cargar_dimcliente;
DELIMITER $$

CREATE PROCEDURE etl_cargar_dimcliente()
BEGIN

    TRUNCATE TABLE ventas_dw.DimCliente;

    INSERT INTO ventas_dw.DimCliente (
        id_cliente_nk, nombre_completo, email, telefono,
        direccion, ciudad, fecha_registro, anio_registro, segmento
    )
    SELECT
        c.id_cliente,
        CONCAT(c.nombre, ' ', c.apellido),
        c.email,
        c.telefono,
        c.direccion,
        TRIM(SUBSTRING_INDEX(IFNULL(c.direccion, ''), ',', -1)),
        c.fecha_registro,
        YEAR(c.fecha_registro),
        CASE
            WHEN compras.total >= 10 THEN 'VIP'
            WHEN compras.total >= 5  THEN 'FRECUENTE'
            WHEN compras.total >= 1  THEN 'OCASIONAL'
            ELSE                          'NUEVO'
        END
    FROM ventas_oltp.Clientes c
    LEFT JOIN (
        SELECT id_cliente, COUNT(*) AS total
        FROM   ventas_oltp.Ventas
        WHERE  estado = 'entregada'
        GROUP BY id_cliente
    ) compras ON compras.id_cliente = c.id_cliente;

    SELECT COUNT(*) AS filas_dimcliente FROM ventas_dw.DimCliente;
END $$

DELIMITER ;

CALL etl_cargar_dimcliente();

DROP PROCEDURE IF EXISTS etl_cargar_dimproducto;
DELIMITER $$

CREATE PROCEDURE etl_cargar_dimproducto()
BEGIN
    TRUNCATE TABLE ventas_dw.DimProducto;

    INSERT INTO ventas_dw.DimProducto (
        id_producto_nk, nombre_producto, descripcion,
        id_categoria, nombre_categoria, rango_precio,
        precio_actual, activo
    )
    SELECT
        p.id_producto,
        p.nombre,
        p.descripcion,
        c.id_categoria,
        c.nombre,
        CASE
            WHEN p.precio < 5000   THEN 'ECONOMICO'
            WHEN p.precio < 50000  THEN 'MEDIO'
            ELSE                        'PREMIUM'
        END,
        p.precio,
        p.activo
    FROM ventas_oltp.Productos  p
    JOIN ventas_oltp.Categorias c ON p.id_categoria = c.id_categoria;

    SELECT COUNT(*) AS filas_dimproducto FROM ventas_dw.DimProducto;
END $$

DELIMITER ;

CALL etl_cargar_dimproducto();

DROP PROCEDURE IF EXISTS etl_cargar_hechoventas;
DELIMITER $$

CREATE PROCEDURE etl_cargar_hechoventas()
BEGIN
    TRUNCATE TABLE ventas_dw.HechoVentas;

    INSERT INTO ventas_dw.HechoVentas (
        id_tiempo, id_cliente_sk, id_producto_sk,
        id_venta_nk, id_cliente_nk, id_producto_nk,
        cantidad, precio_unitario,
        monto_bruto_linea, descuento_pct,
        monto_descuento, monto_neto_linea,
        total_venta, estado_venta,
        anio_venta, mes_venta, trimestre_venta
    )
    SELECT
        YEAR(v.fecha_venta)  * 10000
        + MONTH(v.fecha_venta) * 100
        + DAY(v.fecha_venta)                            AS id_tiempo,

        dc.id_cliente_sk,
        dp.id_producto_sk,

        v.id_venta,
        v.id_cliente,
        dv.id_producto,

        dv.cantidad,
        dv.precio_unitario,

        dv.cantidad * dv.precio_unitario                AS monto_bruto_linea,

        ROUND(
            (1 - v.total / NULLIF(suma_bruta.total_bruto, 0)) * 100
        , 2)                                            AS descuento_pct,

        ROUND(
            (dv.cantidad * dv.precio_unitario)
            * (1 - v.total / NULLIF(suma_bruta.total_bruto, 0))
        , 2)                                            AS monto_descuento,

        ROUND(
            (dv.cantidad * dv.precio_unitario)
            * (v.total / NULLIF(suma_bruta.total_bruto, 0))
        , 2)                                            AS monto_neto_linea,

        v.total                                         AS total_venta,
        v.estado,
        YEAR(v.fecha_venta),
        MONTH(v.fecha_venta),
        QUARTER(v.fecha_venta)

    FROM ventas_oltp.Ventas v
    JOIN (
        SELECT   id_venta,
                 SUM(cantidad * precio_unitario) AS total_bruto
        FROM     ventas_oltp.DetalleVentas
        GROUP BY id_venta
    ) suma_bruta ON suma_bruta.id_venta = v.id_venta

    JOIN ventas_oltp.DetalleVentas dv ON dv.id_venta = v.id_venta

    -- Lookup de surrogate keys
    JOIN ventas_dw.DimCliente  dc ON dc.id_cliente_nk  = v.id_cliente
    JOIN ventas_dw.DimProducto dp ON dp.id_producto_nk = dv.id_producto
    
    WHERE v.estado != 'cancelada';

    SELECT COUNT(*) AS filas_hechoventas FROM ventas_dw.HechoVentas;
END $$

DELIMITER ;

CALL etl_cargar_hechoventas();

DROP PROCEDURE IF EXISTS etl_ejecutar_completo;
DELIMITER $$

CREATE PROCEDURE etl_ejecutar_completo()
BEGIN
    SELECT 'ETL INICIO' AS etapa, NOW() AS timestamp_etapa;

    CALL etl_cargar_dimtiempo('2024-01-01', '2026-12-31');
    SELECT 'DimTiempo OK' AS etapa, NOW() AS timestamp_etapa;

    CALL etl_cargar_dimcliente();
    
    
    
    SELECT 'DimCliente OK' AS etapa, NOW() AS timestamp_etapa;

    CALL etl_cargar_dimproducto();
    SELECT 'DimProducto OK' AS etapa, NOW() AS timestamp_etapa;

    CALL etl_cargar_hechoventas();
    SELECT 'HechoVentas OK' AS etapa, NOW() AS timestamp_etapa;

    -- Resumen final de carga
    SELECT 'DimTiempo'    AS tabla, COUNT(*) AS filas FROM DimTiempo
    UNION ALL
    SELECT 'DimCliente',            COUNT(*)          FROM DimCliente
    UNION ALL
    SELECT 'DimProducto',           COUNT(*)          FROM DimProducto
    UNION ALL
    SELECT 'HechoVentas',           COUNT(*)          FROM HechoVentas;

    SELECT 'ETL FIN' AS etapa, NOW() AS timestamp_etapa;
END $$

DELIMITER ;

SELECT
    t.anio_mes                          AS periodo,
    t.anio,
    t.mes,
    t.nombre_mes,
    COUNT(DISTINCT h.id_venta_nk)       AS cantidad_ventas,
    SUM(h.cantidad)                     AS unidades_vendidas,
    ROUND(SUM(h.monto_bruto_linea), 2)  AS monto_bruto,
    ROUND(SUM(h.monto_descuento),   2)  AS total_descuentos,
    ROUND(SUM(h.monto_neto_linea),  2)  AS monto_neto,
    ROUND(AVG(h.total_venta), 2)        AS ticket_promedio
FROM  HechoVentas h
JOIN  DimTiempo   t ON h.id_tiempo = t.id_tiempo
WHERE h.estado_venta != 'cancelada'
GROUP BY t.anio_mes, t.anio, t.mes, t.nombre_mes
ORDER BY t.anio, t.mes;

SELECT
    dp.nombre_producto,
    dp.nombre_categoria,
    dp.rango_precio,
    SUM(h.cantidad)                     AS unidades_vendidas,
    ROUND(SUM(h.monto_neto_linea), 2)   AS monto_neto_total,
    ROUND(AVG(h.precio_unitario),  2)   AS precio_promedio_venta,
    COUNT(DISTINCT h.id_venta_nk)       AS apariciones_en_ventas,
    ROUND(
        SUM(h.monto_neto_linea) * 100.0
        / SUM(SUM(h.monto_neto_linea)) OVER ()
    , 2)                                AS pct_sobre_total
FROM  HechoVentas  h
JOIN  DimProducto  dp ON h.id_producto_sk = dp.id_producto_sk
WHERE h.estado_venta != 'cancelada'
GROUP BY dp.id_producto_sk, dp.nombre_producto,
         dp.nombre_categoria, dp.rango_precio
ORDER BY monto_neto_total DESC
LIMIT 10;



SELECT
    IFNULL(dp.nombre_categoria, '── TOTAL GENERAL ──') AS categoria,
    COUNT(DISTINCT h.id_venta_nk)                       AS ventas,
    SUM(h.cantidad)                                     AS unidades,
    ROUND(SUM(h.monto_bruto_linea), 2)                  AS bruto,
    ROUND(SUM(h.monto_descuento),   2)                  AS descuentos,
    ROUND(SUM(h.monto_neto_linea),  2)                  AS neto,
    ROUND(
        SUM(h.monto_neto_linea) * 100.0
        / SUM(SUM(h.monto_neto_linea)) OVER ()
    , 2)                                                AS pct_categoria
FROM  HechoVentas  h
JOIN  DimProducto  dp ON h.id_producto_sk = dp.id_producto_sk
WHERE h.estado_venta != 'cancelada'
GROUP BY dp.nombre_categoria WITH ROLLUP
ORDER BY neto DESC;

SELECT
    RANK() OVER (ORDER BY SUM(h.monto_neto_linea) DESC) AS ranking,
    dc.nombre_completo,
    dc.segmento,
    dc.ciudad,
    dc.anio_registro,
    COUNT(DISTINCT h.id_venta_nk)                        AS total_compras,
    SUM(h.cantidad)                                      AS unidades_compradas,
    ROUND(SUM(h.monto_neto_linea),  2)                   AS gasto_total_neto,
    ROUND(AVG(h.total_venta),       2)                   AS ticket_promedio,
    ROUND(SUM(h.monto_descuento),   2)                   AS descuentos_obtenidos,
    MIN(t.fecha)                                         AS primera_compra,
    MAX(t.fecha)                                         AS ultima_compra,
    DATEDIFF(MAX(t.fecha), MIN(t.fecha))                 AS dias_como_cliente
FROM  HechoVentas  h
JOIN  DimCliente   dc ON h.id_cliente_sk  = dc.id_cliente_sk
JOIN  DimTiempo    t  ON h.id_tiempo      = t.id_tiempo
WHERE h.estado_venta != 'cancelada'
GROUP BY dc.id_cliente_sk, dc.nombre_completo, dc.segmento,
         dc.ciudad, dc.anio_registro
ORDER BY gasto_total_neto DESC;

SELECT
    t.anio,
    t.trimestre,
    CONCAT(t.anio, ' Q', t.trimestre)                       AS periodo,
    ROUND(SUM(h.monto_neto_linea), 2)                        AS neto_trimestre,
    -- Trimestre anterior (LAG)
    ROUND(LAG(SUM(h.monto_neto_linea))
          OVER (ORDER BY t.anio, t.trimestre), 2)            AS neto_trimestre_anterior,
    -- Variación absoluta
    ROUND(SUM(h.monto_neto_linea)
        - LAG(SUM(h.monto_neto_linea))
          OVER (ORDER BY t.anio, t.trimestre), 2)            AS variacion_absoluta,
    -- Variación porcentual
    ROUND(
        (SUM(h.monto_neto_linea)
         - LAG(SUM(h.monto_neto_linea))
           OVER (ORDER BY t.anio, t.trimestre))
        / NULLIF(LAG(SUM(h.monto_neto_linea))
                 OVER (ORDER BY t.anio, t.trimestre), 0)
        * 100
    , 2)                                                     AS variacion_pct
FROM  HechoVentas h
JOIN  DimTiempo   t ON h.id_tiempo = t.id_tiempo
WHERE h.estado_venta != 'cancelada'
GROUP BY t.anio, t.trimestre
ORDER BY t.anio, t.trimestre;

USE ventas_oltp;

SELECT
    DATE_FORMAT(v.fecha_venta, '%Y-%m')              AS periodo,
    cat.nombre                                       AS categoria,
    COUNT(DISTINCT v.id_venta)                       AS ventas,
    SUM(dv.cantidad)                                 AS unidades,
    ROUND(SUM(dv.cantidad * dv.precio_unitario), 2)  AS monto_bruto,
    ROUND(SUM(v.total
              * (dv.cantidad * dv.precio_unitario)
              / SUM(dv.cantidad * dv.precio_unitario)
                OVER (PARTITION BY v.id_venta)), 2)  AS monto_neto_aprox
FROM       Ventas         v
JOIN       DetalleVentas  dv  ON v.id_venta    = dv.id_venta
JOIN       Productos      p   ON dv.id_producto = p.id_producto
JOIN       Categorias     cat ON p.id_categoria = cat.id_categoria
WHERE      v.estado != 'cancelada'
GROUP BY   DATE_FORMAT(v.fecha_venta, '%Y-%m'), cat.nombre
ORDER BY   periodo, categoria;

USE ventas_dw;

SELECT
    t.anio_mes                          AS periodo,
    dp.nombre_categoria                 AS categoria,
    COUNT(DISTINCT h.id_venta_nk)       AS ventas,
    SUM(h.cantidad)                     AS unidades,
    ROUND(SUM(h.monto_bruto_linea), 2)  AS monto_bruto,
    ROUND(SUM(h.monto_neto_linea),  2)  AS monto_neto
FROM  HechoVentas  h
JOIN  DimTiempo    t  ON h.id_tiempo      = t.id_tiempo
JOIN  DimProducto  dp ON h.id_producto_sk = dp.id_producto_sk
WHERE h.estado_venta != 'cancelada'
GROUP BY t.anio_mes, dp.nombre_categoria
ORDER BY t.anio_mes, dp.nombre_categoria;

SELECT 'Característica'          AS aspecto,
       'OLTP (ventas_oltp)'      AS oltp,
       'OLAP / DW (ventas_dw)'   AS olap
UNION ALL
SELECT 'Normalización',       '3FN – tablas separadas',    'Estrella – dims desnormalizadas'
UNION ALL
SELECT 'Tablas en la query',  '4 JOINs (V+DV+P+CAT)',      '2 JOINs (H+DimT+DimP)'
UNION ALL
SELECT 'Fecha',               'DATE_FORMAT() en runtime',  'anio_mes pre-calculado en DimTiempo'
UNION ALL
SELECT 'Descuento',           'Calculado en la query',     'monto_descuento ya en HechoVentas'
UNION ALL
SELECT 'Optimizado para',     'INSERT/UPDATE/DELETE',      'SELECT masivo y agregaciones'
UNION ALL
SELECT 'Integridad',          'FK activas, transaccional', 'Sin FK, garantía en ETL'
UNION ALL
SELECT 'Historial',           'Dato vivo (mutable)',       'Snapshot histórico (inmutable)'
UNION ALL
SELECT 'Granularidad hecho',  'Fila por venta (cabecera)', 'Fila por línea de detalle';