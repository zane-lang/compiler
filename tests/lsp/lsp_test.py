"""`zanec --lsp` driven over JSON-RPC, one test per rule of
docs/design/language-server.md.

The fixture project has a library package (`lib/geo`) and a program
(`bin/app`) that imports it. The builds are given in the initialization
options, as an editor without `zane` gives them, so the tests need no `zane`.
"""

import pathlib
import shutil
import tempfile
import unittest

from tests.lsp.client import ZANEC, Client, ResponseError, position_of, uri

FIXTURE = pathlib.Path(__file__).resolve().parent / "fixtures" / "project"


def builds(root):
    lib, app = root / "lib" / "geo", root / "bin" / "app"
    return [
        {"label": "the library packages", "flags": ["--no-root", "--package", f"geo={lib}"]},
        {"label": "bin/app/", "flags": ["--root", "--package", f"app={app}", "--package", f"geo={lib}"]},
    ]


def labels(items):
    return {i["label"] for i in items}


@unittest.skipUnless(ZANEC.exists(), "zanec is not built; run dune build")
class ServerTest(unittest.TestCase):
    encodings = ("utf-16",)

    def setUp(self):
        # A copy, so a test may change files on disk.
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.root = (self.dir / "project").resolve()
        shutil.copytree(FIXTURE, self.root)
        self.main = self.root / "bin" / "app" / "main.zn"
        self.geo = self.root / "lib" / "geo" / "geo.zn"
        self.shapes = self.root / "lib" / "geo" / "shapes.zn"
        self.client = Client()
        self.init = self.client.initialize(self.root, builds(self.root), self.encodings)
        self.text = self.client.open(self.main)

    def tearDown(self):
        self.client.close()
        shutil.rmtree(self.dir)

    def at(self, method, path, text, needle, occurrence=0, offset=0, **extra):
        line, character = position_of(text, needle, occurrence, offset)
        return self.client.at(method, path, line, character, **extra)

    def span_text(self, location, text=None):
        path = pathlib.Path(location["uri"][len("file://") :])
        text = text if text is not None else path.read_text()
        r = location["range"]
        lines = text.split("\n")
        assert r["start"]["line"] == r["end"]["line"]
        line = lines[r["start"]["line"]].encode("utf-16-le")
        return line[r["start"]["character"] * 2 : r["end"]["character"] * 2].decode("utf-16-le")


class DiagnosticsTest(ServerTest):
    def test_a_type_error_is_published_and_clears_when_fixed_unsaved(self):
        broken = self.text.replace("dist(origin, far)", "dist(origin, far, far)")
        self.client.change(self.main, broken)
        diagnostics = self.client.diagnostics(self.main)
        self.assertEqual(len(diagnostics), 1)
        self.assertIn("no `dist` accepts", diagnostics[0]["message"])
        self.assertEqual(diagnostics[0]["range"]["start"]["line"], position_of(broken, "dist(origin")[0])
        self.client.change(self.main, self.text, version=3)
        self.assertEqual(self.client.diagnostics(self.main), [])

    def test_a_parse_error_shows_alone_and_keeps_the_other_files_results(self):
        self.client.change(self.main, self.text.replace("d Float = dist(origin, far);", "d Float = dist(origin,"))
        diagnostics = self.client.diagnostics(self.main)
        self.assertEqual(len(diagnostics), 1)
        # The library's files still answer, checked against main.zn's last
        # text that parsed.
        geo = self.geo.read_text()
        found = self.at("textDocument/definition", self.geo, geo, "dist(this")
        self.assertEqual(self.span_text(found[0]), "dist")

    def test_a_problem_in_a_library_file_is_published_for_that_file(self):
        geo = self.client.open(self.geo)
        self.client.change(self.geo, geo.replace("return @operators$add(", "return @operators$plus("))
        diagnostics = self.client.diagnostics(self.geo)
        self.assertTrue(any("@operators$plus" in d["message"] for d in diagnostics))

    def test_an_unsaved_new_file_is_part_of_its_package(self):
        extra = self.root / "lib" / "geo" / "extra.zn"
        text = "package geo;\n\nFloat twice(p Point) => @operators$add(p.x, p.x);\n"
        self.client.open(extra, text)
        # A file with no problems gets no notification at all.
        self.assertFalse(self.client.diagnostics(extra))
        found = self.at("textDocument/definition", extra, text, "Point)")
        self.assertTrue(found[0]["uri"].endswith("geo.zn"))


class HoverTest(ServerTest):
    def hover(self, needle, occurrence=0, offset=0, path=None, text=None):
        result = self.at("textDocument/hover", path or self.main, text or self.text, needle, occurrence, offset)
        return result["contents"]["value"] if result else None

    def test_a_call_shows_the_signature_and_the_documentation(self):
        value = self.hover("dist(origin")
        self.assertIn("dist(geo$Point, geo$Point)", value)
        self.assertIn("The squared distance between two points.", value)

    def test_a_local_shows_its_type(self):
        self.assertIn("far geo$Point", self.hover("far, Float(2.0)"))

    def test_a_field_read_shows_the_field(self):
        self.assertIn("x @primitives$F64", self.hover("far.x", offset=4))

    def test_a_type_name_shows_its_definition(self):
        self.assertIn("type Point = struct{ x @primitives$F64; y @primitives$F64 }", self.hover("Point = Point(Float(3.0)"))

    def test_an_enum_member_and_an_enum_map(self):
        self.assertIn("Color.red", self.hover("red;"))
        self.assertIn("warm", self.hover("warm;"))

    def test_inside_a_generic_body_nothing_instantiates(self):
        geo = self.geo.read_text()
        self.assertIn("value", self.hover("value;", path=self.geo, text=geo))
        self.assertIn("T Type", self.hover("T = value", path=self.geo, text=geo))


class DefinitionTest(ServerTest):
    def test_into_another_package(self):
        found = self.at("textDocument/definition", self.main, self.text, "dist(origin")
        self.assertTrue(found[0]["uri"].endswith("lib/geo/geo.zn"))
        self.assertEqual(self.span_text(found[0]), "dist")

    def test_an_overloaded_call_finds_the_overload_it_chose(self):
        geo = self.geo.read_text()
        one = self.at("textDocument/definition", self.main, self.text, "scaled(far)")[0]
        two = self.at("textDocument/definition", self.main, self.text, "scaled(far, ")[0]
        self.assertEqual(one["range"]["start"]["line"], position_of(geo, "scaled(p Point)")[0])
        self.assertEqual(two["range"]["start"]["line"], position_of(geo, "scaled(p Point, by")[0])

    def test_a_method_call_across_files(self):
        shapes = self.shapes.read_text()
        found = self.at("textDocument/definition", self.shapes, shapes, "norm()")
        self.assertTrue(found[0]["uri"].endswith("geo.zn"))

    def test_type_definition_of_a_local(self):
        found = self.at("textDocument/typeDefinition", self.main, self.text, "far:norm")
        self.assertEqual(self.span_text(found[0]), "Point")


class ReferencesTest(ServerTest):
    def refs(self, path, text, needle, include=True):
        found = self.at("textDocument/references", path, text, needle, context={"includeDeclaration": include})
        return sorted((r["uri"].rsplit("/", 1)[1], r["range"]["start"]["line"]) for r in found)

    def test_a_library_function_from_a_program(self):
        found = self.refs(self.main, self.text, "dist(origin")
        files = [f for f, _ in found]
        # The declaration, the call in `norm`, the import and the call in main.
        self.assertEqual(files.count("geo.zn"), 2)
        self.assertEqual(files.count("main.zn"), 2)

    def test_without_the_declaration(self):
        found = self.refs(self.main, self.text, "dist(origin", include=False)
        self.assertEqual(len(found), 3)

    def test_a_field_across_files(self):
        shapes = self.shapes.read_text()
        found = self.refs(self.shapes, shapes, "center:")
        self.assertEqual(len(found), 2)

    def test_a_local(self):
        found = self.refs(self.main, self.text, "origin, far")
        self.assertEqual(len(found), 2)


class RenameTest(ServerTest):
    def rename(self, path, text, needle, new_name):
        return self.at("textDocument/rename", path, text, needle, newName=new_name)

    def test_a_function_across_files_keeps_other_spellings(self):
        edit = self.rename(self.main, self.text, "dist(origin", "distance")
        changes = edit["changes"]
        self.assertEqual(len(changes[uri(self.main)]), 2)
        self.assertEqual(len(changes[uri(self.geo)]), 2)
        for edits in changes.values():
            for e in edits:
                self.assertEqual(e["newText"], "distance")

    def test_a_local(self):
        edit = self.rename(self.main, self.text, "far)", "target")
        self.assertEqual(len(edit["changes"][uri(self.main)]), self.text.count("far"))

    def test_prepare_names_the_identifier(self):
        result = self.at("textDocument/prepareRename", self.main, self.text, "origin, far")
        self.assertEqual(result["placeholder"], "origin")

    def test_an_intrinsic_is_refused(self):
        with self.assertRaises(ResponseError):
            self.rename(self.main, self.text, "Unit;", "Nothing")

    def test_a_name_of_the_wrong_case_is_refused(self):
        with self.assertRaises(ResponseError):
            self.rename(self.main, self.text, "Point = Point(Float(3", "point")


class SymbolsAndTokensTest(ServerTest):
    def test_document_symbols_cover_every_declaration(self):
        geo = self.client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(self.geo)}})
        names = [s["name"] for s in geo]
        for name in ["geo", "Point", "Color", "warm", "dist", "Point:norm", "same", "scaled"]:
            self.assertIn(name, names)
        point = next(s for s in geo if s["name"] == "Point" and "children" in s)
        self.assertEqual([c["name"] for c in point["children"]], ["x", "y"])

    def test_semantic_tokens_tell_names_apart(self):
        legend = self.init["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
        data = self.client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(self.main)}})["data"]
        lines = self.text.split("\n")
        line = character = 0
        found = {}
        for i in range(0, len(data), 5):
            dl, dc, length, kind, _ = data[i : i + 5]
            line += dl
            character = character + dc if dl == 0 else dc
            found[lines[line][character : character + length]] = legend[kind]
        self.assertEqual(found["geo"], "namespace")
        self.assertEqual(found["Point"], "type")
        self.assertEqual(found["Color"], "enum")
        self.assertEqual(found["red"], "enumMember")
        self.assertEqual(found["dist"], "function")
        self.assertEqual(found["norm"], "method")
        self.assertEqual(found["origin"], "variable")
        self.assertEqual(found["warm"], "property")


class CompletionTest(ServerTest):
    def complete(self, path, text):
        line, character = position_of(text, "|")
        text = text.replace("|", "")
        self.client.change(path, text, version=5)
        return labels(self.client.at("textDocument/completion", path, line, character)["items"])

    def test_fields_after_a_dot(self):
        found = self.complete(self.main, self.text.replace("x Float = far.x;", "x Float = far.|"))
        self.assertTrue({"x", "y"} <= found)
        self.assertNotIn("norm", found)

    def test_methods_after_a_colon(self):
        found = self.complete(self.main, self.text.replace("far:norm()", "far:n|"))
        self.assertEqual(found, {"norm"})

    def test_names_in_scope(self):
        found = self.complete(self.main, self.text.replace("return Unit();", "o|\n\treturn Unit();"))
        self.assertIn("origin", found)
        self.assertIn("one", found)

    def test_types(self):
        found = self.complete(self.main, self.text.replace("c Color", "c Co|"))
        self.assertIn("Color", found)


class Utf8Test(ServerTest):
    encodings = ("utf-8", "utf-16")

    def test_the_server_picks_utf8_and_counts_bytes(self):
        self.assertEqual(self.init["capabilities"]["positionEncoding"], "utf-8")
        line_text = self.text.split("\n")[position_of(self.text, "x Float = far.x")[0]]
        character = len(line_text[: line_text.index("far.x")].encode())
        line = position_of(self.text, "x Float = far.x")[0]
        result = self.client.at("textDocument/hover", self.main, line, character)
        self.assertIn("far geo$Point", result["contents"]["value"])


class Utf16Test(ServerTest):
    def test_a_position_after_a_non_ascii_character(self):
        self.assertIn("far geo$Point", HoverTest.hover(self, "far.x"))


class LooseFileTest(unittest.TestCase):
    @unittest.skipUnless(ZANEC.exists(), "zanec is not built; run dune build")
    def test_a_file_in_no_build_gets_its_parse_error_and_symbols(self):
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "loose.zn"
            client = Client()
            try:
                client.initialize(pathlib.Path(d))
                client.open(path, "package loose;\n\nalias Unit = @primitives$Unit;\n\nUnit f( {\n")
                diagnostics = client.diagnostics(path)
                self.assertEqual(len(diagnostics), 1)
                client.change(path, "package loose;\n\nalias Unit = @primitives$Unit;\n")
                symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(path)}})
                self.assertEqual([s["name"] for s in symbols], ["loose", "Unit"])
                self.assertFalse(client.diagnostics(path))
            finally:
                client.close()


if __name__ == "__main__":
    unittest.main()
