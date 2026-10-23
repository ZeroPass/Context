#ifndef RUNNER_WORKSPACE_WINDOW_H_
#define RUNNER_WORKSPACE_WINDOW_H_

#include <windows.h>

struct WorkspaceBounds {
  double width = 0;
  bool normal = false;
};

DWORD ReadWorkspaceBounds(HWND window, WorkspaceBounds* bounds);
DWORD ResizeWorkspaceWidth(HWND window, double width, WorkspaceBounds* bounds);

#endif  // RUNNER_WORKSPACE_WINDOW_H_
