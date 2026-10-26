#include "terminal_broker.h"
#include "session_terminal.h"
#include "terminal_probe.h"
#include <shellapi.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <wincrypt.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <thread>
#include <utility>

namespace {
using Owned = std::unique_ptr<void, decltype(&CloseHandle)>;
Owned Own(HANDLE handle) { return Owned(handle == INVALID_HANDLE_VALUE ? nullptr : handle, CloseHandle); }
constexpr DWORD kMagic = 0x43545842, kMaxWire = 65536, kMaxOutput = 256 * 1024;
std::wstring pipe_name;
Owned helper = Own(nullptr);

std::wstring Exe(HANDLE process = GetCurrentProcess()) {
  std::wstring value(32768, L'\0'); DWORD size = static_cast<DWORD>(value.size());
  if (!QueryFullProcessImageNameW(process, 0, value.data(), &size)) throw std::runtime_error("Executable identity");
  value.resize(size); return value;
}
uint64_t Started(HANDLE process) {
  FILETIME c{}, e{}, k{}, u{};
  if (!GetProcessTimes(process, &c, &e, &k, &u)) throw std::runtime_error("Process identity");
  return (static_cast<uint64_t>(c.dwHighDateTime) << 32) | c.dwLowDateTime;
}
std::wstring Sid(HANDLE process) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token)) throw std::runtime_error("Token identity");
  auto owned = Own(token); DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> data(size);
  if (!GetTokenInformation(token, TokenUser, data.data(), size, &size)) throw std::runtime_error("Token user");
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &text)) throw std::runtime_error("SID");
  std::wstring result(text); LocalFree(text); return result;
}
std::wstring Pipe(DWORD pid, const std::wstring& nonce) {
  return L"\\\\.\\pipe\\Context.Terminal." + std::to_wstring(pid) + L"." + nonce;
}
std::wstring Ready(DWORD pid, const std::wstring& nonce) {
  return L"Local\\Context.Terminal.Ready." + std::to_wstring(pid) + L"." + nonce;
}
bool Nonce(const std::wstring& text) {
  return text.size() == 36 && text.find_first_not_of(L"0123456789abcdefABCDEF-") == std::wstring::npos;
}
DWORD Remaining(ULONGLONG deadline) {
  const auto now = GetTickCount64(); return now >= deadline ? 0 : static_cast<DWORD>(deadline-now);
}
bool Transfer(HANDLE pipe, void* data, DWORD size, bool write, HANDLE parent, ULONGLONG deadline) {
  auto* bytes = static_cast<BYTE*>(data);
  while (size) {
    if (!Remaining(deadline)) return false;
    auto event = Own(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    OVERLAPPED io{}; io.hEvent = event.get(); DWORD done = 0;
    const BOOL started = write ? WriteFile(pipe, bytes, size, &done, &io) : ReadFile(pipe, bytes, size, &done, &io);
    if (!started) {
      if (GetLastError() != ERROR_IO_PENDING) return false;
      HANDLE waits[] = {event.get(), parent};
      if (WaitForMultipleObjects(parent ? 2 : 1, waits, FALSE, Remaining(deadline)) != WAIT_OBJECT_0) {
        CancelIoEx(pipe, &io); GetOverlappedResult(pipe, &io, &done, TRUE); return false;
      }
      if (!GetOverlappedResult(pipe, &io, &done, FALSE)) return false;
    }
    if (!done) return false;
    bytes += done; size -= done;
  }
  return true;
}
bool ChildOf(DWORD child, DWORD parent) {
  auto snapshot = Own(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  if (!snapshot) return false;
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry); size_t visited = 0;
  if (Process32FirstW(snapshot.get(), &entry)) do {
    if (++visited > 4096) return false;
    if (entry.th32ProcessID == child) return entry.th32ParentProcessID == parent;
  } while (Process32NextW(snapshot.get(), &entry));
  return false;
}

bool SessionLaunch(const std::vector<std::string>& args) {
  try { TerminalCommandLine(args); } catch (...) { return false; }
  size_t i = 3;
  if (i < args.size() && args[i] == "--profile") {
    if (++i >= args.size()) return false;
    const auto& id = args[i++];
    if (id.size() != 38 || id.front() != '{' || id.back() != '}' ||
        id.find_first_not_of("{}0123456789abcdefABCDEF-") != std::string::npos) return false;
  }
  if (i < args.size() && args[i] == "--title") {
    if (++i >= args.size() || args[i++].size() > 800) return false;
  }
  if (i >= args.size() || args[i++] != "wsl.exe") return false;
  if (i < args.size() && args[i] == "-d") {
    if (++i >= args.size()) return false;
    const auto& distro = args[i++];
    if (distro.empty() || distro.size() > 512 || distro.front() == '-' || distro.find_first_of("/\\") != std::string::npos) return false;
  }
  if (i >= args.size() || args[i++] != "--cd" || i >= args.size()) return false;
  const auto& path = args[i++];
  if (path.empty() || path.front() != '/' || path.rfind("//", 0) == 0) return false;
  for (const auto* fixed : {"--exec", "bash", "-lic", "exec \"$@\"", "context-session"}) {
    if (i >= args.size() || args[i++] != fixed) return false;
  }
  if (args.size() < i + 3) return false;
  const auto& provider = args[i++]; const auto& flag = args[i++]; const auto& id = args[i++];
  const bool codex = provider == "codex" && flag == "resume";
  const bool resume = (provider == "claude" || provider == "qwen") && flag == "--resume";
  const bool session = (provider == "kimi" || provider == "opencode") && flag == "--session";
  const bool muse = provider == "muse" && flag == "resume";
  if ((!codex && !resume && !session && !muse) || id.empty() || id.size() > 200 ||
      !((id.front() >= 'a' && id.front() <= 'z') || (id.front() >= 'A' && id.front() <= 'Z') || (id.front() >= '0' && id.front() <= '9')) ||
      id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != std::string::npos) return false;
  if (muse && (i >= args.size() || args[i++] != "--yolo")) return false;
  return i == args.size();
}

DWORD ReadTabs(HANDLE parent, std::string* output) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, kContextTerminalProbe, -1, nullptr, 0);
  if (count <= 1) return ERROR_INVALID_DATA;
  std::wstring script(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, kContextTerminalProbe, -1, script.data(), count);
  DWORD length = 0;
  const DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF;
  CryptBinaryToStringW(reinterpret_cast<const BYTE*>(script.data()), (count-1)*2, flags, nullptr, &length);
  std::wstring encoded(length, L'\0');
  if (!CryptBinaryToStringW(reinterpret_cast<const BYTE*>(script.data()), (count-1)*2, flags, encoded.data(), &length)) return GetLastError();
  encoded.resize(length);
  wchar_t system[MAX_PATH]; if (!GetSystemDirectoryW(system, MAX_PATH)) return GetLastError();
  const std::wstring executable = std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::wstring command = L"\"" + executable + L"\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded;
  if (command.size() > 30000) return ERROR_BUFFER_OVERFLOW;
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE}; HANDLE read = nullptr, write = nullptr;
  if (!CreatePipe(&read, &write, &sa, 0)) return GetLastError();
  auto reader = Own(read), writer = Own(write);
  SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0);
  auto null = Own(CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr));
  if (!null) return GetLastError();
  SIZE_T size = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<BYTE> storage(size);
  auto* attributes = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &size)) return GetLastError();
  HANDLE inherited[] = {write, null.get()};
  STARTUPINFOEXW info{}; info.StartupInfo.cb = sizeof(info);
  info.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  info.StartupInfo.hStdOutput = write; info.StartupInfo.hStdError = null.get(); info.StartupInfo.hStdInput = null.get();
  info.lpAttributeList = attributes;
  PROCESS_INFORMATION child{};
  const bool created = UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      inherited, sizeof(inherited), nullptr, nullptr) && CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr, &info.StartupInfo, &child);
  const DWORD error = created ? ERROR_SUCCESS : GetLastError();
  DeleteProcThreadAttributeList(attributes);
  if (!created) return error;
  auto process = Own(child.hProcess), thread = Own(child.hThread), job = Own(CreateJobObjectW(nullptr, nullptr));
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job || !SetInformationJobObject(job.get(), JobObjectExtendedLimitInformation, &limits, sizeof(limits)) || !AssignProcessToJobObject(job.get(), process.get())) {
    TerminateProcess(process.get(), 1); return ERROR_ACCESS_DENIED;
  }
  writer.reset();
  const auto resumed = ResumeThread(thread.get());
  if (resumed == MAXDWORD) { TerminateJobObject(job.get(), 1); return GetLastError(); }
  std::atomic_bool valid{true};
  std::thread capture([&] {
    char buffer[4096]; DWORD got = 0;
    while (ReadFile(reader.get(), buffer, sizeof(buffer), &got, nullptr) && got) {
      if (output->size() + got > kMaxOutput) { valid = false; TerminateJobObject(job.get(), 1); break; }
      output->append(buffer, got);
    }
  });
  HANDLE waits[] = {process.get(), parent};
  const DWORD wait = WaitForMultipleObjects(2, waits, FALSE, 14000);
  const DWORD wait_error = wait == WAIT_FAILED ? GetLastError() : ERROR_SUCCESS;
  // A completed probe may leave a compiler child holding stdout open. End only
  // this probe's job before joining the reader; never leave an idle descendant.
  TerminateJobObject(job.get(), 1);
  capture.join(); DWORD exit = 1; GetExitCodeProcess(process.get(), &exit);
  if (wait == WAIT_FAILED) return wait_error;
  if (wait != WAIT_OBJECT_0) return ERROR_TIMEOUT;
  if (!valid) return ERROR_BUFFER_OVERFLOW;
  return exit ? ERROR_PROCESS_ABORTED : ERROR_SUCCESS;
}

void Serve(HANDLE raw, HANDLE parent, DWORD owner) noexcept {
  auto pipe = Own(raw);
  try {
    const auto deadline = GetTickCount64() + 5000;
    DWORD header[4]{};
    if (!Transfer(raw, header, sizeof(header), false, parent, deadline) || header[0] != kMagic || header[1] != 1 || header[2] > 4 || header[3] > 40) return;
    const auto action = static_cast<TerminalBrokerAction>(header[2]);
    ULONG client = 0;
    if (!GetNamedPipeClientProcessId(raw, &client)) return;
    auto caller = Own(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, client));
    if (!caller || _wcsicmp(Exe(caller.get()).c_str(), Exe().c_str()) || Sid(caller.get()) != Sid(parent)) return;
    if (client != owner && (action != TerminalBrokerAction::read_tabs || !ChildOf(client, owner) || Started(caller.get()) < Started(parent))) return;
    std::vector<std::string> args; DWORD total = 0;
    for (DWORD i=0; i<header[3]; i++) {
      DWORD length = 0;
      if (!Transfer(raw, &length, sizeof(length), false, parent, deadline) || length > 32768 || total + length > kMaxWire) return;
      total += length; std::string value(length, '\0');
      if (length && !Transfer(raw, value.data(), length, false, parent, deadline)) return;
      args.push_back(std::move(value));
    }
    DWORD status = ERROR_INVALID_PARAMETER; std::string output;
    if (WaitForSingleObject(parent, 0) != WAIT_TIMEOUT) return;
    switch (action) {
      case TerminalBrokerAction::ping: if (args.empty()) status = ERROR_SUCCESS; break;
      case TerminalBrokerAction::open:
        if (SessionLaunch(args)) status = OpenSessionTerminal(nullptr, args);
        break;
      case TerminalBrokerAction::open_checked:
        if (args.size() >= 3 && SessionLaunch({args.begin()+3, args.end()}))
          status = OpenCheckedSessionTerminal(nullptr, args);
        break;
      case TerminalBrokerAction::close: status = CloseSessionTerminal(args); break;
      case TerminalBrokerAction::read_tabs: if (args.empty()) status = ReadTabs(parent, &output); break;
    }
    DWORD response[] = {status, static_cast<DWORD>(output.size())};
    const auto until = GetTickCount64() + 5000;
    const bool header_sent = Transfer(raw, response, sizeof(response), true, parent, until);
    if (header_sent && (output.empty() || Transfer(raw, output.data(), static_cast<DWORD>(output.size()), true, parent, until))) {
      // DisconnectNamedPipe discards unread buffered bytes. Wait for the client's
      // bounded acknowledgment instead of an uninterruptible FlushFileBuffers.
      BYTE acknowledged = 0;
      Transfer(raw, &acknowledged, 1, false, parent, until);
    }
  } catch (...) { /* Invalid or disconnected requests have no fallback action. */ }
  DisconnectNamedPipe(raw);
}

int Server(DWORD owner, uint64_t started, const std::wstring& nonce) {
  if (!IsContextElevated() || !Nonce(nonce)) return ERROR_ACCESS_DENIED;
  auto parent = Own(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, owner));
  if (!parent || Started(parent.get()) != started || _wcsicmp(Exe(parent.get()).c_str(), Exe().c_str()) || Sid(parent.get()) != Sid(GetCurrentProcess())) return ERROR_ACCESS_DENIED;
  const auto name = Pipe(owner, nonce);
  const auto security = L"D:P(A;;GA;;;SY)(A;;GA;;;" + Sid(parent.get()) + L")S:(ML;;NW;;;ME)";
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(security.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return static_cast<int>(GetLastError());
  const std::unique_ptr<void, decltype(&LocalFree)> owned_descriptor(descriptor, LocalFree);
  SECURITY_ATTRIBUTES sa{sizeof(sa), descriptor, FALSE};
  auto ready = Own(OpenEventW(EVENT_MODIFY_STATE, FALSE, Ready(owner, nonce).c_str()));
  auto completed = Own(CreateEventW(nullptr, FALSE, FALSE, nullptr));
  struct Worker { std::thread thread; std::shared_ptr<std::atomic_bool> done; };
  std::vector<Worker> workers; workers.reserve(4); bool first = true; DWORD failure = ERROR_SUCCESS;
  while (WaitForSingleObject(parent.get(), 0) == WAIT_TIMEOUT) {
    for (auto it = workers.begin(); it != workers.end();) {
      if (*it->done) { it->thread.join(); it = workers.erase(it); } else ++it;
    }
    if (workers.size() >= 4) {
      HANDLE wait[] = {parent.get(), completed.get()}; WaitForMultipleObjects(2, wait, FALSE, INFINITE); continue;
    }
    auto pipe = Own(CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0),
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 4, kMaxOutput, kMaxWire, 5000, &sa));
    if (!pipe) { failure = GetLastError(); break; }
    first = false;
    if (ready) { SetEvent(ready.get()); ready.reset(); }
    auto event = Own(CreateEventW(nullptr, TRUE, FALSE, nullptr)); OVERLAPPED io{}; io.hEvent = event.get();
    bool connected = ConnectNamedPipe(pipe.get(), &io) != FALSE;
    if (!connected) {
      const DWORD error = GetLastError();
      if (error == ERROR_PIPE_CONNECTED) connected = true;
      else if (error == ERROR_IO_PENDING) {
        HANDLE wait[] = {event.get(), parent.get()};
        connected = WaitForMultipleObjects(2, wait, FALSE, INFINITE) == WAIT_OBJECT_0;
        if (!connected) { CancelIoEx(pipe.get(), &io); DWORD ignored; GetOverlappedResult(pipe.get(), &io, &ignored, TRUE); }
      }
    }
    if (!connected) break;
    const auto raw = pipe.release(); auto done = std::make_shared<std::atomic_bool>(false);
    workers.push_back({std::thread([raw, &parent, owner, done, &completed] {
      Serve(raw, parent.get(), owner); *done = true; SetEvent(completed.get());
    }), done});
  }
  for (auto& worker : workers) worker.thread.join();
  return static_cast<int>(failure);
}

DWORD Request(const std::wstring& name, DWORD expected_server, TerminalBrokerAction action, const std::vector<std::string>& args, std::string* output) {
  if (name.rfind(L"\\\\.\\pipe\\Context.Terminal.", 0) != 0 || name.size() > 160 || args.size() > 40) return ERROR_INVALID_PARAMETER;
  DWORD total = 0;
  for (const auto& arg : args) { if (arg.size() > 32768 || total + arg.size() > kMaxWire) return ERROR_BUFFER_OVERFLOW; total += static_cast<DWORD>(arg.size()); }
  if (!WaitNamedPipeW(name.c_str(), 20000)) return GetLastError();
  auto pipe = Own(CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr));
  if (!pipe) return GetLastError();
  ULONG server = 0;
  if (!expected_server || !GetNamedPipeServerProcessId(pipe.get(), &server) || server != expected_server) return ERROR_ACCESS_DENIED;
  const auto deadline = GetTickCount64() + 20000;
  DWORD header[] = {kMagic, 1, static_cast<DWORD>(action), static_cast<DWORD>(args.size())};
  const bool header_sent = Transfer(pipe.get(), header, sizeof(header), true, nullptr, deadline);
  if (!header_sent) return ERROR_TIMEOUT;
  for (const auto& arg : args) {
    DWORD size = static_cast<DWORD>(arg.size());
    if (!Transfer(pipe.get(), &size, sizeof(size), true, nullptr, deadline) ||
        (size && !Transfer(pipe.get(), const_cast<char*>(arg.data()), size, true, nullptr, deadline))) return ERROR_TIMEOUT;
  }
  DWORD reply[2]{};
  const bool reply_read = Transfer(pipe.get(), reply, sizeof(reply), false, nullptr, deadline);
  if (!reply_read || reply[1] > kMaxOutput) return ERROR_INVALID_DATA;
  std::string result(reply[1], '\0');
  if (reply[1] && !Transfer(pipe.get(), result.data(), reply[1], false, nullptr, deadline)) return ERROR_TIMEOUT;
  BYTE acknowledged = 1;
  if (!Transfer(pipe.get(), &acknowledged, 1, true, nullptr, deadline)) return ERROR_TIMEOUT;
  if (output) *output = std::move(result);
  return reply[0];
}
} // namespace

bool TerminalBrokerReady() noexcept { return helper && WaitForSingleObject(helper.get(), 0) == WAIT_TIMEOUT; }
DWORD TerminalBrokerRequest(TerminalBrokerAction action, const std::vector<std::string>& args, std::string* output) noexcept {
  if (!TerminalBrokerReady()) return ERROR_ELEVATION_REQUIRED;
  try { return Request(pipe_name, GetProcessId(helper.get()), action, args, output); } catch (...) { return ERROR_INVALID_DATA; }
}
static DWORD StartBroker(HWND owner, bool inherited) noexcept {
  if (TerminalBrokerReady() || (IsContextElevated() && !inherited)) return ERROR_SUCCESS;
  try {
    GUID guid{}; if (FAILED(CoCreateGuid(&guid))) return ERROR_GEN_FAILURE;
    wchar_t text[40]; StringFromGUID2(guid, text, 40);
    const std::wstring nonce(text+1, 36); const DWORD pid = GetCurrentProcessId();
    auto event = Own(CreateEventW(nullptr, TRUE, FALSE, Ready(pid, nonce).c_str()));
    if (!event) return GetLastError();
    const auto args = L"--context-terminal-helper " + std::to_wstring(pid) + L" " + std::to_wstring(Started(GetCurrentProcess())) + L" " + nonce;
    const auto executable = Exe();
    SHELLEXECUTEINFOW info{}; info.cbSize = sizeof(info); info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    info.hwnd = owner; info.lpVerb = inherited ? L"open" : L"runas"; info.lpFile = executable.c_str(); info.lpParameters = args.c_str(); info.nShow = SW_HIDE;
    if (!ShellExecuteExW(&info)) return GetLastError();
    auto process = Own(info.hProcess); HANDLE waits[] = {event.get(), process.get()};
    const auto wait = WaitForMultipleObjects(2, waits, FALSE, 20000);
    if (wait != WAIT_OBJECT_0) {
      if (wait == WAIT_OBJECT_0 + 1) {
        DWORD code = ERROR_GEN_FAILURE; GetExitCodeProcess(process.get(), &code);
        return code ? code : ERROR_GEN_FAILURE;
      }
      TerminateProcess(process.get(), 1); return ERROR_TIMEOUT;
    }
    pipe_name = Pipe(pid, nonce); helper = std::move(process);
    SetEnvironmentVariableW(L"CONTEXT_TERMINAL_BROKER", pipe_name.c_str());
    SetEnvironmentVariableW(L"CONTEXT_TERMINAL_HELPER_PID", std::to_wstring(GetProcessId(helper.get())).c_str());
    return ERROR_SUCCESS;
  } catch (...) { return ERROR_INVALID_DATA; }
}
DWORD ApproveTerminalBroker(HWND owner) noexcept { return StartBroker(owner, false); }
#ifdef CONTEXT_BROKER_TESTS
DWORD StartTerminalBrokerForTest() noexcept { return IsContextElevated() ? StartBroker(nullptr, true) : ERROR_ELEVATION_REQUIRED; }
DWORD TerminalBrokerTestPid() noexcept { return helper ? GetProcessId(helper.get()) : 0; }
bool TerminalBrokerLaunchValidForTest(const std::vector<std::string>& args) { return SessionLaunch(args); }
DWORD TerminalBrokerReadTabsForTest(std::string* output) {
  auto parent = Own(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, GetCurrentProcessId()));
  return ReadTabs(parent.get(), output);
}
#endif

bool RunTerminalBrokerMode(int* exit_code) noexcept {
  int count = 0; auto** values = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!values) return false;
  std::vector<std::wstring> args(values, values+count); LocalFree(values);
  if (args.size() < 2 || (args[1] != L"--context-terminal-helper" && args[1] != L"--context-terminal-read-tabs")) return false;
  *exit_code = ERROR_INVALID_PARAMETER;
  try {
    if (args[1] == L"--context-terminal-helper" && args.size() == 5) {
      if (args[2].empty() || args[2].find_first_not_of(L"0123456789") != std::wstring::npos || args[3].empty() || args[3].find_first_not_of(L"0123456789") != std::wstring::npos) return true;
      const auto pid = std::stoull(args[2]); if (!pid || pid > MAXDWORD) return true;
      *exit_code = Server(static_cast<DWORD>(pid), std::stoull(args[3]), args[4]);
    } else if (args[1] == L"--context-terminal-read-tabs" && args.size() == 2) {
      wchar_t name[200]; const DWORD size = GetEnvironmentVariableW(L"CONTEXT_TERMINAL_BROKER", name, 200);
      if (!size || size >= 200) return true;
      wchar_t server[24]; const DWORD server_size = GetEnvironmentVariableW(L"CONTEXT_TERMINAL_HELPER_PID", server, 24);
      if (!server_size || server_size >= 24 || std::wstring(server).find_first_not_of(L"0123456789") != std::wstring::npos) return true;
      const auto pid = std::stoull(server); if (!pid || pid > MAXDWORD) return true;
      std::string output; *exit_code = static_cast<int>(Request(name, static_cast<DWORD>(pid), TerminalBrokerAction::read_tabs, {}, &output));
      if (!*exit_code) { DWORD written; if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output.data(), static_cast<DWORD>(output.size()), &written, nullptr) || written != output.size()) *exit_code = ERROR_WRITE_FAULT; }
    }
  } catch (...) { *exit_code = ERROR_INVALID_DATA; }
  return true;
}
