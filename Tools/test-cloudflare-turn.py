#!/usr/bin/env python3
"""Paired app credential issuance plus relay-only native PCM/control roundtrip.
No credentials, cookies, or SDP are written to a receipt or passed in argv.
"""
import http.client,json,socket,ssl,subprocess,sys
from pathlib import Path
config_root,binary,receipt=map(Path,sys.argv[1:4])
config=json.loads((config_root/'configuration.json').read_text())
ctx=ssl.create_default_context()
cert=(config_root/'Blessenger.cer').read_bytes()
ctx.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert(cert) if not cert.startswith(b'-----') else cert.decode())
def request(paired):
 h=http.client.HTTPSConnection(config['host'],config['port'],context=ctx,timeout=30)
 h.sock=ctx.wrap_socket(socket.create_connection(('127.0.0.1',config['port']),timeout=30),server_hostname=config['host'])
 authority=f"{config['host']}:{config['port']}"
 headers={'Host':authority,'Origin':'https://'+authority,'Content-Type':'application/json'}
 if paired:headers['Cookie']='blessenger='+config['session']
 h.request('POST','/api/ice',body='{}',headers=headers);r=h.getresponse();data=r.read();status=r.status;h.close()
 return status,json.loads(data)
stage='initialization'
written=False
try:
 stage='unauthenticated request'
 unauthorized,_=request(False)
 assert unauthorized==401
 stage='paired credential request'
 status,value=request(True)
 assert status==200 and value['turnConfigured'] and value['expiresAt']
 stage='relay media exchange'
 result=subprocess.run([str(binary.resolve()),'--relay-long' if '--long-gather' in sys.argv[4:] else '--relay'],input=json.dumps(value['iceServers']),capture_output=True,text=True,timeout=75)
 # WebRTC logging can contain credentials or network addresses; retain only the
 # explicit structured result, never its stderr or a raw SDP dump.
 try: outcome=json.loads(result.stdout)
 except Exception:outcome={'passed':False,'error':'No structured relay result','timeoutStage':next((line for line in result.stderr.splitlines() if line in ['Timeout: offer candidates','Timeout: answer candidates','Timeout: set description','Timeout: create description','Timeout: audio A shutdown','Timeout: audio B shutdown']),None)}
 record={'unauthenticatedStatus':unauthorized,'pairedStatus':status,'turnConfigured':True,
  'relayExitCode':result.returncode,'relay':outcome,
  'scope':'Installed app issues expiring credentials; two native peers force relay-only Opus/control. Not an iPhone or actual persona call.'}
 receipt.write_text(json.dumps(record,indent=2)+'\n')
 written=True
 print(json.dumps(record))
 assert result.returncode==0 and outcome['passed'] and outcome['relayOnly']
except Exception as error:
 if not written:
  record={'passed':False,'stage':stage,'errorType':type(error).__name__,'scope':'Installed app credential and relay diagnostic'}
  receipt.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
 raise SystemExit(1)
