#!/usr/bin/env python3
"""
launcher.py — Ejecutor secuencial de experimentos TeaStore desde launcher-data.csv

Uso:
    python3 launcher.py [--csv <ruta>] [--dry-run] [--start-from <id>]

Ubicación esperada: mismo directorio que run-experiment.sh (scripts/)
CSV esperado:       mismo directorio que este script (o vía --csv)
"""

import argparse
import csv
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

# ─── Constantes ───────────────────────────────────────────────────────────────

SCRIPT_DIR   = Path(__file__).resolve().parent
RUN_EXP      = SCRIPT_DIR / "run-experiment.sh"
DEFAULT_CSV  = SCRIPT_DIR / "launcher-data.csv"
LOG_FILE     = SCRIPT_DIR / "launcher.log"

# Tiempo de espera (segundos) tras eliminar namespace antes de continuar
TEASTORE_DELETE_WAIT = 60
# Tiempo de espera (segundos) tras un experimento antes del siguiente
BETWEEN_EXP_WAIT     = 15
# Número máximo de reintentos por experimento
MAX_RETRIES          = 1

# ─── Logging ──────────────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE),
    ],
)
log = logging.getLogger("launcher")

# ─── Helpers de formato ───────────────────────────────────────────────────────

def normalizar_componentes(raw: str) -> str:
    """
    'CPU, RAM, SD, NIC'  →  'cpu,ram,sd,nic'
    """
    partes = [p.strip().lower() for p in raw.split(",") if p.strip()]
    return ",".join(partes)


def normalizar_monitor(raw: str) -> str:
    """
    'EcoFloc, Kepler'  →  'ecofloc,kepler'
    """
    partes = [p.strip().lower() for p in raw.split(",") if p.strip()]
    return ",".join(partes)


def normalizar_forma(raw: str) -> str:
    """
    'lineal' → 'linear' | 'escalonada' → 'steps' | 'constante' → 'constant'
    """
    mapping = {
        "lineal":      "linear",
        "linear":      "linear",
        "escalonada":  "steps",
        "steps":       "steps",
        "constante":   "constant",
        "constant":    "constant",
    }
    return mapping.get(raw.strip().lower(), raw.strip().lower())


def construir_cmd_experimento(row: dict) -> list[str]:
    """
    Construye la lista de argumentos para run-experiment.sh a partir de una fila del CSV.
    """
    nombre      = row["Nombre"].strip()
    intervalo   = row["Intervalo (en milisegundos)"].strip()
    componentes = normalizar_componentes(row["Componentes"])
    monitor     = normalizar_monitor(row["Herramienta de monitoreo"])

    cmd = [
        "zsh", str(RUN_EXP),
        nombre,
        intervalo,
        componentes,
        "--monitor", monitor,
        "--categories", row["N° de categorías"].strip(),
        "--products",   row["N° de productos por categoría"].strip(),
        "--users",      row["N° de usuarios"].strip(),
        "--orders",     row["N° de órdenes por usuario"].strip(),
        "--threads",    row["Threads"].strip(),
    ]

    perfil = row.get("Perfil", "").strip()
    max_rps   = row.get("N° max de requests por segundo", "").strip()
    duracion  = row.get("Duración de la carga en segundos", "").strip()
    forma     = row.get("Forma (incremento de la carga)", "").strip()
    escalones = row.get("N° de escalones (solo si la forma es escalonada)", "").strip()

    if perfil:
        cmd += ["--profile", perfil]
    elif max_rps and duracion and forma:
        cmd += [
            "--max-rps",  max_rps,
            "--duration", duracion,
            "--shape",    normalizar_forma(forma),
        ]
        if escalones:
            cmd += ["--num-steps", escalones]
    else:
        raise ValueError(
            f"Fila '{nombre}': debe tener Perfil O (max_rps + duración + forma)"
        )

    return cmd


# ─── Reset de TeaStore ────────────────────────────────────────────────────────

def undeploy_teastore(dry_run: bool = False) -> bool:
    """
    Elimina el namespace 'teastore' y espera hasta que desaparezca.
    Retorna True si tuvo éxito.
    """
    log.info("Eliminando namespace teastore...")

    # Verificar si el namespace existe antes de intentar eliminarlo
    check = subprocess.run(
        ["kubectl", "get", "namespace", "teastore"],
        capture_output=True, text=True
    )
    if check.returncode != 0:
        log.info("  Namespace teastore no existe, nada que eliminar.")
        return True

    if dry_run:
        log.info("  [DRY-RUN] kubectl delete namespace teastore")
        return True

    result = subprocess.run(
        ["kubectl", "delete", "namespace", "teastore", "--ignore-not-found=true"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        log.error(f"  Error al eliminar namespace: {result.stderr.strip()}")
        return False

    log.info(f"  Namespace eliminado. Esperando {TEASTORE_DELETE_WAIT}s para que los pods terminen...")

    # Esperar a que el namespace desaparezca completamente
    deadline = time.time() + TEASTORE_DELETE_WAIT + 60  # margen extra
    while time.time() < deadline:
        check = subprocess.run(
            ["kubectl", "get", "namespace", "teastore"],
            capture_output=True, text=True
        )
        if check.returncode != 0:
            log.info("  ✓ Namespace teastore eliminado completamente.")
            break
        log.info("  ... esperando eliminación del namespace ...")
        time.sleep(10)
    else:
        log.warning("  ⚠ Namespace sigue existiendo tras el tiempo de espera, continuando igual.")

    # Pausa adicional para estabilización del cluster
    time.sleep(TEASTORE_DELETE_WAIT)
    return True


# ─── Ejecución de un experimento ─────────────────────────────────────────────

def ejecutar_experimento(cmd: list[str], nombre: str, dry_run: bool = False) -> bool:
    """
    Ejecuta run-experiment.sh. Retorna True si exitoso.
    """
    log.info(f"  Comando: {' '.join(cmd)}")

    if dry_run:
        log.info("  [DRY-RUN] No se ejecuta el comando real.")
        return True

    start = time.time()
    try:
        result = subprocess.run(
            cmd,
            cwd=str(SCRIPT_DIR),
            text=True,
        )
        elapsed = time.time() - start
        if result.returncode == 0:
            log.info(f"  ✓ Experimento completado en {elapsed:.0f}s")
            return True
        else:
            log.error(f"  ✗ Experimento falló (código {result.returncode}) tras {elapsed:.0f}s")
            return False
    except Exception as e:
        log.error(f"  ✗ Excepción al ejecutar experimento: {e}")
        return False


# ─── Guardar estado ───────────────────────────────────────────────────────────

def guardar_estado(estado: dict, path: Path):
    with open(path, "w") as f:
        json.dump(estado, f, indent=2)


def cargar_estado(path: Path) -> dict:
    if path.exists():
        with open(path) as f:
            return json.load(f)
    return {}


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Launcher secuencial de experimentos TeaStore desde CSV"
    )
    parser.add_argument(
        "--csv", type=Path, default=DEFAULT_CSV,
        help=f"Ruta al CSV (default: {DEFAULT_CSV})"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Mostrar comandos sin ejecutarlos"
    )
    parser.add_argument(
        "--start-from", type=str, default=None, metavar="ID",
        help="Saltar hasta el experimento con este Id (para retomar campaña)"
    )
    args = parser.parse_args()

    # Verificar que run-experiment.sh existe
    if not RUN_EXP.exists():
        log.error(f"No se encontró run-experiment.sh en: {RUN_EXP}")
        sys.exit(1)

    # Leer CSV
    if not args.csv.exists():
        log.error(f"No se encontró el CSV: {args.csv}")
        sys.exit(1)

    with open(args.csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        filas = [row for row in reader if row.get("Id", "").strip().lower() not in ("", "x", "id")]

    if not filas:
        log.error("El CSV no contiene filas válidas (o todas tienen Id='x').")
        sys.exit(1)

    log.info(f"{'='*60}")
    log.info(f"  LAUNCHER TEASTORE")
    log.info(f"  CSV        : {args.csv}")
    log.info(f"  Experimentos: {len(filas)}")
    log.info(f"  Dry-run    : {args.dry_run}")
    log.info(f"  Start-from : {args.start_from or 'primero'}")
    log.info(f"{'='*60}")

    # Estado de la campaña
    estado_path = SCRIPT_DIR / f"launcher-estado-{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    estado = {
        "iniciado":     datetime.now().isoformat(),
        "csv":          str(args.csv),
        "experimentos": [],
    }

    # Saltar hasta --start-from si se especificó
    saltando = bool(args.start_from)

    total   = len(filas)
    exitoso = 0
    fallido = 0

    for idx, row in enumerate(filas, start=1):
        exp_id     = row.get("Id", "").strip()
        exp_nombre = row.get("Nombre", f"exp_{idx}").strip()

        # Salto por --start-from
        if saltando:
            if exp_id == args.start_from or exp_nombre == args.start_from:
                saltando = False
            else:
                log.info(f"[{idx}/{total}] Saltando: {exp_nombre} (Id={exp_id})")
                continue

        log.info(f"")
        log.info(f"{'─'*60}")
        log.info(f"  [{idx}/{total}] EXPERIMENTO: {exp_nombre}  (Id={exp_id})")
        log.info(f"{'─'*60}")

        # Construir comando
        try:
            cmd = construir_cmd_experimento(row)
        except ValueError as e:
            log.error(f"  ✗ Error en CSV: {e}")
            estado["experimentos"].append({
                "id": exp_id, "nombre": exp_nombre,
                "resultado": "error_csv", "ts": datetime.now().isoformat()
            })
            guardar_estado(estado, estado_path)
            fallido += 1
            continue

        # Reset cluster (undeploy TeaStore) — siempre antes de cada experimento
        # (run-experiment.sh hace el deploy, pero queremos partir de estado limpio)
        if idx > 1:
            log.info(f"  → Reiniciando cluster (undeploy TeaStore)...")
            ok_reset = undeploy_teastore(dry_run=args.dry_run)
            if not ok_reset:
                log.error("  ✗ No se pudo hacer undeploy. Abortando este experimento.")
                estado["experimentos"].append({
                    "id": exp_id, "nombre": exp_nombre,
                    "resultado": "error_reset", "ts": datetime.now().isoformat()
                })
                guardar_estado(estado, estado_path)
                fallido += 1
                continue

        # Ejecutar experimento (con 1 reintento si falla)
        resultado = "ok"
        for intento in range(1, MAX_RETRIES + 2):  # intento 1 = normal, intento 2 = retry
            if intento > 1:
                log.warning(f"  ↺ Reintentando experimento (intento {intento}/{MAX_RETRIES+1})...")
                log.info(f"  → Limpiando TeaStore antes del reintento...")
                undeploy_teastore(dry_run=args.dry_run)

            ok = ejecutar_experimento(cmd, exp_nombre, dry_run=args.dry_run)

            if ok:
                resultado = "ok"
                exitoso += 1
                break
            else:
                if intento <= MAX_RETRIES:
                    resultado = "reintentando"
                else:
                    resultado = "fallido"
                    fallido += 1
                    log.error(f"  ✗ Experimento {exp_nombre} marcado como FALLIDO tras {intento} intento(s).")

        estado["experimentos"].append({
            "id":        exp_id,
            "nombre":    exp_nombre,
            "resultado": resultado,
            "intentos":  intento,
            "ts":        datetime.now().isoformat(),
        })
        guardar_estado(estado, estado_path)

        # Pausa entre experimentos (excepto el último)
        if idx < total:
            log.info(f"  Pausa de {BETWEEN_EXP_WAIT}s antes del siguiente experimento...")
            if not args.dry_run:
                time.sleep(BETWEEN_EXP_WAIT)

    # ─── Resumen final ────────────────────────────────────────────────────────
    estado["finalizado"] = datetime.now().isoformat()
    guardar_estado(estado, estado_path)

    log.info(f"")
    log.info(f"{'='*60}")
    log.info(f"  CAMPAÑA COMPLETADA")
    log.info(f"  Total      : {total}")
    log.info(f"  Exitosos   : {exitoso}")
    log.info(f"  Fallidos   : {fallido}")
    log.info(f"  Estado     : {estado_path}")
    log.info(f"  Log        : {LOG_FILE}")
    log.info(f"{'='*60}")

    sys.exit(0 if fallido == 0 else 1)


if __name__ == "__main__":
    main()