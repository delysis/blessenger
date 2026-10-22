"""Reproduce the corrected float16 generation export from pinned source."""
import argparse, hashlib, importlib.util, importlib.metadata, importlib.resources
import json, subprocess, tempfile
from pathlib import Path
import torch, numpy as np, coremltools as ct
from pocket_tts import TTSModel

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent
provenance=json.loads((root/'gelu-parity-status.json').read_text())
if hashlib.sha256(args.source.read_bytes()).hexdigest()!=provenance['original_sha256']:
    raise ValueError('Generation exporter source differs from the pinned revision')
versions={name:importlib.metadata.version(name) for name in ['torch','coremltools','numpy','pocket-tts']}
expected={'torch':'2.7.1','coremltools':'9.0','numpy':'2.5.4','pocket-tts':'4.0.1'}
if versions!=expected:raise ValueError(f'Exporter environment differs: {versions}')
config=importlib.resources.files('pocket_tts').joinpath('config/english_2026-04.yaml').read_bytes()
if hashlib.sha256(config).hexdigest()!=json.loads((root/'provenance.json').read_text())['english_config_sha256']:
    raise ValueError('English configuration differs from pinned weights')
args.output.mkdir(parents=True,exist_ok=False)
torch.set_num_threads(2)
with tempfile.TemporaryDirectory(prefix='blessenger-step-export-') as temporary:
    relative=Path('models/tts/pocket_tts/coreml/convert_models/traceable/traceable_flowlm_step_ane.py')
    source=Path(temporary)/relative;source.parent.mkdir(parents=True)
    source.write_bytes(args.source.read_bytes())
    subprocess.run(['patch','--batch','-p1','-i',str(root/'0002-match-transformer-gelu.patch')],cwd=temporary,check=True)
    spec=importlib.util.spec_from_file_location('corrected_step',source)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    model=TTSModel.load_model(language='english_2026-04',temp=.7,sampler_decode_steps=8).eval()
    wrapper=module.TraceableFlowLMStepANE.from_flowlm(model.flow_lm).eval()
    values=[model.flow_lm.bos_emb.detach().reshape(1,1,32)]
    names=['sequence'];outputs=['transformer_out','is_eos']
    for i in range(6):
        for kind,shape in [('k_cache',(1,512,16,64)),('v_cache',(1,512,16,64)),('position',(1,))]:
            name=f'{kind}{i}';names.append(name);outputs.append('new_'+name)
            values.append(torch.zeros(shape))
    with torch.no_grad(): traced=torch.jit.trace(wrapper,tuple(values))
    pipeline=ct.PassPipeline.DEFAULT
    pipeline.remove_passes({'common::fuse_gelu_tanh_approximation','common::fuse_gelu_exact'})
    converted=ct.convert(traced,inputs=[ct.TensorType(name=n,shape=tuple(v.shape),dtype=np.float32) for n,v in zip(names,values)],outputs=[ct.TensorType(name=n,dtype=np.float32) for n in outputs],minimum_deployment_target=ct.target.iOS17,compute_precision=ct.precision.FLOAT16,pass_pipeline=pipeline,skip_model_load=True)
    converted.save(str(args.output/'generation.mlpackage'))
    (args.output/'environment.json').write_text(json.dumps(versions,indent=2))
