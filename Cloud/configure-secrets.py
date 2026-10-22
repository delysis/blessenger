"""Store the host credential in Keychain; pipe only SHA-256 verifiers to Wrangler."""
from pathlib import Path
import hashlib,json,secrets,subprocess,os
root=Path.home()/'Library/Application Support/Blessenger/Companion'
c=json.loads((root/'configuration.json').read_text())
lookup=subprocess.run(['/usr/bin/security','find-generic-password','-s','Blessenger.CloudGateway','-a','host','-w'],capture_output=True,text=True)
if lookup.returncode==0: token=lookup.stdout.strip()
else:
 token=secrets.token_hex(32)
 result=subprocess.run(['/usr/bin/security','-i'],input=f'add-generic-password -s Blessenger.CloudGateway -a host -w {token}\n',capture_output=True,text=True)
 if result.returncode!=0 or subprocess.run(['/usr/bin/security','find-generic-password','-s','Blessenger.CloudGateway','-a','host'],capture_output=True).returncode: raise RuntimeError('Keychain storage failed')
values={name:hashlib.sha256(value.encode()).hexdigest() for name,value in [('HOST_HASH',token),('INVITE_HASH',c['invite']),('SESSION_HASH',c['session'])]}
# No credentials or pairing keys are printed or written to disk.
result=subprocess.run(['./node_modules/.bin/wrangler','secret','bulk'],input=json.dumps(values),text=True,env={**os.environ,'WRANGLER_SEND_METRICS':'false'})
raise SystemExit(result.returncode)
