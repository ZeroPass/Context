#include "whiteboard_input.h"
#include <ole2.h>
#include <shlobj.h>
#include <cstring>
#include <iostream>
#include <vector>

using Value = flutter::EncodableValue;
void Check(bool condition, const char* name) {
  if (!condition) { std::cerr << "FAIL " << name << '\n'; std::exit(1); }
  std::cout << "PASS " << name << '\n';
}
class Data final : public IDataObject {
 public:
  CLIPFORMAT format;
  std::vector<uint8_t> bytes;
  Data(CLIPFORMAT type, const void* input, size_t size) : format(type), bytes(size) {
    std::memcpy(bytes.data(), input, size);
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void** out) override { *out = nullptr; return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* f) override { return f->cfFormat == format ? S_OK : DV_E_FORMATETC; }
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* f, STGMEDIUM* data) override {
    if (f->cfFormat != format) return DV_E_FORMATETC;
    data->tymed = TYMED_HGLOBAL;
    data->pUnkForRelease = nullptr;
    data->hGlobal = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    auto* dest = GlobalLock(data->hGlobal);
    std::memcpy(dest, bytes.data(), bytes.size());
    GlobalUnlock(data->hGlobal);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return E_NOTIMPL; }
};
int main() {
  Check(SUCCEEDED(OleInitialize(nullptr)), "OLE initialization");
  Check(ReadWhiteboardData(nullptr).count(Value("error")) == 1, "missing clipboard fails closed");
  const wchar_t text[] = L"hello \x03bb";
  Data data(CF_UNICODETEXT, text, sizeof(text));
  Check(std::get<std::string>(ReadWhiteboardData(&data).at(Value("text"))) == "hello \xce\xbb", "unicode text");
  const wchar_t paths[] = L"C:\\one.md\0C:\\two.png\0";
  std::vector<uint8_t> payload(sizeof(DROPFILES) + sizeof(paths));
  DROPFILES drop{}; drop.pFiles = sizeof(DROPFILES); drop.fWide = TRUE;
  std::memcpy(payload.data(), &drop, sizeof(drop));
  std::memcpy(payload.data() + sizeof(drop), paths, sizeof(paths));
  Data files(CF_HDROP, payload.data(), payload.size());
  auto list = std::get<flutter::EncodableList>(ReadWhiteboardData(&files).at(Value("files")));
  Check(list.size() == 2 && std::get<std::string>(list[1]) == "C:\\two.png", "multiple file paths");
  BITMAPINFOHEADER dib{};
  dib.biSize = sizeof(dib); dib.biWidth = 1; dib.biHeight = 1;
  dib.biPlanes = 1; dib.biBitCount = 32;
  std::vector<uint8_t> pixels(sizeof(dib) + 4, 255);
  std::memcpy(pixels.data(), &dib, sizeof(dib));
  Data image(CF_DIB, pixels.data(), pixels.size());
  const auto bmp = std::get<std::vector<uint8_t>>(ReadWhiteboardData(&image).at(Value("image")));
  Check(bmp.size() == sizeof(BITMAPFILEHEADER) + pixels.size() && bmp[0] == 'B' && bmp[1] == 'M', "DIB wraps as BMP");
  Data truncated(CF_DIB, &dib, sizeof(dib));
  Check(ReadWhiteboardData(&truncated).count(Value("error")) == 1, "truncated image rejected");
  const uint8_t png[] = {137, 80, 78, 71};
  Data encoded(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"PNG")), png, sizeof(png));
  Check(std::get<std::string>(ReadWhiteboardData(&encoded).at(Value("extension"))) == "png", "PNG format preserved");
  HWND window = CreateWindowW(L"STATIC", L"Context input test", WS_POPUP, 20, 20, 300, 200, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  Check(window != nullptr, "hidden test window");
  bool hover = false;
  int drops = 0;
  auto* target = new WhiteboardInput(window, [&](const char* event, Value value) {
    if (std::string(event) == "hover") hover = std::get<bool>(value);
    if (std::string(event) == "drop") ++drops;
  });
  Check(SUCCEEDED(target->Status()), "OLE drop target registered");
  target->SetBounds({100, 0, 300, 200});
  POINT origin{0, 0}; ClientToScreen(window, &origin);
  DWORD effect = DROPEFFECT_COPY;
  target->DragEnter(&data, 0, {origin.x + 50, origin.y + 50}, &effect);
  Check(effect == DROPEFFECT_NONE && !hover, "outside whiteboard rejected");
  effect = DROPEFFECT_COPY;
  target->DragOver(0, {origin.x + 150, origin.y + 50}, &effect);
  Check(effect == DROPEFFECT_COPY && hover, "whiteboard hover accepted");
  effect = DROPEFFECT_COPY;
  target->Drop(&data, 0, {origin.x + 150, origin.y + 50}, &effect);
  Check(drops == 1 && !hover, "drop delivers once and clears overlay");
  target->SetBounds({});
  effect = DROPEFFECT_COPY;
  target->DragEnter(&data, 0, {origin.x + 150, origin.y + 50}, &effect);
  Check(effect == DROPEFFECT_NONE, "hidden whiteboard rejects drag");
  target->Detach(); target->Release(); DestroyWindow(window);
  OleUninitialize();
  std::cout << "13 checks completed; no real clipboard or user windows modified.\n";
}
