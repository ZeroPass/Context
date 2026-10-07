#include "clipboard_writer.h"
#include <shlobj.h>

#include <cstring>
#include <limits>
#include <vector>

namespace {
DWORD ClipboardError() {
  const DWORD error = GetLastError();
  return error == ERROR_SUCCESS ? ERROR_GEN_FAILURE : error;
}
DWORD WritePayload(HWND owner, UINT format, const void* payload, size_t bytes) {
  if (owner == nullptr) return ERROR_INVALID_PARAMETER;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory == nullptr) return ClipboardError();
  void* buffer = GlobalLock(memory);
  if (buffer == nullptr) {
    const DWORD error = ClipboardError();
    GlobalFree(memory);
    return error;
  }
  std::memcpy(buffer, payload, bytes);
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
  if (SetClipboardData(format, memory) == nullptr) {
    const DWORD error = ClipboardError();
    CloseClipboard();
    GlobalFree(memory);
    return error;
  }
  // Windows owns memory now. Verify it while this clipboard lock is still held.
  HANDLE published = GetClipboardData(format);
  void* actual = published == nullptr ? nullptr : GlobalLock(published);
  const bool verified = actual != nullptr && GlobalSize(published) >= bytes &&
                        std::memcmp(actual, payload, bytes) == 0;
  if (actual != nullptr) GlobalUnlock(published);
  const BOOL closed = CloseClipboard();
  if (!closed) return ClipboardError();
  return verified ? ERROR_SUCCESS : ERROR_INVALID_DATA;
}

DWORD Utf8Wide(const std::string& text, std::vector<wchar_t>* wide) {
  if (text.find('\0') != std::string::npos) return ERROR_INVALID_PARAMETER;
  if (text.size() > static_cast<size_t>((std::numeric_limits<int>::max)())) {
    return ERROR_FILE_TOO_LARGE;
  }
  const int length = text.empty() ? 0 : MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (!text.empty() && length == 0) return ClipboardError();
  wide->assign(static_cast<size_t>(length) + 1, L'\0');
  if (length != 0 && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), wide->data(), length) == 0) return ClipboardError();
  return ERROR_SUCCESS;
}
}  // namespace

DWORD WriteClipboardText(HWND owner, const std::string& text) {
  std::vector<wchar_t> wide;
  const DWORD error = Utf8Wide(text, &wide);
  if (error != ERROR_SUCCESS) return error;
  return WritePayload(owner, CF_UNICODETEXT, wide.data(), wide.size() * sizeof(wchar_t));
}

DWORD WriteClipboardImage(HWND owner, const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return ERROR_INVALID_DATA;
  BITMAPINFOHEADER header{};
  std::memcpy(&header, dib.data(), sizeof(header));
  if (header.biSize != sizeof(header) || header.biWidth <= 0 || header.biHeight <= 0 ||
      header.biPlanes != 1 || header.biBitCount != 32 || header.biCompression != BI_RGB ||
      header.biClrUsed != 0) return ERROR_INVALID_DATA;
  const uint64_t pixels = static_cast<uint64_t>(header.biWidth) * header.biHeight;
  if (pixels > 32ULL * 1024 * 1024 || dib.size() != sizeof(header) + pixels * 4 ||
      header.biSizeImage != pixels * 4) return ERROR_INVALID_DATA;
  return WritePayload(owner, CF_DIB, dib.data(), dib.size());
}

DWORD WriteClipboardFile(HWND owner, const std::string& path) {
  std::vector<wchar_t> wide;
  const DWORD error = Utf8Wide(path, &wide);
  if (error != ERROR_SUCCESS) return error;
  const bool absolute = wide.size() > 3 &&
      ((wide[0] == L'\\' && wide[1] == L'\\') ||
       (wide[1] == L':' && (wide[2] == L'\\' || wide[2] == L'/')));
  if (!absolute) return ERROR_INVALID_PARAMETER;
  wide.push_back(L'\0');  // CF_HDROP ends its filename list with a double NUL.
  std::vector<uint8_t> payload(sizeof(DROPFILES) + wide.size() * sizeof(wchar_t), 0);
  DROPFILES drop{};
  drop.pFiles = sizeof(DROPFILES);
  drop.fWide = TRUE;
  std::memcpy(payload.data(), &drop, sizeof(drop));
  std::memcpy(payload.data() + sizeof(drop), wide.data(), wide.size() * sizeof(wchar_t));
  return WritePayload(owner, CF_HDROP, payload.data(), payload.size());
}
