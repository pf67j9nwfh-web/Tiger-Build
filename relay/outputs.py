"""Files a model hands to the person: text as it is, or a real Word, Excel or PDF
file built from plain text, or any file given as base64. Standard library only."""
import base64
import csv
import io
import os
import re
import uuid
import zipfile
from xml.sax.saxutils import escape

TEXT_LIMIT = 2000000
BINARY_LIMIT = 8000000


# ---- Word ----

def _runs(text):
    """**bold** and `code` spans of one line as WordprocessingML runs."""
    out = []
    for piece in re.split(r"(\*\*[^*]+\*\*|`[^`]+`)", text):
        if not piece:
            continue
        bold = piece.startswith("**") and piece.endswith("**") and len(piece) > 4
        code = piece.startswith("`") and piece.endswith("`") and len(piece) > 2
        shown = piece[2:-2] if bold else (piece[1:-1] if code else piece)
        props = ""
        if bold:
            props = "<w:rPr><w:b/></w:rPr>"
        elif code:
            props = '<w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/></w:rPr>'
        out.append('<w:r>%s<w:t xml:space="preserve">%s</w:t></w:r>' % (props, escape(shown)))
    return "".join(out) or '<w:r><w:t></w:t></w:r>'


def _paragraph(text, style=None, indent=0):
    props = ""
    if style or indent:
        props = "<w:pPr>%s%s</w:pPr>" % ('<w:pStyle w:val="%s"/>' % style if style else "",
                                         '<w:ind w:left="%d"/>' % indent if indent else "")
    return "<w:p>%s%s</w:p>" % (props, _runs(text))


def _table(rows):
    cells = max(len(r) for r in rows)
    out = ['<w:tbl><w:tblPr><w:tblBorders>']
    for side in ("top", "left", "bottom", "right", "insideH", "insideV"):
        out.append('<w:%s w:val="single" w:sz="4" w:space="0" w:color="999999"/>' % side)
    out.append("</w:tblBorders></w:tblPr>")
    for index, row in enumerate(rows):
        out.append("<w:tr>")
        for column in range(cells):
            text = row[column] if column < len(row) else ""
            out.append("<w:tc>%s</w:tc>" % _paragraph("**%s**" % text if index == 0 and text else text))
        out.append("</w:tr>")
    out.append("</w:tbl>")
    return "".join(out)


def make_docx(text):
    body = []
    lines = text.replace("\r\n", "\n").split("\n")
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if stripped.startswith("|") and stripped.endswith("|") and stripped.count("|") >= 2:
            rows = []
            while index < len(lines) and lines[index].strip().startswith("|"):
                cells = [c.strip() for c in lines[index].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
                    rows.append(cells)
                index += 1
            if rows:
                body.append(_table(rows))
                body.append("<w:p/>")
            continue
        heading = re.match(r"(#{1,3})\s+(.*)", stripped)
        bullet = re.match(r"[-*\u2022]\s+(.*)", stripped)
        if heading:
            body.append(_paragraph(heading.group(2), "Heading%d" % len(heading.group(1))))
        elif bullet:
            body.append(_paragraph("\u2022 " + bullet.group(1), indent=360))
        elif stripped:
            body.append(_paragraph(line))
        else:
            body.append("<w:p/>")
        index += 1
    document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>%s'
                '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>'
                "</w:body></w:document>") % "".join(body)
    styles = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
              '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
              '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>'
              '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:pPr><w:spacing w:after="120"/></w:pPr></w:style>'
              '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/></w:rPr></w:style>'
              '<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="100"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/></w:rPr></w:style>'
              '<w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:pPr><w:keepNext/><w:spacing w:before="160" w:after="80"/></w:pPr><w:rPr><w:b/><w:sz w:val="26"/></w:rPr></w:style>'
              "</w:styles>")
    types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
             '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
             '<Default Extension="xml" ContentType="application/xml"/>'
             '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
             '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
             "</Types>")
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            "</Relationships>")
    document_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                     '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
                     "</Relationships>")
    return _zip({"[Content_Types].xml": types, "_rels/.rels": rels, "word/document.xml": document,
                 "word/styles.xml": styles, "word/_rels/document.xml.rels": document_rels})


# ---- Excel ----

def _column_name(index):
    name = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        name = chr(65 + rest) + name
    return name


def make_xlsx(text):
    sample = text[:4000]
    delimiter = "\t" if "\t" in sample else ("," if "," in sample else ("|" if "|" in sample else "\t"))
    rows = [row for row in csv.reader(io.StringIO(text.replace("\r\n", "\n")), delimiter=delimiter)]
    if delimiter == "|":
        rows = [[c.strip() for c in row if c.strip() != ""] for row in rows if not all(re.fullmatch(r"\s*:?-{2,}:?\s*", c) for c in row if c.strip())]
    out = []
    for r, row in enumerate(rows, 1):
        cells = []
        for c, value in enumerate(row):
            reference = "%s%d" % (_column_name(c), r)
            value = value.strip()
            if value == "":
                continue
            if re.fullmatch(r"-?\d+(\.\d+)?([eE][-+]?\d+)?", value) and not re.fullmatch(r"0\d+", value):
                cells.append('<c r="%s"><v>%s</v></c>' % (reference, value))
            else:
                cells.append('<c r="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' % (reference, escape(value)))
        out.append('<row r="%d">%s</row>' % (r, "".join(cells)))
    sheet = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>%s</sheetData></worksheet>') % "".join(out)
    workbook = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
                'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
                '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>')
    workbook_rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                     '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
                     "</Relationships>")
    types = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
             '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
             '<Default Extension="xml" ContentType="application/xml"/>'
             '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
             '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
             "</Types>")
    rels = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
            "</Relationships>")
    return _zip({"[Content_Types].xml": types, "_rels/.rels": rels, "xl/workbook.xml": workbook,
                 "xl/_rels/workbook.xml.rels": workbook_rels, "xl/worksheets/sheet1.xml": sheet})


def _zip(files):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in files.items():
            zf.writestr(name, data)
    return buffer.getvalue()


# ---- PDF ----

_PDF_WIDTH = 612
_PDF_HEIGHT = 792
_MARGIN = 54


def _pdf_text(text):
    cleaned = text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
    return cleaned.encode("cp1252", "replace").replace(b"\r", b"")


def _wrap(line, size, bold):
    """Break a line to fit the page, using about half an em per character."""
    per_line = max(20, int((_PDF_WIDTH - 2 * _MARGIN) / (size * (0.55 if bold else 0.5))))
    if len(line) <= per_line:
        return [line]
    out = []
    current = ""
    for word in line.split(" "):
        while len(word) > per_line:
            if current:
                out.append(current)
                current = ""
            out.append(word[:per_line])
            word = word[per_line:]
        if len(current) + len(word) + (1 if current else 0) <= per_line:
            current = (current + " " + word) if current else word
        else:
            out.append(current)
            current = word
    out.append(current)
    return out


def make_pdf(text):
    pages = [[]]
    y = _PDF_HEIGHT - _MARGIN
    for raw in text.replace("\r\n", "\n").replace("\t", "    ").split("\n"):
        size, bold, line = 11, False, raw
        heading = re.match(r"(#{1,3})\s+(.*)", raw.strip())
        if heading:
            size, bold, line = {1: 18, 2: 15, 3: 13}[len(heading.group(1))], True, heading.group(2)
        else:
            line = re.sub(r"\*\*([^*]+)\*\*", r"\1", line)
            line = re.sub(r"^(\s*)[-*]\s+", "\\1\u2022 ", line)
        for piece in _wrap(line, size, bold):
            leading = size * 1.35
            if y - leading < _MARGIN:
                pages.append([])
                y = _PDF_HEIGHT - _MARGIN
            y -= leading
            pages[-1].append((y, size, bold, piece))
        if heading:
            y -= 4
    objects = []

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(b"")
    tree = add(b"")
    regular = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    heavy = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    kids = []
    for page in pages:
        stream = bytearray()
        for top, size, bold, piece in page:
            stream += b"BT /F%d %d Tf %d %.2f Td (" % (2 if bold else 1, size, _MARGIN, top) + _pdf_text(piece) + b") Tj ET\n"
        content = add(b"<< /Length %d >>\nstream\n" % len(stream) + bytes(stream) + b"\nendstream")
        kids.append(add(("<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R "
                         "/Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> >>" % (tree, _PDF_WIDTH, _PDF_HEIGHT, content, regular, heavy)).encode()))
    objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % tree
    objects[tree - 1] = ("<< /Type /Pages /Count %d /Kids [%s] >>" % (len(kids), " ".join("%d 0 R" % k for k in kids))).encode()
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    start = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for offset in offsets:
        out += b"%010d 00000 n \n" % offset
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, catalog, start)
    return bytes(out)


# ---- the tool ----

def build(name, content=None, content_base64=None):
    """(clean file name, bytes) for what a model asked to save."""
    if not isinstance(name, str):
        raise ValueError("Give a file name.")
    base = os.path.basename(name.replace("\\", "/")).strip()
    clean = re.sub(r"[^A-Za-z0-9._-]+", "_", base).strip("._") or "file.txt"
    clean = clean[:80]
    if "." not in clean:
        clean += ".txt"
    ext = clean.rsplit(".", 1)[1].lower()
    if content_base64 is not None:
        if not isinstance(content_base64, str):
            raise ValueError("content_base64 must be text.")
        try:
            data = base64.b64decode(re.sub(r"\s+", "", content_base64), validate=True)
        except Exception:
            raise ValueError("content_base64 is not valid base64.")
        if not data:
            raise ValueError("The file is empty.")
        if len(data) > BINARY_LIMIT:
            raise ValueError("The file is larger than 8 MB.")
        return clean, data
    if not isinstance(content, str) or not content.strip():
        raise ValueError("Give the file's content (or content_base64 for a binary file).")
    if len(content.encode("utf-8")) > TEXT_LIMIT:
        raise ValueError("The file is larger than 2 MB.")
    if ext == "docx":
        data = make_docx(content)
    elif ext == "xlsx":
        data = make_xlsx(content)
    elif ext == "pdf":
        data = make_pdf(content)
    else:
        data = content.encode("utf-8")
    return clean, data


def save(name, content=None, content_base64=None):
    """Write the file into the media folder; returns the stored name for the client to fetch."""
    from media import media_dir
    clean, data = build(name, content, content_base64)
    stored = "%s-%s" % (uuid.uuid4().hex[:16], clean)
    with open(os.path.join(media_dir(), stored), "wb") as handle:
        handle.write(data)
    return stored
