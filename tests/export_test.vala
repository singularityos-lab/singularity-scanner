using Singularity.Apps.Scanner;

ScanPage make_page (int w, int h, int dpi, uint8 shade) {
    var p = new ScanPage (w, h, dpi);
    for (int i = 0; i < p.rgb.length; i++) p.rgb[i] = shade;
    p.complete = true;
    return p;
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/export/numbered", () => {
        assert (Export.numbered ("/a/scan.png", 0, 1) == "/a/scan.png");
        assert (Export.numbered ("/a/scan.png", 1, 3) == "/a/scan-2.png");
        assert (Export.numbered ("/a.b/scan", 0, 2) == "/a.b/scan-1");
    });
    Test.add_func ("/export/format", () => {
        assert (ExportFormat.from_path ("x.PDF") == ExportFormat.PDF);
        assert (ExportFormat.from_path ("x.jpeg") == ExportFormat.JPEG);
        assert (ExportFormat.from_path ("x.png") == ExportFormat.PNG);
    });
    Test.add_func ("/export/rotation", () => {
        var p = make_page (30, 50, 100, 128);
        p.rotation = 90;
        var pix = p.pixbuf ();
        assert (pix.width == 50 && pix.height == 30);
    });
    Test.add_func ("/export/pdf", () => {
        string dir = DirUtils.make_tmp ("scan-XXXXXX");
        string path = Path.build_filename (dir, "out.pdf");
        var pages = new Gee.ArrayList<ScanPage> ();
        pages.add (make_page (850, 1100, 100, 200));
        var landscape = make_page (850, 1100, 100, 60);
        landscape.rotation = 90;
        pages.add (landscape);
        Export.save (pages, path);
        uint8[] raw;
        FileUtils.get_data (path, out raw);
        for (int i = 0; i < raw.length; i++) if (raw[i] == 0) raw[i] = ' ';
        raw += 0;
        string data = (string) raw;
        assert (raw.length < 200000);
        assert (data.has_prefix ("%PDF"));
        assert (data.contains ("/DCTDecode"));
        FileUtils.remove (path);
        DirUtils.remove (dir);
    });
    Test.add_func ("/export/searchable", () => {
        if (!Singularity.TextRecognition.Recognizer.get_default ().available) {
            Test.skip ("no text recognition engine");
            return;
        }
        string dir = DirUtils.make_tmp ("scan-XXXXXX");
        string path = Path.build_filename (dir, "text.pdf");
        var pages = new Gee.ArrayList<ScanPage> ();
        pages.add (make_page (850, 1100, 100, 230));
        Export.save (pages, path);
        var loop = new MainLoop ();
        int found = -1;
        Export.add_text_layer.begin (pages, path, (o, r) => {
            try {
                found = Export.add_text_layer.end (r);
            } catch (Error e) {
                error (e.message);
            }
            loop.quit ();
        });
        loop.run ();
        assert (found == 2);
        var doc = Singularity.Pdf.Document.open_file (path);
        assert (Singularity.Pdf.Scans.has_text_layer (doc, 0));
        FileUtils.remove (path);
        DirUtils.remove (dir);
    });
    Test.run ();
}
