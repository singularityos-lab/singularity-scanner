#include "sane-bridge.h"

#include <sane/sane.h>
#include <sane/saneopts.h>
#include <string.h>

struct _SintySane {
  SANE_Handle handle;
  gchar *error;
};

gboolean sinty_sane_init (void) {
  SANE_Int version = 0;
  return sane_init (&version, NULL) == SANE_STATUS_GOOD;
}

void sinty_sane_exit (void) {
  sane_exit ();
}

gchar **sinty_sane_devices (void) {
  const SANE_Device **list = NULL;
  GPtrArray *out = g_ptr_array_new ();
  if (sane_get_devices (&list, SANE_FALSE) == SANE_STATUS_GOOD && list) {
    for (gint i = 0; list[i]; i++) {
      g_ptr_array_add (out, g_strdup_printf ("%s\t%s\t%s\t%s", list[i]->name ? list[i]->name : "",
                                             list[i]->vendor ? list[i]->vendor : "", list[i]->model ? list[i]->model : "",
                                             list[i]->type ? list[i]->type : ""));
    }
  }
  g_ptr_array_add (out, NULL);
  return (gchar **) g_ptr_array_free (out, FALSE);
}

SintySane *sinty_sane_open (const gchar *name, gchar **error) {
  SANE_Handle handle = NULL;
  SANE_Status status = sane_open (name, &handle);
  if (status != SANE_STATUS_GOOD) {
    if (error)
      *error = g_strdup (sane_strstatus (status));
    return NULL;
  }
  SintySane *sane = g_new0 (SintySane, 1);
  sane->handle = handle;
  return sane;
}

void sinty_sane_close (SintySane *sane) {
  if (!sane)
    return;
  sane_close (sane->handle);
  g_free (sane->error);
  g_free (sane);
}

static gint find_option (SintySane *sane, const gchar *option, const SANE_Option_Descriptor **out) {
  for (SANE_Int i = 1;; i++) {
    const SANE_Option_Descriptor *d = sane_get_option_descriptor (sane->handle, i);
    if (!d)
      return -1;
    if (d->name && strcmp (d->name, option) == 0 && SANE_OPTION_IS_ACTIVE (d->cap)) {
      if (out)
        *out = d;
      return i;
    }
  }
}

gboolean sinty_sane_has_option (SintySane *sane, const gchar *option) {
  return find_option (sane, option, NULL) >= 0;
}

gchar **sinty_sane_choices (SintySane *sane, const gchar *option) {
  const SANE_Option_Descriptor *d = NULL;
  GPtrArray *out = g_ptr_array_new ();
  if (find_option (sane, option, &d) >= 0 && d->type == SANE_TYPE_STRING &&
      d->constraint_type == SANE_CONSTRAINT_STRING_LIST) {
    for (gint i = 0; d->constraint.string_list[i]; i++)
      g_ptr_array_add (out, g_strdup (d->constraint.string_list[i]));
  }
  g_ptr_array_add (out, NULL);
  return (gchar **) g_ptr_array_free (out, FALSE);
}

static gdouble word_value (const SANE_Option_Descriptor *d, SANE_Word w) {
  return d->type == SANE_TYPE_FIXED ? SANE_UNFIX (w) : (gdouble) w;
}

gint *sinty_sane_resolutions (SintySane *sane, gint *count) {
  static const gint common[] = { 75, 100, 150, 200, 300, 400, 600, 1200 };
  const SANE_Option_Descriptor *d = NULL;
  GArray *out = g_array_new (FALSE, FALSE, sizeof (gint));
  if (find_option (sane, SANE_NAME_SCAN_RESOLUTION, &d) >= 0) {
    if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST) {
      for (gint i = 1; i <= d->constraint.word_list[0]; i++) {
        gint v = (gint) word_value (d, d->constraint.word_list[i]);
        g_array_append_val (out, v);
      }
    } else if (d->constraint_type == SANE_CONSTRAINT_RANGE) {
      gdouble lo = word_value (d, d->constraint.range->min);
      gdouble hi = word_value (d, d->constraint.range->max);
      for (guint i = 0; i < G_N_ELEMENTS (common); i++)
        if (common[i] >= lo && common[i] <= hi)
          g_array_append_val (out, common[i]);
    }
  }
  *count = out->len;
  return (gint *) g_array_free (out, FALSE);
}

gchar *sinty_sane_get_string (SintySane *sane, const gchar *option) {
  const SANE_Option_Descriptor *d = NULL;
  gint n = find_option (sane, option, &d);
  if (n < 0 || d->type != SANE_TYPE_STRING)
    return NULL;
  gchar *buf = g_malloc0 (d->size + 1);
  if (sane_control_option (sane->handle, n, SANE_ACTION_GET_VALUE, buf, NULL) != SANE_STATUS_GOOD) {
    g_free (buf);
    return NULL;
  }
  return buf;
}

gboolean sinty_sane_set_string (SintySane *sane, const gchar *option, const gchar *value) {
  const SANE_Option_Descriptor *d = NULL;
  gint n = find_option (sane, option, &d);
  if (n < 0 || d->type != SANE_TYPE_STRING || !SANE_OPTION_IS_SETTABLE (d->cap))
    return FALSE;
  gchar *buf = g_malloc0 (MAX (d->size, (SANE_Int) strlen (value) + 1));
  g_strlcpy (buf, value, d->size);
  SANE_Status status = sane_control_option (sane->handle, n, SANE_ACTION_SET_VALUE, buf, NULL);
  g_free (buf);
  return status == SANE_STATUS_GOOD;
}

gboolean sinty_sane_set_number (SintySane *sane, const gchar *option, gdouble value) {
  const SANE_Option_Descriptor *d = NULL;
  gint n = find_option (sane, option, &d);
  if (n < 0 || !SANE_OPTION_IS_SETTABLE (d->cap))
    return FALSE;
  SANE_Word w;
  if (d->type == SANE_TYPE_FIXED)
    w = SANE_FIX (value);
  else if (d->type == SANE_TYPE_INT)
    w = (SANE_Word) (value + 0.5);
  else
    return FALSE;
  if (d->constraint_type == SANE_CONSTRAINT_RANGE) {
    w = CLAMP (w, d->constraint.range->min, d->constraint.range->max);
  } else if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST) {
    SANE_Word best = d->constraint.word_list[1];
    for (gint i = 1; i <= d->constraint.word_list[0]; i++)
      if (ABS (d->constraint.word_list[i] - w) < ABS (best - w))
        best = d->constraint.word_list[i];
    w = best;
  }
  if (d->size > (SANE_Int) sizeof (SANE_Word)) {
    gint count = d->size / sizeof (SANE_Word);
    SANE_Word *values = g_new (SANE_Word, count);
    for (gint i = 0; i < count; i++)
      values[i] = w;
    SANE_Status status = sane_control_option (sane->handle, n, SANE_ACTION_SET_VALUE, values, NULL);
    g_free (values);
    return status == SANE_STATUS_GOOD;
  }
  return sane_control_option (sane->handle, n, SANE_ACTION_SET_VALUE, &w, NULL) == SANE_STATUS_GOOD;
}

gdouble sinty_sane_max_number (SintySane *sane, const gchar *option) {
  const SANE_Option_Descriptor *d = NULL;
  if (find_option (sane, option, &d) < 0)
    return -1;
  if (d->constraint_type == SANE_CONSTRAINT_RANGE)
    return word_value (d, d->constraint.range->max);
  if (d->constraint_type == SANE_CONSTRAINT_WORD_LIST) {
    gdouble best = -1;
    for (gint i = 1; i <= d->constraint.word_list[0]; i++)
      best = MAX (best, word_value (d, d->constraint.word_list[i]));
    return best;
  }
  return -1;
}

gint sinty_sane_start (SintySane *sane, SintySaneParams *params, gchar **error) {
  SANE_Status status = sane_start (sane->handle);
  if (status == SANE_STATUS_NO_DOCS)
    return SINTY_SANE_START_NO_DOCS;
  if (status != SANE_STATUS_GOOD) {
    if (error)
      *error = g_strdup (sane_strstatus (status));
    return 0;
  }
  SANE_Parameters p;
  status = sane_get_parameters (sane->handle, &p);
  if (status != SANE_STATUS_GOOD) {
    if (error)
      *error = g_strdup (sane_strstatus (status));
    sane_cancel (sane->handle);
    return 0;
  }
  params->format = p.format;
  params->last_frame = p.last_frame;
  params->bytes_per_line = p.bytes_per_line;
  params->pixels_per_line = p.pixels_per_line;
  params->lines = p.lines;
  params->depth = p.depth;
  return 1;
}

gint sinty_sane_read (SintySane *sane, guint8 *buffer, gint max_length) {
  SANE_Int length = 0;
  SANE_Status status = sane_read (sane->handle, buffer, max_length, &length);
  if (status == SANE_STATUS_GOOD)
    return length;
  if (status == SANE_STATUS_EOF)
    return SINTY_SANE_READ_EOF;
  if (status == SANE_STATUS_CANCELLED)
    return SINTY_SANE_READ_CANCELLED;
  g_free (sane->error);
  sane->error = g_strdup (sane_strstatus (status));
  return SINTY_SANE_READ_ERROR;
}

void sinty_sane_cancel (SintySane *sane) {
  sane_cancel (sane->handle);
}

const gchar *sinty_sane_last_error (SintySane *sane) {
  return sane->error ? sane->error : "";
}
