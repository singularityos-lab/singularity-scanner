#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef struct _SintySane SintySane;

typedef struct {
  gint format;
  gboolean last_frame;
  gint bytes_per_line;
  gint pixels_per_line;
  gint lines;
  gint depth;
} SintySaneParams;

enum {
  SINTY_SANE_FRAME_GRAY = 0,
  SINTY_SANE_FRAME_RGB = 1,
  SINTY_SANE_FRAME_RED = 2,
  SINTY_SANE_FRAME_GREEN = 3,
  SINTY_SANE_FRAME_BLUE = 4
};

enum {
  SINTY_SANE_READ_ERROR = -1,
  SINTY_SANE_READ_EOF = -2,
  SINTY_SANE_READ_CANCELLED = -3,
  SINTY_SANE_START_NO_DOCS = 2
};

gboolean sinty_sane_init (void);
void sinty_sane_exit (void);
gchar **sinty_sane_devices (void);
SintySane *sinty_sane_open (const gchar *name, gchar **error);
void sinty_sane_close (SintySane *sane);
gchar **sinty_sane_choices (SintySane *sane, const gchar *option);
gint *sinty_sane_resolutions (SintySane *sane, gint *count);
gchar *sinty_sane_get_string (SintySane *sane, const gchar *option);
gboolean sinty_sane_set_string (SintySane *sane, const gchar *option, const gchar *value);
gboolean sinty_sane_set_number (SintySane *sane, const gchar *option, gdouble value);
gdouble sinty_sane_max_number (SintySane *sane, const gchar *option);
gboolean sinty_sane_has_option (SintySane *sane, const gchar *option);
gint sinty_sane_start (SintySane *sane, SintySaneParams *params, gchar **error);
gint sinty_sane_read (SintySane *sane, guint8 *buffer, gint max_length);
void sinty_sane_cancel (SintySane *sane);
const gchar *sinty_sane_last_error (SintySane *sane);

G_END_DECLS
