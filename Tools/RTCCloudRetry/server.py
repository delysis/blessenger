import http.server,json,pathlib,http.client,socket,ssl
root=pathlib.Path(__file__).parent
web=root.parents[1]/'Sources/CallGemma/Resources/Web'
configroot=pathlib.Path.home()/'Library/Application Support/Blessenger/Companion'
c=json.loads((configroot/'configuration.json').read_text());authority=f"{c['host']}:{c['port']}".lower()
ctx=ssl.create_default_context(cafile=str(configroot/'ca.pem'))
def native(path,body=None):
 from urllib.parse import urlsplit
 origin=urlsplit(c['publicOrigin'])
 h=http.client.HTTPSConnection(origin.hostname,timeout=30)
 h.request('POST' if body is not None else 'GET',path,body=body,headers={'Origin':c['publicOrigin'],'Cookie':'blessenger='+c['session'],'Content-Type':'application/json'})
 r=h.getresponse();data=r.read();status=r.status;h.close();return status,data
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def respond(self,status,data,kind='application/json'):
  self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
 def do_GET(self):
  if self.headers.get('Host')!='localhost:8955':return self.respond(403,b'{}')
  if self.path=='/':return self.respond(200,(root/'index.html').read_bytes(),'text/html')
  if self.path=='/speech.wav':return self.respond(200,(root.parents[1]/'Qualification/Fixtures/audio-content/heldout-0.wav').read_bytes(),'audio/wav')
  if self.path in ['/rtc.js','/call-audio.js']:return self.respond(200,(web/('companion-'+self.path[1:])).read_bytes(),'text/javascript')
  if self.path=='/target':
   status,data=native('/api/state');state=json.loads(data)
   if status!=200 or state.get('inCall') or state.get('ready') is not True:return self.respond(409,b'{"error":"App is not ready or is busy"}')
   contact=next(x for x in state['contacts'] if x['name']=='Peter Levine')
   thread=next(x for x in state['threads'] if x['participants']==[contact['id']])
   return self.respond(200,json.dumps({'thread':thread['id']}).encode())
  self.respond(404,b'{}')
 def do_POST(self):
  if self.headers.get('Host')!='localhost:8955' or self.headers.get('Origin')!='http://localhost:8955':return self.respond(403,b'{}')
  if self.path not in ['/api/rtc/start','/api/rtc/offer','/api/rtc/candidates','/api/rtc/end','/api/rtc/report','/api/call','/api/call/end']:return self.respond(404,b'{}')
  length=int(self.headers.get('Content-Length','0'))
  if not 0<length<=300000:return self.respond(400,b'{}')
  try:status,data=native(self.path,self.rfile.read(length));self.respond(status,data)
  except Exception:self.respond(502,b'{"error":"Native request failed"}')
http.server.ThreadingHTTPServer(('127.0.0.1',8955),Handler).serve_forever()
