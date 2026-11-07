import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.parse

config=json.loads(subprocess.check_output(['nix','eval','--json','--file','shared/nix-caches.nix']))
target=subprocess.check_output(['nix','eval','--raw','--no-update-lock-file','.#nixosConfigurations.jupiter.config.system.build.toplevel.outPath','--option','max-jobs','0','--option','builders',''],text=True).strip()
allowed=set(json.loads(Path('scripts/r2-probe-objects.json').read_text()))|{'nix-cache-info'}
if target[11:43]+'.narinfo' not in allowed:
    raise ValueError('Probe target differs from the published generation')
print('Proxy variable presence:',{key:bool(value) for key,value in os.environ.items() if 'proxy' in key.lower()},flush=True)
subprocess.run(['nix','--version'],check=True)
for backlog,connections in [(5,25),(128,25),(128,4)]:
    requests=[]
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if urllib.parse.urlsplit(self.path).path.removeprefix('/') not in allowed:
                self.send_error(404)
                return
            self.send_response(302)
            self.send_header('Location',config['ownSubstituter']+self.path)
            self.end_headers()
        do_HEAD=do_GET
        def log_message(self,*_): pass
    class Server(http.server.ThreadingHTTPServer):
        request_queue_size=backlog
    with Server(('127.0.0.1',0),Handler) as server, tempfile.TemporaryDirectory() as directory:
        thread=threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        sources=config['upstreamSubstituters']+[f'http://127.0.0.1:{server.server_port}']
        command=['nix-store','--store','local?root='+directory+'/store','--realise',target,'--dry-run',
                 '--option','always-allow-substitutes','true','--option','require-sigs','true',
                 '--option','max-jobs','0','--option','builders','',
                 '--option','substituters',' '.join(sources),
                 '--option','trusted-public-keys',' '.join(config['trustedPublicKeys']),
                 '--option','http-connections',str(connections)]
        start=time.monotonic()
        env={**os.environ,'XDG_CACHE_HOME':directory+'/cache'}
        print(json.dumps({'start_case':{'backlog':backlog,'connections':connections}}),flush=True)
        try:
            result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=60)
            outcome={'exit':result.returncode,'plan':[line for line in result.stderr.splitlines() if 'will be fetched' in line or 'will be built' in line or 'error:' in line],'stderr':result.stderr[-1000:] if result.returncode else ''}
        except subprocess.TimeoutExpired as error:
            outcome={'timeout':True,'stderr':str(error.stderr)[-1800:]}
        outcome.update({'backlog':backlog,'connections':connections,'seconds':round(time.monotonic()-start,3),'received':len(requests),'metadata_gets':sum(p.endswith('.narinfo') for p in requests)})
        print(json.dumps(outcome),flush=True)
        server.shutdown()
        thread.join()
