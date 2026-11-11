import json, re, sys
sys.stdout.reconfigure(encoding='utf-8')

with open('iLampa_Stage1_6_Final/changed_screens_preview.html', 'r', encoding='utf-8') as f:
    html = f.read()

# Match screens = {...} in script tag
m = re.search(r'const screens=({.*?});\s*let current', html, re.DOTALL)
if m:
    screens_json = m.group(1)
    screens = json.loads(screens_json)
    print(f"Extracted {len(screens)} screens from changed_screens_preview.html:")
    for sid, data in screens.items():
        print(f"  - {sid}: {data.get('title')} (back: {data.get('back')}, right: {data.get('right')})")
else:
    print("Could not find screens json in changed_screens_preview.html")
