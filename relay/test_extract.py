import io, os, unittest, zipfile
import extract as X


def zipped(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as zf:
        for name, data in files.items():
            zf.writestr(name, data)
    return buffer.getvalue()


def snappy_literal(data):
    """Smallest valid snappy block: the length, then literals."""
    out = bytearray()
    n = len(data)
    while n >= 0x80:
        out.append((n & 0x7f) | 0x80)
        n >>= 7
    out.append(n)
    index = 0
    while index < len(data):
        piece = data[index:index + 60]
        out.append((len(piece) - 1) << 2)
        out += piece
        index += 60
    return bytes(out)


class ExtractTests(unittest.TestCase):
    def test_docx(self):
        document = ('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
                    '<w:p><w:r><w:t>Title line</w:t></w:r></w:p><w:p><w:r><w:t>Cost</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>42</w:t></w:r></w:p>'
                    '</w:body></w:document>')
        result = X.extract("a.docx", zipped({"word/document.xml": document}))
        self.assertEqual(result["text"], "Title line\nCost\t42")

    def test_pptx_slides_in_order_with_notes(self):
        a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        def slide(text): return '<p:sld xmlns:p="x" xmlns:a="%s"><a:p><a:r><a:t>%s</a:t></a:r></a:p></p:sld>' % (a, text)
        files = {"ppt/slides/slide10.xml": slide("Ten"), "ppt/slides/slide2.xml": slide("Two"), "ppt/slides/slide1.xml": slide("One"),
                 "ppt/slides/_rels/slide1.xml.rels": '<Relationships><Relationship Target="../notesSlides/notesSlide1.xml"/></Relationships>',
                 "ppt/notesSlides/notesSlide1.xml": slide("Say hello"), "docProps/thumbnail.jpeg": b"\xff\xd8\xff"}
        result = X.extract("a.pptx", zipped(files))
        self.assertLess(result["text"].index("One"), result["text"].index("Two"))
        self.assertLess(result["text"].index("Two"), result["text"].index("Ten"))
        self.assertIn("[Speaker notes] Say hello", result["text"])
        self.assertEqual(result["images"], [b"\xff\xd8\xff"])

    def test_xlsx_sheets_shared_strings_and_blank_cells(self):
        m = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
        files = {"xl/workbook.xml": '<workbook %s xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Costs" sheetId="1" r:id="rId1"/></sheets></workbook>' % m,
                 "xl/_rels/workbook.xml.rels": '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
                 "xl/sharedStrings.xml": '<sst %s><si><t>Item</t></si><si><r><t>Pa</t></r><r><t>int</t></r></si></sst>' % m,
                 "xl/worksheets/sheet1.xml": '<worksheet %s><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>'
                                             '<row r="2"><c r="A2"><v>7</v></c><c r="B2"><f>1+1</f><v>2</v></c></row></sheetData></worksheet>' % m}
        text = X.extract("a.xlsx", zipped(files))["text"]
        self.assertEqual(text, "--- Sheet: Costs ---\nItem\t\tPaint\n7\t2")

    def test_snappy_and_iwork_text(self):
        def varint(n):
            out = bytearray()
            while n >= 0x80:
                out.append((n & 0x7f) | 0x80)
                n >>= 7
            out.append(n)
            return bytes(out)

        def field(number, value):
            return varint(number << 3 | 2) + varint(len(value)) + value
        storage = field(3, "A short paragraph of real text\n".encode()) + field(3, b"en")
        info = field(2, varint(1 << 3) + varint(2001) + varint(3 << 3) + varint(len(storage)))
        data = varint(len(info)) + info + storage
        block = snappy_literal(data)
        iwa = b"\x00" + len(block).to_bytes(3, "little") + block
        self.assertEqual(X.iwa_bytes(iwa), data)
        result = X.extract("a.pages", zipped({"Index/Document.iwa": iwa, "Index/MasterSlide.iwa": iwa, "preview.jpg": b"\xff\xd8\xff\xe0"}))
        self.assertEqual(result["text"], "A short paragraph of real text")
        self.assertEqual(result["images"], [b"\xff\xd8\xff\xe0"])
        self.assertIn("inside", result["note"])

    def test_snappy_copies(self):
        # "abcabcabc": literal "abc" then a copy of length 6 at offset 3 (type 1: length 4..11).
        block = bytes([9, (3 - 1) << 2]) + b"abc" + bytes([((6 - 4) << 2) | 1, 3])
        self.assertEqual(X.snappy_decompress(block), b"abcabcabc")

    def test_picture_rotation_is_read(self):
        import struct
        def exif(orientation, endian):
            if endian == ">":
                return b"MM\x00\x2a" + struct.pack(">I", 8) + struct.pack(">H", 1) + struct.pack(">HHIHH", 0x0112, 3, 1, orientation, 0) + b"\0\0\0\0"
            return b"II\x2a\x00" + struct.pack("<I", 8) + struct.pack("<H", 1) + struct.pack("<HHIHH", 0x0112, 3, 1, orientation, 0) + b"\0\0\0\0"
        self.assertEqual(X.clockwise_turn(b"junk" + exif(6, "<") + b"more"), 90)
        self.assertEqual(X.clockwise_turn(b"\xff\xe1Exif\0\0" + exif(8, ">")), 270)
        self.assertEqual(X.clockwise_turn(b"x" * 30 + exif(3, ">")), 180)
        self.assertEqual(X.clockwise_turn(b"x" * 30 + exif(1, ">")), 0)
        # HEIF: the irot box holds quarter turns anticlockwise in its low two bits
        self.assertEqual(X.clockwise_turn(b"\0\0\0\x09irot\x01" + exif(1, ">")), 270)
        self.assertEqual(X.clockwise_turn(b"no rotation here"), 0)
        tagged = b"\xff\xd8\xff\xe1" + exif(6, "<") + b"rest"
        fixed = X.upright_tag(tagged)
        self.assertEqual(X.clockwise_turn(fixed), 0)
        self.assertEqual(len(fixed), len(tagged))
        self.assertEqual(X.upright_tag(b"plain"), b"plain")

    def test_hostile_files_are_refused(self):
        evil = '<?xml version="1.0"?><!DOCTYPE d [<!ENTITY a "aaaaaaaaaa">]><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>&a;</w:t></w:r></w:p></w:body></w:document>'
        with self.assertRaises(ValueError):
            X.extract("a.docx", zipped({"word/document.xml": evil}))
        old = X.MAX_PART
        X.MAX_PART = 100
        try:
            with self.assertRaises(ValueError):
                X.extract("a.docx", zipped({"word/document.xml": "<w:document xmlns:w='x'>" + "a" * 500 + "</w:document>"}))
        finally:
            X.MAX_PART = old

    def test_busy_when_both_slots_are_taken(self):
        import threading
        slots = X._SLOTS
        slots.acquire(); slots.acquire()
        original = slots.acquire
        try:
            X._SLOTS = threading.BoundedSemaphore(1)
            X._SLOTS.acquire()
            class Quick:
                def acquire(self, timeout=None): return X._real.acquire(blocking=False)
                def release(self): X._real.release()
            X._real = X._SLOTS
            X._SLOTS = Quick()
            with self.assertRaises(X.Busy):
                X.extract("a.docx", b"x")
        finally:
            X._SLOTS = slots
            slots.release(); slots.release()

    def test_bad_input(self):
        with self.assertRaises(ValueError):
            X.extract("a.docx", b"not a zip")
        with self.assertRaises(ValueError):
            X.extract("a.docx", zipped({"word/document.xml": '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'}))
        self.assertTrue(X.handles("Photo.HEIC") and X.handles("x.key") and not X.handles("x.exe"))


if __name__ == "__main__":
    unittest.main()
