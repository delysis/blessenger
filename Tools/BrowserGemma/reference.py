import argparse,json,time,wave,re
from pathlib import Path
import torch,numpy as np
from transformers import Gemma4ForConditionalGeneration,AutoProcessor
parser=argparse.ArgumentParser()
parser.add_argument('checkpoint',type=Path)
parser.add_argument('receipt',type=Path)
args=parser.parse_args()
root=Path(__file__).resolve().parents[2]/'Qualification/Fixtures/audio-content'
model_path=str(args.checkpoint.resolve())
torch.set_num_threads(8)
processor=AutoProcessor.from_pretrained(model_path,local_files_only=True)
model=Gemma4ForConditionalGeneration.from_pretrained(model_path,local_files_only=True,dtype=torch.float32,attn_implementation='eager').eval()
results=[]
fixtures=json.loads((root/'original-questions.json').read_text())+json.loads((root/'group-questions.json').read_text())
for fixture_info in fixtures:
 fixture=fixture_info['path']
 with wave.open(str(root/fixture)) as wav: pcm=np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').astype(np.float32)/32768
 prompt=processor.apply_chat_template([{'role':'user','content':[{'type':'audio'}]}],tokenize=False,add_generation_prompt=True,enable_thinking=False)
 inputs=processor(text=prompt,audio=pcm,sampling_rate=16000,return_tensors='pt')
 torch.manual_seed(42);start=time.perf_counter()
 with torch.inference_mode(): output=model.generate(**inputs,max_new_tokens=96,do_sample=True,temperature=1,top_k=0,top_p=1)
 text=processor.decode(output[0,inputs.input_ids.shape[1]:],skip_special_tokens=True)
 results.append({'fixture':fixture,'text':text,'seconds':time.perf_counter()-start,'inputTokens':inputs.input_ids.shape[1],'correct':bool(re.search(fixture_info['answer'],text,re.I))})
 print(json.dumps(results[-1]),flush=True)
 args.receipt.write_text(json.dumps({'checkpoint':model_path,'dtype':'float32','temperature':1,'seed':42,'scope':'CPU reference uses Google QAT unquantized checkpoint, distinct from MLC quantized weights','results':results},indent=2)+'\n')
