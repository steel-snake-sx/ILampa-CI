#!/usr/bin/env python3
"""Deterministic ILampa-only adapter for the selected upstream Plugins module.

Keep upstream runtime intact except its auto-loading/persistence paths. In the
managed iOS host, PluginManager is the single authority for plugin execution.
The standalone browser retains every original Plugins behavior.
"""
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
start = source.find("  var _created = [];")
anchor = source.find("  var Plugins = {", start)
end = source.find("\n  /**", anchor)
if start < 0 or anchor <= start or end <= anchor:
    raise SystemExit("Unexpected upstream Plugins module layout; refusing to patch")
module = source[start:end]
functions = {
    "task": "if (window.__ilampaNativeManaged === true) { if (typeof call === 'function') call(); return; }",
    "load": "if (window.__ilampaNativeManaged === true) { if (typeof call === 'function') call(); return; }",
    "add": "if (window.__ilampaNativeManaged === true) return;",
    "remove": "if (window.__ilampaNativeManaged === true) return;",
    "push": "if (window.__ilampaNativeManaged === true) return;",
    "save": "if (window.__ilampaNativeManaged === true) return;",
    "modify": "if (window.__ilampaNativeManaged === true) return;",
    "get": "if (window.__ilampaNativeManaged === true) return Array.isArray(window.__ilampaNativePluginManifest) ? window.__ilampaNativePluginManifest.map(function(p) { return { url: p.url, name: p.name, status: p.status }; }) : [];",
    "awaits": "if (window.__ilampaNativeManaged === true) return [];",
}
for method, guard in functions.items():
    regex = r"\bfunction\s+" + re.escape(method) + r"(?:\$\d+)?\s*\(([^)]*)\)\s*\{"
    found = list(re.finditer(regex, module))
    if len(found) != 1:
        raise SystemExit(f"Expected exactly one {method} in upstream Plugins module, found {len(found)}")
    if method in ("task", "load") and not re.search(r"\bcall\b", found[0].group(1)):
        raise SystemExit(f"Unexpected callback parameter for {method}")
    module = module[:found[0].end()] + "\n    " + guard + module[found[0].end():]
patched = source[:start] + module + source[end:]
if patched == source or "__ilampaNativeManaged" not in module:
    raise SystemExit("No effective patch")
path.write_text(patched, encoding="utf-8")
print(f"Native-managed Plugins adapter applied to {path} (9 verified guards)")
