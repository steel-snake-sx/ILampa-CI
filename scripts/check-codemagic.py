import urllib.request, json, sys, os

TOKEN = os.environ.get('CODEMAGIC_API_TOKEN')
if not TOKEN:
    sys.exit('Set CODEMAGIC_API_TOKEN in the environment before using this helper.')
HEADERS = {'x-auth-token': TOKEN, 'Content-Type': 'application/json'}

def list_builds():
    req = urllib.request.Request('https://api.codemagic.io/builds', headers=HEADERS)
    res = urllib.request.urlopen(req)
    data = json.loads(res.read().decode())
    builds = data.get('builds', [])
    print(f"Total builds: {len(builds)}")
    for b in builds[:6]:
        c = b.get('commit', {}) or {}
        bid = b.get('_id')
        status = b.get('status')
        index = b.get('index')
        branch = b.get('branch')
        h = (c.get('hash') or '')[:7]
        msg = (c.get('commitMessage') or '')[:50].replace('\n', ' ')
        print(f"[{index}] {bid} | {status} | {branch} | {h} - {msg}")
    return builds

def start_build(app_id="6aec91a2e2fb6e294d92d89a", workflow_id="ilampa-ios-build", branch="poc/headless-plugin-runtime"):
    payload = {
        "appId": app_id,
        "workflowId": workflow_id,
        "branch": branch
    }
    body = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request('https://api.codemagic.io/builds', data=body, headers=HEADERS, method='POST')
    res = urllib.request.urlopen(req)
    data = json.loads(res.read().decode())
    print("Build started successfully!")
    print(json.dumps(data, indent=2))
    return data

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'list'
    if cmd == 'list':
        list_builds()
    elif cmd == 'start':
        start_build()
