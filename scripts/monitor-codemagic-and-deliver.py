import urllib.request, urllib.parse, json, time, os, sys, hashlib, zipfile, plistlib, re, subprocess

TOKEN = os.environ.get('CODEMAGIC_API_TOKEN')
if not TOKEN:
    sys.exit('Set CODEMAGIC_API_TOKEN in the environment before using this helper.')
HEADERS = {'x-auth-token': TOKEN}
if len(sys.argv) < 2:
    sys.exit('Usage: python scripts/monitor-codemagic-and-deliver.py <Codemagic build ID>')
BUILD_ID = sys.argv[1]
RYUKSIGN_URL = os.environ.get('RYUKSIGN_URL', 'http://192.168.1.2:2424')

def check_status(build_id):
    req = urllib.request.Request(f'https://api.codemagic.io/builds/{build_id}', headers=HEADERS)
    res = urllib.request.urlopen(req)
    return json.loads(res.read().decode())

def download_artifact(url, dest_path):
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req) as resp, open(dest_path, 'wb') as out:
        out.write(resp.read())
    print(f"Downloaded artifact to {dest_path} ({os.path.getsize(dest_path)} bytes)")

def verify_ipa(ipa_path):
    print(f"\n--- Verifying IPA: {ipa_path} ---")
    with open(ipa_path, 'rb') as f:
        sha256 = hashlib.sha256(f.read()).hexdigest()
    print(f"SHA-256: {sha256}")

    with zipfile.ZipFile(ipa_path, 'r') as z:
        plist_data = z.read('Payload/iLampa.app/Info.plist')
        plist = plistlib.loads(plist_data)
        
        bundle_id = plist.get('CFBundleIdentifier')
        version = plist.get('CFBundleShortVersionString')
        build_num = plist.get('CFBundleVersion')
        git_sha = plist.get('ILAMPA_GIT_COMMIT')

        print(f"Bundle ID: {bundle_id}")
        print(f"Marketing Version: {version}")
        print(f"Build Number: {build_num}")
        print(f"Git Commit SHA: {git_sha}")

        expected_version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', open('project.yml', encoding='utf-8').read()).group(1)
        expected_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        assert z.testzip() is None, 'IPA has a corrupt ZIP member'
        assert 'Payload/iLampa.app/Assets.car' in z.namelist(), 'Compiled AppIcon asset catalog missing'
        assert 'Payload/iLampa.app/lampa_bridge.js' in z.namelist(), 'Lampa runtime bridge missing'
        assert bundle_id == 'com.steelsnake.ilampa', f"Unexpected Bundle ID: {bundle_id}"
        assert version == expected_version, f"Expected {expected_version}, got: {version}"
        assert int(build_num) > 2009, f"Build number must exceed previous delivered 2009, got: {build_num}"
        assert git_sha and expected_commit.lower().startswith(git_sha.lower()), 'Artifact commit does not match local Git HEAD'

        return sha256, bundle_id, version, build_num, git_sha

def upload_to_ryuksign(ipa_path):
    print(f"\n--- Uploading to RyukSign ({RYUKSIGN_URL}) ---")
    filename = os.path.basename(ipa_path)
    upload_url = f"{RYUKSIGN_URL}/upload/{urllib.parse.quote(filename)}"
    
    with open(ipa_path, 'rb') as f:
        data = f.read()

    req = urllib.request.Request(upload_url, data=data, headers={'Content-Type': 'application/octet-stream'}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            print(f"Upload response HTTP {resp.status}")
    except Exception as e:
        print(f"Upload error: {e}")
        return False

    time.sleep(3)
    # Check library
    apps_req = urllib.request.Request(f"{RYUKSIGN_URL}/api/apps")
    with urllib.request.urlopen(apps_req, timeout=10) as resp:
        apps = json.loads(resp.read().decode())
        print(f"RyukSign library currently contains {len(apps)} apps:")
        for app in apps:
            if app.get('identifier') == 'com.steelsnake.ilampa':
                print(f"  -> Found: {app.get('name')} v{app.get('version')} (UUID: {app.get('uuid')}, signed: {app.get('signed')})")
    return True

def monitor():
    print(f"Monitoring Codemagic Build {BUILD_ID}...")
    start_time = time.time()
    last_action = ""
    
    while True:
        data = check_status(BUILD_ID)
        build = data.get('build', {})
        status = build.get('status')
        actions = build.get('buildActions', [])
        
        current_action = ""
        for a in actions:
            if a.get('status') == 'in_progress':
                current_action = f"In Progress: {a.get('name')}"
            elif a.get('status') == 'failed':
                current_action = f"FAILED: {a.get('name')}"
                
        elapsed = int(time.time() - start_time)
        if current_action and current_action != last_action:
            print(f"[{elapsed}s] {status} | {current_action}")
            last_action = current_action
        else:
            print(f"[{elapsed}s] Status: {status}...")

        if status == 'finished':
            print(f"\nBUILD FINISHED in {elapsed}s!")
            artifacts = build.get('artefacts', [])
            print(f"Found {len(artifacts)} artifacts:")
            ipa_url = None
            ipa_name = None
            for art in artifacts:
                name = art.get('name')
                print(f"  - {name} ({art.get('size')} bytes)")
                if name.endswith('.ipa'):
                    ipa_url = art.get('url')
                    ipa_name = name

            if ipa_url:
                local_ipa = os.path.join('build', 'codemagic', ipa_name)
                download_artifact(ipa_url, local_ipa)
                verify_ipa(local_ipa)
                return upload_to_ryuksign(local_ipa)
            print('No IPA artifact was published; delivery is not possible.')
            return False

        if status in ['failed', 'canceled']:
            print(f"\nBUILD {status.upper()}!")
            for a in actions:
                if a.get('status') == 'failed':
                    print(f"Failed step: {a.get('name')}")
                    print(f"Log URL: {a.get('logUrl')}")
            return False

        time.sleep(15)

if __name__ == '__main__':
    monitor()
