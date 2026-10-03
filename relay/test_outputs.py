import base64, io, os, unittest, zipfile
import extract as X
import outputs as O


class OutputTests(unittest.TestCase):
    def test_docx_round_trip(self):
        data = O.build("My Report.docx", "# Title\n\nSome **bold** words & <tags>.\n- one\n- two\n\n| Name | Qty |\n|---|---|\n| Bolt | 4 |\n")[1]
        self.assertTrue(zipfile.is_zipfile(io.BytesIO(data)))
        text = X.extract("a.docx", data)["text"]
        for want in ("Title", "Some bold words & <tags>.", "• one", "Name", "Bolt"):
            self.assertIn(want, text)

    def test_xlsx_round_trip_with_numbers_and_text(self):
        data = O.build("t.xlsx", "Item\tQty\tNote\nBolt\t4\thas, comma\nNut\t12.5\t\n")[1]
        text = X.extract("a.xlsx", data)["text"]
        self.assertEqual(text, "--- Sheet: Sheet1 ---\nItem\tQty\tNote\nBolt\t4\thas, comma\nNut\t12.5")
        comma = O.build("t.xlsx", "a,b\n1,2\n")[1]
        self.assertIn("a\tb\n1\t2", X.extract("a.xlsx", comma)["text"])

    def test_pdf_structure_pages_and_escaping(self):
        text = "# Heading\n" + "\n".join("Line %d with (parentheses) and a \\ backslash" % i for i in range(120))
        data = O.build("t.pdf", text)[1]
        self.assertTrue(data.startswith(b"%PDF-1.4") and data.rstrip().endswith(b"%%EOF"))
        self.assertGreaterEqual(data.count(b"/Type /Page "), 2)
        self.assertIn(b"\\(parentheses\\)", data)
        offset = int(data.rsplit(b"startxref\n", 1)[1].split(b"\n")[0])
        self.assertTrue(data[offset:].startswith(b"xref"))

    def test_plain_binary_and_limits(self):
        self.assertEqual(O.build("x.txt", "hi")[1], b"hi")
        self.assertEqual(O.build("pic.png", content_base64=base64.b64encode(b"\x89PNG data").decode())[1], b"\x89PNG data")
        for bad in (("x.txt", ""), ("x.bin", None, "###"), ("x.bin", None, ""), (None, "x"), ("x.txt", "x" * 2000001)):
            with self.assertRaises(ValueError):
                O.build(*bad)
        self.assertEqual(O.build("../../etc/pass wd", "x")[0], "pass_wd.txt")

    def test_save_writes_into_media_folder(self):
        import tempfile, media
        old = media.media_dir
        with tempfile.TemporaryDirectory() as folder:
            media.media_dir = lambda: folder
            try:
                stored = O.save("a b.docx", "hello")
                self.assertRegex(stored, r"^[0-9a-f]{16}-a_b.docx$")
                self.assertTrue(os.path.getsize(os.path.join(folder, stored)) > 100)
            finally:
                media.media_dir = old


if __name__ == "__main__":
    unittest.main()
