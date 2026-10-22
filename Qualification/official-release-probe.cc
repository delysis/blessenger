// Reference-only probe for the official v0.18.0 C ABI. Not the matched patch gate.
#include "conversation.h"
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

using Clock = std::chrono::steady_clock;
static double milliseconds(Clock::time_point t) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}
int main(int argc, char** argv) {
  if (argc != 4) { std::fprintf(stderr, "model message.json next.json\n"); return 2; }
  auto start = Clock::now();
  auto* settings = litert_lm_engine_settings_create(argv[1], "gpu", nullptr, "cpu");
  if (!settings) return 3;
  litert_lm_engine_settings_set_max_num_tokens(settings, 4096);
  litert_lm_engine_settings_set_audio_num_threads(settings, 2);
  litert_lm_engine_settings_set_enable_speculative_decoding(settings, true);
  auto* engine = litert_lm_engine_create(settings);
  litert_lm_engine_settings_delete(settings);
  if (!engine) return 4;
  std::printf("engine_ms\t%.3f\n", milliseconds(start)); std::fflush(stdout);
  auto* session = litert_lm_session_config_create();
  litert_lm_session_config_set_max_output_tokens(session, 64);
  litert_lm_session_config_set_apply_prompt_template(session, false);
  litert_lm_session_config_set_enable_speculative_decoding(session, true);
  auto* sampler = litert_lm_sampler_params_create(kLiteRtLmSamplerTypeGreedy);
  litert_lm_sampler_params_set_top_k(sampler, 1);
  litert_lm_session_config_set_sampler_params(session, sampler);
  auto* config = litert_lm_conversation_config_create();
  litert_lm_conversation_config_set_session_config(config, session);
  auto* thinking = litert_lm_thinking_config_create();
  litert_lm_thinking_config_set_enable_thinking(thinking, false);
  litert_lm_conversation_config_set_thinking_config(config, thinking);
  auto* conversation = litert_lm_conversation_create(engine, config);
  litert_lm_thinking_config_delete(thinking);
  litert_lm_conversation_config_delete(config);
  litert_lm_sampler_params_delete(sampler);
  litert_lm_session_config_delete(session);
  if (!conversation) { litert_lm_engine_delete(engine); return 5; }
  int result = 0;
  for (int i = 2; i < 4; ++i) {
    std::ifstream input(argv[i]); std::ostringstream json; json << input.rdbuf();
    if (!input.good() && !input.eof()) { result = 6; break; }
    start = Clock::now();
    auto* response = litert_lm_conversation_send_message(conversation, json.str().c_str(), nullptr, nullptr);
    if (!response) { result = 7; break; }
    std::printf("turn%d_ms\t%.3f\nturn%d_json\t%s\n", i-1, milliseconds(start), i-1,
                litert_lm_json_response_get_string(response));
    std::fflush(stdout);
    litert_lm_json_response_delete(response);
  }
  litert_lm_conversation_delete(conversation);
  litert_lm_engine_delete(engine);
  return result;
}
