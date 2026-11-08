#ifndef RUNNER_MPRIS_H_
#define RUNNER_MPRIS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

void mpris_start(FlBinaryMessenger* messenger, GtkWindow* window);

#endif
