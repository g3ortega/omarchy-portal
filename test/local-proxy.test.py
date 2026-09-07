"""Local probes must reach the listener even when the shell configures a proxy."""
import http.server
import os
from pathlib import Path
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]
requests = {"origin": [], "proxy": []}


def server(kind):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests[kind].append(self.path)
            self.send_response(200)
            self.send_header('x-portless', '1')
            self.end_headers()

        def log_message(self, *args):
            pass

    instance = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    return instance, thread


origin, origin_thread = server('origin')
proxy, proxy_thread = server('proxy')
env = {key: value for key, value in os.environ.items()
       if key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')}
env['http_proxy'] = f'http://127.0.0.1:{proxy.server_port}'
env['FIXTURE_PORT'] = str(origin.server_port)
try:
    subprocess.run(['bash', str(ROOT / 'scripts/scan-ports.sh'), '--probe', str(origin.server_port)],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, check=True)
    subprocess.run(['bash', '-c', '''
source scripts/lib/portless.sh
routes_json() { printf '%s' '[{"hostname":"private-project.localhost"}]'; }
PROBE_PORT=$FIXTURE_PORT
PROBE_SCHEME=http
portless_serving_routes
'''], cwd=ROOT, env=env, capture_output=True, timeout=5, check=True)
    assert not requests['proxy'], f"local requests reached proxy: {requests['proxy']}"
    assert len(requests['origin']) == 2, requests
    print('PASS scanner and Portless requests bypass proxy and reach local origin')
finally:
    for instance, thread in ((origin, origin_thread), (proxy, proxy_thread)):
        instance.shutdown()
        instance.server_close()
        thread.join()
