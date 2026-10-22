#!/usr/bin/env python3
"""Exercise recording and inline playback in the isolated packaged 12B app."""
import argparse, importlib.util, json, struct, time, wave
from pathlib import Path
from call_content_checks import corruption_reason
spec=importlib.util.spec_from_file_location('ctl',Path(__file__).with_name('blessenger-control.py'))
ctl=importlib.util.module_from_spec(spec);spec.loader.exec_module(ctl)
p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('--question',type=Path,required=True)
a=p.parse_args();root=a.directory.resolve();checks=[]
def cmd(op,**kw):
 result=ctl.request(root,dict(operation=op,**kw),timeout=15)
 with (root/'voice-note-journey.jsonl').open('a') as f:f.write(json.dumps({'time':time.time(),'operation':op,'args':kw,'result':result})+'\n')
 return result
def wait(predicate,seconds=120):
 until=time.monotonic()+seconds
 while time.monotonic()<until:
  state=cmd('status')
  if predicate(state):return state
  time.sleep(.1)
 raise AssertionError('Timed out: '+repr(state))
def playback(message):
 cmd('play_note',id=message['id'])
 s=wait(lambda s:s['playingNote']==message['id'] and s['noteDuration']>0 and s['notePosition']>0)
 cmd('play_note',id=message['id'])
 paused=cmd('status')['notePosition'];time.sleep(.25)
 assert abs(cmd('status')['notePosition']-paused)<.12,'Pause did not hold playback position'
 cmd('seek_note',fraction=.5)
 s=cmd('status');assert abs(s['notePosition']-s['noteDuration']*.5)<.2,s
 cmd('play_note',id=message['id'])
 wait(lambda s:s['playingNote']=='' or s['notePosition']>s['noteDuration']*.5+.1)
 cmd('stop_note');assert cmd('status')['playingNote']==''
 checks.append('inline play, pause, seek, resume and stop '+message['id'])
try:
 state=cmd('status');assert state['ready'] and not state['inCall'] and state['outputMuted']
 assert state['model']=='litert-community/gemma-4-12B-it-litert-lm'
 person=next(c for c in cmd('contacts')['contacts'] if c['name']=='Bessel van der Kolk')
 cmd('create_chat',contacts=[person['id']])
 cmd('record_start');cmd('inject_audio',path=str(a.question.resolve()))
 with wave.open(str(a.question),'rb') as w:duration=w.getnframes()/w.getframerate()
 time.sleep(duration+.4)
 recorded=Path(cmd('record_finish')['path'])
 # AVAudioFile writes IEEE float WAV; Python wave only accepts integer PCM.
 data=recorded.read_bytes();assert data[:4]==b'RIFF' and data[8:12]==b'WAVE'
 chunks={};offset=12
 while offset+8<=len(data):
  kind,size=struct.unpack_from('<4sI',data,offset);offset+=8
  chunks[kind]=data[offset:offset+size];offset+=size+(size%2)
 encoding,channels,rate,_,alignment,bits=struct.unpack_from('<HHIIHH',chunks[b'fmt '])
 assert encoding in (1,3) and rate==16000 and channels==1
 assert len(chunks[b'data'])//alignment>10000
 checks.append('shared capture produced retained playable WAV')
 job=cmd('send_audio',path=str(recorded))['job']
 state=wait(lambda s:s['jobs'].get(job) in ('completed','failed'))
 assert state['jobs'][job]=='completed',state
 messages=cmd('messages')['messages'];assert len(messages)==2,messages
 user,reply=messages;assert user['voiceNote'] and not user['text'];assert reply['voiceNote']
 assert not corruption_reason(reply['text']),reply
 assert 'four' in reply['text'].lower() or '4' in reply['text'],reply
 checks.append('recorded question received correct text-backed voice-note answer')
 playback(user);playback(reply)
 cmd('record_start');cmd('record_cancel');checks.append('recording cancellation')
 (root/'voice-note-result.json').write_text(json.dumps({'passed':True,'checks':checks,'scope':'actual app, synthetic capture, muted output'},indent=2))
except Exception as e:
 (root/'voice-note-result.json').write_text(json.dumps({'passed':False,'checks':checks,'error':str(e)},indent=2))
 for op in ['record_cancel','stop_note']:
  try:cmd(op)
  except Exception:pass
 raise
