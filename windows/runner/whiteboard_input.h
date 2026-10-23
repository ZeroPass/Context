#ifndef RUNNER_WHITEBOARD_INPUT_H_
#define RUNNER_WHITEBOARD_INPUT_H_
#include <windows.h>
#include <oleidl.h>
#include <flutter/encodable_value.h>
#include <functional>

flutter::EncodableMap ReadWhiteboardData(IDataObject* object);

class WhiteboardInput final : public IDropTarget {
 public:
  using Callback = std::function<void(const char*, flutter::EncodableValue)>;
  WhiteboardInput(HWND window, Callback callback);
  void SetBounds(RECT bounds) { bounds_ = bounds; }
  HRESULT Status() const { return status_; }
  void Detach();
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject*, DWORD, POINTL, DWORD*) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD*) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject*, DWORD, POINTL, DWORD*) override;
 private:
  bool Inside(POINTL point) const;
  void Hover(bool active);
  HWND window_;
  Callback callback_;
  RECT bounds_{};
  ULONG references_ = 1;
  HRESULT status_;
  bool supported_ = false;
  bool hovering_ = false;
};
#endif
