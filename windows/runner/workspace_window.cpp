#include "workspace_window.h"

#include <algorithm>
#include <cmath>

DWORD ReadWorkspaceBounds(HWND window, WorkspaceBounds* bounds) {
  if (bounds == nullptr) return ERROR_INVALID_PARAMETER;
  if (!IsWindow(window)) return ERROR_INVALID_WINDOW_HANDLE;
  RECT frame{};
  if (!GetWindowRect(window, &frame)) return GetLastError();
  const UINT dpi = GetDpiForWindow(window);
  if (dpi == 0) return ERROR_INVALID_WINDOW_HANDLE;
  bounds->width = (frame.right - frame.left) * 96.0 / dpi;
  bounds->normal = !IsZoomed(window) && !IsIconic(window);
  return ERROR_SUCCESS;
}

DWORD ResizeWorkspaceWidth(HWND window, double width, WorkspaceBounds* bounds) {
  if (!std::isfinite(width) || width <= 0 || width > 100000) {
    return ERROR_INVALID_PARAMETER;
  }
  DWORD error = ReadWorkspaceBounds(window, bounds);
  if (error != ERROR_SUCCESS || !bounds->normal) return error;
  RECT frame{};
  if (!GetWindowRect(window, &frame)) return GetLastError();
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                       &monitor)) {
    return GetLastError();
  }
  const double scale = GetDpiForWindow(window) / 96.0;
  const LONG available = monitor.rcWork.right - monitor.rcWork.left;
  if (available <= 0) return ERROR_INVALID_DATA;
  const LONG minimum = std::min(available, static_cast<LONG>(std::lround(320 * scale)));
  const LONG target = std::clamp(static_cast<LONG>(std::lround(width * scale)),
                                  minimum, available);
  const LONG left = std::clamp(frame.left, monitor.rcWork.left,
                                monitor.rcWork.right - target);
  // Keep vertical bounds and activation intact; only shift left if growth needs room.
  if (!SetWindowPos(window, nullptr, left, frame.top, target,
                    frame.bottom - frame.top,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER)) {
    return GetLastError();
  }
  return ReadWorkspaceBounds(window, bounds);
}
