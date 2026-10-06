namespace Singularity.Apps.Scanner {

    public class ScanPage : Object {
        public int width { get; private set; }
        public int height { get; private set; }
        public int dpi { get; construct; }
        public int rotation { get; set; }
        public int rows_done { get; set; }
        public bool complete { get; set; }
        public uint8[] rgb;
        public Mutex mutex = Mutex ();
        private Gdk.Texture? cached;

        public signal void changed ();

        public ScanPage (int width, int height, int dpi) {
            Object (dpi: dpi);
            this.width = width;
            this.height = height;
            rgb = new uint8[width * height * 3];
            Memory.set (rgb, 255, rgb.length);
        }

        public void ensure_rows (int rows) {
            if (rows <= height) return;
            int grown = int.max (rows, height + height / 2 + 64);
            var bigger = new uint8[width * grown * 3];
            Memory.copy (bigger, rgb, rgb.length);
            Memory.set (&bigger[rgb.length], 255, bigger.length - rgb.length);
            rgb = (owned) bigger;
            height = grown;
        }

        public void crop_rows (int rows) {
            if (rows <= 0 || rows >= height) return;
            mutex.lock ();
            rgb.resize (width * rows * 3);
            height = rows;
            mutex.unlock ();
            invalidate ();
        }

        public void invalidate () {
            cached = null;
            changed ();
        }

        public Gdk.Texture texture () {
            if (cached == null) {
                mutex.lock ();
                cached = new Gdk.MemoryTexture (width, height, Gdk.MemoryFormat.R8G8B8, new Bytes (rgb), width * 3);
                mutex.unlock ();
            }
            return cached;
        }

        public Gdk.Pixbuf pixbuf () {
            mutex.lock ();
            var pix = new Gdk.Pixbuf.from_bytes (new Bytes (rgb), Gdk.Colorspace.RGB, false, 8, width, height, width * 3);
            mutex.unlock ();
            switch (rotation) {
                case 90: return pix.rotate_simple (Gdk.PixbufRotation.CLOCKWISE);
                case 180: return pix.rotate_simple (Gdk.PixbufRotation.UPSIDEDOWN);
                case 270: return pix.rotate_simple (Gdk.PixbufRotation.COUNTERCLOCKWISE);
                default: return pix;
            }
        }
    }

    public class DeviceInfo : Object {
        public string name;
        public string vendor;
        public string model;
        public string kind;

        public string label () {
            string v = vendor.strip ();
            string m = model.strip ();
            if (v == "" || v.down () == "noname") return m != "" ? m : name;
            if (m.down ().has_prefix (v.down ())) return m;
            return "%s %s".printf (v, m);
        }
    }

    public class Paper : Object {
        public string id;
        public string label;
        public double width_mm;
        public double height_mm;

        public Paper (string id, string label, double w, double h) {
            this.id = id;
            this.label = label;
            width_mm = w;
            height_mm = h;
        }

        public static Paper[] all () {
            return {
                new Paper ("a4", "A4", 210, 297),
                new Paper ("letter", _("Letter"), 215.9, 279.4),
                new Paper ("legal", _("Legal"), 215.9, 355.6),
                new Paper ("a5", "A5", 148, 210),
                new Paper ("a6", "A6", 105, 148),
                new Paper ("full", _("Whole Scan Area"), 0, 0)
            };
        }
    }

    public class ScanSettings : Object {
        public string device { get; set; default = ""; }
        public string source { get; set; default = ""; }
        public string mode { get; set; default = ""; }
        public int resolution { get; set; default = 300; }
        public string paper { get; set; default = "a4"; }

        private static string path () {
            return Path.build_filename (Environment.get_user_config_dir (), "singularity", "scanner.ini");
        }

        public void load () {
            var kf = new KeyFile ();
            try {
                kf.load_from_file (path (), KeyFileFlags.NONE);
                device = kf.get_string ("scan", "device");
                source = kf.get_string ("scan", "source");
                mode = kf.get_string ("scan", "mode");
                resolution = kf.get_integer ("scan", "resolution");
                paper = kf.get_string ("scan", "paper");
            } catch (Error e) {
            }
        }

        public void save () {
            var kf = new KeyFile ();
            kf.set_string ("scan", "device", device);
            kf.set_string ("scan", "source", source);
            kf.set_string ("scan", "mode", mode);
            kf.set_integer ("scan", "resolution", resolution);
            kf.set_string ("scan", "paper", paper);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path ()), 0700);
                kf.save_to_file (path ());
            } catch (Error e) {
                warning ("scanner: %s", e.message);
            }
        }
    }

    public class DeviceOptions : Object {
        public string[] sources = {};
        public string[] modes = {};
        public int[] resolutions = {};
        public double max_width = -1;
        public double max_height = -1;

        public bool is_feeder (string source) {
            string s = source.down ();
            return s.contains ("feeder") || s.contains ("adf") || s.contains ("duplex");
        }

        public bool has_feeder () {
            foreach (string s in sources) if (is_feeder (s)) return true;
            return false;
        }
    }

    public class ScannerService : Object {
        private Mutex lock;
        private SaneBridge.Device? handle;
        private string handle_name = "";
        private bool initialized;
        private int cancelled;
        public bool busy { get; private set; }
        public Gee.ArrayList<DeviceInfo> devices = new Gee.ArrayList<DeviceInfo> ();

        public signal void page_started (ScanPage page);
        public signal void page_done (ScanPage page);
        public signal void scan_finished (string? error);

        private void ensure_init () {
            if (!initialized) initialized = SaneBridge.init ();
        }

        public async void refresh () {
            SourceFunc cb = refresh.callback;
            var found = new Gee.ArrayList<DeviceInfo> ();
            new Thread<void*> ("sane-list", () => {
                lock.lock ();
                ensure_init ();
                if (handle != null) {
                    handle = null;
                    handle_name = "";
                }
                foreach (string row in SaneBridge.devices ()) {
                    string[] parts = row.split ("\t");
                    if (parts.length < 4 || parts[0] == "") continue;
                    var d = new DeviceInfo ();
                    d.name = parts[0];
                    d.vendor = parts[1];
                    d.model = parts[2];
                    d.kind = parts[3];
                    found.add (d);
                }
                lock.unlock ();
                Idle.add ((owned) cb);
                return null;
            });
            yield;
            devices.clear ();
            devices.add_all (found);
        }

        private unowned SaneBridge.Device? device_for (string name, out string? error) {
            error = null;
            if (handle != null && handle_name == name) return handle;
            handle = null;
            handle = SaneBridge.Device.open (name, out error);
            handle_name = handle != null ? name : "";
            return handle;
        }

        public async DeviceOptions? options (string name, out string? error) {
            SourceFunc cb = options.callback;
            DeviceOptions? result = null;
            string? err = null;
            new Thread<void*> ("sane-options", () => {
                lock.lock ();
                ensure_init ();
                unowned SaneBridge.Device? h = device_for (name, out err);
                if (h != null) {
                    result = new DeviceOptions ();
                    result.sources = h.choices ("source");
                    result.modes = h.choices ("mode");
                    result.resolutions = h.resolutions ();
                    result.max_width = h.max_number ("br-x");
                    result.max_height = h.max_number ("br-y");
                }
                lock.unlock ();
                Idle.add ((owned) cb);
                return null;
            });
            yield;
            error = err;
            return result;
        }

        public void cancel () {
            AtomicInt.set (ref cancelled, 1);
            unowned SaneBridge.Device? h = handle;
            if (busy && h != null) h.cancel ();
        }

        public void scan (ScanSettings settings, bool all_pages) {
            if (busy) return;
            busy = true;
            AtomicInt.set (ref cancelled, 0);
            string device = settings.device;
            string source = settings.source;
            string mode = settings.mode;
            int resolution = settings.resolution;
            string paper = settings.paper;
            new Thread<void*> ("sane-scan", () => {
                string? error = null;
                lock.lock ();
                ensure_init ();
                unowned SaneBridge.Device? h = device_for (device, out error);
                if (h != null) {
                    if (source != "") h.set_string ("source", source);
                    if (mode != "") h.set_string ("mode", mode);
                    h.set_number ("resolution", resolution);
                    apply_paper (h, paper);
                    error = run (h, resolution, all_pages);
                    if (error != null) {
                        handle = null;
                        handle_name = "";
                    }
                }
                lock.unlock ();
                Idle.add (() => {
                    busy = false;
                    scan_finished (error);
                    return Source.REMOVE;
                });
                return null;
            });
        }

        private void apply_paper (SaneBridge.Device h, string paper) {
            double mw = h.max_number ("br-x");
            double mh = h.max_number ("br-y");
            if (mw <= 0 || mh <= 0) return;
            h.set_number ("tl-x", 0);
            h.set_number ("tl-y", 0);
            foreach (var p in Paper.all ()) {
                if (p.id != paper) continue;
                if (p.width_mm <= 0) {
                    h.set_number ("br-x", mw);
                    h.set_number ("br-y", mh);
                } else {
                    h.set_number ("br-x", double.min (p.width_mm, mw));
                    h.set_number ("br-y", double.min (p.height_mm, mh));
                }
                return;
            }
        }

        private string? run (SaneBridge.Device h, int dpi, bool all_pages) {
            int pages = 0;
            while (AtomicInt.get (ref cancelled) == 0) {
                SaneBridge.Params p;
                string? err;
                int started = h.start (out p, out err);
                if (started == SaneBridge.START_NO_DOCS) {
                    if (pages == 0) return _("There is no paper in the document feeder.");
                    break;
                }
                if (started == 0) {
                    if (AtomicInt.get (ref cancelled) != 0) break;
                    return err ?? _("The scanner could not start.");
                }
                int rows_guess = p.lines > 0 ? p.lines : (int) (dpi * 11.7);
                var page = new ScanPage (p.pixels_per_line, rows_guess, dpi);
                Idle.add (() => {
                    page_started (page);
                    return Source.REMOVE;
                });
                string? failure = read_page (h, page, p);
                if (failure != null) {
                    h.cancel ();
                    Idle.add (() => {
                        page.complete = true;
                        page.invalidate ();
                        return Source.REMOVE;
                    });
                    if (failure == "") return null;
                    return failure;
                }
                pages++;
                Idle.add (() => {
                    page.complete = true;
                    page.invalidate ();
                    page_done (page);
                    return Source.REMOVE;
                });
                if (!all_pages) {
                    h.cancel ();
                    break;
                }
            }
            if (AtomicInt.get (ref cancelled) != 0) h.cancel ();
            return null;
        }

        private string? read_page (SaneBridge.Device h, ScanPage page, SaneBridge.Params first) {
            var p = first;
            var buf = new uint8[65536];
            int64 last_update = 0;
            int rows_max = 0;
            while (true) {
                int bpl = p.bytes_per_line;
                var line = new uint8[bpl];
                int fill = 0;
                int row = 0;
                int channel = p.format == SaneBridge.FRAME_RED ? 0 : p.format == SaneBridge.FRAME_GREEN ? 1 : p.format == SaneBridge.FRAME_BLUE ? 2 : -1;
                while (true) {
                    if (AtomicInt.get (ref cancelled) != 0) return "";
                    int n = h.read (buf);
                    if (n == SaneBridge.READ_EOF) break;
                    if (n == SaneBridge.READ_CANCELLED) return "";
                    if (n == SaneBridge.READ_ERROR) return h.last_error ();
                    int off = 0;
                    while (off < n) {
                        int take = int.min (bpl - fill, n - off);
                        Memory.copy (&line[fill], &buf[off], take);
                        fill += take;
                        off += take;
                        if (fill == bpl) {
                            page.mutex.lock ();
                            lock_rows (page, row + 1);
                            convert_line (line, p, channel, page, row);
                            page.mutex.unlock ();
                            row++;
                            fill = 0;
                        }
                    }
                    int64 now = get_monotonic_time ();
                    if (now - last_update > 120000) {
                        last_update = now;
                        int done = int.max (row, rows_max);
                        Idle.add (() => {
                            page.rows_done = done;
                            page.invalidate ();
                            return Source.REMOVE;
                        });
                    }
                }
                rows_max = int.max (rows_max, row);
                if (p.last_frame) break;
                string? err;
                if (h.start (out p, out err) != 1) return err ?? _("The scanner stopped in the middle of a page.");
            }
            int final_rows = rows_max;
            Idle.add (() => {
                page.rows_done = final_rows;
                page.crop_rows (final_rows);
                return Source.REMOVE;
            });
            return null;
        }

        private void lock_rows (ScanPage page, int rows) {
            if (rows > page.height) page.ensure_rows (rows);
        }

        private static void convert_line (uint8[] line, SaneBridge.Params p, int channel, ScanPage page, int row) {
            int w = page.width;
            int o = row * w * 3;
            unowned uint8[] dst = page.rgb;
            if (p.format == SaneBridge.FRAME_RGB) {
                if (p.depth == 8) {
                    Memory.copy (&dst[o], line, int.min (w * 3, line.length));
                } else if (p.depth == 16) {
                    for (int i = 0; i < w * 3 && i * 2 + 1 < line.length; i++) dst[o + i] = line[i * 2 + 1];
                } else if (p.depth == 1) {
                    for (int x = 0; x < w; x++) {
                        for (int c = 0; c < 3; c++) {
                            int bit = x * 3 + c;
                            bool on = ((line[bit / 8] >> (7 - bit % 8)) & 1) != 0;
                            dst[o + x * 3 + c] = on ? 0 : 255;
                        }
                    }
                }
                return;
            }
            for (int x = 0; x < w; x++) {
                uint8 v;
                if (p.depth == 1) v = ((line[x / 8] >> (7 - x % 8)) & 1) != 0 ? 0 : 255;
                else if (p.depth == 16) v = x * 2 + 1 < line.length ? line[x * 2 + 1] : 255;
                else v = x < line.length ? line[x] : 255;
                if (channel < 0) {
                    dst[o + x * 3] = v;
                    dst[o + x * 3 + 1] = v;
                    dst[o + x * 3 + 2] = v;
                } else {
                    dst[o + x * 3 + channel] = v;
                }
            }
        }
    }
}
