"""Emit the exact model for independent recognizer comparisons."""
import json
from pathlib import Path
import sys
from horizontal import Model

model = Model()
i = 0
while i < len(model.nodes):
    model.edges(i)
    i += 1
Path(sys.argv[2]).write_text(json.dumps({"fragments": model.frags,
                                      "edges": [model.edges(q) for q in range(len(model.nodes))]}))
