"""Offline wake-name feature comparison. No model is activated in the app."""
import argparse, hashlib, json, sys, time, wave
from pathlib import Path
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, confusion_matrix
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

p = argparse.ArgumentParser()
for name in ['source','models','dataset','output']:
    p.add_argument('--'+name, type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
sys.path.insert(0,str(a.source))
from openwakeword.utils import AudioFeatures
manifest = json.loads((a.dataset/'manifest.json').read_text())
assert {r['split'] for r in manifest} == {'train','validation','test'}
for identity in ['source','voice']:
    partition = {}
    for row in manifest: partition.setdefault(row[identity],set()).add(row['split'])
    assert all(len(s)==1 for s in partition.values()), f'{identity} leaks across splits'
clips=[]
for row in manifest:
    with wave.open(str(a.dataset/row['path'])) as f:
        assert (f.getframerate(),f.getnchannels(),f.getsampwidth())==(16000,1,2)
        clips.append(np.frombuffer(f.readframes(f.getnframes()),dtype='<i2'))
extractor = AudioFeatures(melspec_model_path=str(a.models/'melspectrogram.onnx'),
                         embedding_model_path=str(a.models/'embedding_model.onnx'), ncpu=2)
start=time.monotonic()
embeddings=extractor.embed_clips(np.stack(clips),batch_size=16,ncpu=2)
np.save(a.output/'embeddings.npy',embeddings)
feature_seconds=time.monotonic()-start
labels=np.array([r['label'] for r in manifest])
splits=np.array([r['split'] for r in manifest])
features={'flatten':embeddings.reshape(len(clips),-1),
          'pool':np.concatenate([embeddings.mean(axis=1),embeddings.max(axis=1)],axis=1)}
trials=[]; best=None
for kind,x in features.items():
    for c in [.001,.01,.1,1]:
        model=make_pipeline(StandardScaler(),LogisticRegression(C=c,max_iter=2000,random_state=42))
        model.fit(x[splits=='train'],labels[splits=='train'])
        validation=accuracy_score(labels[splits=='validation'],model.predict(x[splits=='validation']))
        trials.append(dict(features=kind,C=c,validation_accuracy=float(validation)))
        if best is None or validation>best[0]:best=(validation,kind,c,model)
score,kind,c,model=best
x=features[kind]; pred=model.predict(x[splits=='test']); classes=model[-1].classes_.tolist()
# Tune rejection only on validation. Unknown speech must be allowed to remain
# unknown; a closed-set argmax is not a wake-name detector.
validation_prob = model.predict_proba(x[splits=='validation'])
validation_labels = labels[splits=='validation']
class_array = model[-1].classes_
def decide(prob, threshold, margin):
    order = np.argsort(prob, axis=1)
    best_index = order[:, -1]
    confidence = prob[np.arange(len(prob)), best_index]
    separation = confidence - prob[np.arange(len(prob)), order[:, -2]]
    answer = class_array[best_index].copy()
    answer[(confidence < threshold) | (separation < margin)] = 'other'
    return answer
choices=[]
for threshold in [0,.2,.3,.4,.5,.6,.7,.8,.9,.95,.99,1.01]:
    for margin in [0,.1,.2,.3,.5]:
        answer=decide(validation_prob,threshold,margin)
        wrong=int(np.sum((answer!='other') & (answer!=validation_labels)))
        correct=int(np.sum((answer!='other') & (answer==validation_labels)))
        choices.append((wrong, -correct, threshold, margin))
# First minimize incorrect activations; then retain the most correct detections.
wrong,negative_correct,threshold,margin=min(choices)
test_prob=model.predict_proba(x[splits=='test'])
accepted=decide(test_prob,threshold,margin)
truth=labels[splits=='test']
rejection=dict(threshold=threshold,margin=margin,validation_wrong_activations=wrong,
    validation_correct_detections=-negative_correct,
    test_correct_detections=int(np.sum((accepted!='other') & (accepted==truth))),
    test_wrong_name_detections=int(np.sum((accepted!='other') & (truth!='other') & (accepted!=truth))),
    test_false_activations=int(np.sum((accepted!='other') & (truth=='other'))),
    test_missed_names=int(np.sum((accepted=='other') & (truth!='other'))),
    test_positive_clips=int(np.sum(truth!='other')),test_negative_clips=int(np.sum(truth=='other')))
report=dict(scope='Synthetic held-out voice test only; not streaming or acoustic acceptance',
    rejection=rejection,
    feature_seconds=feature_seconds,embedding_shape=list(embeddings.shape),validation_trials=trials,
    chosen=dict(features=kind,C=c),test_accuracy=float(accuracy_score(labels[splits=='test'],pred)),
    classes=classes,test_confusion=confusion_matrix(labels[splits=='test'],pred,labels=classes).tolist(),
    files={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in [a.models/'embedding_model.onnx',a.models/'melspectrogram.onnx',a.dataset/'manifest.json']})
(a.output/'receipt.json').write_text(json.dumps(report,indent=2)+'\n')
head=dict(classes=classes,features=kind,rejection=dict(threshold=threshold,margin=margin),mean=model[0].mean_.tolist(),scale=model[0].scale_.tolist(),
          coefficients=model[-1].coef_.tolist(),intercept=model[-1].intercept_.tolist())
(a.output/'head.json').write_text(json.dumps(head)+'\n')
print(json.dumps(report,indent=2))
