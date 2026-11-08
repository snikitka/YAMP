#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuOpen = 1, kMenuExit = 2;
constexpr UINT kDrawCaption = 0xAE, kDrawFrame = 0xAF;

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                 static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), size);
  return out;
}

std::wstring StringArg(const flutter::EncodableValue* args, const char* key) {
  auto map = args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
  if (!map) {
    return std::wstring();
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return std::wstring();
  }
  auto text = std::get_if<std::string>(&it->second);
  return text ? Wide(*text) : std::wstring();
}

bool BoolArg(const flutter::EncodableValue* args, const char* key) {
  auto map = args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
  if (!map) {
    return false;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return false;
  }
  auto value = std::get_if<bool>(&it->second);
  return value && *value;
}

int IntArg(const flutter::EncodableValue* args, const char* key, int fallback) {
  auto map = args ? std::get_if<flutter::EncodableMap>(args) : nullptr;
  if (!map) {
    return fallback;
  }
  auto it = map->find(flutter::EncodableValue(key));
  if (it == map->end()) {
    return fallback;
  }
  if (auto value = std::get_if<int32_t>(&it->second)) {
    return *value;
  }
  if (auto value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*value);
  }
  return fallback;
}

constexpr DWORD kCornerPreference = 33;
constexpr DWORD kCornerRound = 2, kCornerDefault = 0;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

UINT FlutterWindow::ShowMessage() {
  static UINT message = RegisterWindowMessageW(L"YAMP.Show");
  return message;
}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "yamp/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });
  media_ = std::make_unique<MediaControls>(
      flutter_controller_->engine()->messenger(), GetHandle());

  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

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
  RemoveTrayIcon();
  media_ = nullptr;
  channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  if (method == "show") {
    ShowWindowNow();
  } else if (method == "tray") {
    auto open_label = StringArg(call.arguments(), "open");
    auto exit_label = StringArg(call.arguments(), "exit");
    if (!open_label.empty()) {
      tray_open_ = open_label;
    }
    if (!exit_label.empty()) {
      tray_exit_ = exit_label;
    }
  } else if (method == "compact") {
    if (BoolArg(call.arguments(), "on")) {
      EnterCompact(IntArg(call.arguments(), "width", 380),
                   IntArg(call.arguments(), "height", 168));
    } else {
      LeaveCompact();
    }
  } else if (method == "pin") {
    Pin(BoolArg(call.arguments(), "on"));
  } else if (method == "resize") {
    if (HWND hwnd = GetHandle(); hwnd && compact_) {
      auto edge = StringArg(call.arguments(), "edge");
      WPARAM side = 0;
      if (edge == L"left") side = WMSZ_LEFT;
      else if (edge == L"right") side = WMSZ_RIGHT;
      else if (edge == L"top") side = WMSZ_TOP;
      else if (edge == L"bottom") side = WMSZ_BOTTOM;
      else if (edge == L"topLeft") side = WMSZ_TOPLEFT;
      else if (edge == L"topRight") side = WMSZ_TOPRIGHT;
      else if (edge == L"bottomLeft") side = WMSZ_BOTTOMLEFT;
      else if (edge == L"bottomRight") side = WMSZ_BOTTOMRIGHT;
      if (side != 0) {
        ReleaseCapture();
        SendMessageW(hwnd, WM_SYSCOMMAND, SC_SIZE | side, 0);
      }
    }
  } else if (method == "drag") {
    if (HWND hwnd = GetHandle()) {
      ReleaseCapture();
      SendMessageW(hwnd, WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
    }
  } else if (method == "quit") {
    quitting_ = true;
    RemoveTrayIcon();
    PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

bool FlutterWindow::Visible() {
  HWND hwnd = GetHandle();
  return hwnd && IsWindowVisible(hwnd) && !IsIconic(hwnd);
}

void FlutterWindow::ShowWindowNow() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  HWND foreground = GetForegroundWindow();
  if (foreground == hwnd) {
    return;
  }
  DWORD ours = GetCurrentThreadId();
  DWORD theirs = GetWindowThreadProcessId(foreground, nullptr);
  bool attached =
      theirs != 0 && theirs != ours && AttachThreadInput(theirs, ours, TRUE);
  const UINT flags = SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW;
  SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags);
  if (!pinned_) {
    SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
  }
  BringWindowToTop(hwnd);
  if (!SetForegroundWindow(hwnd)) {
    FlashWindow(hwnd, TRUE);
  }
  if (attached) {
    AttachThreadInput(theirs, ours, FALSE);
  }
}

void FlutterWindow::EnterCompact(int width, int height) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  compact_min_width_ = width;
  compact_min_height_ = height;
  compact_width_ = (std::max)(compact_width_, width);
  compact_height_ = (std::max)(compact_height_, height);
  if (!compact_) {
    saved_place_.length = sizeof(saved_place_);
    GetWindowPlacement(hwnd, &saved_place_);
    saved_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    compact_ = true;
    if (IsZoomed(hwnd) || IsIconic(hwnd)) {
      ShowWindow(hwnd, SW_RESTORE);
    }
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     (saved_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP | WS_THICKFRAME);
    DWORD corner = kCornerRound;
    DwmSetWindowAttribute(hwnd, kCornerPreference, &corner, sizeof(corner));
  }
  HMONITOR monitor = has_compact_pos_
                         ? MonitorFromPoint(compact_pos_, MONITOR_DEFAULTTONULL)
                         : nullptr;
  bool restore = monitor != nullptr;
  if (!restore) {
    monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  }
  double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  SIZE size = {static_cast<LONG>(compact_width_ * scale),
               static_cast<LONG>(compact_height_ * scale)};
  MONITORINFO info = {sizeof(info)};
  GetMonitorInfoW(monitor, &info);
  LONG x, y;
  if (restore) {
    x = (std::max)(info.rcWork.left,
                   (std::min)(compact_pos_.x, info.rcWork.right - size.cx));
    y = (std::max)(info.rcWork.top,
                   (std::min)(compact_pos_.y, info.rcWork.bottom - size.cy));
  } else {
    LONG margin = static_cast<LONG>(24 * scale);
    x = info.rcWork.right - size.cx - margin;
    y = info.rcWork.bottom - size.cy - margin;
  }
  placing_ = true;
  SetWindowPos(hwnd, nullptr, x, y, size.cx, size.cy,
               SWP_NOZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  placing_ = false;
}

void FlutterWindow::LeaveCompact() {
  HWND hwnd = GetHandle();
  if (!hwnd || !compact_) {
    return;
  }
  RECT rect;
  if (GetWindowRect(hwnd, &rect)) {
    compact_pos_ = {rect.left, rect.top};
    has_compact_pos_ = true;
  }
  Pin(false);
  compact_ = false;
  SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
  DWORD corner = kCornerDefault;
  DwmSetWindowAttribute(hwnd, kCornerPreference, &corner, sizeof(corner));
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
  if (saved_place_.showCmd == SW_SHOWMINIMIZED) {
    saved_place_.showCmd = SW_SHOWNORMAL;
  }
  SetWindowPlacement(hwnd, &saved_place_);
}

void FlutterWindow::Pin(bool on) {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  pinned_ = on;
  SetWindowPos(hwnd, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void FlutterWindow::HideWindow() {
  if (HWND hwnd = GetHandle()) {
    ShowWindow(hwnd, SW_HIDE);
  }
}

void FlutterWindow::ToggleWindow() {
  bool front = active_ || std::chrono::steady_clock::now() - left_at_ <
                              std::chrono::seconds(1);
  if (Visible() && front) {
    HideWindow();
  } else {
    ShowWindowNow();
  }
}

void FlutterWindow::AddTrayIcon() {
  if (tray_added_ || quitting_) {
    return;
  }
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = kTrayId;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = kTrayMessage;
  if (!tray_.hIcon) {
    tray_.hIcon = static_cast<HICON>(LoadImageW(
        GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  }
  wcscpy_s(tray_.szTip, L"YAMP");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_);
    tray_added_ = false;
  }
  if (tray_.hIcon) {
    DestroyIcon(tray_.hIcon);
    tray_.hIcon = nullptr;
  }
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kMenuOpen, tray_open_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuExit, tray_exit_.c_str());
  SetMenuDefaultItem(menu, kMenuOpen, FALSE);
  POINT at;
  GetCursorPos(&at);
  SetForegroundWindow(hwnd);
  UINT command = static_cast<UINT>(TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      at.x, at.y, 0, hwnd, nullptr));
  PostMessageW(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == kMenuOpen) {
    ShowWindowNow();
  } else if (command == kMenuExit) {
    if (channel_) {
      channel_->InvokeMethod("exit", nullptr);
    }
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == ShowMessage()) {
    ShowWindowNow();
    return 0;
  }
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }
  switch (message) {
    case MediaControls::kMessage:
      if (media_) {
        media_->Dispatch(wparam, lparam);
      }
      return 0;
    case kTrayMessage:
      if (LOWORD(lparam) == WM_LBUTTONUP) {
        ToggleWindow();
      } else if (LOWORD(lparam) == WM_RBUTTONUP) {
        ShowTrayMenu();
      }
      return 0;
    case WM_GETMINMAXINFO:
      if (compact_) {
        double scale = GetDpiForWindow(hwnd) / 96.0;
        auto info = reinterpret_cast<MINMAXINFO*>(lparam);
        info->ptMinTrackSize.x = static_cast<LONG>(compact_min_width_ * scale);
        info->ptMinTrackSize.y = static_cast<LONG>(compact_min_height_ * scale);
        info->ptMaxTrackSize.x = static_cast<LONG>(compact_min_width_ * 2 * scale);
        info->ptMaxTrackSize.y = static_cast<LONG>(compact_min_height_ * 2.5 * scale);
        return 0;
      }
      break;
    case WM_NCCALCSIZE:
      if (compact_ && wparam == TRUE) {
        return 0;
      }
      break;
    case WM_NCPAINT:
    case kDrawCaption:
    case kDrawFrame:
      if (compact_) {
        return 0;
      }
      break;
    case WM_NCACTIVATE:
      if (compact_) {
        return DefWindowProcW(hwnd, message, wparam, -1);
      }
      break;
    case WM_SIZE:
      if (compact_ && !placing_ && wparam != SIZE_MINIMIZED) {
        double scale = GetDpiForWindow(hwnd) / 96.0;
        compact_width_ = static_cast<int>(LOWORD(lparam) / scale + 0.5);
        compact_height_ = static_cast<int>(HIWORD(lparam) / scale + 0.5);
      }
      break;
    case WM_DPICHANGED:
      if (compact_) {
        double scale = HIWORD(wparam) / 96.0;
        auto rect = reinterpret_cast<RECT*>(lparam);
        rect->right = rect->left + static_cast<LONG>(compact_width_ * scale);
        rect->bottom = rect->top + static_cast<LONG>(compact_height_ * scale);
      }
      break;
    case WM_CLOSE:
      if (!quitting_) {
        HideWindow();
        return 0;
      }
      break;
    case WM_ACTIVATE:
      active_ = LOWORD(wparam) != WA_INACTIVE;
      if (!active_) {
        left_at_ = std::chrono::steady_clock::now();
      }
      break;
  }

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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
