#include "clipboard_writer.h"

#include <cstdlib>
#include <future>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

void Require(bool condition, const char* operation) {
  if (!condition) {
    std::cerr << operation << " failed; Win32 error " << GetLastError() << '\n';
    std::exit(1);
  }
}

std::wstring ReadText(HWND window) {
  Require(OpenClipboard(window) != FALSE, "OpenClipboard/read");
  HANDLE memory = GetClipboardData(CF_UNICODETEXT);
  Require(memory != nullptr, "GetClipboardData");
  const auto* text = static_cast<const wchar_t*>(GlobalLock(memory));
  Require(text != nullptr, "GlobalLock/read");
  const std::wstring result(text);
  GlobalUnlock(memory);
  Require(CloseClipboard() != FALSE, "CloseClipboard/read");
  return result;
}

std::wstring Wide(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        text.data(), static_cast<int>(text.size()),
                                        nullptr, 0);
  Require(length > 0, "UTF8 length");
  std::wstring result(static_cast<size_t>(length), L'\0');
  Require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                              static_cast<int>(text.size()), result.data(), length) != 0,
          "UTF8 conversion");
  return result;
}

int main() {
  HWINSTA original_station = GetProcessWindowStation();
  HDESK original_desktop = GetThreadDesktop(GetCurrentThreadId());
  // Fail closed if an isolated station cannot be created. Never use WinSta0's
  // clipboard or switch the user's visible/input desktop.
  HWINSTA station = CreateWindowStationW(nullptr, CWF_CREATE_ONLY,
                                         WINSTA_ALL_ACCESS, nullptr);
  Require(station != nullptr, "CreateWindowStation/private");
  Require(SetProcessWindowStation(station) != FALSE, "SetProcessWindowStation");
  HDESK desktop = CreateDesktopW(L"ContextClipboardTest", nullptr, nullptr, 0,
                                 GENERIC_ALL, nullptr);
  Require(desktop != nullptr, "CreateDesktop/private");
  Require(SetThreadDesktop(desktop) != FALSE, "SetThreadDesktop/private");
  HWND window = CreateWindowExW(0, L"STATIC", L"ContextClipboardTest", 0,
                                0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                GetModuleHandleW(nullptr), nullptr);
  Require(window != nullptr, "CreateWindow/private");

  char* reported = nullptr;
  size_t reported_size = 0;
  Require(_dupenv_s(&reported, &reported_size, "CONTEXT_CLIPBOARD_TEST_COMMAND") == 0,
          "read optional reported command");
  const std::string command = reported == nullptr
      ? "codex resume 00000000-0000-4000-8000-000000007d40" : reported;
  std::free(reported);
  const std::vector<std::string> texts = {
      command,
      "codex resume 11111111-1111-1111-1111-111111111111",
      "codex fork 00000000-0000-4000-8000-000000007d40",
      u8"# Response\n\n[notes](\\\\wsl.localhost\\Ubuntu-24.04\\home\\luka\\notes.md)\n\n\u017e \U0001f642",
  };
  int checked = 0;
  for (int repeat = 0; repeat < 50; ++repeat) {
    for (const auto& text : texts) {
      Require(WriteClipboardText(window, text) == ERROR_SUCCESS, "WriteClipboardText");
      Require(ReadText(window) == Wide(text), "independent readback");
      ++checked;
    }
  }
  const auto previous = ReadText(window);
  Require(WriteClipboardText(nullptr, texts[0]) != ERROR_SUCCESS, "reject missing owner");
  Require(WriteClipboardText(window, std::string("a\0b", 3)) != ERROR_SUCCESS,
          "reject embedded null");
  Require(WriteClipboardText(window, std::string("\xff", 1)) != ERROR_SUCCESS,
          "reject invalid UTF8");
  Require(ReadText(window) == previous, "invalid input preserves clipboard");

  std::promise<bool> ready;
  std::promise<void> release;
  auto unlock = release.get_future();
  auto opened = ready.get_future();
  std::thread holder([&]() {
    const bool acquired = SetThreadDesktop(desktop) != FALSE &&
                          OpenClipboard(nullptr) != FALSE;
    ready.set_value(acquired);
    if (acquired) {
      unlock.wait();
      CloseClipboard();
    }
  });
  Require(opened.get(), "clipboard contention setup");
  const DWORD blocked = WriteClipboardText(window, texts[0]);
  release.set_value();
  holder.join();
  Require(blocked != ERROR_SUCCESS, "locked clipboard returns failure");
  Require(ReadText(window) == previous, "locked write preserves old text");
  Require(WriteClipboardText(window, texts[0]) == ERROR_SUCCESS, "copy after lock released");
  Require(ReadText(window) == Wide(texts[0]), "copy after lock readback");
  Require(WriteClipboardText(window, "") == ERROR_SUCCESS, "copy empty text");
  Require(ReadText(window).empty(), "empty text readback");

  DestroyWindow(window);
  Require(SetThreadDesktop(original_desktop) != FALSE, "restore thread desktop");
  CloseDesktop(desktop);
  Require(SetProcessWindowStation(original_station) != FALSE, "restore process station");
  CloseWindowStation(station);
  std::cout << "Isolated clipboard: " << checked
            << " alternating command/Unicode roundtrips passed; invalid input,"
               " contention, recovery, and empty text passed. User clipboard untouched.\n";
  return 0;
}
