import argparse
import importlib.metadata
import json
import hashlib
import importlib.resources
import torch,numpy as np,coremltools as ct
from pathlib import Path
from pocket_tts import TTSModel
from exporter_source import patched_exporter
parser = argparse.ArgumentParser(description="Export corrected PocketTTS conditioning models")
parser.add_argument('--source', type=Path, required=True, help='Original pinned upstream source file')
parser.add_argument('--output', type=Path, required=True, help='New output directory; never overwritten')
parser.add_argument('--widths', type=int, nargs='+', choices=[4,16,256], default=[16,256])
args_cli = parser.parse_args()
versions = {name: importlib.metadata.version(name) for name in ['torch','coremltools','numpy','pocket-tts']}
expected = {'torch':'2.7.1', 'coremltools':'9.0', 'numpy':'2.5.4', 'pocket-tts':'4.0.1'}
if versions != expected:
 raise RuntimeError(f'Use the qualified exporter dependencies: {expected}; found {versions}')
args_cli.output.mkdir(parents=True, exist_ok=False)
(args_cli.output / 'environment.json').write_text(json.dumps(versions, indent=2)+'\n')
with patched_exporter(args_cli.source) as TraceableCondPrefillANE:
 provenance = json.loads((Path(__file__).resolve().parent / 'provenance.json').read_text())
 config = importlib.resources.files('pocket_tts').joinpath('config/english_2026-04.yaml').read_bytes()
 if hashlib.sha256(config).hexdigest() != provenance['english_config_sha256']:
  raise RuntimeError('English model configuration differs from the qualified weights/tokenizer pins')
 print('Loading matching April English weights',flush=True)
 model=TTSModel.load_model(language='english_2026-04',temp=.7,sampler_decode_steps=8).eval()
 for width in args_cli.widths:
  print('Export width',width,flush=True)
  m=TraceableCondPrefillANE.from_flowlm(model.flow_lm,max_seq_len=512,t_max=width).eval()
  args=[torch.zeros(1,width,1024),torch.tensor([float(min(width,11))])]
  inputs=[ct.TensorType(name='conditioning',shape=(1,width,1024),dtype=np.float32),ct.TensorType(name='valid_len',shape=(1,),dtype=np.float32)]
  outputs=[]
  for i in range(6):
   args += [torch.zeros(1,512,16,64),torch.zeros(1,512,16,64),torch.zeros(1)]
   for name,shape in [(f'k_cache{i}',(1,512,16,64)),(f'v_cache{i}',(1,512,16,64)),(f'position{i}',(1,))]:
    inputs.append(ct.TensorType(name=name,shape=shape,dtype=np.float32));outputs.append(ct.TensorType(name='new_'+name,dtype=np.float32))
  with torch.no_grad(): traced=torch.jit.trace(m,tuple(args))
  converted=ct.convert(traced,inputs=inputs,outputs=outputs,minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT16,skip_model_load=True)
  path=args_cli.output/f'prefill-{width}.mlpackage'
  converted.save(str(path));print('Saved',path,flush=True)
