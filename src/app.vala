using Gtk;

namespace Singularity.Apps.Scanner {

    public class ScannerApp : Singularity.Application {
        private bool quick_pending;

        public ScannerApp () {
            Object (application_id: "dev.sinty.scanner", flags: ApplicationFlags.DEFAULT_FLAGS);
            add_main_option ("quick-scan", 0, OptionFlags.NONE, OptionArg.NONE, _("Scan with the last settings"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("quick-scan")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("scanner: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("quick-scan", null);
                return 0;
            }
            quick_pending = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("Scan a Page"), "win.scan");
            f1.append (_("Scan All Pages"), "win.scan-all");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Save…"), "win.save");
            f2.append (_("Save This Page…"), "win.save-page");
            file.append_section (null, f2);
            var f3 = new GLib.Menu ();
            f3.append (_("Start Over"), "win.clear");
            file.append_section (null, f3);
            var f4 = new GLib.Menu ();
            f4.append (_("Close Window"), "win.close");
            f4.append (_("Quit"), "app.quit");
            file.append_section (null, f4);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Rotate Left"), "win.rotate-left");
            e1.append (_("Rotate Right"), "win.rotate-right");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Move Earlier"), "win.move-earlier");
            e2.append (_("Move Later"), "win.move-later");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Delete Page"), "win.delete-page");
            edit.append_section (null, e3);
            var e4 = new GLib.Menu ();
            e4.append (_("Settings"), "app.settings");
            edit.append_section (null, e4);
            menu.append_submenu (_("Edit"), edit);
            var scanner = new GLib.Menu ();
            var s1 = new GLib.Menu ();
            s1.append (_("Scan Settings…"), "win.settings");
            scanner.append_section (null, s1);
            var s2 = new GLib.Menu ();
            s2.append (_("Stop Scanning"), "win.stop");
            s2.append (_("Look for Scanners Again"), "win.refresh");
            scanner.append_section (null, s2);
            menu.append_submenu (_("Scanner"), scanner);
            set_menubar (menu);
            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.scanner");
                } catch (Error e) {
                    warning ("Failed to open settings: %s", e.message);
                }
            });
            add_action (settings_action);
            var quick = new SimpleAction ("quick-scan", null);
            quick.activate.connect (() => {
                quick_pending = true;
                activate ();
            });
            add_action (quick);
            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.scan", { "<Control>Return" });
            set_accels_for_action ("win.save", { "<Control>s" });
            set_accels_for_action ("win.settings", { "<Control>comma" });
        }

        public override void activate () {
            var w = get_active_window ();
            if (w == null) w = new ScannerWindow (this);
            w.present ();
            if (quick_pending) {
                quick_pending = false;
                ((ScannerWindow) w).quick_scan ();
            }
        }

        private const string CSS = """
.scan-card {
    padding: 6px;
    border-radius: 16px;
    background: transparent;
}

.scan-card:selected {
    background-color: alpha(@accent_bg_color, 0.14);
}

.scan-paper {
    background-color: white;
    border-radius: 4px;
    box-shadow: 0 1px 2px alpha(black, 0.18), 0 6px 18px alpha(black, 0.14);
}

.scan-toast {
    padding: 8px 16px;
    border-radius: 18px;
    background-color: alpha(black, 0.7);
    color: white;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-scanner", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-scanner", "UTF-8");
        Intl.textdomain ("singularity-scanner");
        return new ScannerApp ().run (args);
    }
}
