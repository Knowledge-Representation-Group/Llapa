#!/usr/bin/env python3
"""
consolidate.py — Consolida EcoFloc, Scaphandre y Kepler en un único energia.csv

Uso:
    python3 consolidate.py <directorio_experimento> [output.csv]

Ejemplo:
    python3 consolidate.py ~/results/exp-scaph-eco
    python3 consolidate.py ~/results/exp-scaph-eco energia.csv

Schema de salida:
    timestamp, node, component, service, pid, power_w, energy_j, source

Fuentes:
    ecofloc     — CSVs por nodo/componente (cpu, ram, sd, nic)
    scaphandre  — JSONs en <exp>/scaphandre/<node>.json (component=total)
    kepler      — CSVs en <exp>/kepler/ (component=package|core|dram|uncore)
"""

import os
import sys
import json
import csv
import re
from pathlib import Path


# ─── Helpers comunes ──────────────────────────────────────────────────────────

def load_pid_map(node_dir: Path) -> dict:
    """Carga pid_map.json del nodo. Retorna {} si no existe."""
    pid_map_path = node_dir / "pid_map.json"
    if not pid_map_path.exists():
        return {}
    with open(pid_map_path) as f:
        return json.load(f)


# ─── EcoFloc ──────────────────────────────────────────────────────────────────

def parse_csv_filename(filename: str):
    """
    Extrae component, pid y service del nombre del archivo.
    Formato: ECOFLOC_<COMPONENT>_PID_<PID>_<SERVICE>.csv
    Retorna (component, pid, service) o None si no coincide.
    """
    pattern = r"^ECOFLOC_([A-Z]+)_PID_(\d+)_(.+)\.csv$"
    m = re.match(pattern, filename)
    if not m:
        return None
    component = m.group(1).lower()
    pid       = m.group(2)
    service   = m.group(3).lower()
    return component, pid, service


def consolidate_ecofloc(exp_dir: Path, writer, rows_counter: list):
    """Consolida todos los CSVs de EcoFloc."""
    node_dirs = [d for d in exp_dir.iterdir()
                 if d.is_dir() and d.name not in ("limbo", "scaphandre", "kepler")]

    for node_dir in sorted(node_dirs):
        node_name = node_dir.name
        pid_map = load_pid_map(node_dir)

        csv_files = sorted(node_dir.glob("ECOFLOC_*.csv"))
        if not csv_files:
            continue

        for csv_path in csv_files:
            parsed = parse_csv_filename(csv_path.name)
            if parsed is None:
                print(f"  [SKIP ecofloc] {csv_path.name} — nombre no reconocido")
                continue

            component, pid, service_from_filename = parsed

            if pid in pid_map:
                service = pid_map[pid]["service"].lower()
            else:
                service = service_from_filename

            with open(csv_path, newline="") as in_f:
                reader = csv.reader(in_f)
                for line in reader:
                    if len(line) != 4:
                        continue
                    timestamp, _pid, power_w, energy_j = line
                    writer.writerow([
                        timestamp.strip(),
                        node_name,
                        component,
                        service,
                        pid,
                        power_w.strip(),
                        energy_j.strip(),
                        "ecofloc",
                    ])
                    rows_counter[0] += 1

    print(f"  EcoFloc  : {rows_counter[0]} filas")


# ─── Scaphandre ───────────────────────────────────────────────────────────────

def consolidate_scaphandre(exp_dir: Path, writer, rows_counter: list):
    """
    Consolida JSONs de Scaphandre.
    Cada snapshot: host.timestamp, consumers[].{exe, pid, consumption}
    consumption en µW → W dividiendo por 1e6.
    energy_j = power_w * interval_s (delta entre timestamps consecutivos).
    component = 'total' (scaphandre no desglosa cpu/ram/nic/sd).
    El pid_map de cada nodo se usa para mapear pid → service TeaStore.
    """
    scaph_dir = exp_dir / "scaphandre"
    if not scaph_dir.exists():
        return

    # Cargar pid_map por nodo: node_name → {pid: {service, ...}}
    node_pid_maps = {}
    for node_dir in exp_dir.iterdir():
        if node_dir.is_dir() and node_dir.name not in ("scaphandre", "kepler", "limbo"):
            node_pid_maps[node_dir.name] = load_pid_map(node_dir)

    count_before = rows_counter[0]

    for json_path in sorted(scaph_dir.glob("*.json")):
        node_name = json_path.stem  # arrakis, muaddib, etc.
        pid_map   = node_pid_maps.get(node_name, {})

        raw = json_path.read_text().strip()
        if not raw.endswith("]"):
            raw += "]"
        try:
            snapshots = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"  [WARN scaphandre] {json_path.name} JSON inválido: {e}")
            continue

        # Filtrar snapshots con datos reales
        valid = [s for s in snapshots if s.get("host", {}).get("consumption", 0) > 0]

        for i, snap in enumerate(valid):
            ts = snap["host"]["timestamp"]

            # Intervalo para energy_j
            if i + 1 < len(valid):
                interval_s = valid[i + 1]["host"]["timestamp"] - ts
            elif i > 0:
                interval_s = ts - valid[i - 1]["host"]["timestamp"]
            else:
                interval_s = 5.0

            for consumer in snap.get("consumers", []):
                pid            = str(consumer.get("pid", ""))
                exe            = consumer.get("exe", "")
                consumption_uw = consumer.get("consumption", 0.0)
                power_w        = consumption_uw / 1e6

                # pid_map del nodo tiene precedencia → service TeaStore correcto
                if pid in pid_map:
                    service = pid_map[pid]["service"].lower()
                else:
                    # fallback: basename del exe
                    service = exe.split("/")[-1] if exe else "unknown"

                energy_j = power_w * interval_s

                writer.writerow([
                    f"{ts:.3f}",
                    node_name,
                    "total",
                    service,
                    pid,
                    f"{power_w:.6f}",
                    f"{energy_j:.6f}",
                    "scaphandre",
                ])
                rows_counter[0] += 1

    added = rows_counter[0] - count_before
    print(f"  Scaphandre: {added} filas")


# ─── Kepler ───────────────────────────────────────────────────────────────────

def consolidate_kepler(exp_dir: Path, writer, rows_counter: list):
    """
    Consolida CSVs de Kepler.
    - Solo archivos pod_cpu_watts_*.csv (ignora joules acumulativos y node_*)
    - Namespaces: teastore + kube-system + kube-flannel + kepler
    - Mapeo de zona a componente alineado con EcoFloc:
        dram    → ram
        core    → cpu
        package → package
        psys    → psys
        uncore  → uncore
    """
    kepler_dir = exp_dir / "kepler"
    if not kepler_dir.exists():
        return

    ZONE_MAP = {
        "dram":    "ram",
        "core":    "cpu",
        "package": "package",
        "psys":    "psys",
        "uncore":  "uncore",
    }

    # Namespaces a incluir
    NS_INCLUDE = {"teastore", "kube-system", "kube-flannel", "kepler"}

    def pod_to_service(pod_name: str) -> str:
        for svc in ("webui", "auth", "image", "persistence",
                    "recommender", "registry", "db"):
            if f"teastore-{svc}" in pod_name:
                return f"teastore-{svc}"
        return pod_name

    count_before = rows_counter[0]

    # Solo pod_cpu_watts_*.csv — ignorar joules y node_*
    watts_files = sorted(kepler_dir.glob("pod_cpu_watts_*.csv"))
    if not watts_files:
        print("  [WARN kepler] No se encontraron pod_cpu_watts_*.csv")
        return

    for csv_path in watts_files:
        # Extraer namespace y zona del nombre: pod_cpu_watts_<ns>_<zone>.csv
        stem = csv_path.stem  # pod_cpu_watts_teastore_dram
        parts = stem.split("_")
        # parts = ['pod', 'cpu', 'watts', <ns>, <zone>]
        if len(parts) < 5:
            continue
        ns   = parts[3]
        zone = parts[4]

        # Filtrar namespaces
        if ns not in NS_INCLUDE:
            continue

        component = ZONE_MAP.get(zone, zone)

        with open(csv_path, newline="") as in_f:
            reader = csv.DictReader(in_f)
            for row in reader:
                try:
                    ts        = row["timestamp_unix"].strip()
                    node_name = row["node_name"].strip()
                    pod_name  = row["pod_name"].strip()
                    value     = float(row["value"].strip())
                except (KeyError, ValueError):
                    continue

                service = pod_to_service(pod_name)
                power_w = value
                # energy_j = power_w * step (5s hardcodeado en export-kepler)
                energy_j = power_w * 5.0

                writer.writerow([
                    ts,
                    node_name,
                    component,
                    service,
                    "",        # pid no disponible en Kepler
                    f"{power_w:.6f}",
                    f"{energy_j:.6f}",
                    "kepler",
                ])
                rows_counter[0] += 1

    added = rows_counter[0] - count_before
    print(f"  Kepler   : {added} filas")


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    exp_dir = Path(sys.argv[1]).expanduser().resolve()
    if not exp_dir.is_dir():
        print(f"Error: {exp_dir} no es un directorio válido")
        sys.exit(1)

    output_path = Path(sys.argv[2]) if len(sys.argv) >= 3 else exp_dir / "energia.csv"

    print(f"Experimento : {exp_dir.name}")
    print(f"Output      : {output_path}")
    print()

    rows_counter = [0]

    with open(output_path, "w", newline="") as out_f:
        writer = csv.writer(out_f)
        writer.writerow([
            "timestamp", "node", "component", "service",
            "pid", "power_w", "energy_j", "source"
        ])

        consolidate_ecofloc(exp_dir, writer, rows_counter)
        consolidate_scaphandre(exp_dir, writer, rows_counter)
        consolidate_kepler(exp_dir, writer, rows_counter)

    print(f"\nTotal: {rows_counter[0]} filas → {output_path.name}")


if __name__ == "__main__":
    main()