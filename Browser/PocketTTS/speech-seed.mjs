export function speechSeed(value) {
  // Preserve all 64 bits across JSON and the WASM boundary.
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,19})$/.test(value) || BigInt(value) > 18446744073709551615n) {
    throw Error('Speech requires a decimal UInt64 seed');
  }
  return BigInt(value);
}
