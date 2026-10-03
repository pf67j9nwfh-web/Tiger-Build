"""Files the old Macs cannot open, turned into something a model can use.

Tiger Build sends the file here and gets back text, JPEG pictures, or both:
  Word, PowerPoint, Excel (.docx .pptx .xlsx)   their text, slide by slide, sheet by sheet
  Pages, Keynote, Numbers                       the text found inside, and the preview picture
  HEIC, HEIF, WebP, AVIF                         a JPEG
Only the Python standard library is needed, except for the pictures: macOS uses
sips; elsewhere Pillow (with pillow-heif for HEIC) or ImageMagick, when present.
"""
import gzip
import io
import os
import re
import shutil
import subprocess
import tempfile
import threading
import zipfile
from xml.etree import ElementTree as ET

MAX_TEXT = 300000
PICTURE_TYPES = ("heic", "heif", "webp", "avif", "jp2", "jpg", "jpeg")
OFFICE_TYPES = ("docx", "pptx", "xlsx")
IWORK_TYPES = ("pages", "numbers", "key")


class Unsupported(Exception):
    pass


class Busy(Exception):
    pass


MAX_PART = 64 * 1024 * 1024
MAX_ALL = 400 * 1024 * 1024
_SLOTS = threading.BoundedSemaphore(2)


def _read(zf, name, limit=MAX_PART):
    """One file from the archive, refusing one that unpacks to something huge."""
    if zf.getinfo(name).file_size > limit:
        raise ValueError("A part of this file is too large to read (%s)." % name)
    return zf.read(name)


def _xml(data):
    """Parse XML from a file we did not write. Entity definitions are refused: they are
    how a small file is made to expand into gigabytes."""
    if re.search(rb"<!ENTITY", data[:200000], re.I):
        raise ValueError("This file uses XML features the relay will not read.")
    return ET.fromstring(data)


def handles(name):
    ext = os.path.splitext(name)[1].lower().lstrip(".")
    return ext in PICTURE_TYPES + OFFICE_TYPES + IWORK_TYPES + ("odt", "ods", "odp")


# ---- pictures ----

def _exif_orientation(head):
    """(value, offset of the value, byte order) of the EXIF orientation tag, or None."""
    import struct
    for pattern, endian in ((b"MM\x00\x2a", ">"), (b"II\x2a\x00", "<")):
        start = head.find(pattern)
        while start >= 0:
            try:
                offset = struct.unpack(endian + "I", head[start + 4:start + 8])[0]
                count = struct.unpack(endian + "H", head[start + offset:start + offset + 2])[0]
                if 0 < count < 200:
                    for entry in range(count):
                        at = start + offset + 2 + entry * 12
                        tag, kind, _number = struct.unpack(endian + "HHI", head[at:at + 8])
                        if tag == 0x0112 and kind == 3:
                            return struct.unpack(endian + "H", head[at + 8:at + 10])[0], at + 8, endian
            except (struct.error, IndexError):
                pass
            start = head.find(pattern, start + 1)
    return None


def clockwise_turn(data):
    """Degrees clockwise a picture must be turned to stand upright, from its HEIF rotation
    box or its EXIF orientation. The conversion tools write the pixels as stored."""
    index = data.find(b"irot", 0, 1000000)
    if index >= 4 and index + 5 <= len(data):
        return (360 - 90 * (data[index + 4] & 3)) % 360
    found = _exif_orientation(data[:400000])
    if found:
        return {3: 180, 6: 90, 8: 270, 5: 90, 7: 270}.get(found[0], 0)
    return 0


def upright_tag(jpeg):
    """The same JPEG with its EXIF orientation set to 'normal', for pixels already turned
    upright (old Macs ignore the tag, newer ones would turn the picture again)."""
    import struct
    found = _exif_orientation(jpeg[:100000])
    if not found or found[0] == 1:
        return jpeg
    _value, at, endian = found
    return jpeg[:at] + struct.pack(endian + "H", 1) + jpeg[at + 2:]


def to_jpeg(data, ext, longest=2400):
    """JPEG bytes for a picture in a format the old Macs cannot show."""
    sips = shutil.which("sips")
    with tempfile.TemporaryDirectory() as folder:
        source = os.path.join(folder, "in." + ext)
        target = os.path.join(folder, "out.jpg")
        with open(source, "wb") as handle:
            handle.write(data)
        if sips:
            result = subprocess.run([sips, "-s", "format", "jpeg", "-s", "formatOptions", "85", "-Z", str(longest),
                                     source, "--out", target], capture_output=True, timeout=120)
            if result.returncode == 0 and os.path.isfile(target) and os.path.getsize(target) > 0:
                turn = clockwise_turn(data)
                if turn:
                    subprocess.run([sips, "-r", str(turn), target], capture_output=True, timeout=120)
                with open(target, "rb") as handle:
                    return upright_tag(handle.read())
        try:
            from PIL import Image, ImageOps
            try:
                import pillow_heif
                pillow_heif.register_heif_opener()
            except Exception:
                pass
            image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
            image.thumbnail((longest, longest))
            image.save(target, "JPEG", quality=85)
            with open(target, "rb") as handle:
                return handle.read()
        except Exception:
            pass
        for command in (["magick", source, "-auto-orient", "-resize", "%dx%d>" % (longest, longest), target],
                        ["convert", source, "-auto-orient", "-resize", "%dx%d>" % (longest, longest), target],
                        ["heif-convert", source, target], ["dwebp", source, "-o", target]):
            if shutil.which(command[0]):
                result = subprocess.run(command, capture_output=True, timeout=120)
                if result.returncode == 0 and os.path.isfile(target) and os.path.getsize(target) > 0:
                    with open(target, "rb") as handle:
                        return handle.read()
    raise Unsupported("This computer cannot convert %s pictures. On the relay computer, install Pillow "
                      "(and pillow-heif for HEIC) or ImageMagick." % ext.upper())


# ---- Office files ----

def _text_of(element, namespace):
    parts = []
    for node in element.iter():
        tag = node.tag
        if tag == namespace + "t" and node.text:
            parts.append(node.text)
        elif tag == namespace + "tab":
            parts.append("\t")
        elif tag in (namespace + "br", namespace + "cr"):
            parts.append("\n")
    return "".join(parts)


def docx_text(zf):
    namespace = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    lines = []
    for part in ("word/document.xml", "word/footnotes.xml", "word/endnotes.xml"):
        if part not in zf.namelist():
            continue
        root = _xml(_read(zf, part))
        if part != "word/document.xml":
            lines.append("")
            lines.append("[" + part.split("/")[-1].split(".")[0].capitalize() + "]")
        for paragraph in root.iter(namespace + "p"):
            text = _text_of(paragraph, namespace)
            if text.strip() or (lines and lines[-1].strip()):
                lines.append(text)
    return "\n".join(lines).strip()


def _natural(name):
    return [int(piece) if piece.isdigit() else piece for piece in re.split(r"(\d+)", name)]


def pptx_text(zf):
    namespace = "{http://schemas.openxmlformats.org/drawingml/2006/main}"
    slides = sorted((n for n in zf.namelist() if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)), key=_natural)
    out = []
    for index, slide in enumerate(slides, 1):
        out.append("--- Slide %d ---" % index)
        root = _xml(_read(zf, slide))
        for paragraph in root.iter(namespace + "p"):
            text = "".join(node.text or "" for node in paragraph.iter(namespace + "t"))
            if text.strip():
                out.append(text)
        relations = slide.replace("slides/", "slides/_rels/") + ".rels"
        if relations in zf.namelist():
            for target in re.findall(r'Target="\.\./notesSlides/([^"]+)"', _read(zf, relations).decode("utf-8", "replace")):
                notes = "ppt/notesSlides/" + target
                if notes in zf.namelist():
                    spoken = []
                    for paragraph in _xml(_read(zf, notes)).iter(namespace + "p"):
                        text = "".join(node.text or "" for node in paragraph.iter(namespace + "t"))
                        if text.strip() and not text.strip().isdigit():
                            spoken.append(text)
                    if spoken:
                        out.append("[Speaker notes] " + " ".join(spoken))
    return "\n".join(out).strip()


def _column(reference):
    letters = re.match(r"[A-Z]+", reference or "")
    number = 0
    for char in (letters.group(0) if letters else "A"):
        number = number * 26 + ord(char) - 64
    return number - 1


def xlsx_text(zf):
    main = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    relationship = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
    shared = []
    if "xl/sharedStrings.xml" in zf.namelist():
        for item in _xml(_read(zf, "xl/sharedStrings.xml")).iter(main + "si"):
            shared.append("".join(node.text or "" for node in item.iter(main + "t")))
    targets = {}
    if "xl/_rels/workbook.xml.rels" in zf.namelist():
        for found in re.finditer(r"<Relationship\b[^>]*>", _read(zf, "xl/_rels/workbook.xml.rels").decode("utf-8", "replace")):
            tag = found.group(0)
            identity = re.search(r'Id="([^"]+)"', tag)
            target = re.search(r'Target="([^"]+)"', tag)
            if identity and target:
                path = target.group(1)
                targets[identity.group(1)] = path.lstrip("/") if path.startswith("/") else "xl/" + path
    out = []
    budget = MAX_TEXT
    for sheet in _xml(_read(zf, "xl/workbook.xml")).iter(main + "sheet"):
        name = sheet.get("name") or "Sheet"
        part = targets.get(sheet.get(relationship))
        if not part or part not in zf.namelist():
            continue
        out.append("--- Sheet: %s ---" % name)
        rows = 0
        total = 0
        for row in _xml(_read(zf, part)).iter(main + "row"):
            total += 1
            if rows >= 2000 or budget <= 0:
                continue
            cells = []
            for cell in row.iter(main + "c"):
                column = _column(cell.get("r"))
                while len(cells) < column:
                    cells.append("")
                kind = cell.get("t")
                value = cell.find(main + "v")
                if kind == "s" and value is not None and value.text and value.text.isdigit() and int(value.text) < len(shared):
                    text = shared[int(value.text)]
                elif kind == "inlineStr":
                    text = "".join(node.text or "" for node in cell.iter(main + "t"))
                elif value is not None and value.text is not None:
                    text = value.text
                else:
                    text = ""
                cells.append(text.replace("\t", " ").replace("\n", " "))
            line = "\t".join(cells).rstrip("\t")
            if line:
                out.append(line)
                rows += 1
                budget -= len(line)
        if total > rows:
            out.append("[%d more rows not shown]" % (total - rows))
    return "\n".join(out).strip()


def odf_text(zf):
    root = _xml(_read(zf, "content.xml"))
    lines = []
    for node in root.iter():
        if node.tag.endswith("}p") or node.tag.endswith("}h"):
            text = "".join(node.itertext())
            if text.strip():
                lines.append(text)
    return "\n".join(lines).strip()


# ---- Pages, Keynote, Numbers ----

def snappy_decompress(buffer):
    position = 0
    shift = 0
    while True:
        byte = buffer[position]
        position += 1
        if not byte & 0x80:
            break
        shift += 7
    out = bytearray()
    size = len(buffer)
    while position < size:
        tag = buffer[position]
        position += 1
        kind = tag & 3
        if kind == 0:
            length = tag >> 2
            if length < 60:
                length += 1
            else:
                count = length - 59
                length = int.from_bytes(buffer[position:position + count], "little") + 1
                position += count
            out += buffer[position:position + length]
            position += length
            continue
        if kind == 1:
            length = ((tag >> 2) & 7) + 4
            offset = ((tag >> 5) << 8) | buffer[position]
            position += 1
        elif kind == 2:
            length = (tag >> 2) + 1
            offset = int.from_bytes(buffer[position:position + 2], "little")
            position += 2
        else:
            length = (tag >> 2) + 1
            offset = int.from_bytes(buffer[position:position + 4], "little")
            position += 4
        if offset <= 0 or offset > len(out):
            raise ValueError("damaged compressed data")
        start = len(out) - offset
        if offset >= length:
            out += out[start:start + length]
        else:
            for index in range(length):
                out.append(out[start + index])
    return bytes(out)


def iwa_bytes(raw):
    """The data inside an .iwa file: chunks of a header byte, a 3 byte length and snappy data."""
    out = bytearray()
    position = 0
    while position + 4 <= len(raw) and raw[position] == 0:
        length = raw[position + 1] | (raw[position + 2] << 8) | (raw[position + 3] << 16)
        position += 4
        out += snappy_decompress(raw[position:position + length])
        position += length
    return bytes(out)


def _varint(buffer, position):
    value = 0
    shift = 0
    while True:
        byte = buffer[position]
        position += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, position
        shift += 7


def _proto_fields(buffer):
    """The fields of one protocol buffer message: [(number, wire type, value)]."""
    position = 0
    out = []
    while position < len(buffer):
        key, position = _varint(buffer, position)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, position = _varint(buffer, position)
        elif wire == 1:
            value = buffer[position:position + 8]
            position += 8
        elif wire == 5:
            value = buffer[position:position + 4]
            position += 4
        elif wire == 2:
            length, position = _varint(buffer, position)
            value = buffer[position:position + length]
            position += length
            if len(value) != length:
                raise ValueError("cut short")
        else:
            raise ValueError("not a message")
        out.append((number, wire, value))
    return out


def _as_text(value):
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if text and all(c.isprintable() or c in "\n\t\r\u2028\u2029\ufffc" for c in text):
        return text
    return None


def _proto_strings(buffer, depth=0):
    try:
        fields = _proto_fields(buffer)
    except Exception:
        return []
    out = []
    for _number, wire, value in fields:
        if wire == 2:
            text = _as_text(value)
            if text:
                out.append(text)
            elif depth < 8:
                out.extend(_proto_strings(value, depth + 1))
    return out


def _iwa_records(data):
    """(type, payload) for each archived object in decompressed .iwa data."""
    position = 0
    while position < len(data):
        length, position = _varint(data, position)
        info = _proto_fields(data[position:position + length])
        position += length
        for number, _wire, value in info:
            if number == 2:
                details = dict((n, v) for n, _w, v in _proto_fields(value))
                size = details.get(3, 0)
                yield details.get(1), data[position:position + size]
                position += size


_NOISE = re.compile(r"^(?:[a-z]{2,3}(?:[-_][A-Za-z]{2,4})?|[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})$")
_TEXT_STORAGE = 2001
_TABLE_STRINGS = 6005


def iwork_strings(zf):
    """The text of a Pages, Keynote or Numbers file, read from its stored text objects."""
    blocks = []
    slide = 0
    for name in sorted((n for n in zf.namelist() if n.lower().endswith(".iwa")), key=_natural):
        low = name.lower()
        if any(word in low for word in ("stylesheet", "metadata", "masterslide", "viewstate", "annotation")):
            continue
        try:
            records = list(_iwa_records(iwa_bytes(_read(zf, name))))
        except Exception:
            continue
        found = []
        for kind, payload in records:
            if kind in (_TEXT_STORAGE, _TABLE_STRINGS):
                for text in _proto_strings(payload):
                    text = text.replace("\ufffc", "")
                    if not _NOISE.match(text) and text.strip():
                        found.append(text.rstrip("\n"))
        if not found:
            continue
        if "/slide" in low:
            slide += 1
            blocks.append("--- Slide %d ---" % slide)
        blocks.extend(found)
    seen = set()
    out = []
    for block in blocks:
        if block.startswith("---") or block not in seen:
            seen.add(block)
            out.append(block)
    return "\n".join(out)


def iwork_old_text(zf):
    """iWork '09 and earlier keep a plain XML file (index.xml, maybe gzipped)."""
    for name in zf.namelist():
        if name in ("index.xml", "index.xml.gz"):
            data = _read(zf, name)
            if name.endswith(".gz"):
                data = gzip.decompress(data)
            try:
                root = _xml(data)
            except ET.ParseError:
                return ""
            lines = []
            for node in root.iter():
                if node.tag.endswith("}t") or node.tag.endswith("}ls") or node.tag.endswith("}span"):
                    text = "".join(node.itertext()).strip()
                    if text:
                        lines.append(text)
            return "\n".join(dict.fromkeys(lines))
    return ""


def iwork_previews(zf):
    found = []
    for name in zf.namelist():
        low = name.lower()
        if low in ("preview.jpg", "quicklook/thumbnail.jpg", "preview-web.jpg", "docprops/thumbnail.jpeg") and not found:
            found.append(_read(zf, name))
    return found


def extract(name, data):
    """{"text": str, "images": [jpeg bytes], "note": str}. Raises Unsupported, Busy or ValueError.
    Two conversions at a time; another waits a moment, then is told to try again."""
    if not _SLOTS.acquire(timeout=20):
        raise Busy("The relay is busy converting other files. Try again in a moment.")
    try:
        return _extract(name, data)
    finally:
        _SLOTS.release()


def _extract(name, data):
    ext = os.path.splitext(name)[1].lower().lstrip(".")
    if ext in ("jpg", "jpeg"):
        # Phone photos are stored sideways with a rotation tag the old Macs ignore.
        if clockwise_turn(data) == 0:
            return {"text": "", "images": [data], "note": ""}
        return {"text": "", "images": [to_jpeg(data, "jpg")], "note": "Turned upright."}
    if ext in PICTURE_TYPES:
        return {"text": "", "images": [to_jpeg(data, ext)], "note": "Converted from %s to JPEG." % ext.upper()}
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        raise ValueError("This file is not in a form the relay can read. Save it again, or export it as PDF or text.")
    if sum(info.file_size for info in zf.infolist()) > MAX_ALL:
        raise ValueError("This file unpacks to more than 400 MB, which the relay will not read.")
    note = ""
    images = []
    if ext == "docx":
        text = docx_text(zf)
    elif ext == "pptx":
        text = pptx_text(zf)
        if "docProps/thumbnail.jpeg" in zf.namelist():
            images = [_read(zf, "docProps/thumbnail.jpeg")]
    elif ext == "xlsx":
        text = xlsx_text(zf)
    elif ext in ("odt", "ods", "odp"):
        text = odf_text(zf)
    elif ext in IWORK_TYPES:
        text = iwork_old_text(zf) or iwork_strings(zf)
        images = iwork_previews(zf)
        note = ("Text was read from inside the %s file, so slide order may differ, tables and layout are lost, and "
                "some text may be missing. The picture is the first page or slide." % ext)
    else:
        raise Unsupported("Files of this type cannot be converted.")
    if len(text) > MAX_TEXT:
        text = text[:MAX_TEXT]
        note += " Only the first part of the text is included."
    if not text.strip() and not images:
        raise ValueError("No text could be found in this file.")
    return {"text": text, "images": images, "note": note.strip()}
