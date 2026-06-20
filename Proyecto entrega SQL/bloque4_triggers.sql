USE ventas_oltp;
-- ------------------------------------------------------------
-- auditoria_ventas
-- ------------------------------------------------------------
-- Bitácora de toda venta registrada en el sistema. Permite
-- responder "quién vendió qué, cuándo y por cuánto" sin tener
-- que confiar en que cada aplicación cliente lo loguee bien:
-- la queda registrada a nivel de motor, no de aplicación.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS auditoria_ventas;
CREATE TABLE auditoria_ventas (
    id_auditoria   INT NOT NULL AUTO_INCREMENT,
    id_venta       INT NOT NULL,
    id_cliente     INT NULL,
    id_usuario     INT NULL,
    total          DECIMAL(12,2) NULL,
    estado         VARCHAR(20) NULL,
    accion         VARCHAR(20) NOT NULL DEFAULT 'INSERT',
    usuario_bd     VARCHAR(100) NOT NULL,
    detalle        TEXT NULL,
    fecha_evento   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_auditoria_ventas PRIMARY KEY (id_auditoria)
);

-- ------------------------------------------------------------
-- historial_precios_productos
-- ------------------------------------------------------------
-- Guarda cada cambio de precio de un producto: precio anterior,
-- precio nuevo, diferencia absoluta y porcentual, y quién/cuándo
-- lo hizo. Útil para detectar errores de carga de precios y
-- para análisis de pricing histórico.
-- ------------------------------------------------------------
DROP TABLE IF EXISTS historial_precios_productos;
CREATE TABLE historial_precios_productos (
    id_historial       INT NOT NULL AUTO_INCREMENT,
    id_producto        INT NOT NULL,
    nombre_producto    VARCHAR(150) NOT NULL,
    precio_anterior    DECIMAL(10,2) NOT NULL,
    precio_nuevo       DECIMAL(10,2) NOT NULL,
    diferencia         DECIMAL(10,2) NOT NULL,
    porcentaje_cambio  DECIMAL(7,2) NULL,
    usuario_bd         VARCHAR(100) NOT NULL,
    fecha_cambio       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_historial_precios PRIMARY KEY (id_historial)
);


-- Por qué AFTER y no BEFORE:
--   Necesitamos el id_venta definitivo (AUTO_INCREMENT) para
--   poder referenciarlo en auditoria_ventas. Ese valor recién
--   existe una vez que la fila ya fue escrita, por eso el
--   trigger debe ser AFTER INSERT (con BEFORE, NEW.id_venta
--   todavía sería NULL o 0).
-- ============================================================
DELIMITER $$

DROP TRIGGER IF EXISTS trg_auditoria_venta_insert $$

CREATE TRIGGER trg_auditoria_venta_insert
AFTER INSERT ON Ventas
FOR EACH ROW
BEGIN
    INSERT INTO auditoria_ventas
           (id_venta, id_cliente, id_usuario, total, estado,
            accion, usuario_bd, detalle)
    VALUES (NEW.id_venta, NEW.id_cliente, NEW.id_usuario,
            NEW.total, NEW.estado,
            'INSERT', CURRENT_USER(),
            CONCAT('Venta #', NEW.id_venta,
                   ' registrada para cliente id=', NEW.id_cliente,
                   ' | usuario id=', NEW.id_usuario,
                   ' | total=$', FORMAT(NEW.total, 2),
                   ' | estado=', NEW.estado));
END $$

DELIMITER ;

-- Por qué AFTER y no BEFORE:
--   La auditoría es una consecuencia del cambio, no una condición
--   para permitirlo. No necesitamos (ni queremos) modificar NEW
--   antes de que se grabe — solo dejar constancia de que el cambio
--   ya ocurrió. Si usáramos BEFORE UPDATE, el registro de historial
--   quedaría escrito incluso si la actualización fallara después
--   por algún otro motivo (ej. otro trigger o constraint que
--   aborte la operación), generando un historial inconsistente
--   con lo que realmente pasó en Productos.
--
-- Solo registra el cambio si el precio realmente varió, evitando
-- ruido por UPDATEs que tocan otras columnas (stock, activo, etc).
-- ============================================================
DELIMITER $$

DROP TRIGGER IF EXISTS trg_historial_precio_producto $$

CREATE TRIGGER trg_historial_precio_producto
AFTER UPDATE ON Productos
FOR EACH ROW
BEGIN
    IF NEW.precio <> OLD.precio THEN
        INSERT INTO historial_precios_productos
               (id_producto, nombre_producto, precio_anterior,
                precio_nuevo, diferencia, porcentaje_cambio, usuario_bd)
        VALUES (
            NEW.id_producto,
            NEW.nombre,
            OLD.precio,
            NEW.precio,
            NEW.precio - OLD.precio,
            CASE WHEN OLD.precio = 0 THEN NULL
                 ELSE ROUND(((NEW.precio - OLD.precio) / OLD.precio) * 100, 2)
            END,
            CURRENT_USER()
        );
    END IF;
END $$

DELIMITER ;

-- ------------------------------------------------------------
-- 3.1 Vista compleja (solo lectura) – combina Ventas, Clientes,
--     Usuarios, DetalleVentas y Productos.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vista_pedidos_completos AS
SELECT
    v.id_venta,
    v.fecha_venta,
    v.estado,
    v.total                              AS total_venta,
    c.id_cliente,
    CONCAT(c.nombre, ' ', c.apellido)    AS cliente,
    u.id_usuario,
    u.username                            AS vendedor,
    dv.id_producto,
    p.nombre                              AS producto,
    dv.cantidad,
    dv.precio_unitario,
    (dv.cantidad * dv.precio_unitario)    AS subtotal_linea
FROM       Ventas         v
JOIN       Clientes       c  ON v.id_cliente  = c.id_cliente
JOIN       Usuarios       u  ON v.id_usuario  = u.id_usuario
JOIN       DetalleVentas  dv ON v.id_venta    = dv.id_venta
JOIN       Productos      p  ON dv.id_producto = p.id_producto;

-- Confirmación del comportamiento descripto arriba (se puede
-- ejecutar manualmente para verlo fallar):
-- INSERT INTO vista_pedidos_completos (id_cliente, id_usuario, ...)
-- VALUES (...);
-- → ERROR 1393: Can not modify more than one base table through a join view

-- ------------------------------------------------------------
-- 3.2 "Fachada de escritura" de la vista – equivalente funcional
--     al INSTEAD OF trigger. Internamente hace lo mismo que un
--     INSTEAD OF haría: valida, y reparte el INSERT en las
--     tablas reales dentro de una transacción.
-- ------------------------------------------------------------
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_insertar_pedido_via_vista $$

CREATE PROCEDURE sp_insertar_pedido_via_vista(
    IN  p_id_cliente      INT,
    IN  p_id_usuario      INT,
    IN  p_id_producto     INT,
    IN  p_cantidad        INT,
    OUT p_id_venta        INT,
    OUT p_codigo          INT,
    OUT p_mensaje         VARCHAR(500)
)
sp_insertar_pedido_via_vista: BEGIN
    DECLARE v_existe_cli  INT DEFAULT 0;
    DECLARE v_existe_usr  INT DEFAULT 0;
    DECLARE v_precio      DECIMAL(10,2);
    DECLARE v_stock       INT;
    DECLARE v_nombre      VARCHAR(150);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_id_venta = 0;
        SET p_codigo   = 99;
        SET p_mensaje  = 'Error inesperado de base de datos. Operación revertida.';
    END;

    SET p_id_venta = 0;
    SET p_codigo   = 0;
    SET p_mensaje  = '';

    -- Validaciones equivalentes a las que tendría el INSTEAD OF
    SELECT COUNT(*) INTO v_existe_cli FROM Clientes WHERE id_cliente = p_id_cliente;
    IF v_existe_cli = 0 THEN
        SET p_codigo = 1;
        SET p_mensaje = CONCAT('Cliente id=', p_id_cliente, ' no encontrado.');
        LEAVE sp_insertar_pedido_via_vista;
    END IF;

    SELECT COUNT(*) INTO v_existe_usr
    FROM Usuarios WHERE id_usuario = p_id_usuario AND activo = TRUE;
    IF v_existe_usr = 0 THEN
        SET p_codigo = 2;
        SET p_mensaje = CONCAT('Usuario id=', p_id_usuario, ' no encontrado o inactivo.');
        LEAVE sp_insertar_pedido_via_vista;
    END IF;

    SELECT nombre, precio, stock INTO v_nombre, v_precio, v_stock
    FROM Productos WHERE id_producto = p_id_producto AND activo = TRUE;
    IF v_nombre IS NULL THEN
        SET p_codigo = 3;
        SET p_mensaje = CONCAT('Producto id=', p_id_producto, ' no existe o no está activo.');
        LEAVE sp_insertar_pedido_via_vista;
    END IF;

    IF v_stock < p_cantidad THEN
        SET p_codigo = 4;
        SET p_mensaje = CONCAT('Stock insuficiente para "', v_nombre,
                               '": solicitado=', p_cantidad, ', disponible=', v_stock, '.');
        LEAVE sp_insertar_pedido_via_vista;
    END IF;

    START TRANSACTION;

        INSERT INTO Ventas (id_cliente, id_usuario, fecha_venta, total, estado, observaciones)
        VALUES (p_id_cliente, p_id_usuario, NOW(),
                v_precio * p_cantidad, 'confirmada',
                'Insertado vía sp_insertar_pedido_via_vista (fachada de vista_pedidos_completos)');

        SET p_id_venta = LAST_INSERT_ID();

        INSERT INTO DetalleVentas (id_venta, id_producto, cantidad, precio_unitario)
        VALUES (p_id_venta, p_id_producto, p_cantidad, v_precio);

        UPDATE Productos
        SET    stock = stock - p_cantidad
        WHERE  id_producto = p_id_producto;

    COMMIT;
    -- El trigger trg_auditoria_venta_insert (Sección 1) se dispara
    -- automáticamente acá, igual que si el INSERT viniera de
    -- sp_registrar_venta o de cualquier otro punto del sistema.

    SET p_codigo  = 0;
    SET p_mensaje = CONCAT('Pedido registrado vía vista_pedidos_completos. Venta id=', p_id_venta);
END $$

DELIMITER ;

-- ------------------------------------------------------------
-- 3.3 Caso comparativo: vista SIMPLE (una sola tabla base) que
--     SÍ es updatable de forma nativa en MySQL. Acá un trigger
--     normal sobre la tabla base ya alcanza para lograr el efecto
--     de "inserción controlada" buscado por un INSTEAD OF, porque
--     no hay ambigüedad de a qué tabla escribir.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW vista_productos_activos AS
SELECT id_producto, id_categoria, nombre, descripcion, precio, stock, activo
FROM   Productos
WHERE  activo = TRUE
WITH CHECK OPTION;

-- ============================================================
-- SECCIÓN 4: ¿POR QUÉ AFTER Y NO INSTEAD OF? — EXPLICACIÓN
-- ============================================================
-- 1) trg_auditoria_venta_insert (AFTER INSERT en Ventas)
--    Se eligió AFTER porque:
--      a) Necesita el id_venta ya generado por AUTO_INCREMENT.
--      b) Es un efecto secundario de auditoría: no debe poder
--         bloquear ni alterar la venta que se está insertando,
--         solo dejar constancia de que ocurrió. Un BEFORE
--         tendría sentido únicamente si quisiéramos VALIDAR o
--         modificar los datos antes de guardarlos (no es el caso).
--
-- 2) trg_historial_precio_producto (AFTER UPDATE en Productos)
--    Se eligió AFTER por la misma razón: el historial debe
--    reflejar cambios que efectivamente se aplicaron. Comparar
--    OLD.precio vs NEW.precio y decidir si vale la pena guardar
--    el registro es lógica que no necesita ejecutarse "antes" de
--    nada — corre después de que la fila ya fue actualizada.
--
-- 3) Vista compleja → INSTEAD OF
--    MySQL no ofrece INSTEAD OF triggers; solo PostgreSQL,
--    SQL Server y Oracle lo soportan. La razón de fondo de por
--    qué existiría un INSTEAD OF en esos motores es la misma que
--    motiva el "Workaround" de la Sección 3: una vista que junta
--    varias tablas (Ventas + Clientes + Usuarios + DetalleVentas
--    + Productos) no tiene una correspondencia 1:1 con una sola
--    tabla destino, así que el motor no puede inferir solo dónde
--    debería ir cada columna del INSERT. Un INSTEAD OF (o, en
--    MySQL, el procedimiento sp_insertar_pedido_via_vista que lo
--    reemplaza) resuelve esa ambigüedad de forma explícita,
--    repartiendo manualmente el INSERT entre Ventas y
--    DetalleVentas dentro de una transacción.
-- ============================================================

CALL sp_registrar_venta(
    1, 2,
    '[{"id_producto":4,"cantidad":2}]',
    'Prueba Bloque 4 – disparo de trigger de auditoría',
    @id_venta, @total, @desc, @cod, @msg
);
SELECT @cod AS codigo, @id_venta AS id_venta, @msg AS mensaje;

SELECT * FROM auditoria_ventas
WHERE  id_venta = @id_venta;


-- ── TEST B: UPDATE de precio dispara historial ────────────────
UPDATE Productos
SET    precio = precio * 1.10           -- aumento de 10%
WHERE  id_producto = 1;

SELECT * FROM historial_precios_productos
WHERE  id_producto = 1
ORDER BY fecha_cambio DESC
LIMIT  1;

-- ── TEST B2: UPDATE que NO toca el precio → no debe insertar ──
UPDATE Productos
SET    stock = stock - 1
WHERE  id_producto = 2;

SELECT COUNT(*) AS filas_historial_producto_2
FROM   historial_precios_productos
WHERE  id_producto = 2;
-- esperado: 0 (el stock cambió, el precio no)


-- ── TEST C: INSERT directo sobre la vista compleja → debe fallar
-- (descomentar para verificar el error 1393 manualmente)
-- INSERT INTO vista_pedidos_completos
--        (id_cliente, id_usuario, id_producto, cantidad, precio_unitario)
-- VALUES (1, 2, 3, 1, 8900.00);


-- ── TEST D: inserción controlada vía procedimiento (equivalente
--    funcional al INSTEAD OF) ───────────────────────────────────
CALL sp_insertar_pedido_via_vista(
    2,      -- id_cliente
    2,      -- id_usuario
    3,      -- id_producto
    1,      -- cantidad
    @id_venta2, @cod2, @msg2
);
SELECT @cod2 AS codigo, @id_venta2 AS id_venta, @msg2 AS mensaje;

-- Verificar que también quedó auditado automáticamente (Sección 1)
SELECT * FROM auditoria_ventas WHERE id_venta = @id_venta2;

-- Verificar el pedido desde la vista de lectura
SELECT * FROM vista_pedidos_completos WHERE id_venta = @id_venta2;


-- ── TEST E: INSERT vía vista simple (updatable nativa) ─────────
INSERT INTO vista_productos_activos
       (id_categoria, nombre, descripcion, precio, stock, activo)
VALUES (1, 'Webcam Full HD', 'Webcam 1080p con micrófono', 12500.00, 35, TRUE);

SELECT * FROM Productos ORDER BY id_producto DESC LIMIT 1;
