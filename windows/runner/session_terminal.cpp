#include "session_terminal.h"

#include <shellapi.h>

#include <cerrno>
#include <cstdlib>
#include <cstdint>
#include <iterator>
#include <memory>
#include <stdexcept>

namespace {
std::wstring Wide(const std::string& text) {
  if (text.size() > 16384) throw std::invalid_argument("Argument too long");
  for (const unsigned char c : text) {
    if (c < 32 || c == 127) throw std::invalid_argument("Control character");
  }
  if (text.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                       static_cast<int>(text.size()), nullptr, 0);
  if (size == 0) throw std::invalid_argument("Invalid UTF-8");
  std::wstring value(size, L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), value.data(), size)) {
    throw std::invalid_argument("Invalid UTF-8");
  }
  return value;
}

std::wstring Quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (const wchar_t c : value) {
    if (c == L'\\') {
      ++slashes;
      continue;
    }
    result.append(slashes * (c == L'"' ? 2 : 1), L'\\');
    slashes = 0;
    if (c == L'"') result += L'\\';
    result += c;
  }
  result.append(slashes * 2, L'\\');
  return result + L'"';
}

std::wstring Executable() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(),
                                       static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) throw std::runtime_error("Executable path");
  path.resize(size);
  return path;
}

DWORD Launch(HWND owner, const wchar_t* verb, const std::wstring& executable,
             const std::wstring& parameters) {
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
  info.hwnd = owner;
  info.lpVerb = verb;
  info.lpFile = executable.c_str();
  info.lpParameters = parameters.c_str();
  wchar_t directory[MAX_PATH];
  const auto length = GetWindowsDirectoryW(directory, MAX_PATH);
  if (length > 0 && length < MAX_PATH) info.lpDirectory = directory;
  info.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&info)) return GetLastError();
  if (info.hProcess) CloseHandle(info.hProcess);
  return ERROR_SUCCESS;
}
}  // namespace

bool IsContextElevated() noexcept {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  const bool elevated =
      GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation),
                          &size) && elevation.TokenIsElevated != 0;
  CloseHandle(token);
  return elevated;
}

DWORD ReadTerminalSettings(std::string* settings) noexcept {
  if (!settings) return ERROR_INVALID_PARAMETER;
  try {
    wchar_t base[32768];
    const auto size = GetEnvironmentVariableW(L"LOCALAPPDATA", base,
                                              static_cast<DWORD>(std::size(base)));
    if (size == 0 || size >= std::size(base)) return ERROR_PATH_NOT_FOUND;
    for (const auto* relative : {
        L"\\Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState\\settings.json",
        L"\\Packages\\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\\LocalState\\settings.json",
        L"\\Packages\\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\\LocalState\\settings.json",
        L"\\Microsoft\\Windows Terminal\\settings.json"}) {
      const auto path = std::wstring(base) + relative;
      const HANDLE file = CreateFileW(
          path.c_str(), GENERIC_READ,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file == INVALID_HANDLE_VALUE) {
        const auto error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) continue;
        return error;
      }
      const std::unique_ptr<void, decltype(&CloseHandle)> owned(file, &CloseHandle);
      LARGE_INTEGER length{};
      if (!GetFileSizeEx(file, &length) || length.QuadPart <= 0 ||
          length.QuadPart > 1024 * 1024) {
        return ERROR_BAD_LENGTH;
      }
      std::string data(static_cast<size_t>(length.QuadPart), '\0');
      DWORD read = 0;
      const bool success = ReadFile(file, data.data(),
                                   static_cast<DWORD>(data.size()), &read, nullptr);
      const auto error = success ? ERROR_READ_FAULT : GetLastError();
      if (!success || read != data.size()) return error;
      *settings = std::move(data);
      return ERROR_SUCCESS;
    }
    return ERROR_FILE_NOT_FOUND;
  } catch (...) {
    return ERROR_INVALID_DATA;
  }
}

std::wstring TerminalCommandLine(const std::vector<std::string>& arguments) {
  const auto named_window = [](const std::string& value) {
    if (value.size() <= 8 || value.size() > 88 || value.rfind("context-", 0) != 0) return false;
    for (const unsigned char c : value.substr(8)) {
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-')) return false;
    }
    return true;
  };
  if (arguments.size() < 4 || arguments.size() > 40 ||
      arguments[0] != "-w" || (arguments[1] != "0" && !named_window(arguments[1])) ||
      arguments[2] != "new-tab") {
    throw std::invalid_argument("Expected a new tab in a supported window");
  }
  std::wstring line;
  bool payload = false;
  for (const auto& argument : arguments) {
    payload = payload || argument == "wsl.exe" || argument == "powershell.exe";
    auto input = Wide(argument);
    if (payload && (input.find(L' ') != std::wstring::npos ||
                    input.find(L'"') != std::wstring::npos || input.empty())) {
      // Terminal rejoins payload argv, adding quotes only around spaces.
      // Preserve the child's Windows escaping through that extra parse.
      const bool wraps = input.find(L' ') != std::wstring::npos;
      input = Quote(input);
      if (wraps) input = input.substr(1, input.size() - 2);
    }
    std::wstring value;
    // Terminal treats semicolons as action separators, even inside quoted args.
    for (const wchar_t c : input) {
      if (c == L';') value += L'\\';
      value += c;
    }
    if (!line.empty()) line += L' ';
    line += Quote(value);
  }
  if (line.size() > 30000) throw std::invalid_argument("Command line too long");
  return line;
}

DWORD OpenSessionTerminal(HWND owner,
                          const std::vector<std::string>& arguments) noexcept {
  if (!IsContextElevated()) return ERROR_ELEVATION_REQUIRED;
  try {
    const auto parameters = TerminalCommandLine(arguments);
    std::wstring path(32768, L'\0');
    const DWORD size = GetEnvironmentVariableW(
        L"LOCALAPPDATA", path.data(), static_cast<DWORD>(path.size()));
    if (size == 0 || size >= path.size()) return ERROR_PATH_NOT_FOUND;
    path.resize(size);
    path += L"\\Microsoft\\WindowsApps\\wt.exe";
    // Inherit Context's approved token; never ask for elevation per tab.
    return Launch(owner, L"open", path, parameters);
  } catch (...) {
    return ERROR_INVALID_PARAMETER;
  }
}

DWORD RestartContextElevated(HWND owner) noexcept {
  if (IsContextElevated()) return ERROR_ALREADY_EXISTS;
  try {
    const auto status = Launch(
        owner, L"runas", Executable(),
        L"--context-restart-parent " + std::to_wstring(GetCurrentProcessId()));
    if (status == ERROR_SUCCESS) PostMessageW(owner, WM_CLOSE, 0, 0);
    return status;
  } catch (...) {
    return ERROR_INVALID_PARAMETER;
  }
}

DWORD CloseSessionTerminal(const std::vector<std::string>& identity) noexcept {
  if (!IsContextElevated()) return ERROR_ELEVATION_REQUIRED;
  try {
    if (identity.size() != 3) return ERROR_INVALID_PARAMETER;
    std::vector<unsigned long long> values;
    for (const auto& text : identity) {
      if (text.empty() || text.size() > 20 || text.find_first_not_of("0123456789") != std::string::npos)
        return ERROR_INVALID_PARAMETER;
      values.push_back(std::stoull(text));
    }
    if (!values[0] || values[0] > UINTPTR_MAX || !values[1] || values[1] > MAXDWORD || !values[2])
      return ERROR_INVALID_PARAMETER;
    const auto window = reinterpret_cast<HWND>(static_cast<uintptr_t>(values[0]));
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != values[1]) return ERROR_INVALID_WINDOW_HANDLE;
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return GetLastError();
    const std::unique_ptr<void, decltype(&CloseHandle)> owned(process, &CloseHandle);
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) return GetLastError();
    const auto started = (static_cast<unsigned long long>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
    if (started != values[2]) return ERROR_INVALID_WINDOW_HANDLE;
    wchar_t executable[32768];
    DWORD length = static_cast<DWORD>(std::size(executable));
    if (!QueryFullProcessImageNameW(process, 0, executable, &length)) return GetLastError();
    const std::wstring path(executable, length);
    const auto base = path.substr(path.find_last_of(L"\\/") + 1);
    wchar_t class_name[256];
    if (_wcsicmp(base.c_str(), L"WindowsTerminal.exe") != 0 ||
        !GetClassNameW(window, class_name, static_cast<int>(std::size(class_name))) ||
        std::wstring(class_name) != L"CASCADIA_HOSTING_WINDOW_CLASS") return ERROR_INVALID_WINDOW_HANDLE;
    // Request the normal close path, including Terminal's own confirmation.
    // Never kill the process: it may own other windows and running agents.
    return PostMessageW(window, WM_CLOSE, 0, 0) ? ERROR_SUCCESS : GetLastError();
  } catch (...) {
    return ERROR_INVALID_PARAMETER;
  }
}

bool WaitForContextRestartParent() noexcept {
  int count = 0;
  auto** args = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!args) return false;
  if (count < 2 || std::wstring(args[1]) != L"--context-restart-parent") {
    LocalFree(args);
    return true;
  }
  DWORD pid = 0;
  if (count == 3) {
    wchar_t* end = nullptr;
    errno = 0;
    const auto value = wcstoul(args[2], &end, 10);
    if (errno == 0 && end != args[2] && *end == L'\0' &&
        value != GetCurrentProcessId()) {
      pid = value;
    }
  }
  LocalFree(args);
  if (pid == 0) return false;
  const HANDLE parent = OpenProcess(
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!parent) return GetLastError() == ERROR_INVALID_PARAMETER;
  bool stopped = false;
  try {
    wchar_t path[32768];
    DWORD size = static_cast<DWORD>(std::size(path));
    // Do not overlap refresh/autosave workers with the old Context process.
    stopped = QueryFullProcessImageNameW(parent, 0, path, &size) &&
              _wcsicmp(path, Executable().c_str()) == 0 &&
              WaitForSingleObject(parent, 30000) == WAIT_OBJECT_0;
  } catch (...) {
    stopped = false;
  }
  CloseHandle(parent);
  return stopped;
}
