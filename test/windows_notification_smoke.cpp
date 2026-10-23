#include <windows.h>
#include <appmodel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>

#include "whiteboard_notifications.h"

int wmain(int argc, wchar_t** argv) {
  if (ShowWhiteboardNotification(std::string(2049, 'x'), "Codex") != E_INVALIDARG) {
    return 1;
  }
  if (argc == 1) {
    const HRESULT status = ShowWhiteboardNotification("No package fixture", "Codex");
    if (SUCCEEDED(status)) return 2;
    std::cout << "Oversized input rejected; missing identity fails cleanly.\n";
    return 0;
  }
  std::ofstream output(argv[1]);
  const HRESULT status = ShowWhiteboardNotification(
      "Context notification test <&> \"literal\"", "Codex");
  output << "Show HRESULT: " << std::hex << status << "\n";
  if (FAILED(status)) return 3;
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
    UINT32 length = 0;
    GetCurrentApplicationUserModelId(&length, nullptr);
    std::wstring id(length, L'\0');
    if (GetCurrentApplicationUserModelId(&length, id.data()) != ERROR_SUCCESS) return 4;
    id.resize(length - 1);
    using winrt::Windows::UI::Notifications::ToastNotificationManager;
    // One bounded delay permits the OS to insert the toast, without polling.
    std::this_thread::sleep_for(std::chrono::milliseconds(700));
    bool found = false;
    for (const auto& toast : ToastNotificationManager::History().GetHistory(id)) {
      if (toast.Group() != L"whiteboard" || toast.Tag() != L"published") continue;
      const auto nodes = toast.Content().GetElementsByTagName(L"text");
      if (nodes.Length() == 3 && nodes.Item(1).InnerText() ==
          L"Context notification test <&> \"literal\"") found = true;
    }
    output << "Native toast present in Windows notification history: " << found << "\n";
    output << "Settings: " << static_cast<int>(
        ToastNotificationManager::CreateToastNotifier(id).Setting()) << "\n";
    return found ? 0 : 5;
  } catch (...) {
    output << "History HRESULT: " << std::hex << winrt::to_hresult() << "\n";
    return 6;
  }
}
