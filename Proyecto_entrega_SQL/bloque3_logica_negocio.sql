
USE ventas_oltp;

DELIMITER $$

-- ------------------------------------------------------------
-- fn_calcular_descuento
-- ------------------------------------------------------------
-- Devuelve el porcentaje de descuento (0-30) según el monto
-- de la venta y la cantidad de ítems.
--
-- Reglas de negocio:
--   monto >= 200.000               → 15 % base
--   monto >= 100.000               → 10 % base
--   monto >= 50.000                →  5 % base
--   items >= 5 (cualquier monto)   → +3 % adicional
--   cliente con > 5 compras previas→ +5 % fidelidad
--   techo absoluto                 → 30 %
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_calcular_descuento $$

CREATE FUNCTION fn_calcular_descuento(
    p_monto_bruto    DECIMAL(12,2),
    p_cantidad_items INT,
    p_id_cliente     INT
)
RETURNS DECIMAL(5,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_descuento       DECIMAL(5,2) DEFAULT 0.00;
    DECLARE v_compras_previas INT          DEFAULT 0;

    -- Descuento base por monto de la venta
    IF p_monto_bruto >= 200000 THEN
        SET v_descuento = 15.00;
    ELSEIF p_monto_bruto >= 100000 THEN
        SET v_descuento = 10.00;
    ELSEIF p_monto_bruto >= 50000 THEN
        SET v_descuento = 5.00;
    ELSE
        SET v_descuento = 0.00;
    END IF;

    -- Descuento adicional por volumen de ítems
    IF p_cantidad_items >= 5 THEN
        SET v_descuento = v_descuento + 3.00;
    END IF;

    -- Descuento de fidelidad según historial del cliente
    IF p_id_cliente IS NOT NULL THEN
        SELECT COUNT(*)
        INTO   v_compras_previas
        FROM   Ventas
        WHERE  id_cliente = p_id_cliente
          AND  estado     = 'entregada';

        IF v_compras_previas > 5 THEN
            SET v_descuento = v_descuento + 5.00;
        END IF;
    END IF;

    -- Techo absoluto de 30%
    IF v_descuento > 30.00 THEN
        SET v_descuento = 30.00;
    END IF;

    RETURN v_descuento;
END $$

DROP FUNCTION IF EXISTS fn_calcular_total_venta $$

CREATE FUNCTION fn_calcular_total_venta(
    p_monto_bruto    DECIMAL(12,2),
    p_descuento_pct  DECIMAL(5,2)
)
RETURNS DECIMAL(12,2)
DETERMINISTIC
NO SQL
BEGIN
    DECLARE v_total DECIMAL(12,2);

    -- Guardia: monto negativo
    IF p_monto_bruto < 0 THEN
        RETURN 0.00;
    END IF;

    -- Guardia: descuento fuera de rango
    IF p_descuento_pct < 0 THEN
        SET p_descuento_pct = 0.00;
    ELSEIF p_descuento_pct > 100 THEN
        SET p_descuento_pct = 100.00;
    END IF;

    SET v_total = ROUND(
        p_monto_bruto * (1 - p_descuento_pct / 100),
        2
    );

    RETURN v_total;
END $$

-- ------------------------------------------------------------
-- sp_validar_stock
-- ------------------------------------------------------------
-- Verifica disponibilidad de todos los ítems del carrito.
-- Formato JSON: [{"id_producto": N, "cantidad": N}, ...]
--
-- Códigos de salida:
--   0 = stock OK para todos los ítems
--   1 = algún producto no existe o está inactivo
--   2 = stock insuficiente para algún producto
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_validar_stock $$

CREATE PROCEDURE sp_validar_stock(
    IN  p_carrito  JSON,
    OUT p_codigo   INT,
    OUT p_mensaje  VARCHAR(500)
)
BEGIN
    DECLARE v_n        INT DEFAULT 0;
    DECLARE v_i        INT DEFAULT 0;
    DECLARE v_id_prod  INT;
    DECLARE v_cantidad INT;
    DECLARE v_stock    INT;
    DECLARE v_nombre   VARCHAR(150);

    SET p_codigo  = 0;
    SET p_mensaje = 'Stock verificado: disponibilidad suficiente en todos los productos.';
    SET v_n       = JSON_LENGTH(p_carrito);

    WHILE v_i < v_n DO
        SET v_id_prod  = JSON_UNQUOTE(JSON_EXTRACT(p_carrito,
                           CONCAT('$[', v_i, '].id_producto')));
        SET v_cantidad = JSON_UNQUOTE(JSON_EXTRACT(p_carrito,
                           CONCAT('$[', v_i, '].cantidad')));

        -- Verificar existencia del producto
        SELECT nombre, stock
        INTO   v_nombre, v_stock
        FROM   Productos
        WHERE  id_producto = v_id_prod AND activo = TRUE
        LIMIT  1;

        IF v_nombre IS NULL THEN
            SET p_codigo  = 1;
            SET p_mensaje = CONCAT('Producto id=', v_id_prod,
                                   ' no existe o no está activo.');
            LEAVE sp_validar_stock;
        END IF;

        -- Verificar stock suficiente
        IF v_stock < v_cantidad THEN
            SET p_codigo  = 2;
            SET p_mensaje = CONCAT('Stock insuficiente para "', v_nombre,
                                   '": solicitado=', v_cantidad,
                                   ', disponible=', v_stock, '.');
            LEAVE sp_validar_stock;
        END IF;

        SET v_nombre   = NULL;
        SET v_stock    = NULL;
        SET v_i        = v_i + 1;
    END WHILE;

END $$


-- ------------------------------------------------------------
-- sp_registrar_venta
-- ------------------------------------------------------------
-- Registra una venta completa de forma atómica:
--   1. Valida cliente, usuario y carrito
--   2. Verifica stock (llama a sp_validar_stock)
--   3. Calcula descuento y total (usa las funciones escalares)
--   4. Inserta en Ventas y DetalleVentas
--   5. Descuenta stock en Productos
--   6. COMMIT si todo OK, ROLLBACK ante cualquier error
--
-- Códigos de salida:
--   0  = éxito
--   1  = carrito vacío
--   2  = cliente no encontrado
--   3  = usuario no encontrado o inactivo
--   4  = error de stock (propaga código de sp_validar_stock)
--   99 = error inesperado de base de datos
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_registrar_venta $$

CREATE PROCEDURE sp_registrar_venta(
    IN  p_id_cliente  INT,
    IN  p_id_usuario  INT,
    IN  p_carrito     JSON,
    IN  p_observacion TEXT,
    OUT p_id_venta    INT,
    OUT p_total       DECIMAL(12,2),
    OUT p_descuento   DECIMAL(5,2),
    OUT p_codigo      INT,
    OUT p_mensaje     VARCHAR(500)
)
BEGIN
    DECLARE v_monto_bruto DECIMAL(12,2) DEFAULT 0.00;
    DECLARE v_n           INT           DEFAULT 0;
    DECLARE v_i           INT           DEFAULT 0;
    DECLARE v_id_prod     INT;
    DECLARE v_cantidad    INT;
    DECLARE v_precio_unit DECIMAL(10,2);
    DECLARE v_total_items INT           DEFAULT 0;
    DECLARE v_stock_cod   INT;
    DECLARE v_stock_msg   VARCHAR(500);
    DECLARE v_existe_cli  INT           DEFAULT 0;
    DECLARE v_existe_usr  INT           DEFAULT 0;

    -- Handler genérico: ante cualquier error SQL → ROLLBACK
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_id_venta  = 0;
        SET p_total     = 0.00;
        SET p_descuento = 0.00;
        SET p_codigo    = 99;
        SET p_mensaje   = 'Error inesperado de base de datos. Transacción revertida.';
    END;

    -- Inicializar salidas
    SET p_id_venta  = 0;
    SET p_total     = 0.00;
    SET p_descuento = 0.00;
    SET p_codigo    = 0;
    SET p_mensaje   = '';
    SET v_n         = JSON_LENGTH(p_carrito);


    -- 1. Carrito no vacío
    IF v_n IS NULL OR v_n = 0 THEN
        SET p_codigo  = 1;
        SET p_mensaje = 'El carrito está vacío. Debe incluir al menos un producto.';
        LEAVE sp_registrar_venta;
    END IF;

    -- 2. Cliente existe
    SELECT COUNT(*) INTO v_existe_cli
    FROM Clientes WHERE id_cliente = p_id_cliente;

    IF v_existe_cli = 0 THEN
        SET p_codigo  = 2;
        SET p_mensaje = CONCAT('Cliente id=', p_id_cliente, ' no encontrado.');
        LEAVE sp_registrar_venta;
    END IF;

    -- 3. Usuario existe y está activo
    SELECT COUNT(*) INTO v_existe_usr
    FROM Usuarios
    WHERE id_usuario = p_id_usuario AND activo = TRUE;

    IF v_existe_usr = 0 THEN
        SET p_codigo  = 3;
        SET p_mensaje = CONCAT('Usuario id=', p_id_usuario,
                               ' no encontrado o inactivo.');
        LEAVE sp_registrar_venta;
    END IF;

    -- 4. Validar stock de todos los ítems
    CALL sp_validar_stock(p_carrito, v_stock_cod, v_stock_msg);

    IF v_stock_cod <> 0 THEN
        SET p_codigo  = 4;
        SET p_mensaje = v_stock_msg;
        LEAVE sp_registrar_venta;
    END IF;

    -- 5. Calcular monto bruto acumulando precio × cantidad
    SET v_i = 0;
    WHILE v_i < v_n DO
        SET v_id_prod  = JSON_UNQUOTE(JSON_EXTRACT(p_carrito,
                           CONCAT('$[', v_i, '].id_producto')));
        SET v_cantidad = JSON_UNQUOTE(JSON_EXTRACT(p_carrito,
                           CONCAT('$[', v_i, '].cantidad')));

        SELECT precio INTO v_precio_unit
        FROM   Productos WHERE id_producto = v_id_prod;

        SET v_monto_bruto = v_monto_bruto + (v_precio_unit * v_cantidad);
        SET v_total_items = v_total_items + v_cantidad;
        SET v_i           = v_i + 1;
    END WHILE;

    -- 6. Aplicar descuento y calcular total neto
    SET p_descuento = fn_calcular_descuento(v_monto_bruto, v_total_items, p_id_cliente);
    SET p_total     = fn_calcular_total_venta(v_monto_bruto, p_descuento);

    -- ════════════════════════════════════════════
    -- TRANSACCIÓN
    -- ════════════════════════════════════════════
    START TRANSACTION;

        -- a) Cabecera de la venta
        INSERT INTO Ventas
               (id_cliente, id_usuario, fecha_venta,
                total, estado, observaciones)
        VALUES (p_id_cliente, p_id_usuario, NOW(),
                p_total, 'confirmada', p_observacion);

        SET p_id_venta = LAST_INSERT_ID();

        -- b) Líneas de detalle y descuento de stock
        SET v_i = 0;
        WHILE v_i < v_n DO
            SET v_id_prod  = JSON_UNQUOTE(JSON_EXTRACT(p_carrito,
                               CONCAT('$[', v_i, '].id_producto')));
            SET v_cantidad = JSON_UNQUOTE(JSON_EXTRACT(p_carrito,
                               CONCAT('$[', v_i, '].cantidad')));

            SELECT precio INTO v_precio_unit
            FROM   Productos WHERE id_producto = v_id_prod;

            INSERT INTO DetalleVentas
                   (id_venta, id_producto, cantidad, precio_unitario)
            VALUES (p_id_venta, v_id_prod, v_cantidad, v_precio_unit);

            UPDATE Productos
            SET    stock = stock - v_cantidad
            WHERE  id_producto = v_id_prod;

            SET v_i = v_i + 1;
        END WHILE;

    COMMIT;

    SET p_codigo  = 0;
    SET p_mensaje = CONCAT(
        'Venta registrada correctamente. ',
        'ID=', p_id_venta,
        ' | Bruto=$', FORMAT(v_monto_bruto, 2),
        ' | Descuento=', p_descuento, '%',
        ' | Total neto=$', FORMAT(p_total, 2)
    );

END $$


-- ------------------------------------------------------------
-- sp_cancelar_venta
-- ------------------------------------------------------------
-- Cancela una venta y restaura el stock de sus productos.
-- Solo permite cancelar ventas en estado 'pendiente'
-- o 'confirmada'. Las ventas entregadas no se pueden cancelar.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_cancelar_venta $$

CREATE PROCEDURE sp_cancelar_venta(
    IN  p_id_venta INT,
    IN  p_motivo   VARCHAR(255),
    OUT p_codigo   INT,
    OUT p_mensaje  VARCHAR(500)
)
BEGIN
    DECLARE v_estado VARCHAR(20);
    DECLARE v_existe INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_codigo  = 99;
        SET p_mensaje = 'Error inesperado. Cancelación revertida.';
    END;

    SET p_codigo  = 0;
    SET p_mensaje = '';

    -- Verificar existencia
    SELECT COUNT(*), MAX(estado)
    INTO   v_existe, v_estado
    FROM   Ventas WHERE id_venta = p_id_venta;

    IF v_existe = 0 THEN
        SET p_codigo  = 1;
        SET p_mensaje = CONCAT('Venta id=', p_id_venta, ' no encontrada.');
        LEAVE sp_cancelar_venta;
    END IF;

    -- Solo se cancelan ventas pendientes o confirmadas
    IF v_estado NOT IN ('pendiente', 'confirmada') THEN
        SET p_codigo  = 2;
        SET p_mensaje = CONCAT('La venta id=', p_id_venta,
                               ' tiene estado "', v_estado,
                               '" y no puede cancelarse.');
        LEAVE sp_cancelar_venta;
    END IF;

    START TRANSACTION;

        -- Restaurar stock de cada ítem
        UPDATE Productos p
        JOIN   DetalleVentas dv ON p.id_producto = dv.id_producto
        SET    p.stock = p.stock + dv.cantidad
        WHERE  dv.id_venta = p_id_venta;

        -- Marcar venta como cancelada
        UPDATE Ventas
        SET    estado        = 'cancelada',
               observaciones = CONCAT(
                   IFNULL(observaciones, ''),
                   ' | CANCELADA: ', IFNULL(p_motivo, 'sin motivo'),
                   ' (', NOW(), ')'
               )
        WHERE  id_venta = p_id_venta;

    COMMIT;

    SET p_codigo  = 0;
    SET p_mensaje = CONCAT('Venta id=', p_id_venta,
                           ' cancelada correctamente. Stock restaurado.');
END $$

DELIMITER ;


-- ── TEST A: tabla de descuentos por escenario ─────────────────
SELECT
    'Monto bajo, sin bonos'                AS escenario,
    fn_calcular_descuento(30000, 2, 1)    AS descuento_pct,
    fn_calcular_total_venta(30000,
        fn_calcular_descuento(30000,2,1)) AS total_neto
UNION ALL SELECT
    'Monto 50k (5% base)',
    fn_calcular_descuento(50000, 2, 1),
    fn_calcular_total_venta(50000, fn_calcular_descuento(50000,2,1))
UNION ALL SELECT
    'Monto 100k + 6 ítems (10%+3%)',
    fn_calcular_descuento(100000, 6, 2),
    fn_calcular_total_venta(100000, fn_calcular_descuento(100000,6,2))
UNION ALL SELECT
    'Monto 200k + 8 ítems + cliente fiel (techo 30%)',
    fn_calcular_descuento(200000, 8, 1),
    fn_calcular_total_venta(200000, fn_calcular_descuento(200000,8,1));


-- ── TEST B: venta exitosa ─────────────────────────────────────
CALL sp_registrar_venta(
    3,    -- Sofía López
    2,    -- vendedor1
    '[{"id_producto":3,"cantidad":1},{"id_producto":9,"cantidad":2}]',
    'Compra online – auriculares y lámparas',
    @id_venta, @total, @desc, @cod, @msg
);
SELECT @cod AS codigo, @id_venta AS id_venta,
       @desc AS descuento_pct, @total AS total_final,
       @msg AS mensaje;


-- ── TEST C: stock insuficiente ────────────────────────────────
CALL sp_registrar_venta(
    4, 2,
    '[{"id_producto":2,"cantidad":999}]',
    'Prueba stock insuficiente',
    @id_venta, @total, @desc, @cod, @msg
);
SELECT @cod AS codigo, @msg AS mensaje;


-- ── TEST D: cliente inexistente ───────────────────────────────
CALL sp_registrar_venta(
    9999, 2,
    '[{"id_producto":1,"cantidad":1}]',
    'Prueba cliente inválido',
    @id_venta, @total, @desc, @cod, @msg
);
SELECT @cod AS codigo, @msg AS mensaje;


-- ── TEST E: carrito vacío ─────────────────────────────────────
CALL sp_registrar_venta(
    1, 2, '[]', 'Prueba carrito vacío',
    @id_venta, @total, @desc, @cod, @msg
);
SELECT @cod AS codigo, @msg AS mensaje;


-- ── TEST F: cancelar venta válida ─────────────────────────────
-- (Venta 7 tiene estado 'pendiente')
CALL sp_cancelar_venta(7, 'Cliente solicitó cancelación por teléfono', @cod, @msg);
SELECT @cod AS codigo, @msg AS mensaje;

-- Verificar que el stock fue restaurado
SELECT id_producto, nombre, stock
FROM   Productos
WHERE  id_producto IN (
    SELECT id_producto FROM DetalleVentas WHERE id_venta = 7
);


-- ── TEST G: cancelar venta ya entregada (debe fallar) ─────────
CALL sp_cancelar_venta(1, 'Intento inválido sobre venta entregada', @cod, @msg);
SELECT @cod AS codigo, @msg AS mensaje;


-- ── Verificación final de todas las ventas ────────────────────
SELECT
    v.id_venta,
    v.fecha_venta,
    v.estado,
    CONCAT(c.nombre,' ',c.apellido) AS cliente,
    u.username                       AS vendedor,
    v.total
FROM  Ventas    v
JOIN  Clientes  c ON v.id_cliente = c.id_cliente
JOIN  Usuarios  u ON v.id_usuario = u.id_usuario
ORDER BY v.id_venta;
