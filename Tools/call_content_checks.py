"""Content gates for the isolated English arithmetic call fixture, not product moderation."""
import collections
import json
import re
import unicodedata
import wave
from pathlib import Path


def assistant_text(message):
    if message.get('role') != 'assistant':
        return None
    content = message.get('content', [])
    if isinstance(content, str):
        return content
    return ''.join(p.get('text', '') for p in content if p.get('type') == 'text')


def corruption_reason(text):
    # The fixture is English. Latin accented persona names and punctuation are fine.
    foreign = [c for c in text if c.isalpha() and 'LATIN' not in unicodedata.name(c, '')]
    if foreign:
        return 'Unexpected non-Latin letters in the English fixture reply: ' + repr(''.join(foreign[:16]))
    if '<channel|>' in text or '<|channel>' in text:
        return 'Model channel delimiter leaked into the spoken reply'
    lines = collections.Counter(line.strip() for line in text.splitlines() if line.strip())
    if lines and lines.most_common(1)[0][1] >= 8:
        return 'Repeated output line: ' + repr(lines.most_common(1)[0][0])
    words = re.findall(r"\w+", text.casefold())
    phrases = collections.Counter(tuple(words[i:i + 5]) for i in range(len(words) - 4))
    if phrases and phrases.most_common(1)[0][1] >= 4:
        phrase, count = phrases.most_common(1)[0]
        return f'Repeated five-word phrase {count} times: {" ".join(phrase)!r}'
    return None


def histories(root):
    """Read atomically published, app-owned canonical call transcripts."""
    return {str(p.relative_to(root)): json.loads(json.loads(p.read_text())['historyJSON'])
            for p in (Path(root) / 'Runtime/Contacts').glob('*/Calls/Conversations-v3/*/TRANSCRIPT')}


def check_new_content(root, before, answer_pattern=None):
    replies = []
    for pending in (Path(root) / 'Runtime/Contacts').glob('*/Calls/Conversations-v3/*/PENDING-SPEECH'):
        try:
            snapshot = json.loads(pending.read_text())
        except FileNotFoundError:
            continue  # The app atomically committed this turn between listing and reading.
        text = ''.join(segment['text'] for segment in snapshot['segments'])
        reason = corruption_reason(text)
        if reason:
            (Path(root) / 'content-failure.json').write_text(json.dumps(
                {'source': str(pending), 'reason': reason, 'provisionalText': text}, indent=2))
            raise AssertionError(reason + '\nProvisional reply: ' + text)
    for key, messages in histories(root).items():
        for message in messages[len(before.get(key, [])):]:
            text = assistant_text(message)
            if text:
                reason = corruption_reason(text)
                if reason:
                    raise AssertionError(reason + '\nReply: ' + text)
                replies.append(text)
    if answer_pattern is not None:
        if not replies:
            raise AssertionError('No nonempty committed assistant reply to the fixture')
        if not any(re.search(answer_pattern, text, re.IGNORECASE) for text in replies):
            raise AssertionError('Reply did not answer the known audio question: ' + repr(replies))
    return replies


def retained_audio_seconds(root, before):
    """Audio actually referenced by newly committed user turns, not orphan WAVs."""
    paths = set()
    for key, messages in histories(root).items():
        for message in messages[len(before.get(key, [])):]:
            if message.get('role') == 'user' and isinstance(message.get('content'), list):
                paths.update(part['path'] for part in message['content']
                             if part.get('type') == 'audio' and 'path' in part)
    seconds = 0.0
    for path in paths:
        with wave.open(path, 'rb') as audio:
            seconds += audio.getnframes() / audio.getframerate()
    return seconds
