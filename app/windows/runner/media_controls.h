#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <windows.h>
#include <unknwn.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <winrt/Windows.Media.h>

#include <memory>
#include <string>

class MediaControls {
 public:
  static constexpr UINT kMessage = WM_APP + 2;

  MediaControls(flutter::BinaryMessenger* messenger, HWND window);
  ~MediaControls();

  void Dispatch(WPARAM command, LPARAM value);

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Update(const flutter::EncodableMap& state);
  void Stop();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token pressed_{};
  winrt::event_token seek_{};
  std::string art_;
};

#endif
