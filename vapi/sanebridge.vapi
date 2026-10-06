[CCode (cheader_filename = "sane-bridge.h")]
namespace SaneBridge {
    [SimpleType]
    [CCode (cname = "SintySaneParams", has_type_id = false)]
    public struct Params {
        public int format;
        public bool last_frame;
        public int bytes_per_line;
        public int pixels_per_line;
        public int lines;
        public int depth;
    }

    [CCode (cname = "SINTY_SANE_FRAME_GRAY")]
    public const int FRAME_GRAY;
    [CCode (cname = "SINTY_SANE_FRAME_RGB")]
    public const int FRAME_RGB;
    [CCode (cname = "SINTY_SANE_FRAME_RED")]
    public const int FRAME_RED;
    [CCode (cname = "SINTY_SANE_FRAME_GREEN")]
    public const int FRAME_GREEN;
    [CCode (cname = "SINTY_SANE_FRAME_BLUE")]
    public const int FRAME_BLUE;
    [CCode (cname = "SINTY_SANE_READ_ERROR")]
    public const int READ_ERROR;
    [CCode (cname = "SINTY_SANE_READ_EOF")]
    public const int READ_EOF;
    [CCode (cname = "SINTY_SANE_READ_CANCELLED")]
    public const int READ_CANCELLED;
    [CCode (cname = "SINTY_SANE_START_NO_DOCS")]
    public const int START_NO_DOCS;

    [CCode (cname = "sinty_sane_init")]
    public bool init ();
    [CCode (cname = "sinty_sane_exit")]
    public void exit ();
    [CCode (cname = "sinty_sane_devices", array_length = false, array_null_terminated = true)]
    public string[] devices ();

    [Compact]
    [CCode (cname = "SintySane", free_function = "sinty_sane_close")]
    public class Device {
        [CCode (cname = "sinty_sane_open")]
        public static Device? open (string name, out string? error);
        [CCode (cname = "sinty_sane_choices", array_length = false, array_null_terminated = true)]
        public string[] choices (string option);
        [CCode (cname = "sinty_sane_resolutions", array_length_pos = 0.1)]
        public int[] resolutions ();
        [CCode (cname = "sinty_sane_get_string")]
        public string? get_string (string option);
        [CCode (cname = "sinty_sane_set_string")]
        public bool set_string (string option, string value);
        [CCode (cname = "sinty_sane_set_number")]
        public bool set_number (string option, double value);
        [CCode (cname = "sinty_sane_max_number")]
        public double max_number (string option);
        [CCode (cname = "sinty_sane_has_option")]
        public bool has_option (string option);
        [CCode (cname = "sinty_sane_start")]
        public int start (out Params params, out string? error);
        [CCode (cname = "sinty_sane_read")]
        public int read ([CCode (array_length_type = "gint")] uint8[] buffer);
        [CCode (cname = "sinty_sane_cancel")]
        public void cancel ();
        [CCode (cname = "sinty_sane_last_error")]
        public unowned string last_error ();
    }
}
