/* tslint:disable */
/* eslint-disable */

/**
 * A loaded model, on the CPU or on WebGPU.
 *
 * The state sits behind an `Rc<RefCell<Option<_>>>` because `generation_step` is async and a
 * `RefCell` borrow may not be held across an await: the step takes the state out for its
 * duration and puts it back after. A call that arrives meanwhile finds it missing and is
 * refused, so calls must not overlap; `phonon-tts`'s worker awaits each one. The exception
 * is `stop_generation`, which the step applies when it puts the state back.
 */
export class Model {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Registers a voice from a safetensors file and returns its index for
     * `start_generation`. Either a precomputed KV cache (`embeddings_v2/`) or a voice
     * embedding (`emb`, `audio_prompt` or `speaker_wavs`), told apart by tensor name.
     */
    add_voice(voice: Uint8Array): number;
    /**
     * `"cpu"` or `"webgpu"`: where this model runs.
     */
    device(): string;
    /**
     * Waits for the work the device has queued. On WebGPU, `add_voice` only records a voice's
     * prompt, and the GPU runs it here rather than inside the first step that speaks. The CPU
     * has nothing queued. Resolves at once while a `generation_step` holds the model, which
     * waits for the GPU itself.
     */
    flush(): Promise<any>;
    /**
     * Samples in one 80 ms frame: `generation_step` returns whole frames.
     */
    frame_size(): number;
    /**
     * Generates and decodes the next frames of the current chunk: a promise of mono PCM at
     * `sample_rate`, a whole number of `frame_size`-sample frames, or of `undefined` when the
     * chunk is finished. One frame per call on the CPU, several on WebGPU.
     */
    generation_step(): Promise<any>;
    /**
     * The languages the model was trained for, as listed in its config.
     */
    languages(): string[];
    /**
     * Loads a model. `model_weights` is a safetensors or GGUF checkpoint, `tokenizer_json`
     * the contents of the `tokenizer.json` for its vocabulary, and `config_json` its
     * `config.json`. All three are required.
     *
     * One thing a config cannot ask this build for: classifier-free guidance. Guidance is a
     * caller's option in `ptts::synth` (`SpeechOptions::cfg_coef`), not a field of the
     * config, and the browser build never turns it on, so `cfg_null_audio_empty` is inert.
     * A config with baked-in `voices` is refused: voices here come from files. Everything
     * else -- the flow LM and Mimi shapes, `lsd_decode_steps`, `eos_threshold`, `model_id`,
     * `speaker_mimi`, `conditioners` -- is honored.
     *
     * `quant` is `"f32"` or `"q8"`.
     *
     * `lang` is required: the language text is normalized as before it is
     * tokenized, one of `"en"`, `"fr"`, `"de"`, `"es"`, `"pt"`, or `"none"`
     * to hand text to the tokenizer as written. The spoken forms of `@`, `+`
     * and `=` differ per language, so there is nothing safe to default to.
     *
     * `rewrites` is optional and picks which word rewrites run on the
     * normalized text: `"default"` (numbers, currency, dashed-digits, emails,
     * urls, abbreviations, elongations), `"all"` (those and phones, times,
     * dates), `"none"`, or a comma-separated list of rule names.
     *
     * `conditions` is optional and sets the config's conditioners, each as `"NAME=VALUE"`,
     * e.g. `["duration_delta=0.5"]`. Those left out take their defaults.
     *
     * `device` is `"cpu"` or `"webgpu"`. WebGPU needs `q8` weights in a GGUF file, and a
     * build with the `webgpu` feature.
     */
    static load(model_weights: Uint8Array, tokenizer_json: Uint8Array, config_json: Uint8Array, quant: string, lang: string, rewrites: string | null | undefined, conditions: string[] | null | undefined, device: string): Promise<Model>;
    /**
     * Prompts the model with the next chunk's text and returns its token count, or
     * `undefined` once every chunk has been generated.
     */
    next_chunk(): number | undefined;
    sample_rate(): number;
    /**
     * Normalizes `text`, splits it into sentence-aligned chunks and tokenizes them. Returns
     * the number of chunks. Runs no model: call `next_chunk` to start the first one.
     */
    start_generation(voice_index: number, text: string, temperature: number, seed: bigint): number;
    /**
     * Drops the generation in progress, if any. Called while a `generation_step` is pending,
     * it takes effect when that step returns: the step still delivers its frames, and the
     * next one reports the end.
     */
    stop_generation(): void;
}

/**
 * CPU SIMD features the wasm module was compiled with. The relevant one
 * for browser builds is `simd128`; `avx`/`neon`/`f16c` are reported for
 * completeness so it's clear which native-target builds enabled them.
 */
export function cpu_features(): object;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_model_free: (a: number, b: number) => void;
    readonly cpu_features: () => any;
    readonly model_add_voice: (a: number, b: number, c: number) => [number, number, number];
    readonly model_device: (a: number) => [number, number, number, number];
    readonly model_flush: (a: number) => any;
    readonly model_frame_size: (a: number) => [number, number, number];
    readonly model_generation_step: (a: number) => any;
    readonly model_languages: (a: number) => [number, number, number, number];
    readonly model_load: (a: number, b: number, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number, k: number, l: number, m: number, n: number, o: number, p: number) => any;
    readonly model_next_chunk: (a: number) => [number, number, number];
    readonly model_sample_rate: (a: number) => [number, number, number];
    readonly model_start_generation: (a: number, b: number, c: number, d: number, e: number, f: bigint) => [number, number, number];
    readonly model_stop_generation: (a: number) => void;
    readonly wasm_bindgen__convert__closures_____invoke__h148a749c8be419b4: (a: number, b: number, c: any) => [number, number];
    readonly wasm_bindgen__convert__closures_____invoke__h40bd275fcbcc1e4b: (a: number, b: number, c: any, d: any) => void;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_destroy_closure: (a: number, b: number) => void;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __externref_drop_slice: (a: number, b: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
