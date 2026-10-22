"""Export the fourteen existing contact references with upstream PocketTTS April English."""
import json,pathlib,hashlib,torch,soundfile as sf
from pocket_tts import TTSModel
from pocket_tts.models.model_state import export_model_state
root=pathlib.Path(__file__).resolve().parents[2]
out=root/'Browser/PocketTTS/model/voices';out.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(2)
model=TTSModel.load_model(language='english_2026-04',temp=0.7,sampler_decode_steps=8)
contacts=json.loads((root/'Sources/CallGemma/Resources/contacts.json').read_text())
receipts=[]
for contact in contacts:
    source=root/'Sources/CallGemma/Resources/Voices'/f"{contact['voice']}.wav"
    pcm,rate=sf.read(source,dtype='float32',always_2d=True)
    assert rate==24000 and pcm.shape[1]==1, 'Reference must be canonical 24 kHz mono'
    pcm=pcm[:240000,0]
    assert len(pcm)>=24000
    state=model.get_state_for_audio_prompt(torch.from_numpy(pcm).unsqueeze(0))
    path=out/f"{contact['id']}.safetensors"
    export_model_state(state,path)
    receipts.append({'contact':contact['id'],'referenceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'frames':len(pcm),'voiceSHA256':hashlib.sha256(path.read_bytes()).hexdigest()})
    print(contact['name'],len(pcm),flush=True)
(out.parent/'voices.json').write_text(json.dumps({'modelRevision':'19f95fe2df36e79fbd9f10008595cc4c977a0fcc','voices':receipts},indent=2)+'\n')
