// Copyright 2026. Licensed under the Apache License, Version 2.0.
#include "common.h"

#include <array>
#include <iostream>
#include <random>
#include <set>

namespace q = qualification;
using Block = std::array<double, 4>;  // A1, B1, B2, A2, in execution order.
using Paths = std::array<q::fs::path, 4>;

struct Contract {
  std::string a_library, b_library, b_mode;
  int mtp, prefix;
};

std::map<std::string, Contract> Contracts(const std::string& baseline, const std::string& patched, int long_prefix, bool mtp_off_only = false) {
  q::Require(baseline != patched && long_prefix != 512, "Distinct binaries and workload lengths are required");
  std::map<std::string, Contract> result;
  for (int mtp : {0, 1}) {
    if (mtp_off_only && mtp != 0) continue;
    for (int prefix : {512, long_prefix}) {
      for (const std::string comparison : {"baseline-vs-patched", "post-save", "post-restore"}) {
        const auto name = comparison + "-mtp" + std::to_string(mtp) + "-prefix" + std::to_string(prefix);
        result.emplace(name, Contract{comparison == "baseline-vs-patched" ? baseline : patched,
            patched, comparison == "post-save" ? "save" : comparison == "post-restore" ? "restore" : "reference",
            mtp, prefix});
      }
    }
  }
  return result;
}

void CheckIdentity(const q::Fields& fields, const Contract& contract, size_t leg) {
  const bool a = leg == 0 || leg == 3;
  const auto mode = a ? "reference" : contract.b_mode;
  q::Require(fields.at("mode") == mode && fields.at("library_loaded") ==
                 (a ? contract.a_library : contract.b_library), "Trial mode/library does not match ABBA assignment");
  q::Require(fields.at("mtp_requested") == std::to_string(contract.mtp) &&
                 fields.at("prefix_requested_tokens") == std::to_string(contract.prefix) &&
                 fields.at("conversation_mode") == "0" && fields.at("score_mode") == "0",
             "Trial settings do not match the expected workload");
  if (mode == "save") {
    q::Require(q::FieldNumber(fields, "save_ms") > 0 && q::FieldNumber(fields, "cache_bytes") > 0,
               "Save trial lacks completed persistence evidence");
  } else if (mode == "restore") {
    q::Require(q::FieldNumber(fields, "load_ms") > 0 && fields.at("load_status") == "0",
               "Restore trial lacks successful load evidence");
  }
  if (mode != "restore") {
    q::Require(fields.at("prefix_input_tokens") == std::to_string(contract.prefix),
               "History input does not match the declared token fixture");
  }
}

std::vector<std::string> Split(const std::string& line) {
  std::vector<std::string> result;
  size_t begin = 0;
  for (;;) {
    const auto end = line.find('\t', begin);
    result.push_back(line.substr(begin, end == std::string::npos ? end : end - begin));
    if (end == std::string::npos) return result;
    begin = end + 1;
  }
}

double Statistic(const std::vector<Block>& blocks, double quantile, bool ratio) {
  std::vector<double> a, b;
  for (const auto& block : blocks) {
    a.insert(a.end(), {block[0], block[3]});
    b.insert(b.end(), {block[1], block[2]});
  }
  const double first = q::Quantile(a, quantile);
  const double second = q::Quantile(b, quantile);
  q::Require(!ratio || first > 0, "Nonpositive reference latency");
  return ratio ? second / first : second - first;
}

struct Estimate { double point, lower, upper; };

Estimate Bootstrap(const std::vector<Block>& blocks, double quantile, bool ratio,
                    int repetitions, double confidence) {
  q::Require(!blocks.empty() && repetitions > 0 && confidence > 0 && confidence < 1,
               "Invalid bootstrap arguments");
  std::mt19937_64 random(0x73194b5643414348ULL);
  std::uniform_int_distribution<size_t> pick(0, blocks.size() - 1);
  std::vector<double> samples;
  samples.reserve(repetitions);
  for (int i = 0; i < repetitions; ++i) {
    std::vector<Block> sample;
    sample.reserve(blocks.size());
    for (size_t j = 0; j < blocks.size(); ++j) sample.push_back(blocks[pick(random)]);
    samples.push_back(Statistic(sample, quantile, ratio));
  }
  const double tail = (1.0 - confidence) / 2.0;
  return {Statistic(blocks, quantile, ratio), q::Quantile(samples, tail),
           q::Quantile(samples, 1.0 - tail)};
}

std::string Decision(const Estimate& estimate, double limit) {
  if (estimate.upper <= limit) return "PASS";
  if (estimate.lower > limit) return "FAIL";
  return "INCONCLUSIVE";
}

void SameFile(const q::fs::path& a, const q::fs::path& b) {
  q::Require(q::Read(a) == q::Read(b), "Byte mismatch: " + a.string() + " / " + b.string());
}

void Equivalent(const q::fs::path& a, const q::fs::path& b, bool scoring) {
  const auto first = q::ReadFields(a / "metrics.tsv");
  const auto second = q::ReadFields(b / "metrics.tsv");
  for (const auto& key : {"status", "platform", "api_version", "capacity_effective",
                          "mtp_requested", "decode_token_limit", "score_mode", "conversation_mode"}) {
    q::Require(first.at(key) == second.at(key), std::string("Configuration mismatch: ") + key);
  }
  q::Require(first.at("status") == "OK" && first.at("platform") == "Darwin",
               "Device qualification requires successful native Mac runs");
  if (first.at("conversation_mode") == "1") {
    SameFile(a / "next.json", b / "next.json");
    SameFile(a / "continuation.json", b / "continuation.json");
    for (const auto& key : {"conversation_boundary_tokens", "conversation_final_tokens"}) {
      q::Require(first.at(key) == second.at(key), std::string("Conversation token mismatch: ") + key);
    }
    if (q::fs::exists(a / "message.json") && q::fs::exists(b / "message.json")) {
      SameFile(a / "message.json", b / "message.json");
      SameFile(a / "first-response.json", b / "first-response.json");
    }
    if (q::fs::exists(a / "history.json") && q::fs::exists(b / "history.json")) {
      SameFile(a / "history.json", b / "history.json");
    }
    return;
  }
  SameFile(a / "next.txt", b / "next.txt");
  if (q::fs::exists(a / "prefix.txt") && q::fs::exists(b / "prefix.txt")) {
    SameFile(a / "prefix.txt", b / "prefix.txt");
    SameFile(a / "prefix-response.txt", b / "prefix-response.txt");
    q::Require(first.at("prefix_decode_tokens") == second.at("prefix_decode_tokens"),
               "History token-count mismatch");
  }
  if (scoring) {
    // Bitwise float32 comparison, including every teacher-forced token and total.
    // This is not a comparison of the unexposed full logits or generated IDs.
    SameFile(a / "scores.tsv", b / "scores.tsv");
  } else {
    SameFile(a / "continuation.txt", b / "continuation.txt");
    q::Require(first.at("decode_tokens") == second.at("decode_tokens"),
               "Continuation token-count mismatch");
  }
}

bool CompareMtp(const q::fs::path& a, const q::fs::path& b, bool scoring,
                const q::fs::path& output) {
  const auto first = q::ReadFields(a / "metrics.tsv");
  const auto second = q::ReadFields(b / "metrics.tsv");
  for (const auto& key : {"status", "platform", "api_version", "library_loaded",
                          "capacity_effective", "decode_token_limit", "score_mode",
                          "conversation_mode", "mode", "prefix_requested_tokens"}) {
    q::Require(first.at(key) == second.at(key), std::string("Cross-MTP configuration mismatch: ") + key);
  }
  q::Require(first.at("status") == "OK" && first.at("platform") == "Darwin" &&
                 first.at("mode") == "reference" && first.at("conversation_mode") == "0" &&
                 first.at("score_mode") == (scoring ? "1" : "0") &&
                 first.at("mtp_requested") == "0" && second.at("mtp_requested") == "1",
               "Cross-MTP comparison requires successful off/on reference runs of one runtime");
  SameFile(a / "prefix.txt", b / "prefix.txt");
  SameFile(a / "next.txt", b / "next.txt");
  std::string report = "component\tmtp_off\tmtp_on\texact_agreement\n";
  bool matches = true;
  const auto compare = [&](const std::string& component, const std::string& left,
                            const std::string& right) {
    const bool same = left == right;
    matches &= same;
    report += component + "\t" + a.string() + "\t" + b.string() + "\t" +
              (same ? "MATCH" : "DIFFERENT_REQUIRES_REVIEW") + "\n";
  };
  compare("prefix_text", q::Read(a / "prefix-response.txt"), q::Read(b / "prefix-response.txt"));
  compare("prefix_token_count", first.at("prefix_decode_tokens"), second.at("prefix_decode_tokens"));
  if (scoring) {
    compare("selected_float32_scores", q::Read(a / "scores.tsv"), q::Read(b / "scores.tsv"));
  } else {
    compare("continuation_text", q::Read(a / "continuation.txt"), q::Read(b / "continuation.txt"));
    compare("continuation_token_count", first.at("decode_tokens"), second.at("decode_tokens"));
  }
  q::Write(output, report);
  std::cout << report
            << "Decode and verification use different batch shapes. Exact agreement is recorded; "
               "a mismatch requires review and is not automatically diagnosed as an MTP defect.\n";
  return matches;
}

void SelfTest() {
  q::Require(q::AlignedCapacity(4096) == 4096 && q::AlignedCapacity(4097) == 4096 &&
                 q::AlignedCapacity(4098) == 4096 && q::AlignedCapacity(4099) == 4096 &&
                 q::AlignedCapacity(131071) == 131068,
               "Capacity arithmetic failed");
  bool rejected = false;
  try { q::AlignedCapacity(3); } catch (const std::exception&) { rejected = true; }
  q::Require(rejected, "Invalid capacity was accepted");
  std::vector<Block> slower(12, Block{10, 11, 11, 10});
  const auto regression = Bootstrap(slower, 0.5, true, 1000, 0.95);
  q::Require(std::abs(regression.point - 1.1) < 1e-12 &&
                 Decision(regression, 1.0) == "FAIL", "Regression gate failed");
  std::vector<Block> identical(12, Block{10, 10, 10, 10});
  q::Require(Decision(Bootstrap(identical, 0.95, true, 1000, 0.95), 1) == "PASS",
               "Identical synthetic statistic failed");
  q::Require(Decision({1.0, 0.98, 1.02}, 1.0) == "INCONCLUSIVE",
               "Uncertain result was incorrectly accepted");
  const auto memory = Bootstrap(slower, 0.5, false, 1000, 0.95);
  q::Require(memory.point == 1 && Decision(memory, 0) == "FAIL", "Memory difference gate failed");
  q::Require(Split("a\tb\tc").size() == 3, "TSV parser failed");
  const auto contracts = Contracts("/baseline", "/patched", 1151);
  q::Require(contracts.size() == 12, "Expected workload matrix is incomplete");
  q::Require(Contracts("/baseline", "/patched", 4096 - 513).count(
                 "post-save-mtp0-prefix3583") == 1,
               "Full-position workload contract is missing");
  const auto contract = contracts.at("post-restore-mtp1-prefix1151");
  q::Fields fields{{"mode", "restore"}, {"library_loaded", "/patched"}, {"mtp_requested", "1"},
    {"prefix_requested_tokens", "1151"}, {"score_mode", "0"}, {"conversation_mode", "0"},
    {"load_ms", "12"}, {"load_status", "0"}};
  CheckIdentity(fields, contract, 1);
  for (const auto& [key, value] : q::Fields{{"mode", "reference"}, {"library_loaded", "/baseline"}, {"load_status", "15"}}) {
    auto invalid = fields;
    invalid[key] = value;
    bool rejected = false;
    try { CheckIdentity(invalid, contract, 1); } catch (const std::exception&) { rejected = true; }
    q::Require(rejected, "Mislabeled or failed-load trial was accepted");
  }
  std::cout << "PASS: arithmetic, paired bootstrap, strict gate, trial identity and TSV parser unit checks.\n"
               "Synthetic statistics only; no inference, Metal, or persistence qualification was run.\n";
}

int main(int argc, char** argv) {
  try {
    const auto args = q::Arguments(argc, argv);
    const std::vector<std::string> names = {"self-test", "compare-a", "compare-b", "scoring", "cross-mtp",
      "corrupt-copy", "out", "manifest", "min-blocks", "bootstrap", "confidence",
      "max-regression-percent", "max-retained-bytes", "max-save-ms", "max-load-ms", "check-config",
      "baseline-library", "patched-library", "long-prefix", "mtp-modes"};
    for (const auto& [name, value] : args) {
      q::Require(std::find(names.begin(), names.end(), name) != names.end(), "Unknown --" + name);
    }
    const auto get = [&](const std::string& key, const std::string& fallback = "") {
      const auto found = args.find(key);
      return found == args.end() ? fallback : found->second;
    };
    if (get("self-test") == "yes") { SelfTest(); return 0; }
    if (get("cross-mtp") == "yes") {
      return CompareMtp(get("compare-a"), get("compare-b"), get("scoring", "0") == "1", get("out")) ? 0 : 2;
    }
    if (!get("compare-a").empty()) {
      Equivalent(get("compare-a"), get("compare-b"), get("scoring", "0") == "1");
      std::cout << "PASS: public C API continuation evidence matches.\n";
      return 0;
    }
    if (!get("corrupt-copy").empty()) {
      const q::fs::path source = get("corrupt-copy"), target = get("out");
      q::Require(source != target && !q::fs::exists(target), "Corrupt-copy output must be new");
      q::fs::copy_file(source, target);
      std::fstream file(target, std::ios::in | std::ios::out | std::ios::binary);
      q::Require(file.good(), "Cannot open corrupt-copy output");
      file.seekg(-1, std::ios::end);
      char byte = 0;
      file.read(&byte, 1);
      q::Require(file.good(), "Cache is empty");
      byte ^= 1;
      file.seekp(-1, std::ios::end);
      file.write(&byte, 1);
      file.close();
      q::Require(!file.fail(), "Cannot write corrupt-copy output");
      return 0;
    }
    const int minimum_blocks = q::Integer(get("min-blocks", "12"), 12, 10000);
    const int repetitions = q::Integer(get("bootstrap", "20000"), 10000, 1000000);
    const double confidence = q::Real(get("confidence", "0.99"));
    const double margin = q::Real(get("max-regression-percent", "0"));
    const double memory_limit = q::Real(get("max-retained-bytes", "0"));
    const double save_limit = q::Real(get("max-save-ms", "0"));
    const double load_limit = q::Real(get("max-load-ms", "0"));
    q::Require(confidence >= 0.95 && confidence < 1 && std::isfinite(margin) && margin >= 0 &&
                   std::isfinite(memory_limit) && memory_limit >= 0 &&
                   std::isfinite(save_limit) && save_limit > 0 &&
                   std::isfinite(load_limit) && load_limit > 0,
               "Invalid predeclared gate parameters");
    if (get("check-config") == "yes") return 0;
    q::Require(get("mtp-modes", "both") == "both" || get("mtp-modes") == "off", "Invalid MTP scope");
    const auto contracts = Contracts(q::fs::canonical(get("baseline-library")).string(),
                                     q::fs::canonical(get("patched-library")).string(),
                                     q::Integer(get("long-prefix", "1151"), 64, 130000), get("mtp-modes") == "off");
    std::map<std::string, std::map<int, Paths>> groups;
    std::istringstream manifest(q::Read(get("manifest")));
    std::string line;
    q::Require(static_cast<bool>(std::getline(manifest, line)) && line == "group\tblock\tleg\tdirectory",
               "Wrong trial manifest header");
    const std::vector<std::string> legs = {"A1", "B1", "B2", "A2"};
    while (std::getline(manifest, line)) {
      const auto row = Split(line);
      q::Require(row.size() == 4, "Malformed trial manifest row");
      const int block = q::Integer(row[1], 0, 10000);
      const auto leg = std::find(legs.begin(), legs.end(), row[2]);
      q::Require(leg != legs.end(), "Unknown ABBA leg");
      auto& slot = groups[row[0]][block][static_cast<size_t>(leg - legs.begin())];
      q::Require(slot.empty(), "Duplicate ABBA leg");
      slot = row[3];
    }
    q::Require(!groups.empty(), "No trials");
    q::Require(groups.size() == contracts.size(), "Expected all comparison groups in the declared MTP scope");
    for (const auto& [name, contract] : contracts) {
      q::Require(groups.count(name) != 0, "Missing required group: " + name);
    }
    std::string report = "group\tmetric\tstatistic\tunit\treference\tcandidate\tpoint\tci_low\tci_high\tlimit\tdecision\n";
    bool failed = false, uncertain = false;
    for (const auto& [group, paths_by_block] : groups) {
      q::Require(paths_by_block.size() >= static_cast<size_t>(minimum_blocks),
                 "Insufficient independent ABBA blocks in " + group);
      std::map<std::string, std::vector<Block>> measurements;
      std::set<std::string> pids;
      q::fs::path reference;
      for (const auto& [index, paths] : paths_by_block) {
        for (const auto& path : paths) q::Require(!path.empty(), "Incomplete ABBA block");
        if (reference.empty()) reference = paths[0];
        std::array<q::Fields, 4> records;
        for (size_t i = 0; i < paths.size(); ++i) {
          Equivalent(reference, paths[i], false);
          records[i] = q::ReadFields(paths[i] / "metrics.tsv");
          CheckIdentity(records[i], contracts.at(group), i);
          if (records[i].at("mode") != "restore") {
            q::Require(q::fs::is_regular_file(paths[i] / "prefix.txt") &&
                           q::fs::is_regular_file(paths[i] / "prefix-response.txt"),
                         "Trial history evidence is missing");
          }
          q::Require(pids.insert(records[i].at("pid")).second, "Trials reused a process ID");
          q::Require(records[i].at("prefix_requested_tokens") ==
                         records[0].at("prefix_requested_tokens"), "Fixture length mismatch");
          q::Require(q::FieldNumber(records[i], "decode_tokens") >= 8,
                     "Too few continuation tokens for timing qualification");
        }
        for (const auto& key : {"prefill_ms", "decode_ms_per_token", "idle_before_continuation_bytes",
                                "idle_after_continuation_bytes"}) {
          Block values{};
          for (size_t i = 0; i < values.size(); ++i) {
            values[i] = q::FieldNumber(records[i], key);
            q::Require(values[i] > 0, "Invalid nonpositive measurement");
          }
          measurements[key].push_back(values);
        }
        for (const auto& key : {"save_ms", "load_ms"}) {
          if (records[1].count(key) == 0 && records[2].count(key) == 0) continue;
          q::Require(records[1].count(key) != 0 && records[2].count(key) != 0,
                     "Persistence timing missing in one B leg");
          const double first = q::FieldNumber(records[1], key), second = q::FieldNumber(records[2], key);
          q::Require(first > 0 && second > 0, "Nonpositive persistence latency");
          // A=1 makes the bootstrap ratio equal the absolute B latency, while
          // preserving the two observations from each independent ABBA block.
          measurements[key].push_back({1, first, second, 1});
        }
      }
      for (const auto& [metric, values] : measurements) {
        const bool ratio = metric.rfind("idle_", 0) != 0;
        const double limit = metric == "save_ms" ? save_limit : metric == "load_ms" ? load_limit :
                             ratio ? 1 + margin / 100 : memory_limit;
        for (const auto& [label, quantile] : std::array<std::pair<const char*, double>, 2>{
                 {{"median", 0.5}, {"p95", 0.95}}}) {
          const auto estimate = Bootstrap(values, quantile, ratio, repetitions, confidence);
          const auto decision = Decision(estimate, limit);
          std::vector<double> a, b;
          for (const auto& block : values) {
            a.insert(a.end(), {block[0], block[3]});
            b.insert(b.end(), {block[1], block[2]});
          }
          const bool absolute = metric == "save_ms" || metric == "load_ms";
          const std::string unit = absolute ? "absolute_ms" : ratio ? "candidate/reference" : "candidate-reference_bytes";
          failed |= decision == "FAIL";
          uncertain |= decision == "INCONCLUSIVE";
          report += group + "\t" + metric + "\t" + label + "\t" + unit + "\t" +
                    (absolute ? "" : q::Number(q::Quantile(a, quantile))) + "\t" +
                    q::Number(q::Quantile(b, quantile)) + "\t" + q::Number(estimate.point) +
                    "\t" + q::Number(estimate.lower) + "\t" + q::Number(estimate.upper) +
                    "\t" + q::Number(limit) + "\t" + decision + "\n";
        }
      }
    }
    q::Write(get("out"), report);
    std::cout << report;
    std::cout << "Overall timing/memory gate: " << (failed ? "FAIL" : uncertain ? "INCONCLUSIVE" : "PASS")
              << "; paired block bootstrap, confidence=" << confidence << ".\n";
    return failed ? 1 : uncertain ? 2 : 0;
  } catch (const std::exception& error) {
    std::cerr << "Qualification evidence rejected: " << error.what() << '\n';
    return 1;
  }
}
