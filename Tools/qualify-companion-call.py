#!/usr/bin/env python3
"""Real app/12B transport check with a timed simulated phone renderer, not acoustic acceptance."""
import argparse,http.client,json,pathlib,ssl,time
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('receipt',type=pathlib.Path);a=p.parse_args()
c=json.loads((a.root/'Companion/configuration.json').read_text());host=c['host'];port=c['port'];origin=f'https://{host}:{port}';context=ssl.create_default_context(cafile=str(a.root/'Companion/ca.pem'));cookie=''
def req(path,body=None):
    con=http.client.HTTPSConnection(host,port,context=context,timeout=15)
    headers={'Origin':origin,'Cookie':cookie,'Content-Type':'application/json'}
    con.request('POST' if body is not None else 'GET',path,json.dumps(body) if body is not None else None,headers)
    response=con.getresponse();data=response.read();con.close()
    assert response.status<300,(response.status,data.decode())
    return json.loads(data),dict(response.getheaders())
_,headers=req('/api/pair',{'invite':c['invite']});cookie=headers['Set-Cookie'].split(';')[0]
state,_=req('/api/state');results=[]
for name in ['Peter Levine','Gabor Maté']:
    person=next(c for c in state['contacts'] if c['name']==name)
    thread,_=req('/api/chats',{'contacts':[person['id']]})
    call,_=req('/api/call',{'thread':thread['id'],'echoCancellation':True})
    start=time.monotonic();sequence=0;scheduled=[];seen=set();total=0;first=None;lastPacket=None;epoch=call['epoch'];end=start+45
    try:
        while time.monotonic()<end:
            now=time.monotonic();ack=[]
            while scheduled and scheduled[0][1]<=now:ack.append(scheduled.pop(0)[0])
            reply,_=req('/api/call/audio',{'id':call['id'],'epoch':epoch,'sequence':sequence,'samples':[0.0]*512,'acknowledged':ack});sequence+=1
            assert not reply.get('closed'),reply
            if reply['epoch']!=epoch:epoch=reply['epoch'];scheduled=[];seen=set()
            for packet in reply['packets']:
                if packet['sequence'] in seen:continue
                seen.add(packet['sequence']);total+=len(packet['samples']);first=first or now;lastPacket=now
                scheduled.append((packet['sequence'],max(now,scheduled[-1][1] if scheduled else now)+len(packet['samples'])/24000))
            if total>12000 and not scheduled and lastPacket and now-lastPacket>2:break
            time.sleep(max(0,0.032-(time.monotonic()-now)))
        assert total>12000,(name,'No complete greeting',total)
        results.append({'contact':name,'frames':total,'firstPacketMS':round((first-start)*1000),'status':'received and render-acknowledged'})
    finally:req('/api/call/end',{'id':call['id']})
    time.sleep(2)
a.receipt.write_text(json.dumps({'calls':results,'scope':'Actual app with Gemma 4 12B; HTTPS client simulates phone rendering. No physical speaker/microphone evidence.'},indent=2)+'\n');print(json.dumps(results,indent=2))
