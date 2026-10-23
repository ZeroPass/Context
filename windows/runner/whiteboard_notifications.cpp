#include "whiteboard_notifications.h"

#include <appmodel.h>
#include <roapi.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

#include <vector>

namespace {
struct RuntimeApartment {
  HRESULT status = RoInitialize(RO_INIT_SINGLETHREADED);
  ~RuntimeApartment() {
    if (SUCCEEDED(status)) RoUninitialize();
  }
};
}  // namespace

HRESULT ShowWhiteboardNotification(const std::string& title,
                                  const std::string& provider) noexcept {
  try {
    if (title.size() > 2048 || provider.size() > 128) return E_INVALIDARG;
    RuntimeApartment apartment;
    if (FAILED(apartment.status)) return apartment.status;
    UINT32 length = 0;
    LONG status = GetCurrentApplicationUserModelId(&length, nullptr);
    if (status != ERROR_INSUFFICIENT_BUFFER) return HRESULT_FROM_WIN32(status);
    std::vector<wchar_t> app_id(length);
    status = GetCurrentApplicationUserModelId(&length, app_id.data());
    if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);

    using namespace winrt::Windows::Data::Xml::Dom;
    using namespace winrt::Windows::UI::Notifications;
    XmlDocument content;
    content.LoadXml(L"<toast><visual><binding template=\"ToastGeneric\">"
                    L"<text>Whiteboard published</text><text/><text/>"
                    L"</binding></visual></toast>");
    const auto texts = content.GetElementsByTagName(L"text");
    // Text nodes keep quotes, Markdown and XML metacharacters literal.
    texts.Item(1).AppendChild(content.CreateTextNode(
        winrt::to_hstring(title)));
    texts.Item(2).AppendChild(content.CreateTextNode(
        winrt::to_hstring(provider)));
    ToastNotification toast{content};
    toast.Group(L"whiteboard");
    // The newest publication replaces the previous toast instead of piling up.
    toast.Tag(L"published");
    ToastNotificationManager::CreateToastNotifier(app_id.data()).Show(toast);
    return S_OK;
  } catch (...) {
    return winrt::to_hresult();
  }
}
