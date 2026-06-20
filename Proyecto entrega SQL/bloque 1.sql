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