#include "clipboard_writer.h"

#include <cstring>
#include <limits>
#include <vector>

namespace {
DWORD ClipboardError() {
  const DWORD error = GetLastError();
  return error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error;
}
}  // namespace

DWORD WriteClipboardText(HWND owner, const std::string& text) {
  if (owner == nullptr || text.find('\0') != std::string::npos) {
    return ERROR_INVALID_PARAMETER;
  }
  if (text.size() > static_cast<size_t>((std::numeric_limits<int>::max)())) {
    return ERROR_FILE_TOO_LARGE;
  }
  const int length = text.empty()
                         ? 0
                         : MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                               text.data(), static_cast<int>(text.size()),
                                               nullptr, 0);
  if (!text.empty() && length == 0) return ClipboardError();
  std::vector<wchar_t> wide(static_cast<size_t>(length) + 1, L'\0');
  if (length != 0 &&
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                          static_cast<int>(text.size()), wide.data(), length) == 0) {
    return ClipboardError();
  }
  const size_t bytes = wide.size() * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory == nullptr) return ClipboardError();
  void* buffer = GlobalLock(memory);
  if (buffer == nullptr) {
    const DWORD error = ClipboardError();
    GlobalFree(memory);
    return error;
  }
  std::memcpy(buffer, wide.data(), bytes);
  GlobalUnlock(memory);
  if (!OpenClipboard(owner)) {
    const DWORD error = ClipboardError();
    GlobalFree(memory);
    return error;
  }
  if (!EmptyClipboard()) {
    const DWORD error = ClipboardError();
    CloseClipboard();
    GlobalFree(memory);
    return error;
  }
  // Publish the movable allocation HANDLE, never its GlobalLock pointer.
  if (SetClipboardData(CF_UNICODETEXT, memory) == nullptr) {
    const DWORD error = ClipboardError();
    CloseClipboard();
    GlobalFree(memory);
    return error;
  }
  // Windows owns memory now. Verify it while this clipboard lock is still held.
  HANDLE published = GetClipboardData(CF_UNICODETEXT);
  void* actual = published == nullptr ? nullptr : GlobalLock(published);
  const bool verified = actual != nullptr && GlobalSize(published) >= bytes &&
                        std::memcmp(actual, wide.data(), bytes) == 0;
  if (actual != nullptr) GlobalUnlock(published);
  const BOOL closed = CloseClipboard();
  if (!closed) return ClipboardError();
  return verified ? ERROR_SUCCESS : ERROR_INVALID_DATA;
}
