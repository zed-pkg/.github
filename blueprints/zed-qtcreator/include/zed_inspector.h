#pragma once

#include <chrono>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace zed::qtcreator {
struct Command { std::string executable; std::vector<std::string> arguments; std::filesystem::path working_directory; std::chrono::seconds timeout{30}; };
struct Action { std::string id; std::string title; std::string kind; std::string command; std::vector<std::string> arguments; bool requires_confirmation{}; };
struct Issue { std::string id; std::string severity; std::string title; std::string detail; std::vector<Action> actions; };
struct Report { int schema_version{1}; std::filesystem::path workspace_root; std::vector<Issue> issues; };
class Inspector {
 public:
  explicit Inspector(std::string executable = "zed");
  [[nodiscard]] Command command_for(const std::filesystem::path& workspace_root) const;
  [[nodiscard]] Report validate_report(Report report) const;
  [[nodiscard]] static std::string redact(std::string_view text);
 private:
  std::string executable_;
};
}  // namespace zed::qtcreator
