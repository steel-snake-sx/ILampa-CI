import json, sys
sys.stdout.reconfigure(encoding='utf-8')

with open('iLampa_Stage1_6_Final/SCREEN_MANIFEST.json', 'r', encoding='utf-8') as f:
    manifest = json.load(f)

print(f"Total screens in manifest: {len(manifest)}")
for s in manifest:
    sid = s.get('id', '')
    title = s.get('title', '')
    cat = s.get('category', '')
    route = s.get('route', '')
    print(f"{sid:<22} | {title:<35} | {cat:<18} | {route}")
