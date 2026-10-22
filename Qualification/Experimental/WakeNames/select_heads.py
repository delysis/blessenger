"""Select cached-embedding wake-name heads on validation rejection performance.

Does not score the test split. No detector is installed or activated.
"""
import argparse,json,time
from pathlib import Path
import numpy as np
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.neural_network import MLPClassifier
from threadpoolctl import threadpool_limits
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--dataset',type=Path,required=True)
p.add_argument('--embeddings',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--nonlinear',action='store_true')
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
manifest=json.loads((a.dataset/'manifest.json').read_text())
for key in ['voice','source']:
 partitions={}
 for row in manifest:partitions.setdefault(row[key],set()).add(row['split'])
 assert all(len(v)==1 for v in partitions.values())
# Exclude held-out test examples before fitting, transforming, or scoring.
keep=np.array([r['split']!='test' for r in manifest]);e=np.load(a.embeddings,mmap_mode='r')[keep]
rows=[r for r in manifest if r['split']!='test'];labels=np.array([r['label'] for r in rows]);train=np.array([r['split']=='train' for r in rows]);truth=labels[~train]
features={'flatten':e.reshape(len(e),-1),'pool':np.concatenate([e.mean(1),e.max(1)],axis=1)}
trials=[];best=None;start=time.monotonic()
with threadpool_limits(limits=2):
 for kind,x in features.items():
  candidates=[('linear',c,LogisticRegression(C=c,max_iter=2000,random_state=42)) for c in [.001,.01,.1,1]]
  if a.nonlinear and kind=='pool':
   candidates += [('mlp32',alpha,MLPClassifier(hidden_layer_sizes=(32,),activation='relu',solver='lbfgs',alpha=alpha,max_iter=400,random_state=42)) for alpha in [.01,.1,1,10]]
  for classifier,c,estimator in candidates:
   model=make_pipeline(StandardScaler(),estimator);model.fit(x[train],labels[train]);prob=model.predict_proba(x[~train]);classes=model[-1].classes_;order=np.argsort(prob,axis=1);top=order[:,-1];confidence=prob[np.arange(len(prob)),top];gap=confidence-prob[np.arange(len(prob)),order[:,-2]]
   choices=[]
   for threshold in [0,.2,.3,.4,.5,.6,.7,.8,.9,.95,.99,1.01]:
    for margin in [0,.1,.2,.3,.5]:
     answer=classes[top].copy();answer[(confidence<threshold)|(gap<margin)]='other';wrong=int(np.sum((answer!='other')&(answer!=truth)));correct=int(np.sum((answer!='other')&(answer==truth)));choices.append((wrong,-correct,threshold,margin))
   wrong,negative,threshold,margin=min(choices);rank=(wrong,negative)
   trial=dict(features=kind,classifier=classifier,regularization=c,wrong_activations=wrong,correct_detections=-negative,positive_clips=int(np.sum(truth!='other')),negative_clips=int(np.sum(truth=='other')),threshold=threshold,margin=margin);trials.append(trial)
   if best is None or rank<best[0]:best=(rank,model,trial)
_,model,chosen=best
report=dict(scope='Validation only; held-out test not scored; not acoustic or streaming acceptance',seconds=time.monotonic()-start,trials=trials,chosen=chosen)
(a.output/'receipt.json').write_text(json.dumps(report,indent=2))
head=dict(classes=model[-1].classes_.tolist(),features=chosen['features'],classifier=chosen['classifier'],rejection={k:chosen[k] for k in ['threshold','margin']},mean=model[0].mean_.tolist(),scale=model[0].scale_.tolist())
if chosen['classifier']=='linear':
 head.update(coefficients=model[-1].coef_.tolist(),intercept=model[-1].intercept_.tolist())
else:
 head.update(weights=[w.tolist() for w in model[-1].coefs_],biases=[b.tolist() for b in model[-1].intercepts_],activation='relu')
 # Verify exported matrix orientation and nonlinear head against sklearn.
 z=(features[chosen['features']][~train]-np.array(head['mean']))/np.array(head['scale'])
 for i,(w,b) in enumerate(zip(head['weights'],head['biases'])):
  z=z@np.array(w)+np.array(b)
  if i<len(head['weights'])-1:z=np.maximum(z,0)
 z=np.exp(z-z.max(axis=1,keepdims=True));z/=z.sum(axis=1,keepdims=True)
 assert np.allclose(z,model.predict_proba(features[chosen['features']][~train]),rtol=1e-6,atol=1e-8)

(a.output/'head.json').write_text(json.dumps(head))
print(json.dumps(report,indent=2))
