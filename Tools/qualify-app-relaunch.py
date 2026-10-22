#!/usr/bin/env python3
"""Force-terminate an idle isolated packaged app, check exact transcripts, then test spoken recall."""
import argparse,hashlib,importlib.util,json,os,signal,subprocess,time,wave
from pathlib import Path
from call_content_checks import histories,check_new_content
spec=importlib.util.spec_from_file_location('ctl',Path(__file__).with_name('blessenger-control.py'));ctl=importlib.util.module_from_spec(spec);spec.loader.exec_module(ctl)
p=argparse.ArgumentParser();p.add_argument('directory',type=Path);a=p.parse_args();root=a.directory.resolve();checks=[]
def cmd(op,**kw):
 r=ctl.request(root,dict(operation=op,**kw),timeout=20)
 with (root/'relaunch-journey.jsonl').open('a') as f:f.write(json.dumps({'time':time.time(),'operation':op,'args':kw,'result':r})+'\n')
 return r
def wait(predicate,seconds=120):
 until=time.monotonic()+seconds
 while time.monotonic()<until:
  s=cmd('status')
  if predicate(s):return s
  time.sleep(.2)
 raise AssertionError('Timeout: '+repr(s))
def hashes():
 return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('Runtime/Contacts/*/Calls/Conversations-v3/*/TRANSCRIPT')}
try:
 s=cmd('status');assert s['syntheticInput'] and s['outputMuted'] and not s['inCall'] and not s['busy'] and not s['responding'] and not s['playingNote'],s
 package=json.loads((root/'package.json').read_text());exe=Path(package['executable']);assert hashlib.sha256(exe.read_bytes()).hexdigest()==package['sha256']
 before=hashes();assert before
 (root/'pretermination-transcript-hashes.json').write_text(json.dumps(before,indent=2))
 pid=int((root/'pid').read_text());os.kill(pid,signal.SIGKILL)
 for _ in range(100):
  try:os.kill(pid,0);time.sleep(.05)
  except ProcessLookupError:break
 else:raise AssertionError('Isolated process did not exit')
 env=os.environ.copy();env['BLESSENGER_QUALIFICATION_DIRECTORY']=str(root)
 for k in ['CALL_GEMMA_SPECULATION_THRESHOLD','CALL_GEMMA_ENDPOINT_THRESHOLD','CALL_GEMMA_AUDIO_TAIL_MS','CALL_GEMMA_CONFIRMATION_FRAMES']:env.pop(k,None)
 with (root/'process-relaunch.log').open('w') as f:process=subprocess.Popen([str(exe)],env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
 (root/'pid').write_text(str(process.pid));wait(lambda s:s['ready'] and not s['busy'])
 after=hashes();(root/'postrestart-transcript-hashes.json').write_text(json.dumps(after,indent=2));assert before==after,'Canonical transcripts changed during idle forced restart'
 checks.append('exact canonical transcript hashes survived forced idle termination and restart')
 people=cmd('contacts')['contacts'];fixtures=Path(__file__).resolve().parents[1]/'Qualification/Fixtures/audio-content'
 for name,filename,answer in [('Gabor Maté','recall-age.wav',r'\b(?:forty|40)\b'),('Bessel van der Kolk','recall-work.wav',r'\b(?:five|5)\b')]:
  contact=next(x['id'] for x in people if x['name']==name)
  cmd('create_chat',contacts=[contact]);cmd('call',id=contact)
  wait(lambda s:s['inCall'] and not s['dialing'] and not s['responding'] and not s['recovering'])
  baseline=histories(root);count=cmd('status')['completedTurns'];audio=fixtures/filename
  cmd('inject_audio',path=str(audio))
  with wave.open(str(audio),'rb') as w:duration=w.getnframes()/w.getframerate()
  time.sleep(duration+.5)
  wait(lambda s:s['inCall'] and s['completedTurns']>count and not s['responding'] and not s['recovering'] and not s['pendingTurns'])
  replies=check_new_content(root,baseline,answer);checks.append({'spokenRecall':name,'replies':replies})
  cmd('hangup');wait(lambda s:not s['inCall'] and not s['busy'])
 (root/'relaunch-result.json').write_text(json.dumps({'passed':True,'checks':checks,'scope':'Idle forced termination; exact transcript recovery and real 12B app spoken recall with synthetic PCM. Not an in-flight journal/cache fault injection.'},indent=2))
except Exception as e:
 (root/'relaunch-result.json').write_text(json.dumps({'passed':False,'checks':checks,'error':str(e)},indent=2))
 try:cmd('hangup')
 except Exception:pass
 raise
