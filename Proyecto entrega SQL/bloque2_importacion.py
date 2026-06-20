"""
BLOQUE 2 – Importación de Datos
================================
Importa Productos desde CSV y Clientes desde JSON hacia la base
de datos ventas_oltp, aplicando validaciones de:
  - Tipos de datos
  - Duplicados
  - Integridad referencial

Genera un log detallado con cada problema encontrado y la solución aplicada.
"""

import csv
import json
import re
import mysql.connector
from datetime import datetime, date
from decimal import Decimal, InvalidOperation
from pathlib import Path

# ─────────────────────────────────────────────
# CONFIGURACIÓN
# ─────────────────────────────────────────────
DB_CONFIG = {
    "host":     "localhost",
    "user":     "root",
    "password": "tu_password",   # <── cambiá esto
    "database": "ventas_oltp",
    "charset":  "utf8mb4",
}

CSV_PATH  = Path("productos_import.csv")
JSON_PATH = Path("clientes_import.json")
LOG_PATH  = Path("importacion_log.txt")


# ─────────────────────────────────────────────
# LOGGER
# ─────────────────────────────────────────────
class Logger:
    def __init__(self, path: Path):
        self._lines: list[str] = []
        self._path  = path
        self.errores:  list[dict] = []
        self.warnings: list[dict] = []

    def _stamp(self):
        return datetime.now().strftime("%H:%M:%S")

    def info(self, msg: str):
        line = f"[{self._stamp()}] INFO  | {msg}"
        print(line)
        self._lines.append(line)

    def warn(self, entidad: str, fila: int | str, campo: str,
             valor, problema: str, solucion: str):
        msg = (f"[{self._stamp()}] WARN  | {entidad} "
               f"fila={fila} campo='{campo}' valor={repr(valor)} "
               f"| PROBLEMA: {problema} | SOLUCIÓN: {solucion}")
        print(msg)
        self._lines.append(msg)
        self.warnings.append({"entidad": entidad, "fila": fila,
                               "campo": campo, "problema": problema,
                               "solucion": solucion})

    def error(self, entidad: str, fila: int | str, motivo: str):
        msg = f"[{self._stamp()}] ERROR | {entidad} fila={fila} | DESCARTADO: {motivo}"
        print(msg)
        self._lines.append(msg)
        self.errores.append({"entidad": entidad, "fila": fila, "motivo": motivo})

    def separador(self, titulo: str = ""):
        line = f"\n{'─'*70}\n  {titulo}\n{'─'*70}"
        print(line)
        self._lines.append(line)

    def resumen(self, entidad, total, insertados, descartados, corregidos):
        bloque = (
            f"\n{'═'*70}\n"
            f"  RESUMEN – {entidad}\n"
            f"{'═'*70}\n"
            f"  Registros leídos    : {total}\n"
            f"  Insertados OK       : {insertados}\n"
            f"  Descartados (error) : {descartados}\n"
            f"  Corregidos (warn)   : {corregidos}\n"
            f"{'═'*70}\n"
        )
        print(bloque)
        self._lines.append(bloque)

    def guardar(self):
        with open(self._path, "w", encoding="utf-8") as f:
            f.write("\n".join(self._lines))
        print(f"\n📄 Log guardado en: {self._path}")


log = Logger(LOG_PATH)


# ─────────────────────────────────────────────
# HELPERS DE VALIDACIÓN
# ─────────────────────────────────────────────
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

def es_email_valido(valor: str) -> bool:
    return bool(EMAIL_RE.match(valor or ""))

def parsear_decimal(valor, campo: str, fila, entidad: str) -> tuple[Decimal | None, bool]:
    """
    Devuelve (Decimal, corregido).
    corregido=True si se tuvo que limpiar el valor.
    Devuelve (None, False) si es imposible convertir.
    """
    if valor is None or str(valor).strip() == "":
        return None, False
    limpio = str(valor).strip().replace(",", ".")
    try:
        resultado = Decimal(limpio)
        cambio = limpio != str(valor).strip()
        return resultado, cambio
    except InvalidOperation:
        return None, False

def parsear_fecha(valor: str, campo: str, fila, entidad: str) -> tuple[date | None, bool]:
    """
    Intenta varios formatos comunes. Devuelve (date, corregido).
    """
    if not valor:
        return None, False
    formatos = ["%Y-%m-%d", "%d/%m/%Y", "%m/%d/%Y", "%Y%m%d"]
    for fmt in formatos:
        try:
            d = datetime.strptime(valor.strip(), fmt).date()
            corregido = fmt != "%Y-%m-%d"
            return d, corregido
        except ValueError:
            continue
    return None, False

def parsear_int(valor, campo: str, fila, entidad: str) -> tuple[int | None, bool]:
    if valor is None or str(valor).strip() == "":
        return None, False
    try:
        return int(str(valor).strip()), False
    except (ValueError, TypeError):
        return None, False


# ─────────────────────────────────────────────
# CONEXIÓN
# ─────────────────────────────────────────────
def conectar() -> mysql.connector.MySQLConnection:
    return mysql.connector.connect(**DB_CONFIG)


# ─────────────────────────────────────────────
# CARGAR REFERENCIAS EXISTENTES
# ─────────────────────────────────────────────
def cargar_categorias(cursor) -> set[int]:
    cursor.execute("SELECT id_categoria FROM Categorias")
    return {r[0] for r in cursor.fetchall()}

def cargar_emails_existentes(cursor) -> set[str]:
    cursor.execute("SELECT LOWER(email) FROM Clientes")
    return {r[0] for r in cursor.fetchall()}

def cargar_nombres_productos(cursor) -> set[str]:
    cursor.execute("SELECT LOWER(nombre) FROM Productos")
    return {r[0] for r in cursor.fetchall()}


# ─────────────────────────────────────────────
# IMPORTAR PRODUCTOS DESDE CSV
# ─────────────────────────────────────────────
def importar_productos(conn):
    log.separador("IMPORTACIÓN DE PRODUCTOS (CSV)")
    cursor = conn.cursor()

    categorias_validas  = cargar_categorias(cursor)
    nombres_existentes  = cargar_nombres_productos(cursor)

    total = insertados = descartados = corregidos = 0

    with open(CSV_PATH, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)

        for num_fila, fila in enumerate(reader, start=2):   # fila 1 = cabecera
            total += 1
            fila_ok      = True
            fila_corr    = False
            entidad      = "Producto"

            nombre      = (fila.get("nombre") or "").strip()
            descripcion = (fila.get("descripcion") or "").strip() or None
            activo_raw  = (fila.get("activo") or "1").strip()

            # ── 1. Nombre obligatorio ──────────────────────────
            if not nombre:
                log.error(entidad, num_fila,
                          "nombre vacío – campo NOT NULL requerido")
                descartados += 1
                continue

            # ── 2. Duplicado por nombre (case-insensitive) ─────
            if nombre.lower() in nombres_existentes:
                log.error(entidad, num_fila,
                          f"duplicado – '{nombre}' ya existe en Productos")
                descartados += 1
                continue

            # ── 3. id_categoria ────────────────────────────────
            id_cat_raw = (fila.get("id_categoria") or "").strip()
            id_cat, _ = parsear_int(id_cat_raw, "id_categoria", num_fila, entidad)

            if id_cat is None:
                log.error(entidad, num_fila,
                          f"id_categoria='{id_cat_raw}' es nulo o no es entero – "
                          "integridad referencial violada")
                descartados += 1
                continue

            if id_cat not in categorias_validas:
                log.error(entidad, num_fila,
                          f"id_categoria={id_cat} no existe en tabla Categorias – "
                          "FK violation")
                descartados += 1
                continue

            # ── 4. Precio ──────────────────────────────────────
            precio, precio_corr = parsear_decimal(
                fila.get("precio"), "precio", num_fila, entidad)

            if precio is None:
                log.error(entidad, num_fila,
                          f"precio='{fila.get('precio')}' no es numérico – descartado")
                descartados += 1
                continue

            if precio < 0:
                log.warn(entidad, num_fila, "precio", precio,
                         "precio negativo viola CHECK (precio >= 0)",
                         "valor corregido a 0.00")
                precio    = Decimal("0.00")
                fila_corr = True

            if precio_corr:
                log.warn(entidad, num_fila, "precio", fila.get("precio"),
                         "separador decimal no estándar",
                         "normalizado a punto decimal")
                fila_corr = True

            # ── 5. Stock ───────────────────────────────────────
            stock_raw = fila.get("stock", "0")
            stock, _  = parsear_int(stock_raw, "stock", num_fila, entidad)

            if stock is None:
                log.warn(entidad, num_fila, "stock", stock_raw,
                         "stock no es entero",
                         "asignado valor por defecto 0")
                stock     = 0
                fila_corr = True

            if stock < 0:
                log.warn(entidad, num_fila, "stock", stock,
                         "stock negativo viola CHECK (stock >= 0)",
                         "corregido a 0")
                stock     = 0
                fila_corr = True

            # ── 6. Activo (booleano) ───────────────────────────
            if activo_raw not in ("0", "1", "true", "false", "TRUE", "FALSE"):
                log.warn(entidad, num_fila, "activo", activo_raw,
                         "valor booleano no reconocido",
                         "asignado TRUE por defecto")
                activo    = True
                fila_corr = True
            else:
                activo = activo_raw in ("1", "true", "TRUE")

            # ── INSERT ─────────────────────────────────────────
            cursor.execute(
                """INSERT INTO Productos
                   (id_categoria, nombre, descripcion, precio, stock, activo)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (id_cat, nombre, descripcion, float(precio), stock, activo)
            )
            conn.commit()
            nombres_existentes.add(nombre.lower())
            insertados += 1
            if fila_corr:
                corregidos += 1
            log.info(f"Producto insertado: '{nombre}' "
                     f"(cat={id_cat}, precio={precio}, stock={stock})")

    cursor.close()
    log.resumen("PRODUCTOS", total, insertados, descartados, corregidos)


# ─────────────────────────────────────────────
# IMPORTAR CLIENTES DESDE JSON
# ─────────────────────────────────────────────
def importar_clientes(conn):
    log.separador("IMPORTACIÓN DE CLIENTES (JSON)")
    cursor = conn.cursor()

    emails_existentes = cargar_emails_existentes(cursor)

    with open(JSON_PATH, encoding="utf-8") as f:
        try:
            registros = json.load(f)
        except json.JSONDecodeError as e:
            log.error("Clientes", "archivo", f"JSON malformado – {e}")
            return

    total = insertados = descartados = corregidos = 0

    for idx, reg in enumerate(registros, start=1):
        total    += 1
        fila_corr = False
        entidad   = "Cliente"

        nombre   = (reg.get("nombre") or "").strip()
        apellido = (reg.get("apellido") or "").strip()
        email    = (reg.get("email") or "").strip()
        telefono = (reg.get("telefono") or "").strip() or None
        direccion= (reg.get("direccion") or "").strip() or None
        fecha_raw= (reg.get("fecha_registro") or "").strip()

        # ── 1. nombre obligatorio ──────────────────────────────
        if not nombre:
            log.error(entidad, idx,
                      "nombre vacío – NOT NULL requerido")
            descartados += 1
            continue

        # ── 2. apellido obligatorio ────────────────────────────
        if not apellido:
            log.warn(entidad, idx, "apellido", apellido,
                     "apellido vacío – NOT NULL requerido",
                     "asignado '(sin apellido)' como temporal")
            apellido  = "(sin apellido)"
            fila_corr = True

        # ── 3. email – formato ─────────────────────────────────
        if not email:
            log.error(entidad, idx,
                      "email vacío – NOT NULL + UNIQUE requerido")
            descartados += 1
            continue

        if not es_email_valido(email):
            log.error(entidad, idx,
                      f"email='{email}' formato inválido (sin @) – descartado")
            descartados += 1
            continue

        # ── 4. email – duplicado ───────────────────────────────
        if email.lower() in emails_existentes:
            log.error(entidad, idx,
                      f"email='{email}' ya existe en Clientes – duplicado descartado")
            descartados += 1
            continue

        # ── 5. fecha_registro ──────────────────────────────────
        fecha, fecha_corr = parsear_fecha(fecha_raw, "fecha_registro", idx, entidad)

        if fecha is None:
            log.warn(entidad, idx, "fecha_registro", fecha_raw,
                     "fecha inválida o formato no reconocido",
                     "asignada fecha actual como fallback")
            fecha     = date.today()
            fila_corr = True
        elif fecha_corr:
            log.warn(entidad, idx, "fecha_registro", fecha_raw,
                     "formato de fecha no estándar (esperado YYYY-MM-DD)",
                     f"convertida a {fecha.isoformat()}")
            fila_corr = True

        if fecha > date.today():
            log.warn(entidad, idx, "fecha_registro", fecha.isoformat(),
                     "fecha en el futuro",
                     "corregida a fecha actual")
            fecha     = date.today()
            fila_corr = True

        # ── INSERT ─────────────────────────────────────────────
        cursor.execute(
            """INSERT INTO Clientes
               (nombre, apellido, email, telefono, direccion, fecha_registro)
               VALUES (%s, %s, %s, %s, %s, %s)""",
            (nombre, apellido, email, telefono, direccion, fecha.isoformat())
        )
        conn.commit()
        emails_existentes.add(email.lower())
        insertados += 1
        if fila_corr:
            corregidos += 1
        log.info(f"Cliente insertado: '{nombre} {apellido}' ({email})")

    cursor.close()
    log.resumen("CLIENTES", total, insertados, descartados, corregidos)


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def main():
    log.separador("INICIO DE IMPORTACIÓN")
    log.info(f"Base de datos : {DB_CONFIG['database']}")
    log.info(f"Archivo CSV   : {CSV_PATH}")
    log.info(f"Archivo JSON  : {JSON_PATH}")
    log.info(f"Timestamp     : {datetime.now().isoformat()}")

    try:
        conn = conectar()
        log.info("Conexión a MySQL establecida")
    except mysql.connector.Error as e:
        log.error("Conexión", "–", str(e))
        log.guardar()
        return

    importar_productos(conn)
    importar_clientes(conn)

    conn.close()

    log.separador("RESUMEN GLOBAL")
    log.info(f"Total errores  : {len(log.errores)}")
    log.info(f"Total warnings : {len(log.warnings)}")
    log.guardar()


if __name__ == "__main__":
    main()
