#include "zed_inspector.h"
#include <cassert>
#include <filesystem>
#include <string>
using zed::qtcreator::Action; using zed::qtcreator::Inspector; using zed::qtcreator::Issue; using zed::qtcreator::Report;
int main() {
  Inspector inspector{"/opt/zed/bin/zed"};
  const auto command = inspector.command_for("workspace");
  assert(command.executable == "/opt/zed/bin/zed"); assert(command.arguments.size() == 4); assert(command.arguments[0] == "inspect"); assert(command.arguments[1] == "--workspace"); assert(command.arguments[3] == "--json"); assert(command.timeout.count() == 30);
  const auto redacted = Inspector::redact("Authorization: Bearer abc.def token=secret ghp_abcdefghijklmnopqrstuvwxyz");
  assert(redacted.find("secret") == std::string::npos); assert(redacted.find("ghp_") == std::string::npos); assert(redacted.find("[REDACTED]") != std::string::npos);
  Report unsafe{1, std::filesystem::path{"/workspace"}, {Issue{"lock.stale", "warning", "Stale lock", "token=secret", {Action{"install", "Install", "command", "zed", {"install"}, false}}}}};
  assert(inspector.validate_report(std::move(unsafe)).issues[0].id == "inspect.action.unsafe");
  Report unknown{2, std::filesystem::path{"/workspace"}, {}};
  assert(inspector.validate_report(std::move(unknown)).issues[0].id == "inspect.schema.unsupported");
}
