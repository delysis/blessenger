#!/usr/bin/env python3
import argparse,importlib.util,json,time,wave,struct,sys,shutil
from pathlib import Path
from call_content_checks import histories, check_new_content, retained_audio_seconds
spec=importlib.util.spec_from_file_location('ctl',Path(__file__).with_name('blessenger-control.py'));ctl=importlib.util.module_from_spec(spec);spec.loader.exec_module(ctl)
parser=argparse.ArgumentParser(description='Exercise an isolated packaged app with muted synthetic audio; this does not qualify microphone acoustics or spoken-name routing.')
parser.add_argument('directory',type=Path)
parser.add_argument('--question',type=Path,required=True)
parser.add_argument('--two-utterances',type=Path,required=True)
parser.add_argument('--answer-pattern', default=r'\b(?:four|4)\b', help='Expected answer to the known single-utterance audio question')
parser.add_argument('--question-set', type=Path, help='JSON array of WAV paths and expected answer regexes for distinct consecutive questions')
parser.add_argument('--group-question-set', type=Path, help='Additional domain-appropriate audio cases for clinical personas; does not replace the direct-call regression cases')
parser.add_argument('--expect-endpoint', help='JSON subset of the endpoint settings reported by the packaged app')
args=parser.parse_args()
root=args.directory.resolve();checks=[]; content_baseline={}
def cmd(op,**kw):
 result=ctl.request(root,dict(operation=op,**kw),timeout=15)
 with (root/'journey.jsonl').open('a') as f:f.write(json.dumps({'time':time.time(),'operation':op,'args':kw,'result':result})+'\n')
 return result
def wait(test,seconds=120,live=False):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  s=cmd('status')
  if live: check_new_content(root, content_baseline)
  if live and not s['inCall']:raise RuntimeError('Unexpected disconnect: '+json.dumps(s))
  if test(s):return s
  time.sleep(.2)
 raise RuntimeError('Timeout: '+json.dumps(s))
def idle():return wait(lambda s:s['inCall'] and not s['dialing'] and not s['responding'] and not s['recovering'] and not s['pendingTurns'],live=True)
def stop():
 cmd('hangup');wait(lambda s:not s['inCall'] and not s['busy'])
 checks.append('explicit hang-up completed')
def inject():
 with wave.open(str(fixture),'rb') as w:pcm=struct.unpack('<'+'h'*w.getnframes(),w.readframes(w.getnframes()))
 # Fixed fixture signal reference, independent of the tuned VAD thresholds.
 reference=max(i for i,x in enumerate(pcm) if abs(x)>327)
 cmd('inject_audio',path=str(fixture),referenceEnd=reference)
try:
 ready=wait(lambda s:s['ready'] and not s['busy'])
 assert ready['model']=='litert-community/gemma-4-12B-it-litert-lm',ready
 assert ready['syntheticInput'] and ready['outputMuted'],ready
 if args.expect_endpoint:
  for key,value in json.loads(args.expect_endpoint).items():
   assert abs(ready['endpoint'][key]-value)<1e-6,(key,ready['endpoint'])
 people=cmd('contacts')['contacts'];bessel,gabor=[next(p['id'] for p in people if p['name']==name) for name in ['Bessel van der Kolk','Gabor Maté']]
 def case_path(case, manifest):
  path=Path(case['path'])
  return path if path.is_absolute() or manifest is None else manifest.parent/path
 def prepare_question(path, index):
  with wave.open(str(path),'rb') as w:
   assert (w.getnchannels(),w.getsampwidth(),w.getframerate())==(1,2,16000)
   pcm=list(struct.unpack('<'+'h'*w.getnframes(),w.readframes(w.getnframes())))
  start=next(i for i,x in enumerate(pcm) if abs(x)>300);pcm=pcm[max(0,start-160):]+[0]*16000
  fixture=root/('question-'+str(index)+'.wav')
  with wave.open(str(fixture),'wb') as w:
   w.setparams((1,2,16000,0,'NONE','not compressed'));w.writeframes(struct.pack('<'+'h'*len(pcm),*pcm))
  return fixture,len(pcm)/16000
 cases=json.loads(args.question_set.read_text()) if args.question_set else [{'path':str(args.question),'answer':args.answer_pattern}]*3
 fixtures=[(*prepare_question(case_path(case,args.question_set),i),case['answer']) for i,case in enumerate(cases)]
 group_cases=json.loads(args.group_question_set.read_text()) if args.group_question_set else None
 group_fixtures=[(*prepare_question(case_path(case,args.group_question_set), 'group-'+str(i)),case['answer']) for i,case in enumerate(group_cases)] if group_cases else fixtures
 fixture,fixture_duration,answer_pattern=fixtures[0]
 direct=cmd('create_chat',contacts=[bessel])['id'];cmd('call',id=bessel);wait(lambda s:s['inCall'] and not s['dialing'])
 two=root/'two-utterances.wav';shutil.copyfile(args.two_utterances,two)
 cmd('inject_audio',path=str(two))
 with wave.open(str(two),'rb') as w:duration=w.getnframes()/w.getframerate()
 time.sleep(duration+1);idle();checks.append('direct-call greeting barge-in and two utterances survived')
 for i,(fixture,fixture_duration,answer_pattern) in enumerate(fixtures):
  content_baseline=histories(root)
  before=idle()['completedTurns'];inject()
  time.sleep(fixture_duration+1)
  wait(lambda s:s['completedTurns']>before and not s['responding'] and not s['recovering'] and not s['pendingTurns'],live=True)
  replies=check_new_content(root, content_baseline, answer_pattern)
  with (root/'verified-answers.jsonl').open('a') as f:f.write(json.dumps({'fixture':str(fixture),'expected':answer_pattern,'replies':replies})+'\n')
  checks.append('steady response with correct content '+str(i+1))
 stop()
 group=cmd('create_chat',contacts=[bessel,gabor])['id'];cmd('call',id=bessel);wait(lambda s:s['inCall'] and not s['dialing']);idle()
 time.sleep(1.1)
 quiet=cmd('status');assert 'Speech starts: 0' in quiet['audio'] and 'utterances: 0' in quiet['audio'],quiet
 checks.append('new call did not replay an old injected utterance')
 for j,who in enumerate([gabor,bessel]):
  fixture,fixture_duration,answer_pattern=group_fixtures[j%len(group_fixtures)]
  content_baseline=histories(root)
  before=cmd('status')['completedTurns'];cmd('participant',id=who);inject()
  time.sleep(fixture_duration+1)
  wait(lambda s:s['participant']==who and s['completedTurns']>before and not s['responding'] and not s['recovering'] and not s['pendingTurns'],live=True)
  replies=check_new_content(root, content_baseline, answer_pattern)
  with (root/'verified-answers.jsonl').open('a') as f:f.write(json.dumps({'fixture':str(fixture),'expected':answer_pattern,'replies':replies})+'\n')
  if group_cases:
   minimum=group_cases[j%len(group_cases)].get('minimumRetainedAudioSeconds',0)
   retained=retained_audio_seconds(root,content_baseline)
   assert retained>=minimum,f'Confirmed user audio lost: {retained:.3f}s retained, minimum {minimum:.3f}s'
   checks.append(f'group input preserved {retained:.3f}s of committed audio')
  checks.append('group participant response with correct content '+who)
 cmd('select',id=direct);assert cmd('status')['inCall'];checks.append('switching visible conversation retained call');stop()
 cmd('call',id=bessel);wait(lambda s:s['inCall'] and not s['dialing']);stop();checks.append('repeated call and hang-up during greeting')
 (root/'scenario-result.json').write_text(json.dumps({'passed':True,'checks':checks,'scope':'packaged app, synthetic PCM, muted; spoken-name routing not implemented'},indent=2))
except Exception as e:
 (root/'scenario-result.json').write_text(json.dumps({'passed':False,'checks':checks,'error':str(e)},indent=2))
 try:
  cmd('hangup');wait(lambda s:not s['inCall'] and not s['busy'])
 except Exception as cleanup_error:
  (root/'cleanup-failure.txt').write_text(str(cleanup_error))
 raise
