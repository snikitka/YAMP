#include "desktop.h"

#include <string.h>

#include <algorithm>

namespace {

constexpr int kNormalWidth = 900, kNormalHeight = 600;
constexpr int kMargin = 24;

struct State {
  FlMethodChannel* channel = nullptr;
  GtkWindow* window = nullptr;
  bool compact = false;
  bool maximized = false;
  int x = 0, y = 0, width = 0, height = 0;
  bool has_compact = false;
  int compact_x = 0, compact_y = 0, compact_width = 0, compact_height = 0;
  guint button = 0;
  gdouble root_x = 0, root_y = 0;
  guint32 time = 0;
};

State state;

FlValue* Arg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

int IntArg(FlValue* args, const char* key, int fallback) {
  FlValue* value = Arg(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return static_cast<int>(fl_value_get_int(value));
}

bool BoolArg(FlValue* args, const char* key) {
  FlValue* value = Arg(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

const gchar* StringArg(FlValue* args, const char* key) {
  FlValue* value = Arg(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return "";
  }
  return fl_value_get_string(value);
}

gboolean OnPress(GSignalInvocationHint* hint, guint count, const GValue* values,
                 gpointer data) {
  if (count < 2) {
    return TRUE;
  }
  auto event = static_cast<GdkEventButton*>(g_value_get_boxed(values + 1));
  if (event != nullptr && event->type == GDK_BUTTON_PRESS) {
    state.button = event->button;
    state.root_x = event->x_root;
    state.root_y = event->y_root;
    state.time = event->time;
  }
  return TRUE;
}

void Pressed(guint* button, gint* x, gint* y, guint32* time) {
  if (state.button != 0) {
    *button = state.button;
    *x = static_cast<gint>(state.root_x);
    *y = static_cast<gint>(state.root_y);
    *time = state.time;
    return;
  }
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(state.window));
  GdkDevice* pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(display));
  gdk_device_get_position(pointer, nullptr, x, y);
  *button = 1;
  *time = GDK_CURRENT_TIME;
}

GdkRectangle WorkArea() {
  GdkRectangle area = {0, 0, 0, 0};
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(state.window));
  GdkWindow* window = gtk_widget_get_window(GTK_WIDGET(state.window));
  GdkMonitor* monitor = window != nullptr
                            ? gdk_display_get_monitor_at_window(display, window)
                            : gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor != nullptr) {
    gdk_monitor_get_workarea(monitor, &area);
  }
  return area;
}

void EnterCompact(int width, int height) {
  GtkWindow* window = state.window;
  if (!state.compact) {
    state.maximized = gtk_window_is_maximized(window);
    gtk_window_get_position(window, &state.x, &state.y);
    gtk_window_get_size(window, &state.width, &state.height);
    if (state.maximized) {
      gtk_window_unmaximize(window);
    }
    gtk_window_set_decorated(window, FALSE);
    state.compact = true;
  }
  gtk_widget_set_size_request(GTK_WIDGET(window), width, height);
  GdkGeometry hints = {};
  hints.max_width = width * 2;
  hints.max_height = height * 5 / 2;
  gtk_window_set_geometry_hints(window, nullptr, &hints, GDK_HINT_MAX_SIZE);
  int w = state.has_compact ? std::max(state.compact_width, width) : width;
  int h = state.has_compact ? std::max(state.compact_height, height) : height;
  gtk_window_resize(window, w, h);
  if (state.has_compact) {
    gtk_window_move(window, state.compact_x, state.compact_y);
  } else {
    GdkRectangle area = WorkArea();
    gtk_window_move(window, area.x + area.width - w - kMargin,
                    area.y + area.height - h - kMargin);
  }
}

void LeaveCompact() {
  if (!state.compact) {
    return;
  }
  GtkWindow* window = state.window;
  gtk_window_get_position(window, &state.compact_x, &state.compact_y);
  gtk_window_get_size(window, &state.compact_width, &state.compact_height);
  state.has_compact = true;
  state.compact = false;
  gtk_window_set_keep_above(window, FALSE);
  GdkGeometry hints = {};
  gtk_window_set_geometry_hints(window, nullptr, &hints,
                                static_cast<GdkWindowHints>(0));
  gtk_window_set_decorated(window, TRUE);
  gtk_widget_set_size_request(GTK_WIDGET(window), kNormalWidth, kNormalHeight);
  gtk_window_resize(window, state.width, state.height);
  gtk_window_move(window, state.x, state.y);
  if (state.maximized) {
    gtk_window_maximize(window);
  }
}

void Drag() {
  guint button;
  gint x, y;
  guint32 time;
  Pressed(&button, &x, &y, &time);
  gtk_window_begin_move_drag(state.window, button, x, y, time);
}

void Resize(const gchar* edge) {
  GdkWindowEdge side;
  if (strcmp(edge, "left") == 0) {
    side = GDK_WINDOW_EDGE_WEST;
  } else if (strcmp(edge, "right") == 0) {
    side = GDK_WINDOW_EDGE_EAST;
  } else if (strcmp(edge, "top") == 0) {
    side = GDK_WINDOW_EDGE_NORTH;
  } else if (strcmp(edge, "bottom") == 0) {
    side = GDK_WINDOW_EDGE_SOUTH;
  } else if (strcmp(edge, "topLeft") == 0) {
    side = GDK_WINDOW_EDGE_NORTH_WEST;
  } else if (strcmp(edge, "topRight") == 0) {
    side = GDK_WINDOW_EDGE_NORTH_EAST;
  } else if (strcmp(edge, "bottomLeft") == 0) {
    side = GDK_WINDOW_EDGE_SOUTH_WEST;
  } else if (strcmp(edge, "bottomRight") == 0) {
    side = GDK_WINDOW_EDGE_SOUTH_EAST;
  } else {
    return;
  }
  guint button;
  gint x, y;
  guint32 time;
  Pressed(&button, &x, &y, &time);
  gtk_window_begin_resize_drag(state.window, side, button, x, y, time);
}

void HandleCall(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "compact") == 0) {
    if (BoolArg(args, "on")) {
      EnterCompact(IntArg(args, "width", 380), IntArg(args, "height", 168));
    } else {
      LeaveCompact();
    }
  } else if (strcmp(method, "pin") == 0) {
    gtk_window_set_keep_above(state.window, BoolArg(args, "on"));
  } else if (strcmp(method, "drag") == 0) {
    if (state.compact) {
      Drag();
    }
  } else if (strcmp(method, "resize") == 0) {
    if (state.compact) {
      Resize(StringArg(args, "edge"));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  if (response == nullptr) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

}

void desktop_start(FlBinaryMessenger* messenger, GtkWindow* window) {
  state.window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state.channel =
      fl_method_channel_new(messenger, "yamp/desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(state.channel, HandleCall, nullptr,
                                            nullptr);
  g_signal_add_emission_hook(
      g_signal_lookup("button-press-event", GTK_TYPE_WIDGET), 0, OnPress,
      nullptr, nullptr);
}
