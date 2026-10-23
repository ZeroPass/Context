#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "clipboard_writer.h"
#include "session_terminal.h"
#include "whiteboard_notifications.h"
#include "workspace_window.h"
#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  whiteboard_input_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "context/whiteboard-input",
          &flutter::StandardMethodCodec::GetInstance());
  whiteboard_input_ = new WhiteboardInput(flutter_controller_->view()->GetNativeWindow(),
      [this](const char* event, flutter::EncodableValue value) {
        whiteboard_input_channel_->InvokeMethod(event,
            std::make_unique<flutter::EncodableValue>(std::move(value)));
      });
  whiteboard_input_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "paste") {
          IDataObject* object = nullptr;
          OleGetClipboard(&object);
          auto data = ReadWhiteboardData(object);
          if (object) object->Release();
          result->Success(flutter::EncodableValue(data));
        } else if (call.method_name() == "bounds") {
          const auto* values = call.arguments() ? std::get_if<std::vector<double>>(call.arguments()) : nullptr;
          RECT rect{};
          if (values && values->size() == 4) {
            rect = {static_cast<LONG>((*values)[0]), static_cast<LONG>((*values)[1]),
                    static_cast<LONG>((*values)[2]), static_cast<LONG>((*values)[3])};
          }
          whiteboard_input_->SetBounds(rect);
          if (FAILED(whiteboard_input_->Status())) {
            result->Error("drop_unavailable", "Windows drag and drop is unavailable; use Ctrl+V.");
          } else {
            result->Success();
          }
        } else {
          result->NotImplemented();
        }
      });
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "context/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto& method = call.method_name();
        if (method != "writeText" && method != "writeFile" && method != "writeImage") {
          result->NotImplemented();
          return;
        }
        DWORD error = ERROR_INVALID_PARAMETER;
        if (call.arguments() != nullptr) {
          if (method == "writeImage") {
            const auto* bytes = std::get_if<std::vector<uint8_t>>(call.arguments());
            if (bytes != nullptr) error = WriteClipboardImage(GetHandle(), *bytes);
          } else {
            const auto* text = std::get_if<std::string>(call.arguments());
            if (text != nullptr) error = method == "writeFile"
                ? WriteClipboardFile(GetHandle(), *text)
                : WriteClipboardText(GetHandle(), *text);
          }
        }
        if (error != ERROR_SUCCESS) {
          result->Error("Clipboard error", "Windows clipboard could not be updated.",
                        flutter::EncodableValue(static_cast<int32_t>(error)));
          return;
        }
        result->Success();
      });
  notification_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "context/notifications",
          &flutter::StandardMethodCodec::GetInstance());
  notification_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "whiteboardPublished") {
          result->NotImplemented();
          return;
        }
        const auto* args = call.arguments() == nullptr ? nullptr
            : std::get_if<flutter::EncodableMap>(call.arguments());
        if (args == nullptr) {
          result->Error("Invalid notification", "Expected publication metadata.");
          return;
        }
        const auto title = args->find(flutter::EncodableValue("title"));
        const auto provider = args->find(flutter::EncodableValue("provider"));
        const auto* title_text = title == args->end() ? nullptr
            : std::get_if<std::string>(&title->second);
        const auto* provider_text = provider == args->end() ? nullptr
            : std::get_if<std::string>(&provider->second);
        if (title_text == nullptr || provider_text == nullptr) {
          result->Error("Invalid notification", "Expected a title and provider.");
          return;
        }
        const auto status = ShowWhiteboardNotification(*title_text, *provider_text);
        if (FAILED(status)) {
          result->Error("Notification unavailable", "Windows could not show the notification.",
                        flutter::EncodableValue(static_cast<int32_t>(status)));
          return;
        }
        result->Success();
      });
  terminal_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "context/terminal",
          &flutter::StandardMethodCodec::GetInstance());
  terminal_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "isElevated") {
          result->Success(flutter::EncodableValue(IsContextElevated()));
          return;
        }
        DWORD error = ERROR_INVALID_PARAMETER;
        if (call.method_name() == "readSettings") {
          std::string settings;
          error = ReadTerminalSettings(&settings);
          if (error == ERROR_SUCCESS) {
            result->Success(flutter::EncodableValue(settings));
            return;
          }
        } else if (call.method_name() == "restartElevated") {
          error = RestartContextElevated(GetHandle());
        } else if (call.method_name() == "openTab" || call.method_name() == "closeWindow") {
          const auto* values = call.arguments() == nullptr ? nullptr
              : std::get_if<flutter::EncodableList>(call.arguments());
          if (values != nullptr && values->size() <= 40) {
            std::vector<std::string> arguments;
            for (const auto& value : *values) {
              const auto* argument = std::get_if<std::string>(&value);
              if (argument == nullptr) break;
              arguments.push_back(*argument);
            }
            if (arguments.size() == values->size()) {
              error = call.method_name() == "closeWindow"
                  ? CloseSessionTerminal(arguments)
                  : OpenSessionTerminal(GetHandle(), arguments);
            }
          }
        } else {
          result->NotImplemented();
          return;
        }
        if (error != ERROR_SUCCESS) {
          result->Error(
              error == ERROR_ELEVATION_REQUIRED ? "administrator_required"
                  : error == ERROR_CANCELLED ? "cancelled" : "terminal_error",
              "Windows could not complete the Terminal action.",
              flutter::EncodableValue(static_cast<int32_t>(error)));
          return;
        }
        result->Success();
      });
  workspace_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "context/window",
          &flutter::StandardMethodCodec::GetInstance());
  workspace_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        WorkspaceBounds bounds;
        DWORD error = ERROR_INVALID_PARAMETER;
        if (call.method_name() == "bounds") {
          error = ReadWorkspaceBounds(GetHandle(), &bounds);
        } else if (call.method_name() == "setWidth") {
          const auto* width = call.arguments() == nullptr ? nullptr
              : std::get_if<double>(call.arguments());
          if (width != nullptr) error = ResizeWorkspaceWidth(GetHandle(), *width, &bounds);
        } else {
          result->NotImplemented();
          return;
        }
        if (error != ERROR_SUCCESS) {
          result->Error("window_resize", "Windows could not adjust the window width.",
                        flutter::EncodableValue(static_cast<int32_t>(error)));
          return;
        }
        result->Success(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("width"), flutter::EncodableValue(bounds.width)},
            {flutter::EncodableValue("normal"), flutter::EncodableValue(bounds.normal)}}));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (whiteboard_input_) {
    whiteboard_input_->Detach();
    whiteboard_input_->Release();
    whiteboard_input_ = nullptr;
  }
  whiteboard_input_channel_.reset();
  if (workspace_channel_) {
    workspace_channel_->SetMethodCallHandler(nullptr);
    workspace_channel_.reset();
  }
  if (terminal_channel_) {
    terminal_channel_->SetMethodCallHandler(nullptr);
    terminal_channel_.reset();
  }
  if (notification_channel_) {
    notification_channel_->SetMethodCallHandler(nullptr);
    notification_channel_.reset();
  }
  if (clipboard_channel_) {
    clipboard_channel_->SetMethodCallHandler(nullptr);
    clipboard_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_EXITSIZEMOVE: {
      WorkspaceBounds bounds;
      if (workspace_channel_ &&
          ReadWorkspaceBounds(hwnd, &bounds) == ERROR_SUCCESS) {
        workspace_channel_->InvokeMethod("resized",
            std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                {flutter::EncodableValue("width"), flutter::EncodableValue(bounds.width)},
                {flutter::EncodableValue("normal"), flutter::EncodableValue(bounds.normal)}}));
      }
      break;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
