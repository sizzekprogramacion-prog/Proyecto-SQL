# Bloque 2 – Documentación de Importación de Datos

## Contexto

Se importaron datos desde dos fuentes externas hacia la base de datos `ventas_oltp`:

| Fuente | Entidad | Registros leídos |
|--------|---------|-----------------|
| `productos_import.csv` | Productos | 14 |
| `clientes_import.json` | Clientes  | 8  |

La estrategia implementada fue **tabla staging + validación + inserción selectiva**: los archivos se cargan primero en tablas intermedias sin constraints, se validan allí y sólo los registros aptos se transfieren a las tablas definitivas.

---

## Problemas encontrados en Productos (CSV)

### Error 1 – Precio negativo
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| precio | `-500.00` | 9 (Zapatillas running) |

**Problema:** El valor viola el constraint `CHECK (precio >= 0)` definido en la tabla `Productos`. Un precio negativo no tiene sentido de negocio.

**Solución aplicada:** Se marcó como `corregido` y el precio fue seteado a `0.00`. El registro fue insertado con la corrección y se documentó en `staging_productos.observacion`. Se recomienda contactar al proveedor del CSV para corregir el valor real del producto.

---

### Error 2 – Precio no numérico
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| precio | `PRECIO_INVALIDO` | 13 (Campera invierno) |

**Problema:** El campo `precio` contiene texto en lugar de un valor decimal. No es posible convertirlo a `DECIMAL(10,2)` ni corregirlo automáticamente porque se desconoce el valor correcto.

**Solución aplicada:** Registro **descartado** (estado `error`). Se documenta el problema para que el área de datos lo corrija en la fuente y reenvíe el archivo.

---

### Error 3 – Nombre vacío (campo NOT NULL)
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| nombre | `NULL` | 14 |

**Problema:** `nombre` es `NOT NULL` en la tabla `Productos`. Sin nombre, el registro no es identificable ni utilizable.

**Solución aplicada:** Registro **descartado** (estado `error`). No es posible asignar un nombre automático sin conocer el producto real.

---

### Error 4 – Categoría inexistente (violación FK)
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| id_categoria | `6` | 10 (Libro Python) |

**Problema:** La categoría `6` no existe en la tabla `Categorias`. Insertar el producto violaría la `FOREIGN KEY fk_prod_cat`.

**Solución aplicada:** Registro **descartado** (estado `error`). Para que pueda importarse, primero se debe crear la categoría correspondiente (ej: "Libros") o reasignar el producto a una categoría existente.

---

### Error 5 – Categoría nula (violación NOT NULL + FK)
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| id_categoria | `NULL` | 12 (Auriculares BT) |

**Problema:** `id_categoria` es `NOT NULL` y FK obligatoria. Sin categoría, el producto no puede relacionarse con ninguna categoría del catálogo.

**Solución aplicada:** Registro **descartado** (estado `error`). Se debe asignar una categoría válida antes de reimportar.

---

### Error 6 – Duplicados (3 registros)
| Nombre del producto | Fila |
|--------------------|------|
| Remera básica       | 5   |
| Café molido 500g    | 7   |
| Smartphone X12      | 11  |

**Problema:** Los tres productos ya existen en la tabla `Productos` (insertados en el Bloque 1). Insertar nuevamente violaría la unicidad lógica de los datos.

**Solución aplicada:** Los tres registros fueron **descartados** (estado `error`). La detección se hizo por comparación `LOWER(nombre)` (case-insensitive) contra los registros existentes. Se recomienda implementar un campo `codigo_externo` como clave de reconciliación para futuras importaciones.

---

## Resumen Productos

| Estado | Cantidad | Registros |
|--------|----------|-----------|
| `ok` | 5 | Monitor 27" 4K, Teclado Mecánico, Mouse Inalámbrico, Pantalón Jean, Yerba Mate 500g, Escritorio plegable |
| `corregido` | 1 | Zapatillas running (precio corregido a 0.00) |
| `error` | 7 | Campera invierno, producto sin nombre, Libro Python, Auriculares BT, Remera básica ×dup, Café ×dup, Smartphone ×dup |

**Resultado:** 6 productos insertados de 14 leídos (43%). 7 descartados, 1 corregido.

---

## Problemas encontrados en Clientes (JSON)

### Error 1 – Email duplicado
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| email | `ana.garcia@email.com` | 4 |

**Problema:** El email ya pertenece a un cliente existente (Ana García, cargada en el Bloque 1). La columna `email` tiene constraint `UNIQUE`.

**Solución aplicada:** Registro **descartado** (estado `error`). Se notifica al área de datos para que verifiquen si es una actualización de datos del cliente existente (en cuyo caso debería ser un `UPDATE`, no un `INSERT`).

---

### Error 2 – Email con formato inválido
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| email | `email-invalido-sin-arroba` | 6 (Gonzalo Vega) |

**Problema:** El email no contiene `@`. No cumple el formato mínimo para ser un email válido ni podría usarse para contactar al cliente.

**Solución aplicada:** Registro **descartado** (estado `error`). Se requiere el email correcto del cliente para reimportar.

---

### Error 3 – Fecha imposible
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| fecha_registro | `2025-30-99` | 7 (Marcela Ibáñez) |

**Problema:** El valor `2025-30-99` no representa una fecha real (mes 30, día 99). `STR_TO_DATE` retorna `NULL`, lo que impide insertarlo como `DATE`.

**Solución aplicada:** Registro **descartado** (estado `error`). Se asume que el sistema origen tiene un bug de formateo. Se requiere corregir la fecha en la fuente.

---

### Error 4 – Apellido vacío (campo NOT NULL)
| Campo | Valor recibido | Fila |
|-------|---------------|------|
| apellido | `""` (cadena vacía) | 5 (Fernanda) |

**Problema:** `apellido` es `NOT NULL`. El valor recibido es una cadena vacía, lo que es funcionalmente equivalente a nulo.

**Solución aplicada:** Marcado como `corregido`. Se asignó el valor `"(sin apellido)"` como placeholder temporal para no bloquear la importación. El registro fue insertado. Se debe actualizar manualmente con el apellido real a la brevedad.

---

## Resumen Clientes

| Estado | Cantidad | Registros |
|--------|----------|-----------|
| `ok` | 4 | Roberto Sánchez, Daniela Moreno, Esteban Castro, Tomás Acosta |
| `corregido` | 1 | Fernanda (apellido corregido a placeholder) |
| `error` | 3 | Ana García (dup), Gonzalo Vega (email inválido), Marcela Ibáñez (fecha imposible) |

**Resultado:** 5 clientes insertados de 8 leídos (62%). 3 descartados, 1 corregido.

---

## Resumen global de la importación

| Entidad | Leídos | Insertados | Descartados | Corregidos |
|---------|--------|------------|-------------|------------|
| Productos | 14 | 6 | 7 | 1 |
| Clientes  | 8  | 5 | 3 | 1 |
| **Total** | **22** | **11** | **10** | **2** |

---

## Tipos de problemas detectados

| Categoría | Cantidad | Entidades afectadas |
|-----------|----------|---------------------|
| Duplicados | 4 | Productos (×3), Clientes (×1) |
| Tipo de dato inválido | 2 | precio no numérico, fecha imposible |
| Integridad referencial (FK) | 2 | cat. inexistente, cat. nula |
| Campo NOT NULL vacío | 3 | nombre vacío (×2), email vacío |
| Formato inválido | 1 | email sin @ |
| Valor fuera de rango (CHECK) | 1 | precio negativo |

---

## Recomendaciones para futuras importaciones

1. **Agregar `codigo_externo`** en Productos y Clientes como campo de reconciliación para detectar actualizaciones vs inserciones nuevas.
2. **Validar en origen** con reglas básicas (campos obligatorios, formatos de email y fecha) antes de exportar el CSV/JSON.
3. **Acordar un contrato de datos** con los proveedores: separador decimal, formato de fecha ISO 8601 (`YYYY-MM-DD`), codificación UTF-8.
4. **Automatizar la reimportación** de registros descartados: los registros en estado `error` en las tablas staging pueden corregirse y re-procesarse sin re-cargar todo el archivo.
5. **Monitorear el log** de importación con alertas si el porcentaje de errores supera el 10%.
