USE ventas_oltp;


SHOW VARIABLES LIKE 'secure_file_priv';

SHOW VARIABLES LIKE 'log_bin';

DROP TABLE IF EXISTS backup_log;
CREATE TABLE backup_log (
    id_backup       INT NOT NULL AUTO_INCREMENT,
    tipo            ENUM('FULL','DIFERENCIAL','LOG_TRANSACCIONES') NOT NULL,
    tabla_afectada  VARCHAR(100) NULL,        -- NULL para LOG_TRANSACCIONES
    archivo         VARCHAR(255) NULL,
    binlog_file     VARCHAR(100) NULL,        -- solo para LOG_TRANSACCIONES
    binlog_position INT NULL,                 -- solo para LOG_TRANSACCIONES
    filas_respaldadas INT NULL,
    fecha_inicio    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    observacion     TEXT NULL,

    CONSTRAINT pk_backup_log PRIMARY KEY (id_backup)
);

ALTER TABLE Productos
    ADD COLUMN fecha_modificacion DATETIME
        NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP;

ALTER TABLE Clientes
    ADD COLUMN  fecha_modificacion DATETIME
        NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP;

SELECT *
FROM   Productos
INTO OUTFILE '<SECURE_FILE_PRIV>ventas_oltp_productos_FULL.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n';

INSERT INTO backup_log (tipo, tabla_afectada, archivo, filas_respaldadas)
SELECT 'FULL', 'Productos', 'ventas_oltp_productos_FULL.csv', COUNT(*)
FROM   Productos;

SELECT *
FROM   Clientes
INTO OUTFILE '<SECURE_FILE_PRIV>ventas_oltp_clientes_FULL.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n';

INSERT INTO backup_log (tipo, tabla_afectada, archivo, filas_respaldadas)
SELECT 'FULL', 'Clientes', 'ventas_oltp_clientes_FULL.csv', COUNT(*)
FROM   Clientes;

SELECT * FROM backup_log WHERE tipo = 'FULL';

INSERT INTO Productos (id_categoria, nombre, precio, stock, activo)
VALUES (1, 'Producto demo backup', 9999.00, 10, 1);

SELECT p.*
FROM   Productos p
WHERE  p.fecha_modificacion > (
           SELECT MAX(fecha_inicio)
           FROM   backup_log
           WHERE  tipo = 'FULL' AND tabla_afectada = 'Productos'
       )
INTO OUTFILE '<SECURE_FILE_PRIV>ventas_oltp_productos_DIFF_01.csv'
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n';

INSERT INTO backup_log (tipo, tabla_afectada, archivo, filas_respaldadas)
SELECT 'DIFERENCIAL', 'Productos', 'ventas_oltp_productos_DIFF_01.csv', COUNT(*)
FROM   Productos
WHERE  fecha_modificacion > (
           SELECT MAX(fecha_inicio)
           FROM   backup_log
           WHERE  tipo = 'FULL' AND tabla_afectada = 'Productos'
       );

SELECT * FROM backup_log WHERE tipo = 'DIFERENCIAL';

FLUSH BINARY LOGS;

SHOW BINARY LOGS;

SHOW MASTER STATUS;

INSERT INTO backup_log (tipo, binlog_file, binlog_position, observacion)
SELECT 'LOG_TRANSACCIONES',
       File_,                    
       Position_,
       'Cierre de binlog tras alta de Producto demo backup (T1)'
FROM (SELECT 'mysql-bin.000001' AS File_, 0 AS Position_) AS reemplazar_con_valores_reales;

SELECT COUNT(*) AS filas_antes_del_incidente FROM Productos;

SELECT NOW() AS momento_previo_al_desastre;

UPDATE Productos
SET    stock = stock - 1
WHERE  nombre = 'Producto demo backup';

DELETE FROM Productos;

SELECT COUNT(*) AS filas_despues_del_incidente FROM Productos;


TRUNCATE TABLE Productos;

LOAD DATA INFILE '<SECURE_FILE_PRIV>ventas_oltp_productos_FULL.csv'
INTO TABLE Productos
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n';

SELECT COUNT(*) AS filas_tras_restaurar_full FROM Productos;

LOAD DATA INFILE '<SECURE_FILE_PRIV>ventas_oltp_productos_DIFF_01.csv'
REPLACE INTO TABLE Productos    
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n';                           
SELECT * FROM Productos WHERE nombre = 'Producto demo backup';

SELECT id_producto, nombre, precio, stock
FROM   Productos
WHERE  nombre = 'Producto demo backup';

SELECT COUNT(*) AS filas_recuperadas FROM Productos;

SELECT * FROM backup_log ORDER BY fecha_inicio;
