namespace PdfHelper {
    [CCode (cname = "sinty_surface_attach_jpeg", cheader_filename = "pdf-helper.h")]
    public void attach_jpeg (Cairo.Surface surface, [CCode (array_length_type = "gsize")] uint8[] data);
}
