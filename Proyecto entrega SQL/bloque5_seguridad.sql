USE ventas_oltp;

DROP ROLE IF EXISTS rol_administrador, rol_vendedor, rol_auditor;
CREATE ROLE rol_administrador, rol_vendedor, rol_auditor;

-- ------------------------------------------------------------
-- 2.1 rol_administrador
-- ------------------------------------------------------------
-- Control total sobre el esquema de la aplicación: puede crear/
-- alterar tablas, gestionar datos y administrar a los demás
-- usuarios de la base. Es el único rol con privilegios de DDL.
-- ------------------------------------------------------------
GRANT ALL PRIVILEGES ON ventas_oltp.* TO rol_administrador;

-- ------------------------------------------------------------
-- 2.2 rol_vendedor
-- ------------------------------------------------------------
GRANT SELECT                ON ventas_oltp.Productos        TO rol_vendedor;
GRANT SELECT                ON ventas_oltp.Categorias       TO rol_vendedor;
GRANT SELECT, INSERT        ON ventas_oltp.Clientes         TO rol_vendedor;
GRANT SELECT, INSERT        ON ventas_oltp.Ventas           TO rol_vendedor;
GRANT SELECT, INSERT        ON ventas_oltp.DetalleVentas    TO rol_vendedor;

GRANT EXECUTE ON PROCEDURE  ventas_oltp.sp_registrar_venta  TO rol_vendedor;
GRANT EXECUTE ON PROCEDURE  ventas_oltp.sp_validar_stock    TO rol_vendedor;
GRANT EXECUTE ON PROCEDURE  ventas_oltp.sp_cancelar_venta   TO rol_vendedor;
GRANT EXECUTE ON FUNCTION   ventas_oltp.fn_calcular_descuento     TO rol_vendedor;
GRANT EXECUTE ON FUNCTION   ventas_oltp.fn_calcular_total_venta   TO rol_vendedor;

-- ------------------------------------------------------------
-- 2.3 rol_auditor
-- ------------------------------------------------------------
GRANT SELECT ON ventas_oltp.*  TO rol_auditor;

-- Privilegio a nivel de COLUMNA: el auditor puede ver quién es
-- cada usuario y su rol/actividad, pero nunca el hash de password.
REVOKE SELECT ON ventas_oltp.Usuarios FROM rol_auditor;
GRANT SELECT (id_usuario, username, rol, activo, ultimo_login)
      ON ventas_oltp.Usuarios TO rol_auditor;

-- Refuerzo explícito: el auditor no debe poder ejecutar
-- procedimientos que escriben datos (defensa en profundidad,
-- aunque ya no los tenga otorgados).
REVOKE EXECUTE ON PROCEDURE ventas_oltp.sp_registrar_venta FROM rol_auditor;
REVOKE EXECUTE ON PROCEDURE ventas_oltp.sp_cancelar_venta  FROM rol_auditor;

DROP USER IF EXISTS 'db_admin'@'localhost',
                     'db_vendedor'@'localhost',
                     'db_auditor'@'localhost';

CREATE USER 'db_admin'@'localhost'    IDENTIFIED BY 'Adm1n_2026!';
CREATE USER 'db_vendedor'@'localhost' IDENTIFIED BY 'Vend_2026!';
CREATE USER 'db_auditor'@'localhost'  IDENTIFIED BY 'Audi_2026!';

GRANT rol_administrador TO 'db_admin'@'localhost';
GRANT rol_vendedor      TO 'db_vendedor'@'localhost';
GRANT rol_auditor       TO 'db_auditor'@'localhost';

SET DEFAULT ROLE rol_administrador TO 'db_admin'@'localhost';
SET DEFAULT ROLE rol_vendedor      TO 'db_vendedor'@'localhost';
SET DEFAULT ROLE rol_auditor       TO 'db_auditor'@'localhost';

FLUSH PRIVILEGES;

GRANT  UPDATE ON ventas_oltp.Productos TO rol_vendedor;   -- (1) error detectado
REVOKE UPDATE ON ventas_oltp.Productos FROM rol_vendedor; -- (2) corregido

-- Verificación: confirma que rol_vendedor quedó sin UPDATE
SHOW GRANTS FOR rol_vendedor;

DELIMITER $$

DROP TRIGGER IF EXISTS trg_deny_delete_ventas $$

CREATE TRIGGER trg_deny_delete_ventas
BEFORE DELETE ON Ventas
FOR EACH ROW
BEGIN
    IF CURRENT_USER() <> 'db_admin@localhost' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Operación denegada: las ventas no se eliminan, '
                            'use sp_cancelar_venta() para cancelarlas.';
    END IF;
END $$

DELIMITER $$

DROP TRIGGER IF EXISTS trg_deny_delete_producto_con_ventas $$

CREATE TRIGGER trg_deny_delete_producto_con_ventas
BEFORE DELETE ON Productos
FOR EACH ROW
BEGIN
    DECLARE v_tiene_ventas INT DEFAULT 0;

    SELECT COUNT(*) INTO v_tiene_ventas
    FROM DetalleVentas
    WHERE id_producto = OLD.id_producto;

    IF v_tiene_ventas > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Operación denegada: el producto tiene ventas '
                            'asociadas. Desactívelo (activo=FALSE) en lugar '
                            'de eliminarlo.';
    END IF;
END $$

DELIMITER ;

-- ── 6.1 Como db_admin: control total (debe funcionar todo) ────
SELECT CURRENT_USER(), CURRENT_ROLE();
SHOW GRANTS FOR CURRENT_USER();
SELECT * FROM Usuarios;                         -- OK, ve todo
UPDATE Productos SET descripcion = descripcion WHERE id_producto = 1; -- OK (ejemplo no-op, solo para probar permiso)

-- ── 6.2 Como db_vendedor: acceso operativo, sin DDL ni datos
SELECT CURRENT_USER(), CURRENT_ROLE();

-- Permitido: operar el flujo de ventas
CALL sp_registrar_venta(
    1, 2, '[{"id_producto":4,"cantidad":1}]',
    'Prueba de acceso – db_vendedor',
    @id_venta, @total, @desc, @cod, @msg
);
SELECT @cod, @msg;

UPDATE Productos SET precio = 99999 WHERE id_producto = 1;

SELECT password_hash FROM Usuarios;

DELETE FROM Ventas WHERE id_venta = 1;

-- ── 6.3 Como db_auditor: solo lectura, ni siquiera vía
SELECT CURRENT_USER(), CURRENT_ROLE();
SELECT * FROM auditoria_ventas ORDER BY fecha_evento DESC LIMIT 10;
SELECT * FROM historial_precios_productos ORDER BY fecha_cambio DESC LIMIT 10;
SELECT id_usuario, username, rol, activo, ultimo_login FROM Usuarios;
SELECT * FROM Usuarios;
INSERT INTO Clientes (nombre, apellido, email)
VALUES ('Test', 'Auditor', 'test.auditor@email.com');

CALL sp_registrar_venta(1, 2, '[{"id_producto":1,"cantidad":1}]',
                         'intento auditor', @v, @t, @d, @c, @m);



-- ============================================================
-- SECCIÓN 7: PRINCIPIO DE MÍNIMO PRIVILEGIO — EXPLICACIÓN
-- ============================================================
-- El principio de mínimo privilegio dice que cada cuenta debe
-- tener ÚNICAMENTE los permisos estrictamente necesarios para
-- cumplir su función, ni uno más, durante el tiempo mínimo
-- necesario. Cómo se aplicó concretamente en este bloque:
--
-- • rol_vendedor puede INSERTAR ventas pero no puede UPDATE/
--   DELETE sobre Productos: el precio y el stock se gestionan
--   exclusivamente a través de sp_registrar_venta y sp_cancelar_venta,
--   que ya tienen sus propias validaciones (Bloque 3). Si se le
--   diera UPDATE directo, alguien podría poner un precio o stock
--   arbitrario saltándose esa lógica de negocio.
--
-- • rol_vendedor no tiene SELECT sobre Usuarios: no necesita ver
--   esa tabla para vender, y esa tabla contiene password_hash —
--   exponerla sería un riesgo sin ningún beneficio operativo.
--
-- • rol_auditor tiene SELECT casi total (necesita ver todo para
--   controlar), pero ni una sola operación de escritura: auditar
--   es por definición una función de solo lectura; darle INSERT/
--   UPDATE/DELETE rompería la separación de funciones (quien
--   controla no debería poder alterar lo que controla).
--
-- • El privilegio a nivel de COLUMNA en Usuarios (Sección 2.3)
--   es mínimo privilegio llevado al extremo: el auditor necesita
--   "quién hizo qué" (username, rol, ultimo_login) pero jamás
--   necesita ver el hash de la contraseña de nadie.
--
-- • Los triggers "deny" de la Sección 5 son una capa adicional
--   de mínimo privilegio que no depende de roles: aunque alguien
--   tenga DELETE por error (como en el escenario de la Sección 4
--   antes de corregirlo), la operación sigue bloqueada porque la
--   regla de negocio "las ventas no se borran" está en el motor,
--   no en la confianza de que nadie tenga ese privilegio.
--
-- • rol_administrador SÍ tiene privilegio total, pero es una
--   cuenta separada de las operativas — se usa solo para tareas
--   de administración, no para el uso diario de un vendedor o
--   auditor. Minimizar también significa minimizar CUÁNTAS
--   cuentas tienen privilegio alto, no solo qué puede hacer cada
--   una.
-- ============================================================
