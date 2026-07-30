#!/usr/bin/env python3
"""Generate the Windows icon from the canonical Codex Roster PNG."""

from pathlib import Path
from PIL import Image


root = Path(__file__).resolve().parents[1]
source = Image.open(root / "assets" / "codex-roster.png").convert("RGBA")
source.save(
    root / "assets" / "codex-roster.ico",
    format="ICO",
    sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
