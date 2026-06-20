USE ventas_oltp;
DROP TABLE IF EXISTS staging_productos;
CREATE TABLE staging_productos (
    fila            INT AUTO_INCREMENT PRIMARY KEY,
    id_categoria    VARCHAR(20),      -- llega como texto, puede ser nulo/inválido
    nombre          VARCHAR(255),
    descripcion     TEXT,
    precio          VARCHAR(50),      -- puede llegar "PRECIO_INVALIDO"
    stock           VARCHAR(20),
    activo          VARCHAR(10),
    estado          ENUM('pendiente','ok','error','corregido') DEFAULT 'pendiente',
    observacion     TEXT              -- documenta el problema detectado
);

DROP TABLE IF EXISTS staging_clientes;
CREATE TABLE staging_clientes (
    fila            INT AUTO_INCREMENT PRIMARY KEY,
    nombre          VARCHAR(255),
    apellido        VARCHAR(255),
    email           VARCHAR(255),
    telefono        VARCHAR(50),
    direccion       TEXT,
    fecha_registro  VARCHAR(30),      -- puede llegar en formato incorrecto
    estado          ENUM('pendiente','ok','error','corregido') DEFAULT 'pendiente',
    observacion     TEXT
);

INSERT INTO staging_productos (id_categoria, nombre, descripcion, precio, stock, activo)
VALUES
-- Filas limpias
('1', 'Monitor 27" 4K',       'Monitor UHD con panel IPS',              '89500.00', '30',  '1'),
('1', 'Teclado Mecánico',     'Teclado gaming switches Blue',           '15200.00', '75',  '1'),
('1', 'Mouse Inalámbrico',    'Mouse ergonómico 2.4GHz',               '8900.00',  '120', '1'),
('2', 'Pantalón Jean',        'Jean slim fit talle 32',                 '7800.00',  '90',  '1'),
-- DUPLICADO (ya existe en Productos) ─ error esperado
('2', 'Remera básica',        'Remera 100% algodón talle M',            '3500.00',  '200', '1'),
('3', 'Yerba Mate 500g',      'Yerba con palo selección especial',      '1850.00',  '400', '1'),
-- DUPLICADO (ya existe en Productos) ─ error esperado
('3', 'Café molido 500g',     'Café de altura tostado oscuro',          '2800.00',  '300', '1'),
('4', 'Escritorio plegable',  'Escritorio compacto 120x60cm',           '38000.00', '15',  '1'),
-- PRECIO NEGATIVO ─ warning esperado, se corrige a 0
('5', 'Zapatillas running',   'Zapatillas amortiguación máxima',       '-500.00',   '40',  '1'),
-- CATEGORÍA INEXISTENTE (6) ─ error de integridad referencial
('6', 'Libro Python',         'Aprende Python desde cero',              '4200.00',  '60',  '1'),
-- DUPLICADO (ya existe en Productos) ─ error esperado
('1', 'Smartphone X12',       'Teléfono inteligente 128 GB',           '75000.00', '50',  '1'),
-- id_categoria NULL ─ error FK
(NULL,'Auriculares BT',       'Auriculares inalámbricos sin categoria', '18500.00', '80',  '1'),
-- PRECIO NO NUMÉRICO ─ error de tipo de dato
('2', 'Campera invierno',     'Campera con relleno sintético',         'PRECIO_INVALIDO','60','1'),
-- NOMBRE VACÍO ─ error NOT NULL
('1',  NULL,                  'Producto sin nombre',                     NULL,       '25',  '1');


-- ── Clientes desde JSON ──────────────────────────────────
INSERT INTO staging_clientes (nombre, apellido, email, telefono, direccion, fecha_registro)
VALUES
('Roberto', 'Sánchez',  'roberto.sanchez@email.com',  '351-222-0001', 'Av. Figueroa Alcorta 890, Córdoba', '2024-11-01'),
('Daniela', 'Moreno',   'daniela.moreno@email.com',   '351-222-0002', 'Bv. Chacabuco 234, Córdoba',        '2024-11-05'),
('Esteban', 'Castro',   'esteban.castro@email.com',   '351-222-0003', 'Entre Ríos 567, Córdoba',           '2024-11-10'),
-- DUPLICADO (ana.garcia ya existe) ─ error esperado
('Ana',     'García',   'ana.garcia@email.com',        '351-111-0001', 'Av. Colón 123, Córdoba',            '2024-01-15'),
-- APELLIDO VACÍO ─ warning, se corrige
('Fernanda',NULL,        'fernanda@email.com',          '351-222-0005', 'Lima 890, Córdoba',                 '2024-11-12'),
-- EMAIL INVÁLIDO (sin @) ─ error de formato
('Gonzalo', 'Vega',     'email-invalido-sin-arroba',   '351-222-0006', 'Obispo Trejo 11, Córdoba',          '2024-11-15'),
-- FECHA IMPOSIBLE ─ error de tipo de dato
('Marcela', 'Ibáñez',   'marcela.ibanez@email.com',    '351-222-0007', 'Dean Funes 300, Córdoba',           '2025-30-99'),
('Tomás',   'Acosta',   'tomas.acosta@email.com',      '351-222-0008', 'Independencia 445, Córdoba',        '2024-11-20');

-- ERROR: nombre nulo o vacío
UPDATE staging_productos
SET    estado      = 'error',
       observacion = 'nombre vacío o NULL – campo NOT NULL obligatorio'
WHERE  (nombre IS NULL OR TRIM(nombre) = '')
  AND  estado = 'pendiente';

-- ERROR: precio no numérico
UPDATE staging_productos
SET    estado      = 'error',
       observacion = CONCAT('precio="', precio, '" no es un valor numérico válido')
WHERE  precio NOT REGEXP '^-?[0-9]+(\\.[0-9]+)?$'
  AND  estado = 'pendiente';

-- ERROR: id_categoria nulo
UPDATE staging_productos
SET    estado      = 'error',
       observacion = 'id_categoria NULL – campo NOT NULL y FK requerida'
WHERE  (id_categoria IS NULL OR TRIM(id_categoria) = '')
  AND  estado = 'pendiente';

-- ERROR: integridad referencial – categoría no existe
UPDATE staging_productos sp
SET    sp.estado      = 'error',
       sp.observacion = CONCAT('id_categoria=', sp.id_categoria,
                               ' no existe en tabla Categorias – FK violation')
WHERE  sp.estado = 'pendiente'
  AND  CAST(sp.id_categoria AS UNSIGNED) NOT IN (
           SELECT id_categoria FROM Categorias
       );

-- ERROR: duplicado por nombre (case-insensitive)
UPDATE staging_productos sp
SET    sp.estado      = 'error',
       sp.observacion = CONCAT('nombre="', sp.nombre,
                               '" ya existe en Productos – registro duplicado')
WHERE  sp.estado = 'pendiente'
  AND  LOWER(sp.nombre) IN (
           SELECT LOWER(nombre) FROM Productos
       );

-- CORRECCIÓN: precio negativo → 0
UPDATE staging_productos
SET    estado      = 'corregido',
       observacion = CONCAT('precio negativo (', precio,
                            ') corregido a 0.00 – viola CHECK (precio >= 0)'),
       precio      = '0.00'
WHERE  precio REGEXP '^-[0-9]+(\\.[0-9]+)?$'
  AND  estado = 'pendiente';

-- Registros sin problemas → ok
UPDATE staging_productos
SET    estado = 'ok'
WHERE  estado = 'pendiente';


-- ── 3b. Validaciones de Clientes ────────────────────────────

-- ERROR: nombre nulo o vacío
UPDATE staging_clientes
SET    estado      = 'error',
       observacion = 'nombre vacío o NULL – NOT NULL obligatorio'
WHERE  (nombre IS NULL OR TRIM(nombre) = '')
  AND  estado = 'pendiente';

-- ERROR: email inválido (sin @)
UPDATE staging_clientes
SET    estado      = 'error',
       observacion = CONCAT('email="', email, '" formato inválido – no contiene @')
WHERE  email NOT REGEXP '^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$'
  AND  estado = 'pendiente';

-- ERROR: duplicado por email
UPDATE staging_clientes sc
SET    sc.estado      = 'error',
       sc.observacion = CONCAT('email="', sc.email,
                               '" ya existe en Clientes – registro duplicado')
WHERE  sc.estado = 'pendiente'
  AND  LOWER(sc.email) IN (
           SELECT LOWER(email) FROM Clientes
       );

-- ERROR: fecha imposible (día > 28/30/31 o mes > 12)
UPDATE staging_clientes
SET    estado      = 'error',
       observacion = CONCAT('fecha_registro="', fecha_registro,
                            '" es una fecha imposible (día/mes fuera de rango)')
WHERE  estado = 'pendiente'
  AND  STR_TO_DATE(fecha_registro, '%Y-%m-%d') IS NULL;

-- CORRECCIÓN: apellido nulo → placeholder
UPDATE staging_clientes
SET    estado      = 'corregido',
       observacion = 'apellido NULL corregido a "(sin apellido)" – NOT NULL obligatorio',
       apellido    = '(sin apellido)'
WHERE  (apellido IS NULL OR TRIM(apellido) = '')
  AND  estado = 'pendiente';

-- Registros sin problemas → ok
UPDATE staging_clientes
SET    estado = 'ok'
WHERE  estado = 'pendiente';

-- ── 4a. Insertar productos válidos ──────────────────────────
INSERT INTO Productos (id_categoria, nombre, descripcion, precio, stock, activo)
SELECT
    CAST(id_categoria AS UNSIGNED),
    nombre,
    descripcion,
    CAST(precio AS DECIMAL(10,2)),
    CAST(IFNULL(stock, '0') AS UNSIGNED),
    CAST(activo AS UNSIGNED)
FROM  staging_productos
WHERE estado IN ('ok', 'corregido');


-- ── 4b. Insertar clientes válidos ───────────────────────────
INSERT INTO Clientes (nombre, apellido, email, telefono, direccion, fecha_registro)
SELECT
    nombre,
    apellido,
    email,
    NULLIF(telefono, ''),
    NULLIF(direccion, ''),
    STR_TO_DATE(fecha_registro, '%Y-%m-%d')
FROM  staging_clientes
WHERE estado IN ('ok', 'corregido');

-- ── Resumen por estado (Productos) ──────────────────────────
SELECT
    'Productos' AS entidad,
    estado,
    COUNT(*)    AS cantidad,
    GROUP_CONCAT(IFNULL(nombre,'(sin nombre)') SEPARATOR ' | ') AS registros
FROM  staging_productos
GROUP BY estado
ORDER BY FIELD(estado,'ok','corregido','error','pendiente');

-- ── Resumen por estado (Clientes) ───────────────────────────
SELECT
    'Clientes' AS entidad,
    estado,
    COUNT(*)   AS cantidad,
    GROUP_CONCAT(CONCAT(IFNULL(nombre,'?'),' ',IFNULL(apellido,'?')) SEPARATOR ' | ') AS registros
FROM  staging_clientes
GROUP BY estado
ORDER BY FIELD(estado,'ok','corregido','error','pendiente');

-- ── Detalle de errores y correcciones ───────────────────────
SELECT
    'Productos'                     AS entidad,
    fila,
    IFNULL(nombre, '(sin nombre)')  AS identificador,
    estado,
    observacion
FROM  staging_productos
WHERE estado IN ('error','corregido')
UNION ALL
SELECT
    'Clientes',
    fila,
    CONCAT(IFNULL(nombre,'?'), ' – ', IFNULL(email,'sin email')),
    estado,
    observacion
FROM  staging_clientes
WHERE estado IN ('error','corregido')
ORDER BY entidad, fila;

-- ── Vista de verificación final ─────────────────────────────
SELECT 'Productos importados' AS tabla, COUNT(*) AS total FROM Productos
UNION ALL
SELECT 'Clientes importados',           COUNT(*) FROM Clientes;
