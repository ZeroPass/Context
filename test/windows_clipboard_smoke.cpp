#include "clipboard_writer.h"

#include <cstdlib>
#include <cstring>
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

std::vector<uint8_t> ReadPayload(HWND window, UINT format) {
  Require(OpenClipboard(window) != FALSE, "OpenClipboard/binary");
  HANDLE memory = GetClipboardData(format);
  Require(memory != nullptr, "GetClipboardData/binary");
  const auto* data = static_cast<const uint8_t*>(GlobalLock(memory));
  Require(data != nullptr, "GlobalLock/binary");
  const std::vector<uint8_t> result(data, data + GlobalSize(memory));
  GlobalUnlock(memory);
  Require(CloseClipboard() != FALSE, "CloseClipboard/binary");
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

  BITMAPINFOHEADER header{};
  header.biSize = sizeof(header);
  header.biWidth = 2;
  header.biHeight = 1;
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biSizeImage = 8;
  std::vector<uint8_t> dib(sizeof(header) + 8, 0);
  std::memcpy(dib.data(), &header, sizeof(header));
  dib[sizeof(header)] = 255;
  dib[sizeof(header) + 7] = 255;
  Require(WriteClipboardImage(window, dib) == ERROR_SUCCESS, "write bitmap");
  const auto image = ReadPayload(window, CF_DIB);
  Require(image.size() >= dib.size() &&
          std::memcmp(image.data(), dib.data(), dib.size()) == 0, "bitmap independent readback");
  Require(WriteClipboardImage(window, {0}) != ERROR_SUCCESS, "reject invalid bitmap");
  auto invalid = dib;
  invalid[14] = 24;
  Require(WriteClipboardImage(window, invalid) != ERROR_SUCCESS, "reject wrong pixel format");
  Require(ReadPayload(window, CF_DIB) == image, "invalid bitmap preserves clipboard");

  const std::string file = u8"\\\\wsl.localhost\\Ubuntu-24.04\\tmp\\\u017e video.mp4";
  Require(WriteClipboardFile(window, file) == ERROR_SUCCESS, "copy Unicode UNC file");
  const auto drop = ReadPayload(window, CF_HDROP);
  // DROPFILES header is 20 bytes, followed by a double-NUL UTF-16 list.
  const auto file_wide = Wide(file);
  Require(drop.size() >= 20 + (file_wide.size() + 2) * sizeof(wchar_t), "file payload size");
  DWORD offset = 0;
  std::memcpy(&offset, drop.data(), sizeof(offset));
  Require(offset == 20 && drop[16] == 1, "wide file drop header");
  Require(std::memcmp(drop.data() + offset, file_wide.data(), file_wide.size() * sizeof(wchar_t)) == 0,
          "file independent readback");
  const size_t end = offset + file_wide.size() * sizeof(wchar_t);
  Require(drop[end] == 0 && drop[end + 1] == 0 && drop[end + 2] == 0 && drop[end + 3] == 0,
          "file double NUL terminator");
  Require(WriteClipboardFile(window, "relative.mp4") != ERROR_SUCCESS, "reject relative file");
  Require(WriteClipboardFile(window, std::string("C:\\a\0b", 6)) != ERROR_SUCCESS, "reject NUL file");
  Require(ReadPayload(window, CF_HDROP) == drop, "invalid file preserves clipboard");
  Require(WriteClipboardText(window, texts[0]) == ERROR_SUCCESS, "text after media copy");
  Require(ReadText(window) == Wide(texts[0]), "text after media independent readback");

  DestroyWindow(window);
  Require(SetThreadDesktop(original_desktop) != FALSE, "restore thread desktop");
  CloseDesktop(desktop);
  Require(SetProcessWindowStation(original_station) != FALSE, "restore process station");
  CloseWindowStation(station);
  std::cout << "Isolated clipboard: " << checked
            << " alternating command/Unicode roundtrips passed; invalid input,"
               " contention, recovery, empty text, bitmap and Unicode file copy passed. User clipboard untouched.\n";
  return 0;
}
