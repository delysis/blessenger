"""Apply identical open-source Apple build wiring to baseline and patched sources."""
from pathlib import Path
import sys
work = Path(sys.argv[1]).resolve()
lm, rt = work/'LiteRT-LM', work/'LiteRT'
# ObjC++ must use the same C++ dialect as the C++ runtime. Otherwise Abseil
# SourceLocation has different ABI types and -undefined dynamic_lookup hides
# unresolved calls until the first ordinary Status error path crashes.
p = lm/'.bazelrc'
s = p.read_text()
if 'build:macos --objccopt=-std=c++20' not in s:
    p.write_text(s + '\nbuild:macos --objccopt=-std=c++20\nbuild:ios --objccopt=-std=c++20\n')
for relative in [
    'ml_drift_delegate/delegate/gpu_backend_metal_litert.mm',
    'ml_drift_delegate/delegate/shared_memory_manager/shared_memory_manager_metal_test.mm',
]:
    p = rt/relative
    p.write_text(p.read_text().replace('third_party/odml/litert/ml_drift/', 'ml_drift_delegate/'))
# The exported LiteRT BUILD files still name an internal Swift aspect target.
p = rt/'tools/build_defs/swift/BUILD'
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text('alias(name = "no_module", actual = "@build_bazel_rules_swift//swift:no_module", visibility = ["//visibility:public"])\n')
# --override_repository does not evaluate the overridden repository's WORKSPACE.
# Reuse exactly LiteRT's pinned ML Drift source and repository mapping.
p = lm/'WORKSPACE'; s = p.read_text()
marker = '# CallGemma Apple source-build dependencies'
source = (rt/'WORKSPACE').read_text()
a=source.index('ML_DRIFT_COMMIT = ')
b=source.index('EGL_HEADERS_COMMIT = ',a)
block=source[a:b].replace("sed -i -e", "sed -i '' -e")
block = block.replace('patch_cmds = [', """patch_cmds = [
    "find ml_drift -name BUILD -exec sed -i '' -e 's|@//ml_drift_delegate|@litert//ml_drift_delegate|g' {} +",
    "sed -i '' -e 's|@fp16|@FP16//:FP16|g' ml_drift/common/BUILD",""")
s = s.split(marker)[0].rstrip() + '\n'+marker+'\n'+block
p.write_text(s)
