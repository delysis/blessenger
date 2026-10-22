#!/usr/bin/env python3
"""Summarize numeric Call Gemma receipts; never infers acoustic latency."""
import argparse
import collections
import json
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('receipts', nargs='+')
args = parser.parse_args()
runs = collections.defaultdict(lambda: {'events': [], 'metrics': collections.defaultdict(list)})
seen = set()
for path in args.receipts:
    with open(path) as source:
        for line in source:
            record = json.loads(line)
            identity = json.dumps(record, sort_keys=True)
            if identity in seen:
                continue
            seen.add(identity)
            run = runs[record['run']]
            run['events'].extend(record['events'])
            for name, metric in record['metrics'].items():
                run['metrics'][name].append(metric)

intervals = {
    'Estimated speech end → estimated playback onset': ('speech.endpoint_estimate', 'playback.onset_estimate'),
    'Estimated speech end → estimated signal onset': ('speech.endpoint_estimate', 'playback.signal_onset_estimate'),
    'Speculation threshold → first text': ('vad.speculation_threshold_crossed', 'gemma.first_text'),
    'Strict playback threshold → estimated signal onset': ('vad.playback_threshold_crossed', 'playback.signal_onset_estimate'),
    'Strict playback threshold → playback admission': ('vad.playback_threshold_crossed', 'playback.endpoint_admitted'),
    'Estimated speech end → turn start': ('speech.endpoint_estimate', 'turn.start'),
    'Controller submit → native submit': ('gemma.submit', 'gemma.native_submit'),
    'Native submission call': ('gemma.native_submit', 'gemma.native_admitted'),
    'Native submit → native first text': ('gemma.native_submit', 'gemma.native_first_text'),
    'Native text → controller delivery': ('gemma.native_first_text', 'gemma.first_text'),
    'Gemma submit → first text': ('gemma.submit', 'gemma.first_text'),
    'First text → first sentence ready': ('gemma.first_text', 'tts.sentence_ready'),
    'TTS enqueue → first PCM': ('tts.enqueue', 'tts.first_pcm'),
    'First PCM → first scheduled buffer': ('tts.first_pcm', 'playback.first_buffer_scheduled'),
    'First scheduled buffer → played-back callback': ('playback.first_buffer_scheduled', 'playback.first_buffer_played_back'),
    'Turn start → first scheduled buffer': ('turn.start', 'playback.first_buffer_scheduled'),
    'Turn start → first buffer played-back callback': ('turn.start', 'playback.first_buffer_played_back'),
    'Playback drained → snapshot captured': ('playback.drained', 'turn.captured'),
    'Playback drained → checkpoint complete': ('playback.drained', 'turn.saved'),
}
for run_id, run in runs.items():
    print(f'\nRun {run_id}')
    print('Metric | observations | weighted mean ms | maximum ms | latest-window p95 ms')
    for name, metrics in sorted(run['metrics'].items()):
        count = sum(m['count'] for m in metrics)
        mean = sum(m['count'] * m['mean_ms'] for m in metrics) / count
        print(f'{name} | {int(count)} | {mean:.3f} | {max(m["max_ms"] for m in metrics):.3f} | {metrics[-1]["recent_p95_ms"]:.3f}')
    turns = collections.defaultdict(dict)
    for event in sorted(run['events'], key=lambda e: int(e['uptime_ns'])):
        if event['turn']:
            turns[event['turn']].setdefault(event['event'], int(event['uptime_ns']))
    print('Completed-turn interval | n | median ms | maximum ms')
    for label, (start, end) in intervals.items():
        values = [(events[end] - events[start]) / 1e6 for events in turns.values()
                  if ('turn.saved' in events or 'turn.captured' in events) and start in events and end in events]
        if values:
            print(f'{label} | {len(values)} | {statistics.median(values):.3f} | {max(values):.3f}')
    print('Turn outcomes:', dict(collections.Counter(
        'durable' if ('turn.saved' in events or 'checkpoint.durable' in events) else 'captured' if 'turn.captured' in events else 'cancelled' if 'turn.cancelled' in events
        else 'failed' if 'turn.failed' in events else 'incomplete' for events in turns.values())))
print('\nThe played-back callback bounds software delivery; it is not a microphone measurement of speaker onset.')
print('Capture sample age includes batching and device timing; it is not just resampler CPU time.')
print('Recent p95 values cover at most 1024 observations per metric per receipt, not pooled whole-run percentiles.')

print("Captured turns are admitted to the background writer; capture is not a durability acknowledgement.")
