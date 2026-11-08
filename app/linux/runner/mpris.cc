#include "mpris.h"

#include <string.h>

#include <string>

namespace {

const char kBusName[] = "org.mpris.MediaPlayer2.yamp";
const char kPath[] = "/org/mpris/MediaPlayer2";
const char kPlayer[] = "org.mpris.MediaPlayer2.Player";

const char kXml[] = R"(<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek">
      <arg direction="in" name="Offset" type="x"/>
    </method>
    <method name="SetPosition">
      <arg direction="in" name="TrackId" type="o"/>
      <arg direction="in" name="Position" type="x"/>
    </method>
    <method name="OpenUri">
      <arg direction="in" name="Uri" type="s"/>
    </method>
    <signal name="Seeked">
      <arg name="Position" type="x"/>
    </signal>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Rate" type="d" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="read"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>)";

struct State {
  FlMethodChannel* channel = nullptr;
  GtkWindow* window = nullptr;
  GDBusConnection* bus = nullptr;
  bool active = false;
  bool playing = false;
  std::string id, title, artist, album, art;
  gint64 duration = 0;
  gint64 position = 0;
  gint64 at = 0;
};

State state;

std::string Text(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return std::string();
  }
  return fl_value_get_string(value);
}

gint64 Number(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return 0;
  }
  return fl_value_get_int(value);
}

bool Flag(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

gint64 Position() {
  gint64 position = state.position;
  if (state.playing) {
    position += g_get_monotonic_time() - state.at;
  }
  if (state.duration > 0 && position > state.duration) {
    position = state.duration;
  }
  return position;
}

std::string TrackPath() {
  std::string path = "/org/yamp/track/t";
  for (char c : state.id) {
    bool plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9');
    path += plain ? c : '_';
  }
  return path;
}

GVariant* Metadata() {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));
  if (state.active) {
    const gchar* artists[] = {state.artist.c_str(), nullptr};
    g_variant_builder_add(&builder, "{sv}", "mpris:trackid",
                          g_variant_new_object_path(TrackPath().c_str()));
    g_variant_builder_add(&builder, "{sv}", "mpris:length",
                          g_variant_new_int64(state.duration));
    g_variant_builder_add(&builder, "{sv}", "xesam:title",
                          g_variant_new_string(state.title.c_str()));
    g_variant_builder_add(&builder, "{sv}", "xesam:artist",
                          g_variant_new_strv(artists, -1));
    g_variant_builder_add(&builder, "{sv}", "xesam:album",
                          g_variant_new_string(state.album.c_str()));
    if (!state.art.empty()) {
      g_variant_builder_add(&builder, "{sv}", "mpris:artUrl",
                            g_variant_new_string(state.art.c_str()));
    }
  }
  return g_variant_builder_end(&builder);
}

const gchar* Status() {
  if (!state.active) {
    return "Stopped";
  }
  return state.playing ? "Playing" : "Paused";
}

void Invoke(const char* method, FlValue* args) {
  if (state.channel != nullptr) {
    fl_method_channel_invoke_method(state.channel, method, args, nullptr,
                                    nullptr, nullptr);
  }
}

void SeekTo(gint64 position) {
  if (position < 0) {
    position = 0;
  }
  if (state.duration > 0 && position > state.duration) {
    position = state.duration;
  }
  g_autoptr(FlValue) ms = fl_value_new_int(position / 1000);
  Invoke("seek", ms);
}

void EmitChanged() {
  if (state.bus == nullptr) {
    return;
  }
  GVariantBuilder changed;
  g_variant_builder_init(&changed, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&changed, "{sv}", "PlaybackStatus",
                        g_variant_new_string(Status()));
  g_variant_builder_add(&changed, "{sv}", "Metadata", Metadata());
  const char* flags[] = {"CanGoNext", "CanGoPrevious", "CanPlay", "CanPause",
                         "CanSeek"};
  for (const char* flag : flags) {
    g_variant_builder_add(&changed, "{sv}", flag,
                          g_variant_new_boolean(state.active));
  }
  g_dbus_connection_emit_signal(
      state.bus, nullptr, kPath, "org.freedesktop.DBus.Properties",
      "PropertiesChanged",
      g_variant_new("(sa{sv}as)", kPlayer, &changed, nullptr), nullptr);
  g_dbus_connection_emit_signal(state.bus, nullptr, kPath, kPlayer, "Seeked",
                                g_variant_new("(x)", Position()), nullptr);
}

GVariant* GetProperty(GDBusConnection* bus, const gchar* sender,
                      const gchar* path, const gchar* interface,
                      const gchar* name, GError** error, gpointer data) {
  if (g_strcmp0(name, "CanQuit") == 0 || g_strcmp0(name, "HasTrackList") == 0) {
    return g_variant_new_boolean(FALSE);
  }
  if (g_strcmp0(name, "CanRaise") == 0 || g_strcmp0(name, "CanControl") == 0) {
    return g_variant_new_boolean(TRUE);
  }
  if (g_strcmp0(name, "Identity") == 0) {
    return g_variant_new_string("YAMP");
  }
  if (g_strcmp0(name, "DesktopEntry") == 0) {
    return g_variant_new_string("yamp");
  }
  if (g_strcmp0(name, "SupportedUriSchemes") == 0 ||
      g_strcmp0(name, "SupportedMimeTypes") == 0) {
    return g_variant_new_strv(nullptr, 0);
  }
  if (g_strcmp0(name, "PlaybackStatus") == 0) {
    return g_variant_new_string(Status());
  }
  if (g_strcmp0(name, "Metadata") == 0) {
    return Metadata();
  }
  if (g_strcmp0(name, "Position") == 0) {
    return g_variant_new_int64(Position());
  }
  if (g_strcmp0(name, "Rate") == 0 || g_strcmp0(name, "Volume") == 0 ||
      g_strcmp0(name, "MinimumRate") == 0 ||
      g_strcmp0(name, "MaximumRate") == 0) {
    return g_variant_new_double(1.0);
  }
  if (g_str_has_prefix(name, "Can")) {
    return g_variant_new_boolean(state.active);
  }
  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "Unknown property %s", name);
  return nullptr;
}

void CallMethod(GDBusConnection* bus, const gchar* sender, const gchar* path,
                const gchar* interface, const gchar* method,
                GVariant* parameters, GDBusMethodInvocation* invocation,
                gpointer data) {
  if (g_strcmp0(method, "Raise") == 0) {
    if (state.window != nullptr) {
      gtk_window_present(state.window);
    }
  } else if (g_strcmp0(method, "Next") == 0) {
    Invoke("next", nullptr);
  } else if (g_strcmp0(method, "Previous") == 0) {
    Invoke("previous", nullptr);
  } else if (g_strcmp0(method, "Pause") == 0 ||
             g_strcmp0(method, "Stop") == 0) {
    Invoke("pause", nullptr);
  } else if (g_strcmp0(method, "Play") == 0) {
    Invoke("play", nullptr);
  } else if (g_strcmp0(method, "PlayPause") == 0) {
    Invoke(state.playing ? "pause" : "play", nullptr);
  } else if (g_strcmp0(method, "Seek") == 0) {
    gint64 offset = 0;
    g_variant_get(parameters, "(x)", &offset);
    SeekTo(Position() + offset);
  } else if (g_strcmp0(method, "SetPosition") == 0) {
    const gchar* track = nullptr;
    gint64 position = 0;
    g_variant_get(parameters, "(&ox)", &track, &position);
    if (TrackPath() == track) {
      SeekTo(position);
    }
  }
  g_dbus_method_invocation_return_value(invocation, nullptr);
}

const GDBusInterfaceVTable kVtable = {CallMethod, GetProperty, nullptr};

void Update(FlValue* map) {
  state.active = true;
  state.playing = Flag(map, "playing");
  state.id = Text(map, "id");
  state.title = Text(map, "title");
  state.artist = Text(map, "artist");
  state.album = Text(map, "album");
  state.art = Text(map, "art");
  state.duration = Number(map, "duration") * 1000;
  state.position = Number(map, "position") * 1000;
  state.at = g_get_monotonic_time();
  EmitChanged();
}

void Stop() {
  state.active = false;
  state.playing = false;
  state.id.clear();
  state.position = 0;
  EmitChanged();
}

void HandleCall(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "update") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      Update(args);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "stop") == 0) {
    Stop();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

void OnBus(GDBusConnection* bus, const gchar* name, gpointer data) {
  g_autoptr(GError) error = nullptr;
  GDBusNodeInfo* info = g_dbus_node_info_new_for_xml(kXml, &error);
  if (info == nullptr) {
    return;
  }
  state.bus = bus;
  for (int i = 0; info->interfaces[i] != nullptr; i++) {
    g_dbus_connection_register_object(bus, kPath, info->interfaces[i],
                                      &kVtable, nullptr, nullptr, nullptr);
  }
  g_dbus_node_info_unref(info);
}

}

void mpris_start(FlBinaryMessenger* messenger, GtkWindow* window) {
  state.window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state.channel =
      fl_method_channel_new(messenger, "yamp/media", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(state.channel, HandleCall, nullptr,
                                            nullptr);
  g_bus_own_name(G_BUS_TYPE_SESSION, kBusName, G_BUS_NAME_OWNER_FLAGS_NONE,
                 OnBus, nullptr, nullptr, nullptr, nullptr);
}
