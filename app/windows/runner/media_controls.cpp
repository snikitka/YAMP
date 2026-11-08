#include "media_controls.h"

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>

#include <chrono>

namespace {

using namespace winrt::Windows::Media;
using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Foundation::Uri;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

enum Command : WPARAM { kPlay, kPause, kNext, kPrevious, kSeek };

const flutter::EncodableValue* Field(const flutter::EncodableMap& map,
                                     const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

winrt::hstring Text(const flutter::EncodableMap& map, const char* key) {
  auto value = Field(map, key);
  auto text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? winrt::to_hstring(*text) : winrt::hstring();
}

bool Flag(const flutter::EncodableMap& map, const char* key) {
  auto value = Field(map, key);
  auto flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

std::chrono::milliseconds Millis(const flutter::EncodableMap& map,
                                 const char* key) {
  auto value = Field(map, key);
  if (!value) {
    return std::chrono::milliseconds(0);
  }
  if (auto narrow = std::get_if<int32_t>(value)) {
    return std::chrono::milliseconds(*narrow);
  }
  if (auto wide = std::get_if<int64_t>(value)) {
    return std::chrono::milliseconds(*wide);
  }
  return std::chrono::milliseconds(0);
}

}

MediaControls::MediaControls(flutter::BinaryMessenger* messenger,
                             HWND window) {
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls_)));
    controls_.IsPlayEnabled(true);
    controls_.IsPauseEnabled(true);
    controls_.IsStopEnabled(true);
    controls_.IsNextEnabled(true);
    controls_.IsPreviousEnabled(true);
    controls_.IsEnabled(false);
    pressed_ = controls_.ButtonPressed(
        [window](const SystemMediaTransportControls&,
                 const SystemMediaTransportControlsButtonPressedEventArgs& args) {
          WPARAM command;
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play:
              command = kPlay;
              break;
            case SystemMediaTransportControlsButton::Pause:
            case SystemMediaTransportControlsButton::Stop:
              command = kPause;
              break;
            case SystemMediaTransportControlsButton::Next:
              command = kNext;
              break;
            case SystemMediaTransportControlsButton::Previous:
              command = kPrevious;
              break;
            default:
              return;
          }
          PostMessageW(window, kMessage, command, 0);
        });
    seek_ = controls_.PlaybackPositionChangeRequested(
        [window](const SystemMediaTransportControls&,
                 const PlaybackPositionChangeRequestedEventArgs& args) {
          auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        args.RequestedPlaybackPosition())
                        .count();
          PostMessageW(window, kMessage, kSeek, static_cast<LPARAM>(ms));
        });
  } catch (const winrt::hresult_error&) {
    controls_ = nullptr;
    return;
  }
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "yamp/media", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });
}

MediaControls::~MediaControls() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  if (!controls_) {
    return;
  }
  try {
    controls_.ButtonPressed(pressed_);
    controls_.PlaybackPositionChangeRequested(seek_);
    controls_.DisplayUpdater().ClearAll();
    controls_.IsEnabled(false);
  } catch (const winrt::hresult_error&) {
  }
}

void MediaControls::Dispatch(WPARAM command, LPARAM value) {
  if (!channel_) {
    return;
  }
  switch (command) {
    case kPlay:
      channel_->InvokeMethod("play", nullptr);
      break;
    case kPause:
      channel_->InvokeMethod("pause", nullptr);
      break;
    case kNext:
      channel_->InvokeMethod("next", nullptr);
      break;
    case kPrevious:
      channel_->InvokeMethod("previous", nullptr);
      break;
    case kSeek:
      channel_->InvokeMethod("seek", std::make_unique<flutter::EncodableValue>(
                                         static_cast<int64_t>(value)));
      break;
  }
}

void MediaControls::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  try {
    if (method == "update") {
      auto state = call.arguments()
                       ? std::get_if<flutter::EncodableMap>(call.arguments())
                       : nullptr;
      if (state) {
        Update(*state);
      }
    } else if (method == "stop") {
      Stop();
    } else {
      result->NotImplemented();
      return;
    }
  } catch (const winrt::hresult_error&) {
  }
  result->Success();
}

void MediaControls::Update(const flutter::EncodableMap& state) {
  controls_.IsEnabled(true);
  controls_.PlaybackStatus(Flag(state, "playing") ? MediaPlaybackStatus::Playing
                                                  : MediaPlaybackStatus::Paused);

  auto display = controls_.DisplayUpdater();
  display.Type(MediaPlaybackType::Music);
  auto music = display.MusicProperties();
  music.Title(Text(state, "title"));
  music.Artist(Text(state, "artist"));
  music.AlbumTitle(Text(state, "album"));
  auto art = Field(state, "art");
  auto url = art ? std::get_if<std::string>(art) : nullptr;
  std::string next = url ? *url : std::string();
  if (next != art_) {
    art_ = next;
    display.Thumbnail(next.empty() ? nullptr
                                   : RandomAccessStreamReference::CreateFromUri(
                                         Uri(winrt::to_hstring(next))));
  }
  display.Update();

  auto duration = Millis(state, "duration");
  SystemMediaTransportControlsTimelineProperties timeline;
  timeline.StartTime(TimeSpan::zero());
  timeline.MinSeekTime(TimeSpan::zero());
  timeline.EndTime(duration);
  timeline.MaxSeekTime(duration);
  timeline.Position(Millis(state, "position"));
  controls_.UpdateTimelineProperties(timeline);
}

void MediaControls::Stop() {
  art_.clear();
  controls_.DisplayUpdater().ClearAll();
  controls_.PlaybackStatus(MediaPlaybackStatus::Closed);
  controls_.IsEnabled(false);
}
