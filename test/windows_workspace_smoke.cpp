#include "workspace_window.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>

namespace {
int checked = 0;
void Require(bool value, const char* label) {
  if (!value) {
    std::cerr << label << " failed; error " << GetLastError() << '\n';
    std::exit(1);
  }
  ++checked;
}
RECT Frame(HWND window) {
  RECT result{};
  Require(GetWindowRect(window, &result) != FALSE, "GetWindowRect");
  return result;
}
}

int main() {
  Require(SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != FALSE,
          "per-monitor DPI awareness");
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  const POINT point{0, 0};
  Require(GetMonitorInfoW(MonitorFromPoint(point, MONITOR_DEFAULTTOPRIMARY), &monitor) != FALSE,
          "monitor work area");
  const LONG available = monitor.rcWork.right - monitor.rcWork.left;
  const LONG initial = std::min(available,
      std::max(available / 4, static_cast<LONG>(std::lround(400 * GetDpiForSystem() / 96.0))));
  const HWND window = CreateWindowExW(0, L"STATIC", L"Context width test (hidden)",
      WS_OVERLAPPEDWINDOW, monitor.rcWork.left + 20, monitor.rcWork.top + 50,
      initial, 500, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  Require(window != nullptr, "hidden test window");
  Require(!IsWindowVisible(window), "test never shows a window");
  WorkspaceBounds bounds;
  Require(ReadWorkspaceBounds(window, &bounds) == ERROR_SUCCESS && bounds.normal,
          "read normal bounds");
  const RECT before = Frame(window);
  const double scale = GetDpiForWindow(window) / 96.0;
  const double original = bounds.width;
  Require(std::abs(original * scale - initial) < 1, "DPI-normalized width");
  Require(ResizeWorkspaceWidth(window, original * 3, &bounds) == ERROR_SUCCESS,
          "expand width");
  const RECT expanded = Frame(window);
  Require(expanded.top == before.top && expanded.bottom == before.bottom,
          "expansion preserves height and vertical position");
  Require(expanded.right - expanded.left == std::min(available, initial * 3),
          "default expansion triples width unless capped by screen");
  Require(ResizeWorkspaceWidth(window, original, &bounds) == ERROR_SUCCESS,
          "restore width");
  const RECT restored = Frame(window);
  Require(restored.right - restored.left == before.right - before.left,
          "restores exact original width");
  Require(restored.top == before.top && restored.bottom == before.bottom,
          "restoration preserves height and vertical position");
  Require(SetWindowPos(window, nullptr, monitor.rcWork.right - initial,
      before.top, initial, before.bottom - before.top,
      SWP_NOACTIVATE | SWP_NOZORDER) != FALSE, "position near right edge");
  Require(ResizeWorkspaceWidth(window, original * 3, &bounds) == ERROR_SUCCESS,
          "expand near right edge");
  const RECT edge = Frame(window);
  Require(edge.right <= monitor.rcWork.right && edge.left >= monitor.rcWork.left,
          "growth stays on monitor");
  Require(edge.top == before.top && edge.bottom == before.bottom,
          "edge adjustment is horizontal only");
  Require(ResizeWorkspaceWidth(window, 100000, &bounds) == ERROR_SUCCESS,
          "oversized request is capped");
  const RECT capped = Frame(window);
  Require(capped.right - capped.left == available, "cap uses work area width");
  Require(ResizeWorkspaceWidth(window, 1, &bounds) == ERROR_SUCCESS,
          "undersized request is capped");
  const RECT narrow = Frame(window);
  Require(narrow.right - narrow.left >= std::min(available, static_cast<LONG>(std::lround(320 * scale))),
          "minimum logical width");
  for (const double value : {-1.0, 0.0, 100001.0,
                            std::numeric_limits<double>::quiet_NaN(),
                            std::numeric_limits<double>::infinity()}) {
    Require(ResizeWorkspaceWidth(window, value, &bounds) == ERROR_INVALID_PARAMETER,
            "reject invalid width");
  }
  Require(ReadWorkspaceBounds(nullptr, &bounds) == ERROR_INVALID_WINDOW_HANDLE,
          "reject invalid window");
  Require(ResizeWorkspaceWidth(window, original, nullptr) == ERROR_INVALID_PARAMETER,
          "reject missing output");
  Require(!IsWindowVisible(window), "resize never activates or shows test window");
  Require(DestroyWindow(window) != FALSE, "destroy hidden test window");
  std::cout << checked << " native workspace checks passed. No user windows changed.\n";
  return 0;
}
