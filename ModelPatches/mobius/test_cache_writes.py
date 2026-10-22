"""Padding must preserve every cache slot for all exported block widths."""
import argparse
import torch
from exporter_source import patched_exporter

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True)
args = parser.parse_args()
torch.manual_seed(42)
checks = 0
with patched_exporter(args.source) as exporter:
    for width in [4, 16, 256]:
        model = exporter(num_layers=0, t_max=width).eval()
        cases = [(0, 0), (0, 1), (126, min(width, 11)), (0, width),
                 (512-width, width), (511, 1), (500, min(width, 12))]
        for position, length in cases:
            assign, covered = model._shared_block_values(
                torch.tensor([float(position)]), torch.tensor([float(length)]), torch.float32)[2:4]
            assert torch.equal(assign.sum(1), (torch.arange(width) < length).float())
            expected = torch.zeros(512)
            expected[position:position+length] = 1
            assert torch.equal(covered, expected)
            old = torch.randn(512, 16)
            tokens = torch.randn(width, 16)
            tokens[length:] *= 10000
            got = old * (1-covered[:, None]) + assign.T @ tokens
            want = old.clone()
            want[position:position+length] = tokens[:length]
            assert torch.equal(got, want), (width, position, length)
            checks += 1
print(f'{checks} cache-write boundary cases passed; padding writes no slot')
