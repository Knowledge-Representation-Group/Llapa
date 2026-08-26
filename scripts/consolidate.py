#!/usr/bin/env python3
"""
consolidate.py — Consolida todos los CSVs de EcoFloc en un único energia.csv

Uso:
    python3 consolidate.py <directorio_experimento> [output.csv]

Ejemplo:
    python3 consolidate.py ~/results/exp-test-auto8
    python3 consolidate.py ~/results/exp-test-auto8 energia.csv
"""

import os
import sys
import json
import csv
import re
from pathlib import Path

def load_pid_map(node_dir: Path) -> dict:
    """Carga pid_map.json del nodo. Retorna {} si no existe."""
    pid_map_path = node_dir / "pid_map.json"
    if not pid_map_path.exists():
        return {}
    with open(pid_map_path) as f:
        return json.load(f)

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
    component = m.group(1).lower()   # cpu, ram, sd, nic
    pid       = m.group(2)
    service   = m.group(3).lower()   # teastore-auth, kubelet, etc.
    return component, pid, service

def consolidate(exp_dir: Path, output_path: Path):
    nodes = [d for d in exp_dir.iterdir() if d.is_dir() and d.name != "limbo"]

    rows_written = 0

    with open(output_path, "w", newline="") as out_f:
        writer = csv.writer(out_f)
        writer.writerow(["timestamp", "node", "component", "service", "pid", "power_w", "energy_j"])

        for node_dir in sorted(nodes):
            node_name = node_dir.name
            pid_map = load_pid_map(node_dir)

            csv_files = sorted(node_dir.glob("ECOFLOC_*.csv"))
            for csv_path in csv_files:
                parsed = parse_csv_filename(csv_path.name)
                if parsed is None:
                    print(f"  [SKIP] {csv_path.name} — nombre no reconocido")
                    continue

                component, pid, service_from_filename = parsed

                # pid_map tiene precedencia para el nombre del servicio
                # (más confiable que el nombre del archivo)
                if pid in pid_map:
                    service = pid_map[pid]["service"].lower()
                    category = pid_map[pid]["category"]
                else:
                    service = service_from_filename
                    category = "unknown"

                with open(csv_path, newline="") as in_f:
                    reader = csv.reader(in_f)
                    for line in reader:
                        if len(line) != 4:
                            continue  # fila malformada
                        timestamp, _pid, power_w, energy_j = line
                        writer.writerow([
                            timestamp.strip(),
                            node_name,
                            component,
                            service,
                            pid,
                            power_w.strip(),
                            energy_j.strip(),
                        ])
                        rows_written += 1

    return rows_written

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    exp_dir = Path(sys.argv[1]).expanduser().resolve()
    if not exp_dir.is_dir():
        print(f"Error: {exp_dir} no es un directorio válido")
        sys.exit(1)

    output_path = Path(sys.argv[2]) if len(sys.argv) >= 3 else exp_dir / "energia.csv"

    print(f"Experimento : {exp_dir}")
    print(f"Output      : {output_path}")

    nodes = [d for d in exp_dir.iterdir() if d.is_dir() and d.name != "limbo"]
    print(f"Nodos       : {sorted(d.name for d in nodes)}")
    print()

    rows = consolidate(exp_dir, output_path)
    print(f"\nListo — {rows} filas escritas en {output_path.name}")

if __name__ == "__main__":
    main()