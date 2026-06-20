CREATE DATABASE IF NOT EXISTS ventas_oltp
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

use ventas_oltp;

CREATE TABLE Clientes (
    id_cliente      INT NOT NULL AUTO_INCREMENT,
    nombre          VARCHAR(100) NOT NULL,
    apellido        VARCHAR(100) NOT NULL,
    email           VARCHAR(150) NOT NULL,
    telefono        VARCHAR(20) NULL,
    direccion       VARCHAR(100) NULL,
    fecha_registro  DATE NOT NULL DEFAULT (CURRENT_DATE),
    
    CONSTRAINT pk_clientes       PRIMARY KEY (id_cliente),
    CONSTRAINT uq_clientes_email UNIQUE (email)
);

CREATE TABLE Categorias (
    id_categoria  INT NOT NULL AUTO_INCREMENT,
    nombre        VARCHAR(100) NOT NULL,
    descripcion   VARCHAR(255) NULL,
    
	CONSTRAINT pk_categorias PRIMARY KEY (id_categoria),
	CONSTRAINT uq_categorias_nombre UNIQUE (nombre)
    );

CREATE TABLE Productos (
    id_producto   INT NOT NULL AUTO_INCREMENT,
    id_categoria  INT NOT NULL,
    nombre        VARCHAR(150) NOT NULL,
    descripcion   TEXT NULL,
    precio        DECIMAL(10,2) NOT NULL,
    stock         INT NOT NULL DEFAULT 0,
    activo        BOOLEAN NOT NULL DEFAULT TRUE,
 
    CONSTRAINT pk_productos PRIMARY KEY (id_producto),
    CONSTRAINT fk_prod_cat  FOREIGN KEY (id_categoria)
        REFERENCES Categorias(id_categoria)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_precio       CHECK (precio >= 0),
    CONSTRAINT chk_stock        CHECK (stock  >= 0)
);
CREATE TABLE Usuarios (
    id_usuario    INT NOT NULL AUTO_INCREMENT,
    username      VARCHAR(50) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    rol           ENUM('admin','vendedor','supervisor') NOT NULL DEFAULT 'vendedor',
    activo        BOOLEAN NOT NULL DEFAULT TRUE,
    ultimo_login  DATETIME NULL,
 
    CONSTRAINT pk_usuarios PRIMARY KEY (id_usuario),
    CONSTRAINT uq_usuarios_uname UNIQUE (username)
);

CREATE TABLE Ventas (
    id_venta      INT NOT NULL AUTO_INCREMENT,
    id_cliente    INT NOT NULL,
    id_usuario    INT NOT NULL,
    fecha_venta   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total         DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    estado        ENUM('pendiente','confirmada','cancelada','entregada') NOT NULL DEFAULT 'pendiente',
    observaciones TEXT NULL,
 
    CONSTRAINT pk_ventas PRIMARY KEY (id_venta),
    CONSTRAINT fk_venta_cliente FOREIGN KEY (id_cliente)
        REFERENCES Clientes(id_cliente)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT fk_venta_usuario FOREIGN KEY (id_usuario)
        REFERENCES Usuarios(id_usuario)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_total CHECK (total >= 0)
);

CREATE TABLE DetalleVentas (
    id_detalle      INT NOT NULL AUTO_INCREMENT,
    id_venta        INT NOT NULL,
    id_producto     INT NOT NULL,
    cantidad        INT NOT NULL,
    precio_unitario DECIMAL(10,2) NOT NULL,
    subtotal        DECIMAL(12,2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED,
 
    CONSTRAINT pk_detalle PRIMARY KEY (id_detalle),
    CONSTRAINT fk_det_venta FOREIGN KEY (id_venta)
        REFERENCES Ventas (id_venta)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    CONSTRAINT fk_det_producto   FOREIGN KEY (id_producto)
        REFERENCES Productos(id_producto)
        ON UPDATE CASCADE
        ON DELETE RESTRICT,
    CONSTRAINT chk_cantidad CHECK (cantidad > 0),
    CONSTRAINT chk_precio_unit CHECK (precio_unitario >= 0)
);

-- Búsquedas frecuentes por categoría
CREATE INDEX idx_productos_categoria ON Productos(id_categoria);
 
-- Filtros por precio (rangos de precio)
CREATE INDEX idx_productos_precio    ON Productos(precio);
 
-- Búsquedas de ventas por cliente y por fecha
CREATE INDEX idx_ventas_cliente      ON Ventas(id_cliente);
CREATE INDEX idx_ventas_fecha        ON Ventas(fecha_venta);
CREATE INDEX idx_ventas_estado       ON Ventas(estado);
 
-- Acceso rápido al detalle por venta
CREATE INDEX idx_detalle_venta       ON DetalleVentas(id_venta);
CREATE INDEX idx_detalle_producto    ON DetalleVentas(id_producto);
 
-- Búsqueda de clientes por apellido
CREATE INDEX idx_clientes_apellido   ON Clientes(apellido);

-- Vista: productos activos con su categoría
CREATE VIEW v_productos_activos AS
SELECT
    p.id_producto,
    p.nombre        AS producto,
    c.nombre        AS categoria,
    p.precio,
    p.stock
FROM  Productos  p
JOIN  Categorias c ON p.id_categoria = c.id_categoria
WHERE p.activo = TRUE;
 
-- Vista: clientes registrados (sólo datos de contacto)
CREATE VIEW v_clientes AS
SELECT
    id_cliente,
    CONCAT(nombre, ' ', apellido) AS nombre_completo,
    email,
    telefono,
    fecha_registro
FROM Clientes;
 
-- Vista: ventas por estado
CREATE VIEW v_ventas_resumen AS
SELECT
    id_venta,
    fecha_venta,
    estado,
    total
FROM Ventas;

-- Vista: detalle completo de cada venta
CREATE VIEW v_detalle_ventas_completo AS
SELECT
    v.id_venta,
    v.fecha_venta,
    v.estado,
    CONCAT(cl.nombre, ' ', cl.apellido) AS cliente,
    cl.email                             AS email_cliente,
    u.username                           AS vendedor,
    p.nombre                             AS producto,
    cat.nombre                           AS categoria,
    dv.cantidad,
    dv.precio_unitario,
    dv.subtotal,
    v.total                              AS total_venta
FROM  DetalleVentas dv
JOIN  Ventas     v   ON dv.id_venta    = v.id_venta
JOIN  Clientes   cl  ON v.id_cliente   = cl.id_cliente
JOIN  Usuarios   u   ON v.id_usuario   = u.id_usuario
JOIN  Productos  p   ON dv.id_producto = p.id_producto
JOIN  Categorias cat ON p.id_categoria = cat.id_categoria;
 
-- Vista: resumen de ventas por cliente (total histórico)
CREATE VIEW v_ventas_por_cliente AS
SELECT
    cl.id_cliente,
    CONCAT(cl.nombre, ' ', cl.apellido) AS cliente,
    cl.email,
    COUNT(v.id_venta)                    AS total_compras,
    SUM(v.total)                         AS monto_total,
    MAX(v.fecha_venta)                   AS ultima_compra
FROM  Clientes cl
LEFT JOIN Ventas v ON cl.id_cliente = v.id_cliente
                  AND v.estado <> 'cancelada'
GROUP BY cl.id_cliente, cl.nombre, cl.apellido, cl.email;
 
-- Vista: ranking de productos más vendidos
CREATE VIEW v_ranking_productos AS
SELECT
    p.id_producto,
    p.nombre                     AS producto,
    cat.nombre                   AS categoria,
    SUM(dv.cantidad)             AS unidades_vendidas,
    SUM(dv.subtotal)             AS ingresos_totales,
    COUNT(DISTINCT dv.id_venta)  AS veces_en_venta
FROM  DetalleVentas dv
JOIN  Productos  p   ON dv.id_producto = p.id_producto
JOIN  Categorias cat ON p.id_categoria = cat.id_categoria
JOIN  Ventas     v   ON dv.id_venta    = v.id_venta
WHERE v.estado <> 'cancelada'
GROUP BY p.id_producto, p.nombre, cat.nombre
ORDER BY unidades_vendidas DESC;
 
-- Vista: performance de vendedores
CREATE VIEW v_performance_vendedores AS
SELECT
    u.id_usuario,
    u.username                  AS vendedor,
    u.rol,
    COUNT(v.id_venta)           AS ventas_realizadas,
    SUM(v.total)                AS monto_total_vendido,
    AVG(v.total)                AS ticket_promedio
FROM  Usuarios u
LEFT JOIN Ventas v ON u.id_usuario = v.id_usuario
                  AND v.estado <> 'cancelada'
GROUP BY u.id_usuario, u.username, u.rol;

-- Categorías
INSERT INTO Categorias (nombre, descripcion) VALUES
    ('Electrónica',    'Dispositivos y equipos electrónicos'),
    ('Ropa',           'Indumentaria para adultos y niños'),
    ('Alimentos',      'Productos alimenticios y bebidas'),
    ('Hogar',          'Artículos para el hogar y decoración'),
    ('Deportes',       'Equipamiento y ropa deportiva');
 
-- Productos
INSERT INTO Productos (id_categoria, nombre, descripcion, precio, stock) VALUES
    (1, 'Smartphone X12',    'Teléfono inteligente 128 GB',      75000.00, 50),
    (1, 'Laptop ProBook',    'Laptop 15" Intel i7 16 GB RAM',   320000.00, 20),
    (1, 'Auriculares BT',    'Auriculares inalámbricos',          18500.00, 80),
    (2, 'Remera básica',     'Remera 100% algodón talle M',       3500.00, 200),
    (2, 'Campera invierno',  'Campera con relleno sintético',    12000.00, 60),
    (3, 'Café molido 500g',  'Café de altura tostado oscuro',     2800.00, 300),
    (3, 'Granola artesanal', 'Granola con frutas y semillas',     1900.00, 150),
    (4, 'Silla ergonómica',  'Silla de oficina regulable',        45000.00, 25),
    (4, 'Lámpara LED',       'Lámpara de escritorio USB',         8700.00, 90),
    (5, 'Pelota de fútbol',  'Pelota profesional N°5',            6500.00, 70),
    (5, 'Mochila deportiva', 'Mochila 30 lts impermeable',        9800.00, 45);
 
-- Clientes
INSERT INTO Clientes (nombre, apellido, email, telefono, direccion, fecha_registro) VALUES
    ('Ana',     'García',    'ana.garcia@email.com',    '351-111-0001', 'Av. Colón 123, Córdoba',        '2024-01-15'),
    ('Luis',    'Martínez',  'luis.m@email.com',        '351-111-0002', 'Bv. San Juan 456, Córdoba',     '2024-02-20'),
    ('Sofía',   'López',     'sofia.lopez@email.com',   '351-111-0003', 'Calle 9 de Julio 789, Córdoba', '2024-03-05'),
    ('Carlos',  'Fernández', 'carlos.f@email.com',      '351-111-0004', 'Av. Vélez Sársfield 10, Cba.',  '2024-04-10'),
    ('Valeria', 'Ruiz',      'valeria.r@email.com',     '351-111-0005', 'Los Robles 22, Villa Allende',  '2024-05-18'),
    ('Mateo',   'Díaz',      'mateo.diaz@email.com',    '351-111-0006', 'Italia 333, Córdoba',           '2024-06-01'),
    ('Luciana', 'Torres',    'luciana.t@email.com',     '351-111-0007', 'Hipólito Yrigoyen 55, Cba.',    '2024-07-22');
 
-- Usuarios
INSERT INTO Usuarios (username, password_hash, rol) VALUES
    ('admin',      SHA2('Admin2024!',256),    'admin'),
    ('vendedor1',  SHA2('Vend2024#01',256),   'vendedor'),
    ('vendedor2',  SHA2('Vend2024#02',256),   'vendedor'),
    ('supervisor', SHA2('Super2024!',256),    'supervisor');
 
-- Ventas
INSERT INTO Ventas (id_cliente, id_usuario, fecha_venta, total, estado) VALUES
    (1, 2, '2024-08-01 10:30:00',  93500.00, 'entregada'),
    (2, 2, '2024-08-05 14:00:00',  15500.00, 'entregada'),
    (3, 3, '2024-08-10 09:15:00', 326500.00, 'confirmada'),
    (4, 2, '2024-09-01 11:00:00',  45000.00, 'entregada'),
    (1, 3, '2024-09-15 16:45:00',  19300.00, 'confirmada'),
    (5, 2, '2024-10-02 13:20:00',   4700.00, 'cancelada'),
    (6, 3, '2024-10-10 10:00:00',  28300.00, 'pendiente'),
    (7, 2, '2024-10-20 17:30:00',  12000.00, 'confirmada');
 
-- DetalleVentas
INSERT INTO DetalleVentas (id_venta, id_producto, cantidad, precio_unitario) VALUES
    (1, 1,  1, 75000.00),   -- Venta 1: Smartphone
    (1, 3,  1, 18500.00),   -- Venta 1: Auriculares
    (2, 4,  2,  3500.00),   -- Venta 2: 2x Remera
    (2, 6,  3,  2800.00),   -- Venta 2: 3x Café
    (3, 2,  1,320000.00),   -- Venta 3: Laptop
    (3, 6,  1,  2800.00),   -- Venta 3: Café
    (4, 8,  1, 45000.00),   -- Venta 4: Silla
    (5, 9,  1,  8700.00),   -- Venta 5: Lámpara
    (5, 3,  1, 18500.00),   -- Venta 5: Auriculares (+ impuesto)  
    -- (subtotal ajustado via total en Ventas)
    (6, 10, 1,  6500.00),   -- Venta 6 (cancelada): Pelota
    (6, 7,  2,  1900.00),   -- Venta 6 (cancelada): 2x Granola
    (7, 11, 1,  9800.00),   -- Venta 7: Mochila
    (7, 5,  1, 12000.00),   -- Venta 7: Campera
    (7, 9,  1,  8700.00),   -- Venta 7: Lámpara
    (8, 5,  1, 12000.00);   -- Venta 8: Campera
    
    -- Ver todos los productos con su categoría
SELECT * FROM v_productos_activos;
 
-- Ver detalle completo de todas las ventas
SELECT * FROM v_detalle_ventas_completo;
 
-- Ver ranking de productos más vendidos
SELECT * FROM v_ranking_productos;
 
-- Ver resumen por cliente
SELECT * FROM v_ventas_por_cliente ORDER BY monto_total DESC;
 
-- Ver performance de vendedores
SELECT * FROM v_performance_vendedores;