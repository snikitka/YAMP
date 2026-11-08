#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kMutexName[] = L"Local\\YAMP.SingleInstance";

bool HasFlag(const wchar_t* flag) {
  int count = 0;
  wchar_t** args = CommandLineToArgvW(GetCommandLineW(), &count);
  bool found = false;
  for (int i = 1; args && i < count; i++) {
    if (_wcsicmp(args[i], flag) == 0) {
      found = true;
    }
  }
  LocalFree(args);
  return found;
}

bool TakeLock(bool wait, HANDLE* lock) {
  for (int tries = 0;; tries++) {
    *lock = CreateMutexW(nullptr, FALSE, kMutexName);
    if (!*lock || GetLastError() != ERROR_ALREADY_EXISTS) {
      return true;
    }
    CloseHandle(*lock);
    *lock = nullptr;
    if (!wait || tries >= 100) {
      return false;
    }
    Sleep(100);
  }
}

void ShowRunning() {
  HWND running = FindWindowW(L"YAMPWindow", nullptr);
  if (running) {
    AllowSetForegroundWindow(ASFW_ANY);
    PostMessageW(running, FlutterWindow::ShowMessage(), 0, 0);
    return;
  }
  MessageBoxW(nullptr,
              L"YAMP \x0443\x0436\x0435 \x0437\x0430\x043F\x0443\x0449\x0435\x043D.",
              L"YAMP", MB_OK | MB_ICONINFORMATION);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_lock = nullptr;
  if (!TakeLock(HasFlag(L"--restart"), &instance_lock)) {
    ShowRunning();
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1240, 820);
  if (!window.Create(L"YAMP", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_lock) {
    CloseHandle(instance_lock);
  }
  return EXIT_SUCCESS;
}
