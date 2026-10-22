"""Local, silent synthetic feasibility corpus. Split voices before augmentation."""
import argparse, hashlib, json, subprocess, wave
from pathlib import Path
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('output', type=Path)
parser.add_argument('--contacts', type=Path, help='Optional full roster; label by stable contact ID')
parser.add_argument('--reuse-originals', type=Path, help='Reuse an immutable prior originals directory; never resynthesize missing clips')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
if args.reuse_originals:
    assert args.reuse_originals.is_dir()
    (args.output/'originals').symlink_to(args.reuse_originals.resolve(), target_is_directory=True)
voices = [('Samantha (English (US))', 'train'), ('Fred', 'train'),
          ('Karen', 'validation'), ('Daniel (English (UK))', 'test')]
phrases = {
    'peter': ['Peter.', 'Hey Peter.', 'Peter please.', 'Okay Peter.', 'Peter, listen.', 'Hello Peter.',
              'Peter, what do you think?', 'Tell me Peter.', 'Peter, are you there?', 'Yes Peter.'],
    'gabor': ['Gabor.', 'Hey Gabor.', 'Gabor please.', 'Okay Gabor.', 'Gabor, listen.', 'Hello Gabor.',
              'Gabor, what do you think?', 'Tell me Gabor.', 'Gabor, are you there?', 'Yes Gabor.'],
    'other': ['Paper.', 'Later.', 'Neighbor.', 'Get more.', 'Hello there.', 'Please listen.',
              'What do you think?', 'The client is forty.', 'I feel tired.', 'Good morning.']}
roster = []
if args.contacts:
    contacts = json.loads(args.contacts.read_text())
    phrases = {}
    for contact in contacts:
        # A single syllable "Ad" is also ordinary English "add". Evaluate the
        # full name as the default candidate, without changing contact settings.
        wake_name = contact.get('wakeName') or ('Ad de Jongh' if contact['name'].startswith('Ad de Jongh') else contact['name'].split()[0])
        label = contact['id'].lower()
        roster.append(dict(id=label, name=contact['name'], wake_name=wake_name))
        phrases[label] = [wake_name + '.', 'Hey ' + wake_name + '.', wake_name + ' please.',
            'Okay ' + wake_name + '.', wake_name + ', listen.', 'Hello ' + wake_name + '.',
            wake_name + ', what do you think?', 'Tell me ' + wake_name + '.']
    phrases['other'] = ['Paper.', 'Later.', 'Neighbor.', 'Get more.', 'Vessel.', 'Basket.',
        'Richardson.', 'Judicious.', 'Genuine.', 'Christine is not here.', 'Robertson.',
        'Arnold Palmer.', 'Jiminy.', 'Francis.', 'Surely.', 'Delores is a town.',
        'Add another.', 'The client is forty.', 'I feel tired.', 'Good morning.',
        'What do you think?', 'Please listen.', 'The phone is ringing.', 'Let me finish.']
    # Do not call ambiguous names-in-ordinary-speech negatives yet: this first
    # experiment measures acoustic names, not semantic addressee inference.
    phrases['other'] = [t for t in phrases['other'] if t not in ['Christine is not here.', 'Arnold Palmer.', 'Delores is a town.']]
    (args.output/'roster.json').write_text(json.dumps(roster, indent=2)+'\n')
rng = np.random.default_rng(42)
manifest = []
for voice, split in voices:
    for label, texts in phrases.items():
        for text in texts:
            source_id = hashlib.sha256((voice+'\0'+text).encode()).hexdigest()
            original = args.output/'originals'/f'{source_id}.wav'
            original.parent.mkdir(exist_ok=True)
            if args.reuse_originals:
                assert original.is_file(), ('Missing immutable source', original)
            else:
                subprocess.run(['say', '-v', voice, '-r', '180', '--file-format=WAVE',
                                '--data-format=LEI16@16000', '-o', str(original), text], check=True)
            with wave.open(str(original)) as f:
                assert f.getframerate() == 16000 and f.getnchannels() == 1 and f.getsampwidth() == 2
                pcm = np.frombuffer(f.readframes(f.getnframes()), dtype='<i2').astype(np.float64)/32768
            # Never crop a name just to fit the classifier's window.
            assert len(pcm) < 64000, (voice, text, len(pcm))
            source_hash = hashlib.sha256(original.read_bytes()).hexdigest()
            for variant in range(5 if split == 'train' else 1):
                out = args.output/split/label/f'{source_id}-{variant}.wav'
                out.parent.mkdir(parents=True, exist_ok=True)
                padded = np.zeros(64000)
                offset = int(rng.integers(0, 64000-len(pcm)+1))
                gain = float(rng.uniform(.25, 1))
                padded[offset:offset+len(pcm)] = pcm*gain
                noise = float(rng.uniform(0, .001)) if variant else 0
                padded += rng.normal(0, noise, len(padded))
                with wave.open(str(out), 'wb') as f:
                    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
                    f.writeframes((np.clip(padded, -1, 1)*32767).round().astype('<i2').tobytes())
                manifest.append(dict(path=str(out.relative_to(args.output)), source=source_id,
                    source_sha256=source_hash, voice=voice, text=text, split=split, label=label,
                    gain=gain, offset=offset, noise_std=noise))
# No transformed sibling can appear across partitions.
partitions = {}
for entry in manifest:
    partitions.setdefault(entry['source'], set()).add(entry['split'])
assert all(len(splits) == 1 for splits in partitions.values())
(args.output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
print(f'{len(manifest)} examples; held-out voices never used for training')
