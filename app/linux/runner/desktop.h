#ifndef RUNNER_DESKTOP_H_
#define RUNNER_DESKTOP_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void desktop_start(FlBinaryMessenger* messenger, GtkWindow* window);

#endif
