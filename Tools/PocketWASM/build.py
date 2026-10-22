#!/usr/bin/env python3
"""Build the pinned CPU/SIMD PocketTTS-compatible runtime without changing global tools."""
import argparse, pathlib, subprocess, os, shutil, hashlib, json
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('wasm_bindgen',type=pathlib.Path);a=p.parse_args()
source=a.source.resolve();bindgen=a.wasm_bindgen.resolve()
revision='49b9033e44ab0fbb935973eca3213757644d1bbb'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=source,text=True).strip()==revision
root=pathlib.Path(__file__).resolve().parents[2]
patch=root/'ModelPatches/xn-ptts/0001-pocket-speaker-projection.patch'
changes=subprocess.check_output(['git','diff'],cwd=source)
if not changes:
    subprocess.run(['git','apply',str(patch)],cwd=source,check=True)
assert subprocess.check_output(['git','diff'],cwd=source)==patch.read_bytes(), 'Unexpected source changes'
assert subprocess.check_output([str(bindgen),'--version'],text=True).strip()=='wasm-bindgen 0.2.120'
cargo=subprocess.check_output(['rustup','which','cargo'],text=True).strip()
rustc=subprocess.check_output(['rustup','which','rustc'],text=True).strip()
env={**os.environ,'RUSTC':rustc,'RUSTFLAGS':'-C target-feature=+simd128 --cfg getrandom_backend="wasm_js"'}
subprocess.run([cargo,'build','-p','ptts-wasm','--target','wasm32-unknown-unknown','--release','--locked'],cwd=source,env=env,check=True)
root=pathlib.Path(__file__).resolve().parents[2]
out=root/'Browser/PocketTTS';(out/'wasm').mkdir(parents=True,exist_ok=True)
subprocess.run([str(bindgen),'--target','web','--out-dir',str(out/'wasm'),'--out-name','phonon_tts',str(source/'target/wasm32-unknown-unknown/release/ptts_wasm.wasm')],check=True)
for file in (source/'ptts-wasm/js').glob('*.js'):shutil.copyfile(file,out/file.name)
for name in ['LICENSE-MIT','LICENSE-APACHE']:shutil.copyfile(source/name,out/name)
shutil.copyfile(source/'ptts-wasm/js/index.d.ts',out/'index.d.ts')
files={str(f.relative_to(out)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(out.rglob('*')) if f.is_file() and f.name!='build.json'}
(out/'build.json').write_text(json.dumps({'source':'https://github.com/gradium-ai/xn-ptts','revision':revision,'wasmBindgen':'0.2.120','backend':'CPU, baseline SIMD, single thread','files':files,'patchSHA256':hashlib.sha256(patch.read_bytes()).hexdigest(),'qualifiedAudio':False},indent=2)+'\n')
