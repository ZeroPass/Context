#ifndef RUNNER_TERMINAL_BROKER_H_
#define RUNNER_TERMINAL_BROKER_H_
#include <windows.h>
#include <string>
#include <vector>

enum class TerminalBrokerAction : DWORD { ping, open, open_checked, close, read_tabs };
bool TerminalBrokerReady() noexcept;
DWORD ApproveTerminalBroker(HWND owner) noexcept;
DWORD TerminalBrokerRequest(TerminalBrokerAction action,
    const std::vector<std::string>& args, std::string* output = nullptr) noexcept;
// Handles helper/read-only-client command lines before Flutter/WSL initialize.
bool RunTerminalBrokerMode(int* exit_code) noexcept;
#ifdef CONTEXT_BROKER_TESTS
DWORD StartTerminalBrokerForTest() noexcept;
DWORD TerminalBrokerTestPid() noexcept;
bool TerminalBrokerLaunchValidForTest(const std::vector<std::string>& args);
DWORD TerminalBrokerReadTabsForTest(std::string* output);
#endif
#endif
