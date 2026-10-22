// Copyright 2026. Licensed under the Apache License, Version 2.0.
#ifndef CALL_GEMMA_QUALIFICATION_COMMON_H_
#define CALL_GEMMA_QUALIFICATION_COMMON_H_

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace qualification {
namespace fs = std::filesystem;
using Fields = std::map<std::string, std::string>;

inline void Require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

inline std::string Read(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  Require(input.good(), "Cannot open " + path.string());
  std::ostringstream contents;
  contents << input.rdbuf();
  Require(!input.bad(), "Cannot read " + path.string());
  return contents.str();
}

inline void Write(const fs::path& path, const std::string& contents) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  Require(output.good(), "Cannot create " + path.string());
  output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
  output.close();
  Require(!output.fail(), "Cannot write " + path.string());
}

inline std::string Number(double value) {
  Require(std::isfinite(value), "Nonfinite measurement");
  std::ostringstream out;
  out << std::setprecision(17) << value;
  return out.str();
}

inline void WriteFields(const fs::path& path, const Fields& fields) {
  std::string out;
  for (const auto& [key, value] : fields) {
    Require(key.find_first_of("\t\r\n") == std::string::npos &&
                value.find_first_of("\t\r\n") == std::string::npos,
            "A TSV field contains a control character");
    out += key + "\t" + value + "\n";
  }
  Write(path, out);
}

inline Fields ReadFields(const fs::path& path) {
  Fields fields;
  std::istringstream input(Read(path));
  std::string line;
  while (std::getline(input, line)) {
    const auto tab = line.find('\t');
    Require(tab != std::string::npos && tab != 0 &&
                fields.emplace(line.substr(0, tab), line.substr(tab + 1)).second,
            "Malformed/duplicate field in " + path.string());
  }
  return fields;
}

inline double FieldNumber(const Fields& fields, const std::string& key) {
  const auto found = fields.find(key);
  Require(found != fields.end(), "Missing measurement: " + key);
  size_t consumed = 0;
  const double value = std::stod(found->second, &consumed);
  Require(consumed == found->second.size() && std::isfinite(value),
          "Invalid measurement: " + key);
  return value;
}

inline std::map<std::string, std::string> Arguments(int argc, char** argv) {
  std::map<std::string, std::string> args;
  for (int i = 1; i < argc; i += 2) {
    Require(i + 1 < argc && std::string(argv[i]).rfind("--", 0) == 0,
            "Arguments must be --name value pairs");
    Require(args.emplace(std::string(argv[i]).substr(2), argv[i + 1]).second,
            "Duplicate argument: " + std::string(argv[i]));
  }
  return args;
}

inline int Integer(const std::string& value, int low, int high) {
  size_t consumed = 0;
  const long long number = std::stoll(value, &consumed);
  Require(consumed == value.size() && number >= low && number <= high,
          "Integer out of range: " + value);
  return static_cast<int>(number);
}

inline double Real(const std::string& value) {
  size_t consumed = 0;
  const double number = std::stod(value, &consumed);
  Require(consumed == value.size() && std::isfinite(number), "Invalid finite number: " + value);
  return number;
}

// This mirrors the experiment's declared capacity. App policy is tested in
// the app target itself; this helper is not evidence that Swift policy ran.
inline int AlignedCapacity(int requested) {
  Require(requested >= 4 && requested <= 131071,
          "Qualification capacity must be in [4, 131071]");
  return requested - requested % 4;
}

inline double Quantile(std::vector<double> values, double fraction) {
  Require(!values.empty(), "Empty distribution");
  std::sort(values.begin(), values.end());
  const double position = fraction * static_cast<double>(values.size() - 1);
  const auto lo = static_cast<size_t>(position);
  const auto hi = std::min(lo + 1, values.size() - 1);
  return values[lo] + (values[hi] - values[lo]) * (position - lo);
}
}  // namespace qualification
#endif
