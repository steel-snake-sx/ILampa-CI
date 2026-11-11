import json, re, sys
sys.stdout.reconfigure(encoding='utf-8')

with open('iLampa_Stage1_6_Final/changed_screens_preview.html', 'r', encoding='utf-8') as f:
    html = f.read()

m = re.search(r'const screens=({.*?});\s*let current', html, re.DOTALL)
screens = json.loads(m.group(1))

requested = sys.argv[1:] if len(sys.argv) > 1 else list(screens.keys())

for k in requested:
    if k in screens:
        s = screens[k]
        print(f"==================================================")
        print(f"SCREEN ID: {k}")
        print(f"TITLE: {s.get('title')}")
        print(f"BACK: {s.get('back')}, RIGHT: {s.get('right')}")
        print(f"BODY:\n{s.get('body')}")
        print(f"==================================================\n")
