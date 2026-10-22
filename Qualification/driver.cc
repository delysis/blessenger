// Copyright 2026. Licensed under the Apache License, Version 2.0.
// Runs against real LiteRT-LM C API 1.0 binaries; no runtime implementation is
// linked into this executable. Persistence symbols are optional on baseline.
#include "common.h"
#include "c/conversation.h"
#include "c/engine.h"

#include <dlfcn.h>
#include <sys/resource.h>
#include <sys/utsname.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#endif

#include <chrono>
#include <atomic>
#include <future>
#include <condition_variable>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>

namespace q = qualification;
using Clock = std::chrono::steady_clock;

#define REQUIRED_API(X) \
  X(litert_lm_get_api_version) \
  X(litert_lm_get_last_error_message) \
  X(litert_lm_engine_settings_create) \
  X(litert_lm_engine_settings_delete) \
  X(litert_lm_engine_settings_set_max_num_tokens) \
  X(litert_lm_engine_settings_set_enable_speculative_decoding) \
  X(litert_lm_engine_settings_enable_benchmark) \
  X(litert_lm_engine_create) \
  X(litert_lm_engine_delete) \
  X(litert_lm_engine_create_session) \
  X(litert_lm_session_config_create) \
  X(litert_lm_session_config_delete) \
  X(litert_lm_session_config_set_max_output_tokens) \
  X(litert_lm_session_config_set_apply_prompt_template) \
  X(litert_lm_session_config_set_enable_speculative_decoding) \
  X(litert_lm_session_config_set_sampler_params) \
  X(litert_lm_sampler_params_create) \
  X(litert_lm_sampler_params_delete) \
  X(litert_lm_sampler_params_set_seed) \
  X(litert_lm_sampler_params_set_top_k) \
  X(litert_lm_session_delete) \
  X(litert_lm_session_run_prefill) \
  X(litert_lm_session_run_decode) \
  X(litert_lm_session_run_decode_async) \
  X(litert_lm_session_run_text_scoring) \
  X(litert_lm_session_cancel_process) \
  X(litert_lm_input_data_create) \
  X(litert_lm_input_data_delete) \
  X(litert_lm_responses_delete) \
  X(litert_lm_responses_get_num_candidates) \
  X(litert_lm_responses_get_response_text_at) \
  X(litert_lm_responses_get_score_at) \
  X(litert_lm_responses_get_token_length_at) \
  X(litert_lm_responses_get_num_token_scores_at) \
  X(litert_lm_responses_get_token_scores_at) \
  X(litert_lm_session_get_benchmark_info) \
  X(litert_lm_benchmark_info_delete) \
  X(litert_lm_benchmark_info_get_num_prefill_turns) \
  X(litert_lm_benchmark_info_get_num_decode_turns) \
  X(litert_lm_benchmark_info_get_prefill_token_count_at) \
  X(litert_lm_benchmark_info_get_decode_token_count_at) \
  X(litert_lm_benchmark_info_get_decode_tokens_per_sec_at) \
  X(litert_lm_engine_tokenize) \
  X(litert_lm_tokenize_result_delete) \
  X(litert_lm_tokenize_result_get_tokens) \
  X(litert_lm_tokenize_result_get_num_tokens) \
  X(litert_lm_engine_detokenize) \
  X(litert_lm_detokenize_result_delete) \
  X(litert_lm_detokenize_result_get_string) \
  X(litert_lm_stream_chunk_get_text) \
  X(litert_lm_stream_chunk_is_final) \
  X(litert_lm_stream_chunk_get_error) \
  X(litert_lm_conversation_config_create) \
  X(litert_lm_conversation_config_delete) \
  X(litert_lm_conversation_config_set_session_config) \
  X(litert_lm_conversation_config_set_filter_channel_content_from_kv_cache) \
  X(litert_lm_thinking_config_create) \
  X(litert_lm_thinking_config_delete) \
  X(litert_lm_thinking_config_set_enable_thinking) \
  X(litert_lm_conversation_config_set_thinking_config) \
  X(litert_lm_conversation_create) \
  X(litert_lm_conversation_delete) \
  X(litert_lm_conversation_send_message) \
  X(litert_lm_conversation_wait_until_done) \
  X(litert_lm_conversation_get_token_count) \
  X(litert_lm_json_response_get_string) \
  X(litert_lm_json_response_delete)

class Api {
 public:
  // Exact signatures of the additive patch; baseline headers need not declare
  // these symbols. They are never resolved through a different process image.
  using CacheFn = LiteRtLmStatusCode (*)(LiteRtLmSession*, const char*, const char*);
  CacheFn save = nullptr;
  CacheFn load = nullptr;
  using HistoryFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*, LiteRtLmJsonResponse**);
  using ConversationSaveFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*, const char*, const char*);
  using ConversationLoadFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*, const char*, const char*, const char*);
  using CountTokensFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*, const char*, const char*,
                                              const LiteRtLmConversationOptionalArgs*, int*);
  decltype(&::litert_lm_conversation_capture_cache) capture = nullptr;
  decltype(&::litert_lm_conversation_capture_cache_bounded) capture_bounded = nullptr;
  decltype(&::litert_lm_cache_snapshot_write) write_snapshot = nullptr;
  decltype(&::litert_lm_cache_snapshot_delete) delete_snapshot = nullptr;
  using BeginAudioFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*, const char*);
  using AppendAudioFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*, const float*, size_t);
  using FinishAudioFn = LiteRtLmStatusCode (*)(LiteRtLmConversation*);
  BeginAudioFn begin_audio = nullptr, replay_history = nullptr;
  AppendAudioFn append_audio = nullptr;
  FinishAudioFn finish_audio = nullptr;
  HistoryFn history = nullptr;
  ConversationSaveFn conversation_save = nullptr;
  ConversationLoadFn conversation_load = nullptr;
  CountTokensFn count_tokens = nullptr;
#define DECLARE(name) decltype(&::name) name = nullptr;
  REQUIRED_API(DECLARE)
#undef DECLARE

  explicit Api(const std::string& path) {
    q::Require(q::fs::path(path).is_absolute(), "--library must be an absolute path");
    handle_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    const char* error = handle_ ? nullptr : dlerror();
    q::Require(handle_ != nullptr, error ? error : "dlopen failed");
    litert_lm_get_api_version = Symbol<decltype(litert_lm_get_api_version)>(
        "litert_lm_get_api_version");
    int major = 0, minor = 0, patch = 0;
    q::Require(litert_lm_get_api_version(&major, &minor, &patch) == kLiteRtLmStatusOk &&
                   major == LITERT_LM_C_API_VERSION_MAJOR &&
                   minor >= LITERT_LM_C_API_VERSION_MINOR,
               "Incompatible LiteRT-LM C API version");
    version = std::to_string(major) + "." + std::to_string(minor) + "." + std::to_string(patch);
#define RESOLVE(name) name = Symbol<decltype(name)>(#name);
    REQUIRED_API(RESOLVE)
#undef RESOLVE
    save = Symbol<CacheFn>("litert_lm_session_save_cache", false);
    load = Symbol<CacheFn>("litert_lm_session_load_cache", false);
    capture = Symbol<decltype(capture)>("litert_lm_conversation_capture_cache", false);
    capture_bounded = Symbol<decltype(capture_bounded)>("litert_lm_conversation_capture_cache_bounded", false);
    write_snapshot = Symbol<decltype(write_snapshot)>("litert_lm_cache_snapshot_write", false);
    delete_snapshot = Symbol<decltype(delete_snapshot)>("litert_lm_cache_snapshot_delete", false);
    begin_audio = Symbol<BeginAudioFn>("litert_lm_conversation_begin_audio_input", false);
    append_audio = Symbol<AppendAudioFn>("litert_lm_conversation_append_audio_input", false);
    finish_audio = Symbol<FinishAudioFn>("litert_lm_conversation_finish_audio_input", false);
    replay_history = Symbol<BeginAudioFn>("litert_lm_conversation_prefill_history_suffix", false);
    history = Symbol<HistoryFn>("litert_lm_conversation_get_history", false);
    conversation_save = Symbol<ConversationSaveFn>("litert_lm_conversation_save_cache", false);
    conversation_load = Symbol<ConversationLoadFn>("litert_lm_conversation_load_cache", false);
    count_tokens = Symbol<CountTokensFn>("litert_lm_conversation_count_tokens", false);
    Dl_info info{};
    q::Require(dladdr(reinterpret_cast<void*>(litert_lm_get_api_version), &info) != 0,
               "Cannot identify loaded runtime");
    loaded_path = std::filesystem::canonical(info.dli_fname).string();
    q::Require(loaded_path == std::filesystem::canonical(path).string(),
               "C API resolved from a different library than requested");
  }
  ~Api() { if (handle_) dlclose(handle_); }
  Api(const Api&) = delete;
  Api& operator=(const Api&) = delete;

  void Check(LiteRtLmStatusCode status, const char* operation) const {
    if (status == kLiteRtLmStatusOk) return;
    const char* error = litert_lm_get_last_error_message();
    throw std::runtime_error(std::string(operation) + " (" + std::to_string(status) +
                             "): " + (error ? error : "no error detail"));
  }
  std::string version, loaded_path;
 private:
  template <class F> F Symbol(const char* name, bool required = true) {
    void* address = dlsym(handle_, name);
    q::Require(address || !required, std::string("Missing public C API symbol: ") + name);
    return reinterpret_cast<F>(address);
  }
  void* handle_ = nullptr;
};

template <class T, class Deleter>
auto Owned(T* pointer, Deleter deleter) {
  q::Require(pointer != nullptr, "C API succeeded with a null owned handle");
  return std::unique_ptr<T, Deleter>(pointer, deleter);
}

double Milliseconds(Clock::time_point start) {
  return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

uint64_t Footprint() {
#if defined(__APPLE__)
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  q::Require(task_info(mach_task_self(), TASK_VM_INFO,
                       reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS,
               "task_info(TASK_VM_INFO) failed");
  return info.phys_footprint;
#else
  // Linux is supported for compiling/testing the harness, not for Metal gates.
  std::ifstream status("/proc/self/statm");
  uint64_t size = 0, resident = 0;
  status >> size >> resident;
  q::Require(status.good(), "Cannot read process resident memory");
  return resident * static_cast<uint64_t>(sysconf(_SC_PAGESIZE));
#endif
}

// Samples the full capture/write/inference overlap, not merely post-save idle
// memory. macOS's lifetime high-water marks are recorded independently too.
class PeakMemory {
 public:
  PeakMemory() { Sample(); thread_ = std::thread([this] {
    while (!stop_.load()) { Sample(); std::this_thread::sleep_for(std::chrono::milliseconds(2)); }
  }); }
  ~PeakMemory() { Stop(); }
  void Stop() { stop_ = true; if (thread_.joinable()) thread_.join(); Sample(); }
  uint64_t peak = 0, rss = 0, kernel_peak = 0, kernel_rss = 0;
 private:
  void Sample() {
#if defined(__APPLE__)
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return;
    peak = std::max(peak, uint64_t(info.phys_footprint));
    rss = std::max(rss, uint64_t(info.resident_size));
    kernel_peak = std::max(kernel_peak, uint64_t(info.ledger_phys_footprint_peak));
    kernel_rss = std::max(kernel_rss, uint64_t(info.resident_size_peak));
#else
    peak = std::max(peak, Footprint());
#endif
  }
  std::atomic<bool> stop_{false};
  std::thread thread_;
};

uint64_t IdleFootprint() {
  std::vector<double> samples;
  for (int i = 0; i < 3; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    samples.push_back(static_cast<double>(Footprint()));
  }
  return static_cast<uint64_t>(q::Quantile(samples, 0.5));
}

std::vector<int> Tokens(Api& api, LiteRtLmEngine* engine, const std::string& text) {
  LiteRtLmTokenizeResult* raw = nullptr;
  api.Check(api.litert_lm_engine_tokenize(engine, text.c_str(), &raw), "tokenize");
  auto tokens = Owned(raw, api.litert_lm_tokenize_result_delete);
  const int* data = nullptr;
  size_t count = 0;
  api.Check(api.litert_lm_tokenize_result_get_num_tokens(raw, &count), "token count");
  api.Check(api.litert_lm_tokenize_result_get_tokens(raw, &data), "token data");
  q::Require(count == 0 || data, "Null token array");
  return count == 0 ? std::vector<int>{} : std::vector<int>(data, data + count);
}

std::string Prompt(Api& api, LiteRtLmEngine* engine, int target) {
  const std::string beginning = "Remember the gate code 7319. Background:";
  const std::string ending = "\nContinue counting from one, separated by commas:";
  int repeat = target;
  std::string prompt;
  for (int attempt = 0; attempt < 16; ++attempt) {
    prompt = beginning;
    for (int i = 0; i < repeat; ++i) prompt += " blue";
    prompt += ending;
    const int count = static_cast<int>(Tokens(api, engine, prompt).size());
    if (count == target) return prompt;
    repeat += target - count;
    q::Require(repeat >= 0 && repeat <= target * 2, "Cannot construct requested token fixture");
  }
  throw std::runtime_error("Tokenizer cannot construct exact fixture length; do not silently change it");
}

struct Counts { int prefill = 0; int decode = 0; double last_decode_tps = 0; };
Counts Benchmark(Api& api, LiteRtLmSession* session) {
  LiteRtLmBenchmarkInfo* raw = nullptr;
  api.Check(api.litert_lm_session_get_benchmark_info(session, &raw), "benchmark info");
  auto info = Owned(raw, api.litert_lm_benchmark_info_delete);
  int prefill_turns = 0, decode_turns = 0;
  api.Check(api.litert_lm_benchmark_info_get_num_prefill_turns(raw, &prefill_turns), "prefill turns");
  api.Check(api.litert_lm_benchmark_info_get_num_decode_turns(raw, &decode_turns), "decode turns");
  Counts counts;
  for (int i = 0; i < prefill_turns; ++i) {
    int tokens = 0;
    api.Check(api.litert_lm_benchmark_info_get_prefill_token_count_at(raw, i, &tokens), "prefill tokens");
    counts.prefill += tokens;
  }
  for (int i = 0; i < decode_turns; ++i) {
    int tokens = 0;
    api.Check(api.litert_lm_benchmark_info_get_decode_token_count_at(raw, i, &tokens), "decode tokens");
    counts.decode += tokens;
  }
  if (decode_turns > 0) {
    api.Check(api.litert_lm_benchmark_info_get_decode_tokens_per_sec_at(
                  raw, decode_turns - 1, &counts.last_decode_tps), "decode throughput");
  }
  return counts;
}

void Prefill(Api& api, LiteRtLmSession* session, const std::string& text) {
  LiteRtLmInputData* raw = nullptr;
  api.Check(api.litert_lm_input_data_create(kLiteRtLmInputDataTypeText, text.data(), text.size(), &raw),
            "create text input");
  auto input = Owned(raw, api.litert_lm_input_data_delete);
  const LiteRtLmInputData* inputs[] = {raw};
  api.Check(api.litert_lm_session_run_prefill(session, inputs, 1), "prefill");
}

std::string Decode(Api& api, LiteRtLmSession* session) {
  LiteRtLmResponses* raw = nullptr;
  api.Check(api.litert_lm_session_run_decode(session, &raw), "decode");
  auto responses = Owned(raw, api.litert_lm_responses_delete);
  int count = 0;
  api.Check(api.litert_lm_responses_get_num_candidates(raw, &count), "response candidates");
  q::Require(count == 1, "Expected exactly one response candidate");
  const char* text = nullptr;
  api.Check(api.litert_lm_responses_get_response_text_at(raw, 0, &text), "response text");
  q::Require(text != nullptr, "Null response text");
  return text;
}

struct Stream {
  Api& api;
  LiteRtLmSession* session;
  std::mutex mutex;
  std::condition_variable changed;
  bool final = false, requested = false;
  std::string text, error;
};

void CancelCallback(void* opaque, const LiteRtLmStreamChunk* chunk) noexcept {
  auto& stream = *static_cast<Stream*>(opaque);
  std::lock_guard<std::mutex> lock(stream.mutex);
  try {
    bool final = false;
    const char* text = nullptr;
    const char* error = nullptr;
    stream.api.Check(stream.api.litert_lm_stream_chunk_is_final(chunk, &final), "stream final");
    stream.api.Check(stream.api.litert_lm_stream_chunk_get_text(chunk, &text), "stream text");
    stream.api.Check(stream.api.litert_lm_stream_chunk_get_error(chunk, &error), "stream error");
    if (text) stream.text += text;
    if (error) stream.error = error;
    if (!final && !stream.requested && text && text[0]) {
      // The pinned C API explicitly permits cancellation from a nonfinal callback.
      stream.api.Check(stream.api.litert_lm_session_cancel_process(stream.session), "cancel");
      stream.requested = true;
    }
    stream.final = final;
  } catch (const std::exception& error) {
    // An accessor/cancellation failure is not a final callback. This isolated
    // test process cannot safely unwind callback storage on an ABI failure.
    std::cerr << "Cancellation callback failed: " << error.what() << '\n';
    std::_Exit(1);
  }
  stream.changed.notify_all();
}

void Score(Api& api, LiteRtLmSession* session, const std::string& target,
           const q::fs::path& output) {
  const char* targets[] = {target.c_str()};
  LiteRtLmResponses* raw = nullptr;
  api.Check(api.litert_lm_session_run_text_scoring(session, targets, 1, true, &raw), "text scoring");
  auto response = Owned(raw, api.litert_lm_responses_delete);
  int count = 0, length = 0;
  float total = 0;
  const float* values = nullptr;
  api.Check(api.litert_lm_responses_get_num_token_scores_at(raw, 0, &count), "score count");
  api.Check(api.litert_lm_responses_get_token_scores_at(raw, 0, &values), "token scores");
  api.Check(api.litert_lm_responses_get_token_length_at(raw, 0, &length), "score token length");
  api.Check(api.litert_lm_responses_get_score_at(raw, 0, &total), "total score");
  q::Require(count > 0 && count == length && values, "Missing or inconsistent per-token scores");
  std::string out = "index\tfloat32_bits\tvalue\n";
  for (int i = 0; i <= count; ++i) {
    const float value = i == count ? total : values[i];
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    out += (i == count ? "total" : std::to_string(i)) + "\t" +
           std::to_string(bits) + "\t" + q::Number(value) + "\n";
  }
  q::Write(output, out);
}

std::string HistoryHash(const std::string& history) {
#if defined(__APPLE__)
  q::Require(history.size() <= std::numeric_limits<CC_LONG>::max(), "History exceeds SHA256 input limit");
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  q::Require(CC_SHA256(history.data(), static_cast<CC_LONG>(history.size()), digest) != nullptr,
             "CC_SHA256 failed");
  std::ostringstream result;
  for (auto byte : digest) result << std::hex << std::setfill('0') << std::setw(2) << static_cast<int>(byte);
  return result.str();
#else
  (void)history;
  throw std::runtime_error("Conversation history binding requires the native macOS CommonCrypto build");
#endif
}

std::string Json(Api& api, LiteRtLmJsonResponse* raw) {
  auto response = Owned(raw, api.litert_lm_json_response_delete);
  const char* text = nullptr;
  api.Check(api.litert_lm_json_response_get_string(raw, &text), "JSON response");
  q::Require(text != nullptr, "Null JSON response");
  return text;
}

void RunConversation(Api& api, LiteRtLmEngine* engine, LiteRtLmSessionConfig* session_config,
                     const q::Fields& args, q::Fields& record, const q::fs::path& output) {
  const auto get = [&](const std::string& key) {
    const auto found = args.find(key);
    return found == args.end() ? std::string{} : found->second;
  };
  const auto mode = record.at("mode");
  const bool incremental = get("incremental") == "1";
  const bool bounded = get("bounded") == "1";
  PeakMemory memory;
  const bool save = mode == "conversation-save", restore = mode == "conversation-restore";
  const bool malformed = mode == "conversation-reject-malformed";
  const bool populated = mode == "conversation-reject-populated";
  const bool reject = mode == "conversation-reject-history" || malformed || populated;
  q::Require(!(save || restore || reject) || (api.history && api.conversation_save && api.conversation_load),
             "Runtime lacks conversation persistence symbols");
  q::Require(!api.history || api.count_tokens,
             "Patched runtime lacks conversation count_tokens");
  LiteRtLmConversationConfig* config_raw = nullptr;
  api.Check(api.litert_lm_conversation_config_create(&config_raw), "conversation config");
  auto config = Owned(config_raw, api.litert_lm_conversation_config_delete);
  api.Check(api.litert_lm_conversation_config_set_session_config(config_raw, session_config), "conversation session config");
  api.Check(api.litert_lm_conversation_config_set_filter_channel_content_from_kv_cache(config_raw, false),
             "disable KV channel filtering");
  LiteRtLmThinkingConfig* thinking_raw = nullptr;
  api.Check(api.litert_lm_thinking_config_create(&thinking_raw), "thinking config");
  auto thinking = Owned(thinking_raw, api.litert_lm_thinking_config_delete);
  api.Check(api.litert_lm_thinking_config_set_enable_thinking(thinking_raw, false), "disable thinking");
  api.Check(api.litert_lm_conversation_config_set_thinking_config(config_raw, thinking_raw), "set thinking config");
  LiteRtLmConversation* raw = nullptr;
  api.Check(api.litert_lm_conversation_create(engine, config_raw, &raw), "conversation create");
  auto conversation = Owned(raw, api.litert_lm_conversation_delete);
  const auto token_count = [&] {
    int count = 0;
    api.Check(api.litert_lm_conversation_get_token_count(raw, &count), "conversation token count");
    return count;
  };
  const auto check_count_tokens = [&](const std::string& message, const std::string& phase) {
    if (!api.count_tokens) return;  // The pinned baseline has no additive API.
    q::Require(api.history != nullptr && message.find('\0') == std::string::npos,
               "Cannot verify token counting without valid history/message access");
    api.Check(api.litert_lm_conversation_wait_until_done(raw), "count tokens completion barrier");
    LiteRtLmJsonResponse* before_raw = nullptr;
    api.Check(api.history(raw, &before_raw), "history before count tokens");
    const auto before_history = Json(api, before_raw);
    const int before_tokens = token_count();
    int input_tokens = -1;
    const auto start = Clock::now();
    api.Check(api.count_tokens(raw, message.c_str(), nullptr, nullptr, &input_tokens), "count next input tokens");
    record[phase + "_count_tokens_ms"] = q::Number(Milliseconds(start));
    LiteRtLmJsonResponse* after_raw = nullptr;
    api.Check(api.history(raw, &after_raw), "history after count tokens");
    const auto after_history = Json(api, after_raw);
    q::Require(input_tokens > 0 && before_tokens == token_count() &&
                   before_history == after_history,
               "Counting the selected input mutated conversation state or returned no tokens");
    record[phase + "_input_tokens_counted"] = std::to_string(input_tokens);
  };
  const auto send = [&](const std::string& message) {
    q::Require(message.find('\0') == std::string::npos, "NUL in message JSON");
    LiteRtLmJsonResponse* response = nullptr;
    api.Check(api.litert_lm_conversation_send_message(raw, message.c_str(), nullptr, nullptr, &response),
               "conversation send");
    auto text = Json(api, response);
    api.Check(api.litert_lm_conversation_wait_until_done(raw), "conversation completion barrier");
    return text;
  };
  if (mode == "conversation-reference" || save || populated) {
    const auto message = q::Read(get("message"));
    q::Write(output / "message.json", message);
    check_count_tokens(message, "first");
    const auto start = Clock::now();
    q::Write(output / "first-response.json", send(message));
    record["first_turn_ms"] = q::Number(Milliseconds(start));
  }
  
  std::future<std::pair<double, size_t>> background;
  std::shared_ptr<LiteRtLmCacheSnapshot> previous_capture;
  const auto capture_write = [&](const std::string& path, const std::string& key,
                                  const std::string& previous, const std::string& label,
                                  std::shared_future<std::pair<double, size_t>> previous_write = {}) {
    q::Require(api.capture && api.write_snapshot && api.delete_snapshot, "Missing snapshot API");
    LiteRtLmCacheSnapshot* snapshot = nullptr;
    PeakMemory capture_memory;
    const auto barrier = Clock::now();
    if (bounded) {
      q::Require(api.capture_bounded != nullptr, "Missing bounded capture API");
      api.Check(api.capture_bounded(raw, output.c_str(), previous_capture.get(), &snapshot), "capture bounded snapshot");
    } else { api.Check(api.capture(raw, &snapshot), "capture immutable snapshot"); }
    record[label + "_capture_pause_ms"] = q::Number(Milliseconds(barrier));
    capture_memory.Stop();
    record[label + "_capture_peak_bytes"] = std::to_string(capture_memory.peak);
    record[label + "_capture_peak_rss_bytes"] = std::to_string(capture_memory.rss);
    auto owned = std::shared_ptr<LiteRtLmCacheSnapshot>(snapshot, api.delete_snapshot);
    if (bounded) previous_capture = owned;
    record[label + "_capture_footprint_bytes"] = std::to_string(Footprint());
    const std::string reference_path = get("full-reference") == "1" ? path + ".full-reference" : "";
    if (!reference_path.empty()) {
      // Qualification only: independently serialize every byte from the same
      // paused live state. This does not reset the bounded capture's dirty tags.
      LiteRtLmCacheSnapshot* reference = nullptr;
      api.Check(api.capture(raw, &reference), "capture full comparison reference");
      auto reference_owner = std::shared_ptr<LiteRtLmCacheSnapshot>(reference, api.delete_snapshot);
      size_t ignored = 0;
      api.Check(api.write_snapshot(reference, reference_path.c_str(), key.c_str(), nullptr, &ignored),
                "write full comparison reference");
    }
    return std::async(std::launch::async, [&, owned, path, key, previous, previous_write] {
      auto snapshot = owned.get();
      if (previous_write.valid()) (void)previous_write.get();
      size_t written = 0;
      const auto start = Clock::now();
      api.Check(api.write_snapshot(snapshot, path.c_str(), key.c_str(),
                    previous.empty() ? nullptr : previous.c_str(), &written), "write snapshot");
      return std::make_pair(Milliseconds(start), written);
    });
  };
  if (save) {
    LiteRtLmJsonResponse* history_raw = nullptr;
    api.Check(api.history(raw, &history_raw), "get completed history");
    const auto history = Json(api, history_raw);
    q::Write(output / "history.json", history);
    const auto hash = HistoryHash(history);
    const auto key = get("key") + ":history-sha256:" + hash;
    record["history_sha256"] = hash;
    record["idle_before_save_bytes"] = std::to_string(incremental ? Footprint() : IdleFootprint());
    const auto start = Clock::now();
    if (incremental) {
      background = capture_write(get("cache"), key, "", "first");
    } else {
      api.Check(api.conversation_save(raw, get("cache").c_str(), key.c_str()), "save conversation");
    }
    record["save_ms"] = q::Number(Milliseconds(start));
    if (!incremental) record["cache_bytes"] = std::to_string(q::fs::file_size(get("cache")));
    record["idle_after_save_bytes"] = std::to_string(incremental ? Footprint() : IdleFootprint());
  } else if (restore || reject) {
    const auto history = q::Read(get("history"));
    q::Require(history.find('\0') == std::string::npos, "NUL in history JSON");
    const auto hash = HistoryHash(history);
    // App fixtures already bind configuration and history in their own key.
    // Pass that exact key without adding the driver's fixture suffix.
    const auto key = get("exact-key") == "1"
        ? get("key") : get("key") + ":history-sha256:" + hash;
    record["history_sha256"] = hash;
    const int before = token_count();
    record["idle_before_load_bytes"] = std::to_string(incremental ? Footprint() : IdleFootprint());
    const auto start = Clock::now();
    const auto status = api.conversation_load(raw, get("cache").c_str(), key.c_str(), history.c_str());
    record["load_ms"] = q::Number(Milliseconds(start));
    record["load_status"] = std::to_string(status);
    if (restore) {
      api.Check(status, "restore conversation");
      LiteRtLmJsonResponse* restored_raw = nullptr;
      api.Check(api.history(raw, &restored_raw), "get restored history");
      q::Require(Json(api, restored_raw) == history, "Restored history differs from committed bytes");
      q::Write(output / "history.json", history);
    } else {
      const auto expected = malformed ? kLiteRtLmStatusInvalidArgument : kLiteRtLmStatusFailedPrecondition;
      q::Require(status == expected && token_count() == before,
                 "Invalid history/load target was not rejected before session mutation");
    }
    record["idle_after_load_bytes"] = std::to_string(incremental ? Footprint() : IdleFootprint());
  }
  if (!get("replay-history").empty()) {
    q::Require(api.replay_history, "Missing history suffix API");
    const auto started = Clock::now();
    api.Check(api.replay_history(raw, q::Read(get("replay-history")).c_str()), "replay corrected history");
    record["replay_ms"] = q::Number(Milliseconds(started));
  }
  if (!get("stream-pcm").empty()) {
    q::Require(api.begin_audio && api.append_audio && api.finish_audio, "Missing streaming APIs");
    const auto pcm = q::Read(get("stream-pcm"));
    q::Require(pcm.size() % sizeof(float) == 0, "Invalid float PCM size");
    std::vector<float> samples(pcm.size() / sizeof(float));
    std::memcpy(samples.data(), pcm.data(), pcm.size());
    const auto prototype = q::Read(get("next-message"));
    auto started = Clock::now();
    api.Check(api.begin_audio(raw, prototype.c_str()), "begin streaming audio");
    record["stream_begin_ms"] = q::Number(Milliseconds(started));
    started = Clock::now();
    const size_t chunk = q::Integer(get("stream-chunk"), 1, 16000);
    for (size_t offset = 0; offset < samples.size(); offset += chunk) {
      api.Check(api.append_audio(raw, samples.data() + offset,
          std::min(chunk, samples.size() - offset)), "append streaming audio");
    }
    record["stream_append_ms"] = q::Number(Milliseconds(started));
    started = Clock::now();
    api.Check(api.finish_audio(raw), "finish streaming audio");
    record["stream_finish_ms"] = q::Number(Milliseconds(started));
  }
  record["conversation_boundary_tokens"] = std::to_string(token_count());
  record["idle_before_continuation_bytes"] = std::to_string(incremental ? Footprint() : IdleFootprint());
  const auto next = q::Read(get("next-message"));
  q::Write(output / "next.json", next);
  check_count_tokens(next, "continuation");
  const auto start = Clock::now();
  q::Write(output / "continuation.json", send(next));
  record["continuation_turn_ms"] = q::Number(Milliseconds(start));
  record["conversation_final_tokens"] = std::to_string(token_count());
  if (save && incremental) {
    auto first_write = background.share();
    const auto second_barrier = Clock::now();
    LiteRtLmJsonResponse* history_raw = nullptr;
    api.Check(api.history(raw, &history_raw), "history after second turn");
    const auto history = Json(api, history_raw);
    q::Write(output / "second-history.json", history);
    const auto key = get("key") + ":history-sha256:" + HistoryHash(history);
    background = capture_write(get("cache") + ".second", key, get("cache"), "second", first_write);
    record["second_turn_barrier_ms"] = q::Number(Milliseconds(second_barrier));
    const auto next_start = Clock::now();
    q::Write(output / "third-response.json", send(next));
    record["third_turn_ms"] = q::Number(Milliseconds(next_start));
    record["third_final_tokens"] = std::to_string(token_count());
    auto first = first_write.get();
    record["first_background_write_ms"] = q::Number(first.first);
    record["first_written_bytes"] = std::to_string(first.second);
    auto second = background.get();
    record["second_background_write_ms"] = q::Number(second.first);
    record["second_written_bytes"] = std::to_string(second.second);
    record["second_cache_bytes"] = std::to_string(q::fs::file_size(get("cache") + ".second"));
    if (get("steady") == "1") {
      LiteRtLmJsonResponse* third_history = nullptr;
      api.Check(api.history(raw, &third_history), "get steady history");
      const auto json = Json(api, third_history);
      q::Write(output / "third-history.json", json);
      const auto start = Clock::now();
      auto steady_write = capture_write(get("cache") + ".third",
          get("key") + ":history-sha256:" + HistoryHash(json), get("cache") + ".second", "steady");
      record["steady_turn_barrier_ms"] = q::Number(Milliseconds(start));
      const auto fourth_start = Clock::now();
      q::Write(output / "fourth-response.json", send(q::Read(get("next-message"))));
      record["fourth_turn_ms"] = q::Number(Milliseconds(fourth_start));
      record["fourth_final_tokens"] = std::to_string(token_count());
      const auto written = steady_write.get();
      record["steady_background_write_ms"] = q::Number(written.first);
      record["steady_written_bytes"] = std::to_string(written.second);
    }

  }

  if (mode == "conversation-reference" && get("steady") == "1") {
    const auto third_start = Clock::now();
    q::Write(output / "third-response.json", send(next));
    record["third_turn_ms"] = q::Number(Milliseconds(third_start));
    record["third_final_tokens"] = std::to_string(token_count());
    const auto fourth_start = Clock::now();
    q::Write(output / "fourth-response.json", send(next));
    record["fourth_turn_ms"] = q::Number(Milliseconds(fourth_start));
    record["fourth_final_tokens"] = std::to_string(token_count());
  }

  if (api.history) {
    LiteRtLmJsonResponse* final_history = nullptr;
    api.Check(api.history(raw, &final_history), "final canonical history");
    const auto history = Json(api, final_history);
    q::Write(output / "final-history.json", history);
    if (!get("post-cache").empty()) {
      q::Require(api.conversation_save, "Missing conversation save API");
      const auto key = get("key") + ":history-sha256:" + HistoryHash(history);
      api.Check(api.conversation_save(raw, get("post-cache").c_str(), key.c_str()), "save after replay and continuation");
    }
  }
  if (!get("after-message").empty()) {
    q::Write(output / "after-response.json", send(q::Read(get("after-message"))));
    record["after_tokens"] = std::to_string(token_count());
  }
  memory.Stop();
  record["sampled_peak_footprint_bytes"] = std::to_string(memory.peak);
  record["sampled_peak_rss_bytes"] = std::to_string(memory.rss);
  record["kernel_lifetime_peak_footprint_bytes"] = std::to_string(memory.kernel_peak);
  record["kernel_lifetime_peak_rss_bytes"] = std::to_string(memory.kernel_rss);
  record["bounded_capture"] = bounded ? "1" : "0";
  record["full_reference_saved"] = get("full-reference") == "1" ? "1" : "0";
  record["idle_after_continuation_bytes"] = std::to_string(incremental ? Footprint() : IdleFootprint());
  record["status"] = "OK";
  q::WriteFields(output / "metrics.tsv", record);
}

int main(int argc, char** argv) {
  q::fs::path output;
  try {
    const auto args = q::Arguments(argc, argv);
    const auto get = [&](const std::string& key, const std::string& fallback = "") {
      const auto found = args.find(key);
      return found == args.end() ? fallback : found->second;
    };
    const std::vector<std::string> names = {"exact-key", "full-reference", "steady", "bounded", "incremental", "library", "model", "out", "mode", "prefix-tokens",
      "prefix", "next", "score", "capacity", "mtp", "decode-tokens", "cache", "key",
      "message", "next-message", "history", "replay-history", "stream-pcm", "stream-chunk", "post-cache", "after-message", "prefix", "tokenize-lines"};
    for (const auto& [name, value] : args) {
      q::Require(std::find(names.begin(), names.end(), name) != names.end(), "Unknown --" + name);
    }
    const auto mode = get("mode", "reference");
    const bool conversation = mode.rfind("conversation-", 0) == 0;
    q::Require(mode == "reference" || mode == "save" || mode == "restore" || mode == "cancel" ||
                   mode == "fresh" || mode == "reject-corrupt" || mode == "reject-key" ||
                   mode == "conversation-reference" || mode == "conversation-save" ||
                   mode == "conversation-restore" || mode == "conversation-reject-history" ||
                   mode == "conversation-reject-malformed" || mode == "conversation-reject-populated" ||
                   mode == "conversation-fresh",
               "Unknown mode");
    const int requested = q::Integer(get("capacity", "4096"), 4, 131071);
    const int capacity = q::AlignedCapacity(requested);
    const int decode_tokens = q::Integer(get("decode-tokens", "64"), 1, 4096);
    const int prefix_tokens = q::Integer(get("prefix-tokens", "512"), 64, 130000);
    const bool mtp = q::Integer(get("mtp", "1"), 0, 1) != 0;
    q::Require(q::fs::path(get("model")).is_absolute() && q::fs::is_regular_file(get("model")),
               "--model must be an absolute path to the real model artifact");
    q::Require(prefix_tokens + 2 * decode_tokens + 128 < capacity,
               "Requested fixture does not leave safe context capacity");
    output = get("out");
    q::Require(!output.empty() && !q::fs::exists(output), "Output directory must be new");
    q::fs::create_directories(output);
    const bool persistence = mode != "reference" && mode != "fresh" &&
                             mode != "conversation-reference" && mode != "conversation-fresh";
    q::Require(!persistence || (!get("cache").empty() && !get("key").empty()),
               "Persistence modes require --cache and --key");
    q::Fields record{{"format", "call-gemma-qualification-1"}, {"mode", mode},
      {"pid", std::to_string(getpid())}, {"capacity_requested", std::to_string(requested)},
      {"capacity_effective", std::to_string(capacity)}, {"mtp_requested", mtp ? "1" : "0"},
      {"prefix_requested_tokens", std::to_string(prefix_tokens)},
      {"decode_token_limit", std::to_string(decode_tokens)}, {"score_mode", get("score").empty() ? "0" : "1"},
      {"conversation_mode", conversation ? "1" : "0"}};
    utsname system{};
    q::Require(uname(&system) == 0, "uname failed");
    record["platform"] = system.sysname;
    Api api(get("library"));
    record["api_version"] = api.version;
    record["library_loaded"] = api.loaded_path;
    record["library_sha256"] = HistoryHash(q::Read(api.loaded_path));
    record["single_token_prefill"] = std::getenv("CALL_GEMMA_QUALIFY_SINGLE_TOKEN_PREFILL") ? "1" : "0";
    record["stream_chunk_samples"] = get("stream-chunk", "0");
    q::Require(!persistence || conversation || (api.save && api.load), "This runtime lacks persistence symbols");
    LiteRtLmEngineSettings* settings_raw = nullptr;
    api.Check(api.litert_lm_engine_settings_create(get("model").c_str(), "gpu", nullptr, conversation ? "cpu" : nullptr,
                                                   &settings_raw), "engine settings");
    auto settings = Owned(settings_raw, api.litert_lm_engine_settings_delete);
    api.Check(api.litert_lm_engine_settings_set_max_num_tokens(settings_raw, capacity), "set capacity");
    api.Check(api.litert_lm_engine_settings_set_enable_speculative_decoding(settings_raw, mtp), "engine MTP");
    // Do not set benchmark token counts: those APIs replace real input tokens.
    api.Check(api.litert_lm_engine_settings_enable_benchmark(settings_raw), "enable timing");
    LiteRtLmEngine* engine_raw = nullptr;
    auto started = Clock::now();
    api.Check(api.litert_lm_engine_create(settings_raw, &engine_raw), "engine create");
    auto engine = Owned(engine_raw, api.litert_lm_engine_delete);
    if (!get("tokenize-lines").empty()) {
      std::istringstream lines(q::Read(get("tokenize-lines")));
      std::ostringstream results;
      std::string text;
      while (std::getline(lines, text)) {
        LiteRtLmTokenizeResult* result = nullptr;
        api.Check(api.litert_lm_engine_tokenize(engine_raw, text.c_str(), &result), "tokenize greeting");
        auto owned = Owned(result, api.litert_lm_tokenize_result_delete);
        size_t count = 0; const int* ids = nullptr;
        api.Check(api.litert_lm_tokenize_result_get_num_tokens(result, &count), "token count");
        api.Check(api.litert_lm_tokenize_result_get_tokens(result, &ids), "token ids");
        results << count << "\t" << text << "\t";
        for (size_t i = 0; i < count; ++i) results << ids[i] << ",";
        results << "\n";
      }
      q::Write(output / "greeting-tokens.tsv", results.str());
      return 0;
    }

    record["engine_init_ms"] = q::Number(Milliseconds(started));
    LiteRtLmSessionConfig* config_raw = nullptr;
    api.Check(api.litert_lm_session_config_create(&config_raw), "session config");
    auto config = Owned(config_raw, api.litert_lm_session_config_delete);
    LiteRtLmSamplerParams* sampler_raw = nullptr;
    api.Check(api.litert_lm_sampler_params_create(kLiteRtLmSamplerTypeGreedy, &sampler_raw), "greedy sampler");
    auto sampler = Owned(sampler_raw, api.litert_lm_sampler_params_delete);
    // GPU samplers construct a top-k graph even for GREEDY. The C API's
    // default k=0 produces a zero-channel softmax; k=1 is explicit argmax.
    api.Check(api.litert_lm_sampler_params_set_top_k(sampler_raw, 1), "greedy top-k");
    api.Check(api.litert_lm_sampler_params_set_seed(sampler_raw, 7319), "sampling seed");
    api.Check(api.litert_lm_session_config_set_sampler_params(config_raw, sampler_raw), "set sampler");
    api.Check(api.litert_lm_session_config_set_enable_speculative_decoding(config_raw, mtp), "session MTP");
    api.Check(api.litert_lm_session_config_set_apply_prompt_template(config_raw, false), "raw fixture mode");
    api.Check(api.litert_lm_session_config_set_max_output_tokens(config_raw, decode_tokens), "output limit");
    if (conversation) {
      RunConversation(api, engine_raw, config_raw, args, record, output);
      return 0;
    }
    LiteRtLmSession* session_raw = nullptr;
    api.Check(api.litert_lm_engine_create_session(engine_raw, config_raw, &session_raw), "session create");
    auto session = Owned(session_raw, api.litert_lm_session_delete);
    const bool history = mode == "reference" || mode == "save" || mode == "cancel";
    if (history) {
      const auto prefix = get("prefix").empty() ? Prompt(api, engine_raw, prefix_tokens) : q::Read(get("prefix"));
      q::Require(prefix.find('\0') == std::string::npos, "NUL in text fixture");
      const auto ids = Tokens(api, engine_raw, prefix);
      record["prefix_input_tokens"] = std::to_string(ids.size());
      q::Write(output / "prefix.txt", prefix);
      started = Clock::now();
      Prefill(api, session_raw, prefix);
      record["prefix_prefill_ms"] = q::Number(Milliseconds(started));
      started = Clock::now();
      const auto response = Decode(api, session_raw);
      record["prefix_decode_ms"] = q::Number(Milliseconds(started));
      q::Write(output / "prefix-response.txt", response);
      const auto counts = Benchmark(api, session_raw);
      record["prefix_prefill_tokens"] = std::to_string(counts.prefill);
      record["prefix_decode_tokens"] = std::to_string(counts.decode);
      q::Require(counts.decode > 0, "History decode produced no benchmark tokens");
    }
    if (mode == "save" || mode == "cancel") {
      record["idle_before_save_bytes"] = std::to_string(IdleFootprint());
      started = Clock::now();
      api.Check(api.save(session_raw, get("cache").c_str(), get("key").c_str()), "save cache");
      record["save_ms"] = q::Number(Milliseconds(started));
      record["cache_bytes"] = std::to_string(q::fs::file_size(get("cache")));
      record["idle_after_save_bytes"] = std::to_string(IdleFootprint());
    } else if (mode == "restore" || mode == "reject-corrupt" || mode == "reject-key") {
      record["idle_before_load_bytes"] = std::to_string(IdleFootprint());
      started = Clock::now();
      const auto status = api.load(session_raw, get("cache").c_str(), get("key").c_str());
      record["load_ms"] = q::Number(Milliseconds(started));
      record["load_status"] = std::to_string(status);
      if (mode == "restore") {
        api.Check(status, "load cache");
      } else {
        const auto expected = mode == "reject-corrupt" ? kLiteRtLmStatusDataLoss : kLiteRtLmStatusFailedPrecondition;
        q::Require(status == expected, "Cache rejection returned the wrong status: " + std::to_string(status));
        // Both errors originate in file validation before any tensor transfer.
        // The following fresh-turn comparison tests that rejected input did not
        // alter the newly created session. Device-transfer failures never reuse it.
      }
      record["idle_after_load_bytes"] = std::to_string(IdleFootprint());
    }
    record["idle_before_continuation_bytes"] = std::to_string(IdleFootprint());
    const auto next = get("next").empty() ? "\nWhat was the gate code? Answer it, then count from one:" : q::Read(get("next"));
    q::Require(next.find('\0') == std::string::npos, "NUL in text fixture");
    q::Write(output / "next.txt", next);
    const auto before = Benchmark(api, session_raw);
    started = Clock::now();
    Prefill(api, session_raw, next);
    record["prefill_ms"] = q::Number(Milliseconds(started));
    if (mode == "cancel") {
      Stream stream{api, session_raw, {}, {}, false, false, {}, {}};
      started = Clock::now();
      try {
        api.Check(api.litert_lm_session_run_decode_async(session_raw, CancelCallback, &stream), "async decode");
      } catch (const std::exception& error) {
        std::cerr << "Cancellation stream start failed: " << error.what() << '\n';
        std::_Exit(1);  // A failed start must not release possibly borrowed data.
      }
      {
        std::unique_lock<std::mutex> lock(stream.mutex);
        if (!stream.changed.wait_for(lock, std::chrono::minutes(10), [&] { return stream.final; })) {
          // Returning would destroy callback state while the runtime can still
          // use it. Terminate this isolated qualification process on timeout.
          std::cerr << "Cancellation timed out\n";
          std::_Exit(124);
        }
      }
      // The C Session API has no wait function, and its destructor ignores a
      // bounded wait's error. Keep callback storage alive until engine deletion
      // joins both execution and callback pools, even after the final chunk.
      session.reset();
      engine.reset();
      record["cancel_ms"] = q::Number(Milliseconds(started));
      q::Require(stream.requested && stream.error.find("CANCELLED") != std::string::npos,
                 "Did not observe requested cancellation followed by a cancelled final chunk");
      record["cancelled_session_discarded"] = "1";
      q::Write(output / "cancelled-partial.txt", stream.text);
    } else if (!get("score").empty()) {
      const auto target = q::Read(get("score"));
      Score(api, session_raw, target, output / "scores.tsv");
    } else {
      started = Clock::now();
      const auto response = Decode(api, session_raw);
      const double elapsed = Milliseconds(started);
      q::Write(output / "continuation.txt", response);
      const auto after = Benchmark(api, session_raw);
      const int count = after.decode - before.decode;
      q::Require(count > 0, "Continuation produced no benchmark tokens");
      record["decode_ms"] = q::Number(elapsed);
      record["decode_tokens"] = std::to_string(count);
      record["decode_ms_per_token"] = q::Number(elapsed / count);
      record["runtime_decode_tps"] = q::Number(after.last_decode_tps);
      record["continuation_prefill_tokens"] = std::to_string(after.prefill - before.prefill);
    }
  record["idle_after_continuation_bytes"] = std::to_string(IdleFootprint());
    rusage usage{};
    q::Require(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed");
#if defined(__APPLE__)
    record["peak_rss_bytes"] = std::to_string(usage.ru_maxrss);
#else
    record["peak_rss_bytes"] = std::to_string(static_cast<uint64_t>(usage.ru_maxrss) * 1024);
#endif
    record["status"] = "OK";
    q::WriteFields(output / "metrics.tsv", record);
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    if (!output.empty() && q::fs::is_directory(output)) {
      try { q::Write(output / "error.txt", std::string(error.what()) + "\n"); } catch (...) {}
    }
    return 1;
  }
}
