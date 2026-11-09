#!/usr/bin/env python3
"""Verify recursive dictionary serialization is byte stable across three runs."""
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
outputs = []
for _ in range(3):
    subprocess.run([sys.executable, str(root / "scripts/generate_project.py")], check=True)
    outputs.append((root / "Inkstone.xcodeproj/project.pbxproj").read_bytes())
if not all(output == outputs[0] for output in outputs):
    raise SystemExit("Project generation is not byte stable")
print("Project generation is byte stable across three runs")
