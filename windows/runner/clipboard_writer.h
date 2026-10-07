#ifndef RUNNER_CLIPBOARD_WRITER_H_
#define RUNNER_CLIPBOARD_WRITER_H_

#include <windows.h>

#include <string>

// Returns ERROR_SUCCESS only after publishing and verifying CF_UNICODETEXT.
DWORD WriteClipboardText(HWND owner, const std::string& text);

#endif  // RUNNER_CLIPBOARD_WRITER_H_
