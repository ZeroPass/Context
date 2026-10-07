#ifndef RUNNER_CLIPBOARD_WRITER_H_
#define RUNNER_CLIPBOARD_WRITER_H_

#include <windows.h>

#include <string>
#include <cstdint>
#include <vector>

// Returns ERROR_SUCCESS only after publishing and verifying CF_UNICODETEXT.
DWORD WriteClipboardText(HWND owner, const std::string& text);
DWORD WriteClipboardImage(HWND owner, const std::vector<uint8_t>& dib);
DWORD WriteClipboardFile(HWND owner, const std::string& path);

#endif  // RUNNER_CLIPBOARD_WRITER_H_
