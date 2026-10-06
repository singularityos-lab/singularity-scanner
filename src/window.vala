using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Scanner {

    public class PageView : Widget {
        private const int HEIGHT = 260;
        public ScanPage page { get; construct; }
        private ulong changed_id;

        public PageView (ScanPage page) {
            Object (page: page);
            add_css_class ("scan-paper");
            overflow = Overflow.HIDDEN;
            changed_id = page.changed.connect (() => {
                queue_resize ();
                queue_draw ();
            });
        }

        public override void dispose () {
            if (changed_id != 0) page.disconnect (changed_id);
            changed_id = 0;
            base.dispose ();
        }

        private void page_size (out double w, out double h) {
            bool turned = page.rotation == 90 || page.rotation == 270;
            w = turned ? page.height : page.width;
            h = turned ? page.width : page.height;
        }

        protected override void measure (Orientation orientation, int for_size, out int minimum, out int natural, out int minimum_baseline, out int natural_baseline) {
            minimum_baseline = natural_baseline = -1;
            if (orientation == Orientation.VERTICAL) {
                minimum = natural = HEIGHT;
                return;
            }
            double w, h;
            page_size (out w, out h);
            int width = h > 0 ? (int) (HEIGHT * w / h) : HEIGHT;
            minimum = natural = width.clamp (110, 380);
        }

        protected override void snapshot (Gtk.Snapshot snapshot) {
            float w = get_width (), h = get_height ();
            var tex = page.texture ();
            snapshot.save ();
            snapshot.translate (Graphene.Point ().init (w / 2, h / 2));
            snapshot.rotate (page.rotation);
            bool turned = page.rotation == 90 || page.rotation == 270;
            float bw = turned ? h : w, bh = turned ? w : h;
            var rect = Graphene.Rect ().init (-bw / 2, -bh / 2, bw, bh);
            snapshot.append_scaled_texture (tex, Gsk.ScalingFilter.TRILINEAR, rect);
            if (!page.complete && page.height > 0) {
                float y = -bh / 2 + bh * page.rows_done / page.height;
                var accent = Gdk.RGBA ();
                accent.parse ("#3584e4");
                var style = get_style_context ();
                Gdk.RGBA found;
                if (style.lookup_color ("accent_bg_color", out found)) accent = found;
                snapshot.append_color (accent, Graphene.Rect ().init (-bw / 2, y - 1.5f, bw, 3));
            }
            snapshot.restore ();
        }
    }

    public class PageCard : FlowBoxChild {
        public ScanPage page;
        private Label caption;

        public PageCard (ScanPage page) {
            this.page = page;
            add_css_class ("scan-card");
            var box = new Box (Orientation.VERTICAL, 10);
            box.halign = Align.CENTER;
            box.append (new PageView (page));
            caption = new Label ("");
            caption.add_css_class ("dim-label");
            caption.add_css_class ("caption");
            box.append (caption);
            child = box;
        }

        public void set_number (int n) {
            caption.label = _("Page %d").printf (n);
        }
    }

    public class ScannerWindow : Singularity.Widgets.Window {
        private ScannerService service;
        private ScanSettings settings = new ScanSettings ();
        private DeviceOptions? options;
        private Stack stack;
        private WelcomePage none_page;
        private WelcomePage ready_page;
        private WelcomePage feeder_page;
        private FlowBox grid;
        private Gee.ArrayList<ScanPage> pages = new Gee.ArrayList<ScanPage> ();
        private Button scan_bubble;
        private Button settings_bubble;
        private Button save_bubble;
        private Button clear_bubble;
        private Label? toast;
        private uint toast_id;
        private Overlay root;
        private bool searching;
        private bool dirty;
        private bool quick_pending;
        private int scan_count;
        private ScanPage? scanning_page;
        private double launcher_fraction = -1;

        public ScannerWindow (Gtk.Application app) {
            Object (application: app);
            title = _("Document Scanner");
            set_default_size (1000, 720);
            service = new ScannerService ();
            settings.load ();

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            none_page = new WelcomePage ();
            none_page.app_icon_name = "dev.sinty.scanner";
            none_page.title = _("Document Scanner");
            none_page.subtitle = _("Looking for scanners. This can take a few seconds for scanners on the network.");
            none_page.add_action ("printer", _("Look Again"), _("Search for scanners once more"), () => search.begin ());
            stack.add_named (none_page, "none");

            ready_page = build_ready (false);
            stack.add_named (ready_page, "ready");
            feeder_page = build_ready (true);
            stack.add_named (feeder_page, "ready-feeder");

            grid = new FlowBox ();
            grid.selection_mode = SelectionMode.SINGLE;
            grid.activate_on_single_click = false;
            grid.homogeneous = false;
            grid.min_children_per_line = 1;
            grid.max_children_per_line = 8;
            grid.column_spacing = 28;
            grid.row_spacing = 28;
            grid.valign = Align.START;
            grid.margin_top = 28;
            grid.margin_bottom = 40;
            grid.margin_start = 40;
            grid.margin_end = 40;
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.child = grid;
            apply_view_edge (scroll);
            stack.add_named (scroll, "pages");
            root = new Overlay ();
            root.child = stack;
            set_content (root);

            scan_bubble = add_bubble_suggested (_("Scan"), () => {
                if (service.busy) service.cancel ();
                else start_scan (feeder_selected ());
            });
            settings_bubble = add_bubble_icon ("emblem-system-symbolic", _("Scan Settings"), () => open_settings ());
            save_bubble = add_bubble_icon ("document-save-symbolic", _("Save"), () => save ());
            clear_bubble = add_bubble_icon ("edit-clear-all-symbolic", _("Start Over"), () => confirm_clear ());

            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval == Gdk.Key.Delete && selected () != null && stack.visible_child_name == "pages") {
                    remove_page (selected ());
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);

            var save_action = new SimpleAction ("save", null);
            save_action.activate.connect (() => save ());
            add_action (save_action);
            var scan_action = new SimpleAction ("scan", null);
            scan_action.activate.connect (() => {
                if (!service.busy) start_scan (false);
            });
            add_action (scan_action);
            var scan_all_action = new SimpleAction ("scan-all", null);
            scan_all_action.activate.connect (() => {
                if (!service.busy) start_scan (true);
            });
            add_action (scan_all_action);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => open_settings ());
            add_action (settings_action);
            var clear_action = new SimpleAction ("clear", null);
            clear_action.activate.connect (() => confirm_clear ());
            add_action (clear_action);
            var refresh_action = new SimpleAction ("refresh", null);
            refresh_action.activate.connect (() => search.begin ());
            add_action (refresh_action);
            var stop_action = new SimpleAction ("stop", null);
            stop_action.activate.connect (() => {
                if (service.busy) service.cancel ();
            });
            add_action (stop_action);
            var save_page_action = new SimpleAction ("save-page", null);
            save_page_action.activate.connect (() => {
                var card = selected ();
                if (card != null && card.page.complete) save_pages (single (card.page));
            });
            add_action (save_page_action);
            var rotate_left_action = new SimpleAction ("rotate-left", null);
            rotate_left_action.activate.connect (() => {
                var card = selected ();
                if (card != null) rotate (card, 270);
            });
            add_action (rotate_left_action);
            var rotate_right_action = new SimpleAction ("rotate-right", null);
            rotate_right_action.activate.connect (() => {
                var card = selected ();
                if (card != null) rotate (card, 90);
            });
            add_action (rotate_right_action);
            var earlier_action = new SimpleAction ("move-earlier", null);
            earlier_action.activate.connect (() => {
                var card = selected ();
                if (card != null) move (card, -1);
            });
            add_action (earlier_action);
            var later_action = new SimpleAction ("move-later", null);
            later_action.activate.connect (() => {
                var card = selected ();
                if (card != null) move (card, 1);
            });
            add_action (later_action);
            var delete_action = new SimpleAction ("delete-page", null);
            delete_action.activate.connect (() => {
                var card = selected ();
                if (card != null) remove_page (card);
            });
            add_action (delete_action);
            var close_action = new SimpleAction ("close", null);
            close_action.activate.connect (() => close ());
            add_action (close_action);
            grid.selected_children_changed.connect (sync_actions);

            service.page_started.connect ((p) => {
                scanning_page = p;
                p.notify["rows-done"].connect (() => {
                    if (scanning_page == p) update_launcher ();
                });
                add_page (p);
                update_launcher ();
            });
            service.page_done.connect ((p) => {
                scan_count++;
                sync ();
                update_launcher ();
            });
            service.scan_finished.connect ((err) => {
                scanning_page = null;
                sync ();
                update_launcher ();
                if (err != null) show_error (_("Scanning Stopped"), err);
            });
            close_request.connect (() => {
                if (dirty && pages.size > 0) {
                    confirm_discard (() => {
                        dirty = false;
                        close ();
                    });
                    return true;
                }
                if (service.busy) service.cancel ();
                return false;
            });
            sync ();
            search.begin ();
        }

        private WelcomePage build_ready (bool feeder) {
            var page = new WelcomePage ();
            page.app_icon_name = "dev.sinty.scanner";
            page.title = _("Document Scanner");
            page.subtitle = _("Ready to scan.");
            page.add_action ("x-office-document", _("Scan a Page"), _("Place the page face down on the glass"), () => start_scan (false));
            if (feeder) page.add_action ("folder-documents", _("Scan All Pages"), _("Feed a stack of pages through the document feeder"), () => start_scan (true));
            page.add_action ("printer", _("Scan Settings"), _("Scanner, color, quality and paper size"), () => open_settings ());
            return page;
        }

        private bool feeder_selected () {
            return options != null && settings.source != "" && options.is_feeder (settings.source);
        }

        private DeviceInfo? current_device () {
            foreach (var d in service.devices) if (d.name == settings.device) return d;
            return null;
        }

        private async void search () {
            if (searching) return;
            searching = true;
            none_page.subtitle = _("Looking for scanners. This can take a few seconds for scanners on the network.");
            sync ();
            yield service.refresh ();
            searching = false;
            if (service.devices.size > 0 && current_device () == null) settings.device = service.devices[0].name;
            if (service.devices.size == 0) {
                none_page.subtitle = _("No scanner found. Connect a scanner and turn it on, or check that it is on the same network.");
                options = null;
                quick_pending = false;
            } else {
                yield load_options ();
            }
            sync ();
            if (quick_pending) {
                quick_pending = false;
                if (options != null) start_scan (feeder_selected ());
            }
        }

        public void quick_scan () {
            if (service.busy) return;
            if (searching || options == null) {
                quick_pending = true;
                if (!searching) search.begin ();
                return;
            }
            start_scan (feeder_selected ());
        }

        private void update_launcher () {
            var conn = application.get_dbus_connection ();
            if (conn == null) return;
            bool visible = service.busy && scanning_page != null;
            double fraction = 0;
            if (visible && scanning_page.height > 0) fraction = ((double) scanning_page.rows_done / scanning_page.height).clamp (0, 1);
            double delta = fraction - launcher_fraction;
            if (visible && launcher_fraction >= 0 && delta < 0.01 && delta > -0.01) return;
            if (!visible && launcher_fraction < 0) return;
            launcher_fraction = visible ? fraction : -1;
            var props = new VariantBuilder (VariantType.VARDICT);
            props.add ("{sv}", "progress", new Variant.double (fraction));
            props.add ("{sv}", "progress-visible", new Variant.boolean (visible));
            props.add ("{sv}", "count", new Variant.int64 (scan_count));
            props.add ("{sv}", "count-visible", new Variant.boolean (visible && scan_count > 0));
            if (visible) props.add ("{sv}", "label", new Variant.string (ngettext ("Scanning page %d", "Scanning page %d", scan_count + 1).printf (scan_count + 1)));
            try {
                conn.emit_signal (null, "/com/canonical/Unity/LauncherEntry", "com.canonical.Unity.LauncherEntry", "Update",
                    new Variant ("(s@a{sv})", "application://dev.sinty.scanner.desktop", props.end ()));
            } catch (Error e) {
                warning ("scanner: %s", e.message);
            }
        }

        private async void load_options () {
            string? err;
            options = yield service.options (settings.device, out err);
            if (options == null) {
                show_error (_("The Scanner Is Not Available"), err ?? _("The scanner could not be opened."));
                return;
            }
            if (!contains (options.sources, settings.source)) settings.source = options.sources.length > 0 ? pick_source (options.sources) : "";
            if (!contains (options.modes, settings.mode)) settings.mode = options.modes.length > 0 ? pick_mode (options.modes) : "";
            if (options.resolutions.length > 0) {
                bool ok = false;
                foreach (int r in options.resolutions) if (r == settings.resolution) ok = true;
                if (!ok) settings.resolution = nearest (options.resolutions, 300);
            }
            settings.save ();
        }

        private static bool contains (string[] list, string value) {
            foreach (string s in list) if (s == value) return true;
            return false;
        }

        private static string pick_source (string[] sources) {
            foreach (string s in sources) if (s.down ().contains ("flatbed")) return s;
            return sources[0];
        }

        private static string pick_mode (string[] modes) {
            foreach (string m in modes) if (m.down () == "color") return m;
            return modes[0];
        }

        private static int nearest (int[] values, int target) {
            int best = values[0];
            foreach (int v in values) if ((v - target).abs () < (best - target).abs ()) best = v;
            return best;
        }

        private void sync () {
            bool have_device = service.devices.size > 0 && !searching;
            string page;
            if (pages.size > 0) page = "pages";
            else if (have_device) page = options != null && options.has_feeder () ? "ready-feeder" : "ready";
            else page = "none";
            stack.visible_child_name = page;
            var d = current_device ();
            if (d != null) {
                ready_page.subtitle = _("Scanning with %s").printf (d.label ());
                feeder_page.subtitle = ready_page.subtitle;
            }
            scan_bubble.label = service.busy ? _("Stop") : (feeder_selected () ? _("Scan All") : _("Scan"));
            scan_bubble.visible = have_device || service.busy;
            settings_bubble.visible = have_device && page == "pages";
            save_bubble.visible = page == "pages" && !service.busy;
            clear_bubble.visible = page == "pages" && !service.busy;
            settings_bubble.sensitive = !service.busy;
            renumber ();
            sync_actions ();
        }

        private void sync_actions () {
            bool have_device = service.devices.size > 0 && !searching;
            bool idle = !service.busy;
            bool has_pages = pages.size > 0 && idle;
            var card = selected ();
            bool page_ready = card != null && card.page.complete && idle && stack.visible_child_name == "pages";
            int index = card != null ? card.get_index () : -1;
            enable_action ("scan", have_device && idle);
            enable_action ("scan-all", have_device && idle && options != null && options.has_feeder ());
            enable_action ("stop", service.busy);
            enable_action ("settings", have_device && idle);
            enable_action ("refresh", idle && !searching);
            enable_action ("save", has_pages);
            enable_action ("clear", has_pages);
            enable_action ("save-page", page_ready);
            enable_action ("rotate-left", page_ready);
            enable_action ("rotate-right", page_ready);
            enable_action ("delete-page", page_ready);
            enable_action ("move-earlier", page_ready && index > 0);
            enable_action ("move-later", page_ready && index >= 0 && index < pages.size - 1);
        }

        private void enable_action (string name, bool on) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (on);
        }

        private void renumber () {
            int n = 1;
            for (var c = grid.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var card = c as PageCard;
                if (card != null) card.set_number (n++);
            }
        }

        private void start_scan (bool all_pages) {
            if (service.busy || settings.device == "") return;
            if (all_pages && options != null && !feeder_selected ()) {
                foreach (string s in options.sources) {
                    if (options.is_feeder (s)) {
                        settings.source = s;
                        break;
                    }
                }
            } else if (!all_pages && feeder_selected () && options != null) {
                string flat = "";
                foreach (string s in options.sources) if (!options.is_feeder (s)) flat = s;
                if (flat != "") settings.source = flat;
            }
            settings.save ();
            scan_count = 0;
            launcher_fraction = -1;
            service.scan (settings, all_pages);
            sync ();
        }

        private void add_page (ScanPage page) {
            pages.add (page);
            dirty = true;
            var card = new PageCard (page);
            var click = new GestureClick ();
            click.button = 3;
            click.pressed.connect ((n, x, y) => page_menu (card, x, y));
            card.add_controller (click);
            var press = new GestureLongPress ();
            press.pressed.connect ((x, y) => page_menu (card, x, y));
            card.add_controller (press);
            grid.append (card);
            sync ();
            Idle.add (() => {
                card.grab_focus ();
                var adj = ((ScrolledWindow) stack.get_child_by_name ("pages")).vadjustment;
                adj.value = adj.upper;
                return Source.REMOVE;
            });
        }

        private PageCard? selected () {
            var sel = grid.get_selected_children ();
            if (sel.length () == 0) return null;
            return sel.nth_data (0) as PageCard;
        }

        private void page_menu (PageCard card, double x, double y) {
            grid.select_child (card);
            var menu = new ContextMenu (card);
            menu.add_item (_("Rotate Left"), "object-rotate-left-symbolic", () => rotate (card, 270));
            menu.add_item (_("Rotate Right"), "object-rotate-right-symbolic", () => rotate (card, 90));
            menu.add_separator ();
            int index = card.get_index ();
            if (index > 0) menu.add_item (_("Move Earlier"), "go-previous-symbolic", () => move (card, -1));
            if (index < pages.size - 1) menu.add_item (_("Move Later"), "go-next-symbolic", () => move (card, 1));
            menu.add_item (_("Save This Page"), "document-save-symbolic", () => save_pages (single (card.page)));
            menu.add_separator ();
            menu.add_item (_("Delete"), "user-trash-symbolic", () => remove_page (card), "destructive");
            menu.pointing_to = { (int) x, (int) y, 1, 1 };
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private static Gee.List<ScanPage> single (ScanPage p) {
            var l = new Gee.ArrayList<ScanPage> ();
            l.add (p);
            return l;
        }

        private void rotate (PageCard card, int by) {
            card.page.rotation = (card.page.rotation + by) % 360;
            card.page.invalidate ();
            dirty = true;
        }

        private void move (PageCard card, int delta) {
            int index = card.get_index ();
            int target = index + delta;
            if (target < 0 || target >= pages.size) return;
            var p = pages.remove_at (index);
            pages.insert (target, p);
            grid.remove (card);
            grid.insert (card, target);
            grid.select_child (card);
            dirty = true;
            renumber ();
            sync_actions ();
        }

        private void remove_page (PageCard card) {
            if (!card.page.complete) return;
            pages.remove (card.page);
            grid.remove (card);
            dirty = pages.size > 0;
            sync ();
        }

        private void confirm_clear () {
            if (pages.size == 0) return;
            confirm_discard (() => clear_pages ());
        }

        private void clear_pages () {
            Widget? c;
            while ((c = grid.get_first_child ()) != null) grid.remove (c);
            pages.clear ();
            dirty = false;
            sync ();
        }

        private delegate void Then ();

        private void confirm_discard (owned Then then) {
            var dlg = new ConfirmDialog ((Gtk.Application) application, _("Discard the Scanned Pages?"), "user-trash-symbolic",
                _("The pages have not been saved."), _("Discard"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.set_secondary (_("Save"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) then ();
                else if (r == ConfirmDialog.Response.SECONDARY) save ();
            });
            dlg.present ();
        }

        private void save () {
            var list = new Gee.ArrayList<ScanPage> ();
            foreach (var p in pages) if (p.complete) list.add (p);
            if (list.size == 0) return;
            save_pages (list);
        }

        private void save_pages (Gee.List<ScanPage> list) {
            var dialog = new FileDialog ();
            dialog.title = _("Save Scan");
            dialog.initial_name = _("Scan %s.pdf").printf (new DateTime.now_local ().format ("%Y-%m-%d %H-%M"));
            string? docs = Environment.get_user_special_dir (UserDirectory.DOCUMENTS);
            if (docs != null) dialog.initial_folder = File.new_for_path (docs);
            var filters = new GLib.ListStore (typeof (FileFilter));
            var pdf = new FileFilter ();
            pdf.name = _("PDF Document");
            pdf.add_suffix ("pdf");
            filters.append (pdf);
            var png = new FileFilter ();
            png.name = _("PNG Image");
            png.add_suffix ("png");
            filters.append (png);
            var jpg = new FileFilter ();
            jpg.name = _("JPEG Image");
            jpg.add_suffix ("jpg");
            jpg.add_suffix ("jpeg");
            filters.append (jpg);
            dialog.filters = filters;
            dialog.default_filter = pdf;
            dialog.save.begin (this, null, (o, res) => {
                try {
                    var file = dialog.save.end (res);
                    if (file == null) return;
                    string path = file.get_path ();
                    var fmt = ExportFormat.from_path (path);
                    if (fmt == ExportFormat.PDF && !path.down ().has_suffix (".pdf")) path += ".pdf";
                    Export.save (list, path);
                    if (list.size == pages.size) dirty = false;
                    show_toast (_("Saved %s").printf (Path.get_basename (path)));
                } catch (Error e) {
                    if (e is Gtk.DialogError.DISMISSED) return;
                    show_error (_("Could Not Save"), e.message);
                }
            });
        }

        private static string mode_label (string mode) {
            switch (mode.down ()) {
                case "color": return _("Color");
                case "gray": return _("Grayscale");
                case "lineart": return _("Black and White");
                case "halftone": return _("Halftone");
                default: return mode;
            }
        }

        private static string source_label (string source) {
            string s = source.down ();
            if (s == "flatbed") return _("Glass");
            if (s.contains ("duplex")) return _("Document Feeder, Both Sides");
            if (s.contains ("feeder") || s.contains ("adf")) return _("Document Feeder");
            return source;
        }

        private static void set_choices (SelectionRow row, string[] labels, int selected) {
            var list = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            for (int i = 0; i < labels.length; i++) {
                var option = new Singularity.Core.AppSettingOption ();
                option.id = i.to_string ();
                option.label = labels[i];
                list.add (option);
            }
            row.set_options (list);
            row.current_value = labels.length == 0 ? "" : (selected >= 0 && selected < labels.length ? selected : 0).to_string ();
        }

        private static int chosen (SelectionRow row) {
            return row.current_value == "" ? -1 : int.parse (row.current_value);
        }

        private static int index_of (string[] list, string value) {
            for (int i = 0; i < list.length; i++) if (list[i] == value) return i;
            return 0;
        }

        private void open_settings () {
            if (service.busy) return;
            var dlg = new ConfirmDialog ((Gtk.Application) application, _("Scan Settings"), null, null, _("Done"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (440, 0);
            var group = new PreferencesGroup ();

            string[] names = {};
            string[] labels = {};
            foreach (var d in service.devices) {
                names += d.name;
                labels += d.label ();
            }
            var scanner_row = new SelectionRow (_("Scanner"), {});
            set_choices (scanner_row, labels, index_of (names, settings.device));
            group.add_row (scanner_row);

            var source_row = new SelectionRow (_("Paper From"), {});
            var mode_row = new SelectionRow (_("Colors"), {});
            var res_row = new SelectionRow (_("Quality"), {});
            var paper_row = new SelectionRow (_("Paper Size"), {});
            group.add_row (source_row);
            group.add_row (mode_row);
            group.add_row (res_row);
            group.add_row (paper_row);
            dlg.custom_area.append (group);

            var papers = Paper.all ();

            Then fill = () => {
                bool have = options != null;
                source_row.visible = have && options.sources.length > 1;
                mode_row.visible = have && options.modes.length > 0;
                res_row.visible = have && options.resolutions.length > 0;
                paper_row.visible = have && options.max_width > 0;
                if (!have) return;
                string[] sl = {};
                foreach (string src in options.sources) sl += source_label (src);
                set_choices (source_row, sl, index_of (options.sources, settings.source));
                string[] ml = {};
                foreach (string m in options.modes) ml += mode_label (m);
                set_choices (mode_row, ml, index_of (options.modes, settings.mode));
                string[] rl = {};
                int ri = 0;
                for (int i = 0; i < options.resolutions.length; i++) {
                    int r = options.resolutions[i];
                    string hint = r <= 150 ? _("draft") : r <= 300 ? _("documents") : _("photos");
                    rl += _("%d dpi, %s").printf (r, hint);
                    if (r == settings.resolution) ri = i;
                }
                set_choices (res_row, rl, ri);
                string[] pl = {};
                int pi = 0;
                for (int i = 0; i < papers.length; i++) {
                    pl += papers[i].label;
                    if (papers[i].id == settings.paper) pi = i;
                }
                set_choices (paper_row, pl, pi);
            };
            fill ();
            scanner_row.selected.connect (() => {
                int i = chosen (scanner_row);
                if (i < 0 || i >= names.length || names[i] == settings.device) return;
                settings.device = names[i];
                load_options.begin ((o, r) => {
                    load_options.end (r);
                    fill ();
                    sync ();
                });
            });
            dlg.response.connect ((r) => {
                if (options != null) {
                    int si = chosen (source_row), mi = chosen (mode_row), qi = chosen (res_row), pi = chosen (paper_row);
                    if (si >= 0 && si < options.sources.length) settings.source = options.sources[si];
                    if (mi >= 0 && mi < options.modes.length) settings.mode = options.modes[mi];
                    if (qi >= 0 && qi < options.resolutions.length) settings.resolution = options.resolutions[qi];
                    if (pi >= 0 && pi < papers.length) settings.paper = papers[pi].id;
                }
                settings.save ();
                sync ();
            });
            dlg.present ();
        }

        private void show_error (string title, string message) {
            var dlg = new ConfirmDialog.message ((Gtk.Application) application, title, "dialog-error-symbolic", message);
            dlg.transient_for = this;
            dlg.present ();
        }

        private void show_toast (string text) {
            if (toast == null) {
                toast = new Label ("");
                toast.add_css_class ("scan-toast");
                toast.halign = Align.CENTER;
                toast.valign = Align.END;
                toast.margin_bottom = 28;
                toast.can_target = false;
                root.add_overlay (toast);
            }
            toast.label = text;
            toast.visible = true;
            if (toast_id != 0) Source.remove (toast_id);
            toast_id = Timeout.add (2500, () => {
                toast_id = 0;
                toast.visible = false;
                return Source.REMOVE;
            });
        }
    }
}
