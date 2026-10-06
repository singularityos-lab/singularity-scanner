#include "pdf-helper.h"

void sinty_surface_attach_jpeg (cairo_surface_t *surface, const guint8 *data, gsize length) {
  guint8 *copy = g_memdup2 (data, length);
  cairo_surface_set_mime_data (surface, CAIRO_MIME_TYPE_JPEG, copy, length, g_free, copy);
}
