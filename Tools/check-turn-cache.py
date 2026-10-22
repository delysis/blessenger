#!/usr/bin/env python3
"""Check installed-app TURN cache reuse without logging secrets or placing calls."""
import http.client,json,socket,ssl,time
from pathlib import Path
root=Path.home()/'Library/Application Support/Blessenger/Companion'
c=json.loads((root/'configuration.json').read_text())
ctx=ssl.create_default_context(cafile=str(root/'ca.pem'))
authority=f"{c['host']}:{c['port']}".lower()
previous=None
receipts=[]
for attempt in range(3):
 start=time.monotonic()
 h=http.client.HTTPSConnection(c['host'],c['port'],context=ctx,timeout=30)
 h.sock=ctx.wrap_socket(socket.create_connection(('127.0.0.1',c['port']),timeout=30),server_hostname=c['host'])
 h.request('POST','/api/ice',body='{}',headers={'Host':authority,'Origin':'https://'+authority,'Content-Type':'application/json','Cookie':'blessenger='+c['session']})
 r=h.getresponse();v=json.loads(r.read());h.close()
 assert r.status==200 and v['turnConfigured']
 if previous is not None:assert v==previous,'Provider credentials were regenerated instead of reused'
 previous=v
 receipts.append({'attempt':attempt+1,'status':r.status,'milliseconds':round((time.monotonic()-start)*1000)})
print(json.dumps({'identicalCredentialsAcrossThreeRequests':True,'requests':receipts},indent=2))
