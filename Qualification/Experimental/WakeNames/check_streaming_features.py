"""Compare offline versus 80 ms streaming features, using validation clips only."""
import argparse, json, sys, time, wave
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser(description=__doc__)
for name in ['source','models','dataset','trained','output']:
    p.add_argument('--'+name,type=Path,required=True)
a=p.parse_args()
if a.output.exists(): raise FileExistsError(a.output)
sys.path.insert(0,str(a.source))
from openwakeword.utils import AudioFeatures
manifest=json.loads((a.dataset/'manifest.json').read_text())
head=json.loads((a.trained/'head.json').read_text())
offline=np.load(a.trained/'embeddings.npy')
extractor=AudioFeatures(melspec_model_path=str(a.models/'melspectrogram.onnx'),embedding_model_path=str(a.models/'embedding_model.onnx'),ncpu=1)
mean=np.array(head['mean']);scale=np.array(head['scale']);weights=np.array(head['coefficients']);bias=np.array(head['intercept'])
def prediction(features):
    x=features.reshape(-1) if head['features']=='flatten' else np.concatenate([features.mean(axis=0),features.max(axis=0)])
    scores=weights@((x-mean)/scale)+bias
    return head['classes'][int(np.argmax(scores))]
rows=[];times=[]
for index,row in enumerate(manifest):
    if row['split']!='validation':continue
    with wave.open(str(a.dataset/row['path'])) as f:pcm=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2')
    extractor.reset()
    # Never admit reset's synthetic initial feature history. Read only the
    # last offline-sized window after the complete real clip has been fed.
    for offset in range(0,len(pcm),1280):
        start=time.monotonic();extractor(pcm[offset:offset+1280]);times.append((time.monotonic()-start)*1000)
    stream=extractor.get_features(offline.shape[1])[0]
    expected=offline[index]
    rows.append(dict(path=row['path'],label=row['label'],offline=prediction(expected),streaming=prediction(stream),
        relative_rmse=float(np.sqrt(np.mean((stream-expected)**2))/max(np.sqrt(np.mean(expected**2)),1e-12))))
report=dict(scope='Validation-only offline/streaming parity; not detection latency or app acceptance',
    frames=offline.shape[1],hop_ms=80,clips=len(rows),changed_predictions=sum(r['offline']!=r['streaming'] for r in rows),
    inference_ms=dict(p50=float(np.percentile(times,50)),p95=float(np.percentile(times,95)),max=max(times)),rows=rows)
a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='rows'},indent=2))
