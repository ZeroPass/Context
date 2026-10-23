#include "session_terminal.h"

#include <shellapi.h>

#include <iostream>
#include <cstdint>
#include <stdexcept>

int main(int argc, char** argv) {
  int checks = 0;
  auto require = [&](bool condition) {
    ++checks;
    if (!condition) throw std::runtime_error("Terminal assertion failed");
  };
  try {
    const std::vector<std::string> args = {
        "-w", "0", "new-tab", "--title", "Name \"quoted\"; more",
        "wsl.exe", "-d", "Ubuntu-24.04", "--cd", "/home/a project/",
        "--exec", "bash", "-lic", "exec \"$@\"", "context-session",
        "codex", "resume", "session-id"};
    const auto line = TerminalCommandLine(args);
    int count = 0;
    auto** parsed = CommandLineToArgvW((L"wt.exe " + line).c_str(), &count);
    require(parsed != nullptr);
    require(count == static_cast<int>(args.size()) + 1);
    require(std::wstring(parsed[5]) == L"Name \"quoted\"\\; more");
    require(std::wstring(parsed[6]) == L"wsl.exe");
    require(std::wstring(parsed[10]) == L"/home/a project/");
    require(std::wstring(parsed[14]) == L"exec \\\"$@\\\"");
    std::wstring child;
    for (int i = 6; i < count; ++i) {
      auto argument = std::wstring(parsed[i]);
      for (auto pos = argument.find(L"\\;"); pos != std::wstring::npos;
           pos = argument.find(L"\\;", pos + 1)) {
        argument.replace(pos, 2, L";");
      }
      if (!child.empty()) child += L' ';
      const bool wraps = argument.find(L' ') != std::wstring::npos;
      child += wraps ? L"\"" + argument + L"\"" : argument;
    }
    int child_count = 0;
    auto** child_args = CommandLineToArgvW(child.c_str(), &child_count);
    require(child_args != nullptr && child_count == count - 6);
    require(std::wstring(child_args[8]) == L"exec \"$@\"");
    require(std::wstring(child_args[4]) == L"/home/a project/");
    LocalFree(child_args);
    LocalFree(parsed);
    const auto named = TerminalCommandLine({"-w", "context-g123_1", "new-tab", "wsl.exe"});
    require(named.find(L"context-g123_1") != std::wstring::npos);
    const auto trailing = TerminalCommandLine({"-w", "0", "new-tab", "C:\\path\\"});
    parsed = CommandLineToArgvW((L"wt.exe " + trailing).c_str(), &count);
    require(parsed != nullptr && count == 5);
    require(std::wstring(parsed[4]) == L"C:\\path\\");
    LocalFree(parsed);
    for (const auto& bad : std::vector<std::vector<std::string>>{
             {}, {"-w", "new", "new-tab", "wsl.exe"},
             {"-w", "context-", "new-tab", "wsl.exe"},
             {"-w", "context-group;nt", "new-tab", "wsl.exe"},
             {"-w", "0", "new-tab", "bad\narg"},
             {"-w", "0", "new-tab", std::string("\xff", 1)}}) {
      bool rejected = false;
      try {
        TerminalCommandLine(bad);
      } catch (const std::invalid_argument&) {
        rejected = true;
      }
      require(rejected);
    }
    require(WaitForContextRestartParent());
    std::string settings;
    const auto settings_error = ReadTerminalSettings(&settings);
    require(settings_error == ERROR_SUCCESS && !settings.empty());
    require(ReadTerminalSettings(nullptr) == ERROR_INVALID_PARAMETER);
    if (IsContextElevated()) {
      require(CloseSessionTerminal({}) == ERROR_INVALID_PARAMETER);
      require(CloseSessionTerminal({"1", "bad", "1"}) == ERROR_INVALID_PARAMETER);
      require(CloseSessionTerminal({"0", "1", "1"}) == ERROR_INVALID_PARAMETER);
      require(CloseSessionTerminal({"1", "1", "1"}) != ERROR_SUCCESS);
      FILETIME created{}, exited{}, kernel{}, user{};
      require(GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user));
      const auto started = (static_cast<unsigned long long>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
      const HWND own = CreateWindowExW(0, L"STATIC", L"Context test", WS_POPUP,
          0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
      require(own != nullptr);
      const auto handle = std::to_string(reinterpret_cast<uintptr_t>(own));
      const auto pid = std::to_string(GetCurrentProcessId());
      require(CloseSessionTerminal({handle, pid, std::to_string(started + 1)}) == ERROR_INVALID_WINDOW_HANDLE);
      require(CloseSessionTerminal({handle, pid, std::to_string(started)}) == ERROR_INVALID_WINDOW_HANDLE);
      require(IsWindow(own));
      DestroyWindow(own);
    }
    if (argc == 4 && std::string(argv[1]) == "--open-test-tabs") {
      require(IsContextElevated());
      for (const std::string suffix : {"1", "2"}) {
        const std::string directory = argv[2];
        const auto error = OpenSessionTerminal(nullptr, {
            "-w", "0", "new-tab", "--profile", argv[3], "--title",
            "Context test \"" + suffix + "\"; temporary",
            "wsl.exe", "-d", "Ubuntu-24.04", "--cd", directory,
            "--exec", "bash", "-lic",
            "printf '%s\\n' \"$PWD\" \"$WT_SESSION\" \"$1\" \"$WSL_DISTRO_NAME\" \"$WT_PROFILE_ID\" > \"$2\"; sleep 2",
            "context-session", "a \"literal\"; argument",
            directory + "/tab" + suffix + ".txt"});
        require(error == ERROR_SUCCESS);
      }
      std::cout << "Opened two temporary WSL test tabs.\n";
    }
    std::cout << "Checks: " << checks
              << "\nElevated: " << IsContextElevated()
              << "\nNo UAC requested.\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
