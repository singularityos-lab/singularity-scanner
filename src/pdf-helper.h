#pragma once

#include <cairo.h>
#include <glib.h>

void sinty_surface_attach_jpeg (cairo_surface_t *surface, const guint8 *data, gsize length);
