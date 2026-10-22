#!/usr/bin/env python3
"""Loopback-only browser qualification proxy; validates the app's TLS certificate.
No pairing secret, provider token, SDP, or conversation text is written to disk.
"""
import http.server, http.client, json, pathlib, socket, ssl, sys
root=pathlib.Path(sys.argv[1]); port=int(sys.argv[2]); source=pathlib.Path(__file__).resolve().parent
config=json.loads((root/'configuration.json').read_text())
context=ssl.create_default_context(cafile=str(root/'ca.pem'))
origin=f'http://127.0.0.1:{port}'
allowed={'/api/rtc/start','/api/rtc/offer','/api/rtc/candidates','/api/rtc/end','/api/call','/api/call/end'}
def request(path,body=None):
    con=http.client.HTTPSConnection(config['host'],config['port'],context=context,timeout=25)
    con.sock=context.wrap_socket(socket.create_connection(('127.0.0.1',config['port']),timeout=25),server_hostname=config['host'])
    authority=f"{config['host']}:{config['port']}"
    con.request('POST' if body is not None else 'GET',path,body,{'Host':authority,'Origin':'https://'+authority,'Cookie':'blessenger='+config['session'],'Content-Type':'application/json'})
    response=con.getresponse(); status=response.status; data=response.read(); con.close(); return status,data
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def respond(self,status,data,kind='application/json'):
        self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
    def do_GET(self):
        files={'/':(source/'app.html','text/html'),'/probe.js':(source/'app.js','text/javascript'),'/rtc.js':(source.parent.parent/'Sources/CallGemma/Resources/Web/companion-rtc.js','text/javascript'),'/call-audio.js':(source.parent.parent/'Sources/CallGemma/Resources/Web/companion-call-audio.js','text/javascript')}
        if self.path in files:
            path,kind=files[self.path];self.respond(200,path.read_bytes(),kind);return
        self.respond(404,b'{}')
    def do_POST(self):
        if self.headers.get('Origin')!=origin or self.headers.get('Content-Type')!='application/json':self.respond(403,b'{}');return
        length=int(self.headers.get('Content-Length','0'))
        if not 0<=length<=300000:self.respond(413,b'{}');return
        data=self.rfile.read(length)
        try:
            if self.path=='/fixture':
                status,value=request('/api/state');assert status==200
                value=json.loads(value);assert not value['inCall'] and value['ready']
                person=next(p['id'] for p in value['contacts'] if p['name']=='Peter Levine')
                thread=next(t['id'] for t in value['threads'] if t['participants']==[person])
                self.respond(200,json.dumps({'thread':thread}).encode());return
            if self.path not in allowed:self.respond(404,b'{}');return
            status,result=request(self.path,data);self.respond(status,result)
        except Exception as error:self.respond(502,json.dumps({'error':type(error).__name__}).encode())
http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
