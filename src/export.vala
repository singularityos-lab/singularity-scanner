namespace Singularity.Apps.Scanner {

    public enum ExportFormat {
        PDF,
        PNG,
        JPEG;

        public static ExportFormat from_path (string path) {
            string p = path.down ();
            if (p.has_suffix (".png")) return PNG;
            if (p.has_suffix (".jpg") || p.has_suffix (".jpeg")) return JPEG;
            return PDF;
        }
    }

    namespace Export {
        public async int add_text_layer (Gee.List<ScanPage> list, string path) throws Error {
            var recognizer = Singularity.TextRecognition.Recognizer.get_default ();
            var doc = Singularity.Pdf.Document.open_file (path);
            int found = 0;
            for (int i = 0; i < list.size && i < doc.page_count (); i++) {
                var pix = list[i].pixbuf ();
                var result = yield recognizer.recognize_texture (Gdk.Texture.for_pixbuf (pix), null);
                double[] box = doc.page_box (i);
                double pw = box[2] - box[0], ph = box[3] - box[1];
                double sx = pw / pix.width, sy = ph / pix.height;
                var words = new Gee.ArrayList<Singularity.Pdf.OcrWord> ();
                foreach (var w in result.words) {
                    if (w.text.strip () == "") continue;
                    words.add (new Singularity.Pdf.OcrWord (w.text, Singularity.Pdf.Rect.of (box[0] + w.x * sx, box[1] + ph - (w.y + w.height) * sy,
                        box[0] + (w.x + w.width) * sx, box[1] + ph - w.y * sy)));
                }
                found += Singularity.Pdf.Scans.add_text_layer (doc, i, words);
            }
            if (found > 0) doc.save_to_file (path);
            return found;
        }

        public string numbered (string path, int index, int total) {
            if (total <= 1) return path;
            int dot = path.last_index_of (".");
            int slash = path.last_index_of ("/");
            if (dot <= slash) return "%s-%d".printf (path, index + 1);
            return "%s-%d%s".printf (path.substring (0, dot), index + 1, path.substring (dot));
        }

        public void save (Gee.List<ScanPage> pages, string path, int quality = 85) throws Error {
            var format = ExportFormat.from_path (path);
            if (format == ExportFormat.PDF) {
                save_pdf (pages, path, quality);
                return;
            }
            for (int i = 0; i < pages.size; i++) {
                var pix = pages[i].pixbuf ();
                string target = numbered (path, i, pages.size);
                if (format == ExportFormat.PNG) pix.savev (target, "png", {}, {});
                else pix.savev (target, "jpeg", { "quality" }, { quality.to_string () });
            }
        }

        public void save_pdf (Gee.List<ScanPage> pages, string path, int quality) throws Error {
            if (pages.size == 0) throw new IOError.INVALID_ARGUMENT (_("There are no pages to save."));
            Cairo.PdfSurface? pdf = null;
            Cairo.Context? cr = null;
            foreach (var page in pages) {
                var pix = page.pixbuf ();
                double pw = pix.width * 72.0 / page.dpi;
                double ph = pix.height * 72.0 / page.dpi;
                if (pdf == null) {
                    pdf = new Cairo.PdfSurface (path, pw, ph);
                    if (pdf.status () != Cairo.Status.SUCCESS) throw new IOError.FAILED (_("The file could not be written."));
                    pdf.set_metadata (Cairo.PdfMetadata.CREATOR, "Singularity Document Scanner");
                    cr = new Cairo.Context (pdf);
                } else {
                    pdf.set_size (pw, ph);
                }
                var image = new Cairo.ImageSurface (Cairo.Format.RGB24, pix.width, pix.height);
                var icr = new Cairo.Context (image);
                Gdk.cairo_set_source_pixbuf (icr, pix, 0, 0);
                icr.paint ();
                image.flush ();
                uint8[] jpeg;
                pix.save_to_buffer (out jpeg, "jpeg", "quality", quality.to_string ());
                PdfHelper.attach_jpeg (image, jpeg);
                cr.save ();
                cr.scale (72.0 / page.dpi, 72.0 / page.dpi);
                cr.set_source_surface (image, 0, 0);
                cr.paint ();
                cr.restore ();
                cr.show_page ();
            }
            pdf.finish ();
            if (pdf.status () != Cairo.Status.SUCCESS) throw new IOError.FAILED (_("The file could not be written."));
        }
    }
}
