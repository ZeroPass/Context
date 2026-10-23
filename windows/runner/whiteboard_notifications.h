#ifndef RUNNER_WHITEBOARD_NOTIFICATIONS_H_
#define RUNNER_WHITEBOARD_NOTIFICATIONS_H_

#include <windows.h>
#include <string>

// Uses the installed APPX identity. No helper process or notification service.
HRESULT ShowWhiteboardNotification(const std::string& title,
                                  const std::string& provider) noexcept;

#endif  // RUNNER_WHITEBOARD_NOTIFICATIONS_H_
