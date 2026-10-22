Tools/build-runtime.sh writes runtime.json here with the SHA-256 of the actual
patched dylib. A missing identity is an error, never a generic cache identity.
