#ifndef RUNNER_SESSION_TERMINAL_H_
#define RUNNER_SESSION_TERMINAL_H_

#include <windows.h>

#include <string>
#include <vector>

bool IsContextElevated() noexcept;
DWORD ReadTerminalSettings(std::string* settings) noexcept;
std::wstring TerminalCommandLine(const std::vector<std::string>& arguments);
DWORD OpenSessionTerminal(HWND owner,
                          const std::vector<std::string>& arguments) noexcept;
DWORD RestartContextElevated(HWND owner) noexcept;
DWORD CloseSessionTerminal(const std::vector<std::string>& identity) noexcept;
bool WaitForContextRestartParent() noexcept;

#endif  // RUNNER_SESSION_TERMINAL_H_
