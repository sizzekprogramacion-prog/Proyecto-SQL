USE ventas_oltp;

DROP TABLE IF EXISTS audit_configuracion;
CREATE TABLE audit_configuracion (
    id_config      INT NOT NULL AUTO_INCREMENT,
    nombre_audit   VARCHAR(100) NOT NULL,
    accion         VARCHAR(50)  NOT NULL,
    tabla_destino  VARCHAR(100) NOT NULL, 
    activo         BOOLEAN NOT NULL DEFAULT TRUE,
    fecha_creacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    creado_por     VARCHAR(100) NOT NULL DEFAULT (CURRENT_USER()),
    descripcion    TEXT NULL,

    CONSTRAINT pk_audit_config PRIMARY KEY (id_config)
);

INSERT INTO audit_configuracion
       (nombre_audit,        accion,         tabla_destino,           descripcion)
VALUES
('ventas_oltp_audit', 'DELETE',         'audit_delete_ventas',
 'Registra cada intento de DELETE en la tabla Ventas'),
('ventas_oltp_audit', 'GRANT_REVOKE',   'audit_permisos',
 'Registra GRANTs y REVOKEs ejecutados por administradores'),
('ventas_oltp_audit', 'FAILED_LOGIN',   'audit_login_fallidos',
 'Registra intentos de conexión fallidos al servidor MySQL');


-- ------------------------------------------------------------
-- 1.2 audit_delete_ventas
-- ------------------------------------------------------------
DROP TABLE IF EXISTS audit_delete_ventas;
CREATE TABLE audit_delete_ventas (
    id_evento        INT NOT NULL AUTO_INCREMENT,
    id_venta         INT          NULL,
    id_cliente_ref   INT          NULL,
    id_usuario_ref   INT          NULL,
    total_ref        DECIMAL(12,2) NULL,
    estado_ref       VARCHAR(20)  NULL,
    usuario_bd       VARCHAR(100) NOT NULL,
    host_origen      VARCHAR(100) NOT NULL,
    resultado        ENUM('EXITOSO','BLOQUEADO') NOT NULL DEFAULT 'EXITOSO',
    motivo_bloqueo   TEXT         NULL,
    fecha_evento     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    datos_eliminados JSON         NULL,

    CONSTRAINT pk_audit_delete_ventas PRIMARY KEY (id_evento)
);


-- ------------------------------------------------------------
-- 1.3 audit_permisos
-- ------------------------------------------------------------
DROP TABLE IF EXISTS audit_permisos;
CREATE TABLE audit_permisos (
    id_evento        INT NOT NULL AUTO_INCREMENT,
    accion           ENUM('GRANT','REVOKE') NOT NULL,
    privilegio       VARCHAR(200) NOT NULL,      -- ej. "SELECT ON ventas_oltp.Ventas"
    objeto           VARCHAR(200) NOT NULL,      -- tabla / procedimiento / columna
    beneficiario     VARCHAR(200) NOT NULL,      -- usuario o rol que recibe/pierde el permiso
    otorgado_por     VARCHAR(100) NOT NULL,      -- quien ejecutó el GRANT/REVOKE
    with_grant_option BOOLEAN NOT NULL DEFAULT FALSE,
    resultado        ENUM('EXITOSO','ERROR') NOT NULL DEFAULT 'EXITOSO',
    detalle_error    TEXT NULL,
    fecha_evento     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sentencia_sql    TEXT NULL,                  -- la sentencia completa ejecutada

    CONSTRAINT pk_audit_permisos PRIMARY KEY (id_evento)
);


-- ------------------------------------------------------------
-- 1.4 audit_login_fallidos
-- ------------------------------------------------------------
DROP TABLE IF EXISTS audit_login_fallidos;
CREATE TABLE audit_login_fallidos (
    id_evento        INT NOT NULL AUTO_INCREMENT,
    usuario_intento  VARCHAR(100) NOT NULL,       -- nombre de usuario que intentó conectar
    host_origen      VARCHAR(100) NOT NULL,       -- IP / hostname de origen
    intentos_cuenta  INT          NOT NULL DEFAULT 1, -- acumulado desde el último exitoso
    bloqueado        BOOLEAN      NOT NULL DEFAULT FALSE,
    descripcion      VARCHAR(255) NULL,
    fecha_evento     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_audit_login PRIMARY KEY (id_evento)
);
-- ---------------------------------------------------------
-- 2.1 trg_audit_delete_ventas_before
-- ------------------------------------------------------------
DELIMITER $$

DROP TRIGGER IF EXISTS trg_audit_delete_ventas_before $$

CREATE TRIGGER trg_audit_delete_ventas_before
BEFORE DELETE ON Ventas
FOR EACH ROW
BEGIN
    INSERT INTO audit_delete_ventas
           (id_venta, id_cliente_ref, id_usuario_ref, total_ref,
            estado_ref, usuario_bd, host_origen, resultado, datos_eliminados)
    VALUES (OLD.id_venta, OLD.id_cliente, OLD.id_usuario, OLD.total,
            OLD.estado, CURRENT_USER(), @@hostname,
            'EXITOSO',
            JSON_OBJECT(
                'id_venta',   OLD.id_venta,
                'id_cliente', OLD.id_cliente,
                'id_usuario', OLD.id_usuario,
                'total',      OLD.total,
                'estado',     OLD.estado,
                'fecha_venta',OLD.fecha_venta
            ));
END $$

DELIMITER ;


-- ------------------------------------------------------------
-- 2.2 trg_audit_delete_ventas_bloqueado
-- ------------------------------------------------------------
DROP TABLE IF EXISTS audit_delete_ventas_bloqueados;
CREATE TABLE audit_delete_ventas_bloqueados (
    id_evento       INT NOT NULL AUTO_INCREMENT,
    id_venta_ref    INT NULL,
    usuario_bd      VARCHAR(100) NOT NULL,
    host_origen     VARCHAR(100) NOT NULL,
    motivo          VARCHAR(500) NOT NULL,
    fecha_evento    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT pk_audit_delete_bloqueados PRIMARY KEY (id_evento)
);
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_registrar_delete_bloqueado $$

CREATE PROCEDURE sp_registrar_delete_bloqueado(
    IN p_id_venta INT,
    IN p_motivo   VARCHAR(500)
)
BEGIN
    INSERT INTO audit_delete_ventas_bloqueados
           (id_venta_ref, usuario_bd, host_origen, motivo)
    VALUES (p_id_venta, CURRENT_USER(), @@hostname, p_motivo);
END $$

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_grant_auditado $$

CREATE PROCEDURE sp_grant_auditado(
    IN  p_accion          ENUM('GRANT','REVOKE'),
    IN  p_privilegio      VARCHAR(200),
    IN  p_objeto          VARCHAR(200),
    IN  p_beneficiario    VARCHAR(200),
    IN  p_with_grant      BOOLEAN,
    OUT p_codigo          INT,
    OUT p_mensaje         VARCHAR(500)
)
sp_grant_auditado: BEGIN
    DECLARE v_sql       TEXT;
    DECLARE v_resultado ENUM('EXITOSO','ERROR') DEFAULT 'EXITOSO';
    DECLARE v_error     TEXT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET v_resultado = 'ERROR';
        GET DIAGNOSTICS CONDITION 1 v_error = MESSAGE_TEXT;
        INSERT INTO audit_permisos
               (accion, privilegio, objeto, beneficiario, otorgado_por,
                with_grant_option, resultado, detalle_error, sentencia_sql)
        VALUES (p_accion, p_privilegio, p_objeto, p_beneficiario,
                CURRENT_USER(), p_with_grant, 'ERROR', v_error, v_sql);
        SET p_codigo  = 1;
        SET p_mensaje = CONCAT('Error al ejecutar ', p_accion, ': ', v_error);
    END;

    SET p_codigo  = 0;
    SET p_mensaje = '';

    -- Construir sentencia dinámica
    IF p_accion = 'GRANT' THEN
        SET v_sql = CONCAT('GRANT ', p_privilegio,
                           ' ON ', p_objeto,
                           ' TO ', p_beneficiario,
                           IF(p_with_grant, ' WITH GRANT OPTION', ''));
    ELSE
        SET v_sql = CONCAT('REVOKE ', p_privilegio,
                           ' ON ', p_objeto,
                           ' FROM ', p_beneficiario);
    END IF;

    -- Ejecutar
    SET @__grant_sql = v_sql;
    PREPARE __stmt FROM @__grant_sql;
    EXECUTE __stmt;
    DEALLOCATE PREPARE __stmt;

    -- Registrar el evento exitoso
    INSERT INTO audit_permisos
           (accion, privilegio, objeto, beneficiario, otorgado_por,
            with_grant_option, resultado, sentencia_sql)
    VALUES (p_accion, p_privilegio, p_objeto, p_beneficiario,
            CURRENT_USER(), p_with_grant, 'EXITOSO', v_sql);

    SET p_mensaje = CONCAT(p_accion, ' ejecutado y auditado: ', v_sql);
END $$

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_fn_get_audit_file $$

CREATE PROCEDURE sp_fn_get_audit_file(
    IN p_accion   VARCHAR(20),   -- 'DELETE' | 'GRANT' | 'LOGIN_FALLIDO' | 'TODAS'
    IN p_desde    DATETIME,
    IN p_hasta    DATETIME,
    IN p_usuario  VARCHAR(100)
)
BEGIN
    -- Valores por defecto para fechas
    IF p_desde IS NULL THEN SET p_desde = '2000-01-01 00:00:00'; END IF;
    IF p_hasta IS NULL THEN SET p_hasta = NOW();                  END IF;

    -- ── DELETE en Ventas ────────────────────────────────────────
    IF p_accion IN ('DELETE', 'TODAS') THEN
        SELECT
            'DELETE_VENTAS'          AS categoria_evento,
            id_evento,
            fecha_evento,
            usuario_bd               AS principal_name,
            host_origen              AS client_host,
            resultado                AS succeeded,
            CONCAT('DELETE FROM Ventas WHERE id_venta = ', IFNULL(id_venta, '(masivo)'))
                                     AS statement,
            motivo_bloqueo           AS additional_info,
            datos_eliminados         AS row_data_json
        FROM  audit_delete_ventas
        WHERE fecha_evento BETWEEN p_desde AND p_hasta
          AND (p_usuario IS NULL OR usuario_bd LIKE CONCAT('%', p_usuario, '%'))

        UNION ALL

        SELECT
            'DELETE_VENTAS_BLOQUEADO',
            id_evento,
            fecha_evento,
            usuario_bd,
            host_origen,
            'BLOQUEADO',
            CONCAT('DELETE FROM Ventas WHERE id_venta = ',
                   IFNULL(id_venta_ref, '(masivo)')),
            motivo,
            NULL
        FROM  audit_delete_ventas_bloqueados
        WHERE fecha_evento BETWEEN p_desde AND p_hasta
          AND (p_usuario IS NULL OR usuario_bd LIKE CONCAT('%', p_usuario, '%'));
    END IF;

    -- ── GRANT / REVOKE ──────────────────────────────────────────
    IF p_accion IN ('GRANT', 'TODAS') THEN
        SELECT
            CONCAT('PERMISO_', accion)  AS categoria_evento,
            id_evento,
            fecha_evento,
            otorgado_por                AS principal_name,
            'localhost'                 AS client_host,
            resultado                   AS succeeded,
            sentencia_sql               AS statement,
            CONCAT('Beneficiario: ', beneficiario,
                   IF(with_grant_option, ' WITH GRANT OPTION', ''))
                                        AS additional_info,
            NULL                        AS row_data_json
        FROM  audit_permisos
        WHERE fecha_evento BETWEEN p_desde AND p_hasta
          AND (p_usuario IS NULL OR otorgado_por LIKE CONCAT('%', p_usuario, '%'));
    END IF;

    -- ── LOGIN FALLIDOS ──────────────────────────────────────────
    IF p_accion IN ('LOGIN_FALLIDO', 'TODAS') THEN
        SELECT
            'LOGIN_FALLIDO'          AS categoria_evento,
            id_evento,
            fecha_evento,
            usuario_intento          AS principal_name,
            host_origen              AS client_host,
            IF(bloqueado, 'BLOQUEADO', 'FALLIDO') AS succeeded,
            CONCAT('CONNECT AS ', usuario_intento) AS statement,
            CONCAT('Intento #', intentos_cuenta,
                   IF(bloqueado, ' – cuenta bloqueada', ''))
                                     AS additional_info,
            NULL                     AS row_data_json
        FROM  audit_login_fallidos
        WHERE fecha_evento BETWEEN p_desde AND p_hasta
          AND (p_usuario IS NULL OR usuario_intento LIKE CONCAT('%', p_usuario, '%'));
    END IF;
END $$

DELIMITER ;

CALL sp_registrar_delete_bloqueado(
    1,
    'Operación denegada: las ventas no se eliminan, use sp_cancelar_venta(). '
    || 'Usuario: ' || CURRENT_USER()
);

-- ── TEST B: Registrar un GRANT via procedimiento auditado ────
CALL sp_grant_auditado(
    'GRANT',
    'SELECT',
    'ventas_oltp.audit_delete_ventas',
    'db_auditor@localhost',
    FALSE,
    @cod, @msg
);
SELECT @cod AS codigo, @msg AS mensaje;

-- ── TEST C: Registrar un REVOKE via procedimiento auditado ───
CALL sp_grant_auditado(
    'REVOKE',
    'SELECT',
    'ventas_oltp.audit_delete_ventas',
    'db_auditor@localhost',
    FALSE,
    @cod, @msg
);
SELECT @cod AS codigo, @msg AS mensaje;

INSERT INTO audit_login_fallidos
       (usuario_intento, host_origen, intentos_cuenta, bloqueado, descripcion)
VALUES
('hacker_user',    '192.168.1.99', 1, FALSE, 'Contraseña incorrecta'),
('hacker_user',    '192.168.1.99', 2, FALSE, 'Contraseña incorrecta'),
('hacker_user',    '192.168.1.99', 3, TRUE,  'Cuenta bloqueada tras 3 intentos fallidos'),
('db_vendedor',    '10.0.0.5',     1, FALSE, 'Contraseña incorrecta – posible typo');

-- ── 6.1 Todos los eventos de auditoría ───────────────────────
CALL sp_fn_get_audit_file('TODAS', NULL, NULL, NULL);

-- ── 6.2 Solo DELETEs de Ventas (últimas 24 h) ────────────────
CALL sp_fn_get_audit_file('DELETE', DATE_SUB(NOW(), INTERVAL 24 HOUR), NULL, NULL);

-- ── 6.3 Solo GRANTs/REVOKEs ejecutados hoy ───────────────────
CALL sp_fn_get_audit_file('GRANT', CURDATE(), NULL, NULL);

-- ── 6.4 Solo login fallidos ───────────────────────────────────
CALL sp_fn_get_audit_file('LOGIN_FALLIDO', NULL, NULL, NULL);

-- ── 6.5 Actividad de un usuario específico ───────────────────
CALL sp_fn_get_audit_file('TODAS', NULL, NULL, 'hacker_user');

-- ── 6.6 Reporte consolidado de eventos por categoría ─────────
SELECT
    categoria,
    COUNT(*)             AS total_eventos,
    SUM(bloqueados)      AS bloqueados,
    MAX(ultimo_evento)   AS ultimo_evento
FROM (
    SELECT 'DELETE en Ventas' AS categoria,
           COUNT(*)           AS total,
           SUM(resultado = 'BLOQUEADO') AS bloqueados,
           MAX(fecha_evento)  AS ultimo_evento
    FROM   audit_delete_ventas
    UNION ALL
    SELECT 'DELETE Bloqueado',
           COUNT(*), COUNT(*), MAX(fecha_evento)
    FROM   audit_delete_ventas_bloqueados
    UNION ALL
    SELECT CONCAT('Permisos (', accion, ')'),
           COUNT(*), SUM(resultado = 'ERROR'), MAX(fecha_evento)
    FROM   audit_permisos
    GROUP BY accion
    UNION ALL
    SELECT 'Login Fallidos',
           COUNT(*), SUM(bloqueado), MAX(fecha_evento)
    FROM   audit_login_fallidos
) AS resumen(categoria, total_eventos, bloqueados, ultimo_evento)
GROUP BY categoria
ORDER BY categoria;


-- ============================================================
-- SECCIÓN 7: CONSULTAS DE REPORTE TÉCNICO
-- ============================================================

-- ── R1: Intentos de DELETE en Ventas (evidencia forense) ─────
SELECT
    dv.id_evento,
    dv.fecha_evento,
    dv.usuario_bd,
    dv.host_origen,
    dv.id_venta,
    dv.total_ref,
    dv.estado_ref,
    dv.resultado,
    dv.datos_eliminados
FROM  audit_delete_ventas dv
ORDER BY dv.fecha_evento DESC;

-- ── R2: Historial completo de cambios de privilegios ─────────
SELECT
    ap.id_evento,
    ap.fecha_evento,
    ap.accion,
    ap.privilegio,
    ap.objeto,
    ap.beneficiario,
    ap.otorgado_por,
    ap.with_grant_option,
    ap.resultado,
    ap.sentencia_sql
FROM  audit_permisos ap
ORDER BY ap.fecha_evento DESC;

-- ── R3: Usuarios con más intentos fallidos (top amenazas) ────
SELECT
    usuario_intento,
    host_origen,
    COUNT(*)         AS total_intentos,
    MAX(intentos_cuenta) AS max_intentos_seguidos,
    SUM(bloqueado)   AS veces_bloqueado,
    MIN(fecha_evento) AS primer_intento,
    MAX(fecha_evento) AS ultimo_intento
FROM  audit_login_fallidos
GROUP BY usuario_intento, host_origen
ORDER BY total_intentos DESC;

-- ── R4: Configuración activa de auditoría ────────────────────
SELECT
    nombre_audit,
    accion,
    tabla_destino,
    activo,
    fecha_creacion,
    creado_por,
    descripcion
FROM  audit_configuracion
ORDER BY accion;
