#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <shellapi.h>

#include <chrono>
#include <memory>
#include <string>

#include "media_controls.h"
#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  static UINT ShowMessage();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void ShowWindowNow();
  void HideWindow();
  void ToggleWindow();
  bool Visible();

  void EnterCompact(int width, int height);
  void LeaveCompact();
  void Pin(bool on);

  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<MediaControls> media_;

  bool quitting_ = false;
  bool compact_ = false;
  bool pinned_ = false;
  int compact_width_ = 0, compact_height_ = 0;
  int compact_min_width_ = 380, compact_min_height_ = 168;
  bool has_compact_pos_ = false;
  bool placing_ = false;
  POINT compact_pos_ = {};
  LONG_PTR saved_style_ = 0;
  WINDOWPLACEMENT saved_place_ = {sizeof(WINDOWPLACEMENT)};
  bool active_ = false;
  std::chrono::steady_clock::time_point left_at_;

  NOTIFYICONDATAW tray_ = {};
  bool tray_added_ = false;
  UINT taskbar_created_ = 0;
  std::wstring tray_open_ = L"Open YAMP", tray_exit_ = L"Exit";
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
