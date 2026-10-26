#include "whiteboard_input.h"
#include <shellapi.h>
#include <ole2.h>
#include <cstring>
#include <string>
#include <vector>
#include <utility>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr SIZE_T kMaxImage = 64 * 1024 * 1024;
constexpr SIZE_T kMaxText = 2 * 1024 * 1024;
FORMATETC Format(CLIPFORMAT format) {
  return {format, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}
bool Has(IDataObject* object, CLIPFORMAT id) {
  auto format = Format(id);
  return object->QueryGetData(&format) == S_OK;
}
std::string Utf8(const wchar_t* text, int length) {
  const int count = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0, nullptr, nullptr);
  std::string result(count, '\0');
  if (count) WideCharToMultiByte(CP_UTF8, 0, text, length, result.data(), count, nullptr, nullptr);
  return result;
}
Map Error(const char* message) { return {{Value("error"), Value(message)}}; }
struct Medium {
  STGMEDIUM data{};
  ~Medium() { if (data.tymed) ReleaseStgMedium(&data); }
};
}

flutter::EncodableMap ReadWhiteboardData(IDataObject* object) {
  if (!object) return Error("Clipboard is unavailable. Try again.");
  const auto png = static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"PNG"));
  for (CLIPFORMAT id : {static_cast<CLIPFORMAT>(CF_HDROP), png,
                       static_cast<CLIPFORMAT>(CF_DIB), static_cast<CLIPFORMAT>(CF_UNICODETEXT)}) {
    auto format = Format(id);
    Medium medium;
    if (FAILED(object->GetData(&format, &medium.data))) continue;
    if (medium.data.tymed != TYMED_HGLOBAL || !medium.data.hGlobal) continue;
    const SIZE_T size = GlobalSize(medium.data.hGlobal);
    if (size == 0 || size > (id == CF_UNICODETEXT ? kMaxText : kMaxImage)) {
      return Error("Clipboard content is too large.");
    }
    if (id == CF_HDROP) {
      HDROP drop = static_cast<HDROP>(medium.data.hGlobal);
      const UINT count = DragQueryFileW(drop, 0xffffffff, nullptr, 0);
      if (!count || count > 64) return Error("Drop between 1 and 64 files at a time.");
      flutter::EncodableList files;
      for (UINT i = 0; i < count; ++i) {
        const UINT length = DragQueryFileW(drop, i, nullptr, 0);
        if (!length || length > 32767) return Error("Invalid file path.");
        std::vector<wchar_t> path(length + 1);
        if (DragQueryFileW(drop, i, path.data(), length + 1) != length) return Error("Could not read file path.");
        files.emplace_back(Utf8(path.data(), static_cast<int>(length)));
      }
      return {{Value("files"), Value(files)}};
    }
    const auto* bytes = static_cast<const uint8_t*>(GlobalLock(medium.data.hGlobal));
    if (!bytes) continue;
    Map result;
    if (id == CF_UNICODETEXT) {
      const auto* text = reinterpret_cast<const wchar_t*>(bytes);
      const SIZE_T limit = size / sizeof(wchar_t);
      SIZE_T length = 0;
      while (length < limit && text[length]) ++length;
      result = length < limit ? Map{{Value("text"), Value(Utf8(text, static_cast<int>(length)))}}
                              : Error("Invalid clipboard text.");
    } else if (id == png) {
      result = {{Value("image"), Value(std::vector<uint8_t>(bytes, bytes + size))},
                {Value("extension"), Value("png")}};
    } else {
      // Wrap an uncompressed Windows DIB in a BMP file header; no pixel decoding
      // or image conversion on the window message thread.
      BITMAPINFOHEADER header{};
      if (size >= sizeof(header)) std::memcpy(&header, bytes, sizeof(header));
      const uint64_t height = header.biHeight < 0 ? -static_cast<int64_t>(header.biHeight) : header.biHeight;
      const uint64_t stride = ((static_cast<uint64_t>(header.biWidth) * header.biBitCount + 31) / 32) * 4;
      const uint64_t offset = header.biSize + static_cast<uint64_t>(header.biClrUsed) * 4;
      if (header.biSize < sizeof(header) || header.biWidth <= 0 || !height ||
          header.biPlanes != 1 || (header.biBitCount != 24 && header.biBitCount != 32) ||
          header.biCompression != BI_RGB || offset + stride * height > size ||
          static_cast<uint64_t>(header.biWidth) * height > 16 * 1024 * 1024) {
        result = Error("Unsupported clipboard image. Paste a PNG or drop the image file.");
      } else {
        BITMAPFILEHEADER file{};
        file.bfType = 0x4d42;
        file.bfSize = static_cast<DWORD>(size + sizeof(file));
        file.bfOffBits = static_cast<DWORD>(sizeof(file) + offset);
        std::vector<uint8_t> bmp(sizeof(file) + size);
        std::memcpy(bmp.data(), &file, sizeof(file));
        std::memcpy(bmp.data() + sizeof(file), bytes, size);
        result = {{Value("image"), Value(bmp)}, {Value("extension"), Value("bmp")}};
      }
    }
    GlobalUnlock(medium.data.hGlobal);
    return result;
  }
  return Error("Copy files, an image, or text first.");
}

WhiteboardInput::WhiteboardInput(HWND window, Callback callback)
    : window_(window), callback_(std::move(callback)), status_(RegisterDragDrop(window, this)) {}
void WhiteboardInput::Detach() {
  if (SUCCEEDED(status_)) RevokeDragDrop(window_);
  status_ = E_ABORT;
  callback_ = nullptr;
}
HRESULT WhiteboardInput::QueryInterface(REFIID iid, void** value) {
  if (!value) return E_POINTER;
  *value = nullptr;
  if (iid != IID_IUnknown && iid != IID_IDropTarget) return E_NOINTERFACE;
  *value = static_cast<IDropTarget*>(this);
  AddRef();
  return S_OK;
}
ULONG WhiteboardInput::AddRef() { return ++references_; }
ULONG WhiteboardInput::Release() {
  const auto count = --references_;
  if (!count) delete this;
  return count;
}
bool WhiteboardInput::Inside(POINTL point) const {
  POINT client{point.x, point.y};
  return ScreenToClient(window_, &client) && PtInRect(&bounds_, client);
}
void WhiteboardInput::Hover(bool active) {
  if (hovering_ == active) return;
  hovering_ = active;
  if (callback_) callback_("hover", Value(active));
}
HRESULT WhiteboardInput::DragEnter(IDataObject* object, DWORD, POINTL point, DWORD* effect) {
  supported_ = object && (Has(object, CF_HDROP) || Has(object, CF_UNICODETEXT) ||
      Has(object, CF_DIB) || Has(object, static_cast<CLIPFORMAT>(RegisterClipboardFormatW(L"PNG"))));
  return DragOver(0, point, effect);
}
HRESULT WhiteboardInput::DragOver(DWORD, POINTL point, DWORD* effect) {
  const DWORD allowed = *effect & (DROPEFFECT_COPY | DROPEFFECT_LINK);
  const bool accept = supported_ && Inside(point) && allowed;
  Hover(accept);
  *effect = accept ? (allowed & DROPEFFECT_LINK ? DROPEFFECT_LINK : DROPEFFECT_COPY) : DROPEFFECT_NONE;
  return S_OK;
}
HRESULT WhiteboardInput::DragLeave() { Hover(false); supported_ = false; return S_OK; }
HRESULT WhiteboardInput::Drop(IDataObject* object, DWORD, POINTL point, DWORD* effect) {
  const DWORD allowed = *effect & (DROPEFFECT_COPY | DROPEFFECT_LINK);
  const bool accept = supported_ && Inside(point) && allowed;
  DragLeave();
  *effect = accept ? (allowed & DROPEFFECT_LINK ? DROPEFFECT_LINK : DROPEFFECT_COPY) : DROPEFFECT_NONE;
  if (accept && callback_) callback_("drop", Value(ReadWhiteboardData(object)));
  return S_OK;
}
