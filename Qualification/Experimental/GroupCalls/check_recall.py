"""Semantic gate after the isolated Peter-age / Gabor-recall app journey."""
import argparse,json,re
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('root',type=Path);a=p.parse_args()
contacts=['51F43A46-D1AB-5F92-A9B1-E08CCBD61C82','A9D82286-78A6-5CF4-96CA-E870242ED744']
failures=[]
for contact in contacts:
 paths=list((a.root/'Runtime'/'Contacts'/contact/'Calls').rglob('TRANSCRIPT'))
 if len(paths)!=1:
  failures.append(f'{contact}: expected one isolated call transcript, found {len(paths)}');continue
 h=json.loads(json.loads(paths[0].read_text())['historyJSON'])
 replies=[' '.join(c.get('text','') for c in m['content']) for m in h if m['role']=='assistant']
 if not replies or not re.search(r'\b(?:73|seventy[ -]three)\b',replies[-1],re.I):
  failures.append(f'{contact}: wrong age recall: {replies[-1] if replies else "no reply"}')
print(json.dumps({'passed':not failures,'failures':failures},indent=2))
raise SystemExit(bool(failures))
