#!/usr/bin/env python3
"""Exercise the actual app's authenticated HTTPS API; never disables TLS checks."""
import argparse,http.client,json,pathlib,ssl,time
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('receipt',type=pathlib.Path);p.add_argument('--note',type=pathlib.Path);a=p.parse_args()
c=json.loads((a.root/'Companion/configuration.json').read_text());host=c['host'];port=c['port'];origin=f'https://{host}:{port}'
context=ssl.create_default_context(cafile=str(a.root/'Companion/ca.pem'))
def request(path,body=None,cookie=None,extra=None):
    connection=http.client.HTTPSConnection(host,port,context=context,timeout=30)
    headers={'Origin':origin}
    if cookie:headers['Cookie']=cookie
    if extra:headers.update(extra)
    data=body if isinstance(body,bytes) else json.dumps(body).encode() if body is not None else None
    if data:headers.setdefault('Content-Type','application/json')
    connection.request('POST' if body is not None else 'GET',path,body=data,headers=headers)
    response=connection.getresponse();result=(response.status,dict(response.getheaders()),response.read());connection.close();return result
checks=[]
def check(name,test):assert test,name;checks.append(name)
status,_,body=request('/');check('HTML is served over verified TLS',status==200 and b'Blessenger' in body)
status,_,_=request('/api/state');check('Private state requires pairing',status==401)
status,_,_=request('/api/pair',{'invite':'invalid'});check('Invalid pairing denied',status==401)
status,_,_=request('/api/pair',{'invite':c['invite']},extra={'Origin':'https://attacker.invalid'});check('Cross-origin pairing denied',status==403)
status,headers,_=request('/api/pair',{'invite':c['invite']});check('Pairing succeeds',status==200)
cookie=headers['Set-Cookie'].split(';')[0]
check('Cookie is secure and inaccessible to JavaScript',all(v in headers['Set-Cookie'] for v in ['Secure','HttpOnly','SameSite=Strict']))
status,_,body=request('/api/state',cookie=cookie);state=json.loads(body);check('All fourteen real contacts present',status==200 and len(state['contacts'])==14)
status,_,body=request(state['contacts'][0]['avatar'],cookie=cookie);check('Actual contact avatar served',status==200 and body.startswith(b'\x89PNG'))
status,_,_=request('/api/state',cookie=cookie,extra={'Host':'attacker.invalid'});check('Host rebinding denied',status==403)
status,_,body=request('/manifest.webmanifest');check('Standalone manifest',status==200 and json.loads(body)['display']=='standalone')
status,_,_=request('/api/send',{'thread':'invalid','text':'test'},cookie);check('Invalid conversation rejected',status==400)
status,_,body=request('/api/chats',{'contacts':[state['contacts'][0]['id']]},cookie);check('Real chat created',status==200);thread=json.loads(body)['id']
status,_,body=request('/api/chats',{'contacts':[state['contacts'][0]['id']]},cookie);check('Direct chat reused',json.loads(body)['id']==thread)
status,_,body=request('/api/send',{'thread':thread,'text':'Reply with one sentence confirming that this message reached you.'},cookie);check('Message durably admitted',status==202 and json.loads(body)['accepted'])
deadline=time.monotonic()+90
while time.monotonic()<deadline:
    time.sleep(1);status,_,body=request('/api/state',cookie=cookie);state=json.loads(body)
    messages=[m for m in state['messages'] if m['thread']==thread]
    if messages and messages[-1]['sender'] and messages[-1]['text']:break
else:raise AssertionError('No actual model reply within 90 seconds')
check('Actual model reply',bool(messages[-1]['text']))
if a.note:
    before={m['id'] for m in state['messages']}
    status,_,body=request('/api/note',a.note.read_bytes(),cookie,{'Content-Type':'audio/wav','X-Blessenger-Thread':thread})
    check('Voice note durably admitted',status==202)
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        time.sleep(1);_,_,body=request('/api/state',cookie=cookie);state=json.loads(body)
        fresh=[m for m in state['messages'] if m['id'] not in before and m['thread']==thread]
        if any(m['sender'] and m['text'] for m in fresh):break
    else:raise AssertionError('No actual model reply to voice note')
    note=next(m for m in fresh if m['attachments'])
    status,_,body=request(note['attachments'][0]['url'],cookie=cookie)
    check('Voice note is playable and byte-preserved',status==200 and body==a.note.read_bytes())
    check('Real model replied to voice note',any(m['sender'] for m in fresh))
a.receipt.parent.mkdir(parents=True,exist_ok=True);a.receipt.write_text(json.dumps({'checks':checks,'reply':messages[-1]['text'],'limitations':['No physical iPhone check','No phone voice call qualification']},indent=2)+'\n');print('\n'.join('PASS '+x for x in checks))
