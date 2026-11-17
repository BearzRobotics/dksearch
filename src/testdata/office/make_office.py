#!/usr/bin/env python3
"""Builds the small office-document fixtures used by the tests: sample.docx, sample.odt and
sample.epub, with invented content. Run: python3 make_office.py"""
import zipfile

def z(path, files, first_stored=None):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as f:
        for name, data in files:
            comp = zipfile.ZIP_STORED if name == first_stored else zipfile.ZIP_DEFLATED
            f.writestr(zipfile.ZipInfo(name, date_time=(2026, 1, 2, 3, 4, 5)), data, compress_type=comp)

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
docx = [
 ("[Content_Types].xml", '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>'),
 ("docProps/core.xml", '<?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"><dc:title>Harbour Report</dc:title><dc:creator>Ada Quill</dc:creator><dc:subject>Tide tables</dc:subject><dc:description>Notes on spring tides</dc:description><cp:keywords>harbour, tides; boats</cp:keywords><cp:category>Reports</cp:category><cp:lastModifiedBy>Cy Marsh</cp:lastModifiedBy><dcterms:modified>2026-03-04T10:00:00Z</dcterms:modified></cp:coreProperties>'),
 ("docProps/app.xml", '<?xml version="1.0" encoding="UTF-8"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Imaginary Writer</Application><Company>Harbour Board</Company><Manager>Di Park</Manager></Properties>'),
 ("docProps/custom.xml", '<?xml version="1.0" encoding="UTF-8"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Project Code"><vt:lpwstr>HB-7</vt:lpwstr></property><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="3" name="Pages Checked"><vt:i4>12</vt:i4></property></Properties>'),
 ("word/document.xml", '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="%s"><w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Tides at the harbour</w:t></w:r></w:p><w:p><w:r><w:t xml:space="preserve">Spring tides follow the </w:t></w:r><w:r><w:t>new moon</w:t></w:r><w:r><w:tab/><w:t>and fishing boats wait.</w:t></w:r></w:p><w:p><w:r><w:t>First line</w:t><w:br/><w:t>second line</w:t></w:r></w:p><w:p><w:del><w:r><w:delText>removed words</w:delText></w:r></w:del><w:r><w:instrText> PAGE </w:instrText></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell one</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>cell two</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>' % W),
]
z("sample.docx", docx, first_stored="[Content_Types].xml")

T = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
O = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
odt = [
 ("mimetype", "application/vnd.oasis.opendocument.text"),
 ("meta.xml", '<?xml version="1.0" encoding="UTF-8"?><office:document-meta xmlns:office="%s" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"><office:meta><dc:title>Lantern Notes</dc:title><dc:creator>Bo Reed</dc:creator><dc:date>2026-02-03T04:05:06</dc:date><dc:subject>Lamps</dc:subject><dc:description>How to keep a lantern</dc:description><meta:keyword>lantern</meta:keyword><meta:keyword>oil</meta:keyword><meta:generator>Imaginary Writer/1.0</meta:generator><meta:user-defined meta:name="Project Code">LN-3</meta:user-defined></office:meta></office:document-meta>' % O),
 ("content.xml", '<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="%s" xmlns:text="%s"><office:body><office:text><text:h text:outline-level="1">Keeping the lantern lit</text:h><text:p>Trim the wick<text:s text:c="3"/>and polish the lens.<text:tab/>Done.<text:line-break/>Next line.</text:p><text:list><text:list-item><text:p>an item in a list</text:p></text:list-item></text:list></office:text></office:body></office:document-content>' % (O, T)),
]
z("sample.odt", odt, first_stored="mimetype")

epub = [
 ("mimetype", "application/epub+zip"),
 ("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'),
 ("OEBPS/content.opf", '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Sea Almanac</dc:title><dc:creator>C. Marlowe</dc:creator><dc:language>en</dc:language><dc:date>1901-05-06</dc:date></metadata><manifest><item id="c2" href="text/two.xhtml" media-type="application/xhtml+xml"/><item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/><item id="img" href="img/x.png" media-type="image/png"/><item id="css" href="s.css" media-type="text/css"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>'),
 ("OEBPS/text/one.xhtml", '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title><style>p{}</style></head><body><h1>Chapter one</h1><p>The lighthouse stands on the cape.</p></body></html>'),
 ("OEBPS/text/two.xhtml", '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Chapter two</h1><p>Zeppelins crossed the bay &amp; the harbour.</p></body></html>'),
 ("OEBPS/img/x.png", b"\x89PNG not an image"),
 ("OEBPS/s.css", "p{}"),
]
z("sample.epub", epub, first_stored="mimetype")
print("ok")
