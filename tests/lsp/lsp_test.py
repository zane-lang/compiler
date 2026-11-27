"""`zanec --lsp` driven over JSON-RPC, one test per rule of
docs/design/language-server.md.

The fixture project has a library package (`lib/geo`) and a program
(`bin/app`) that imports it. The builds are given in the initialization
options, as an editor without `zane` gives them, so the tests need no `zane`.
"""

import pathlib
import re
import shutil
import tempfile
import unittest
import urllib.parse
import urllib.request

from tests.lsp.client import ROOT, ZANEC, Client, ResponseError, position_of, uri

FIXTURE = pathlib.Path(__file__).resolve().parent / "fixtures" / "project"

# The reserved words, as the generated lexer lists them.
KEYWORDS = set(
    re.findall(r'"([^"]+)"', re.search(r"let words = \[(.*?)\]", (ROOT / "lib" / "cst" / "lexer.ml").read_text()).group(1))
)


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
        parsed = urllib.parse.urlparse(location["uri"])
        path = pathlib.Path(urllib.request.url2pathname(parsed.path))
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

    def test_every_syntax_error_is_published(self):
        # The parse restarts at the declaration after a syntax error, so a
        # second one, inside the body of `main`, is found too.
        broken = self.text.replace("alias Float = @primitives$F64;", "alias Float = ;").replace(
            "first Float = pair.left;", "first Float = ;"
        )
        self.client.change(self.main, broken)
        diagnostics = self.client.diagnostics(self.main)
        self.assertEqual(
            [(d["range"]["start"]["line"], d["range"]["start"]["character"]) for d in diagnostics],
            [position_of(broken, "= ;", offset=2), position_of(broken, "= ;", occurrence=1, offset=2)],
        )

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

    def test_a_linked_file_keeps_its_unsaved_text(self):
        # main.zn is a link to main.src; the package reads main.zn, so the
        # editor's text for main.zn is what the build checks.
        source = self.main.with_suffix(".src")
        self.main.rename(source)
        self.main.symlink_to(source.name)
        self.client.open(self.main, self.text)
        self.client.change(self.main, self.text.replace("dist(origin, far)", "dist(origin, far, far)"))
        diagnostics = self.client.diagnostics(self.main)
        self.assertEqual(len(diagnostics), 1)

    def test_lines_may_end_in_a_bare_carriage_return(self):
        self.client.change(self.main, self.text.replace("\n", "\r"))
        self.assertFalse(self.client.diagnostics(self.main))
        found = self.at("textDocument/definition", self.main, self.text, "dist(origin")
        self.assertEqual(self.span_text(found[0]), "dist")

    def test_a_file_on_another_machine_is_ignored(self):
        remote = "file://elsewhere" + uri(self.main)[len("file://") :]
        params = {"textDocument": {"uri": remote}, "position": {"line": 0, "character": 0}}
        self.client.notify(
            "textDocument/didOpen",
            {"textDocument": {"uri": remote, "languageId": "zane", "version": 1, "text": self.text}},
        )
        self.assertIsNone(self.client.request("textDocument/hover", params))


class TransportTest(unittest.TestCase):
    @unittest.skipUnless(ZANEC.exists(), "zanec is not built; run dune build")
    def test_a_frame_the_server_cannot_read_ends_it_rather_than_hanging_it(self):
        client = Client()
        try:
            client.process.stdin.write(b"Content-Length: -5\r\n\r\n")
            client.process.stdin.flush()
            client.process.wait(timeout=10)
        finally:
            client.process.kill()
            for stream in (client.process.stdin, client.process.stdout, client.process.stderr):
                stream.close()


class ShownOnceTest(unittest.TestCase):
    @unittest.skipUnless(ZANEC.exists(), "zanec is not built; run dune build")
    def test_a_problem_without_a_file_is_shown_once_while_it_lasts(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d).resolve()
            shutil.copytree(FIXTURE, root / "project")
            lib = root / "project" / "lib" / "geo"
            missing = root / "project" / "lib" / "missing"
            client = Client()
            try:
                flags = ["--no-root", "--package", f"geo={lib}", "--package", f"missing={missing}"]
                client.initialize(root / "project", [{"label": "the library packages", "flags": flags}])
                geo = client.open(lib / "geo.zn")
                for version in (2, 3):
                    client.change(lib / "geo.zn", geo + "\n" * version, version=version)
                    client.diagnostics(lib / "geo.zn")
                shown = [n for n in client.notifications if n["method"] == "window/showMessage"]
                logged = [n for n in client.notifications if n["method"] == "window/logMessage" and "missing" in n["params"]["message"]]
                self.assertEqual(len(shown), 1, shown)
                self.assertIn("missing", shown[0]["params"]["message"])
                self.assertGreaterEqual(len(logged), 2)
            finally:
                client.close()


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

    def test_an_intrinsic_type_shows_its_constructors_and_description(self):
        value = self.hover("@primitives$F64;", offset=13)
        self.assertIn("type @primitives$F64", value)
        self.assertIn("@primitives$F64(value @concepts$Float)", value)
        self.assertIn("A 64-bit IEEE 754 float", value)

    def test_an_intrinsic_call_shows_its_overloads_and_description(self):
        text = self.text.replace("return Unit();", "z Float = @math$fma(d, d, d);\n\treturn Unit();")
        self.client.change(self.main, text, version=5)
        value = self.hover("@math$fma", offset=7, text=text)
        self.assertIn("@primitives$F64 @math$fma(left @primitives$F64, right @primitives$F64, addend @primitives$F64)", value)
        self.assertIn("rounded once", value)

    def test_an_intrinsic_method_and_value(self):
        text = self.text.replace("return Unit();", "@program$console!print(label);\n\treturn Unit();")
        self.client.change(self.main, text, version=5)
        value = self.hover("print(label", text=text)
        self.assertIn("print(this @runtime$Console, text @primitives$String) mut", value)
        self.assertIn("Writes `text` to the console", value)
        self.assertIn("The running program's console", self.hover("@program$console", offset=10, text=text))

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

    def test_a_named_constructor(self):
        found = self.at("textDocument/definition", self.main, self.text, "zero()")
        self.assertEqual(self.span_text(found[0]), "zero")

    def test_constructors_of_an_enum_and_a_variant(self):
        named = self.at("textDocument/definition", self.main, self.text, "background()")
        self.assertEqual(self.span_text(named[0]), "background")
        anonymous = self.at("textDocument/definition", self.main, self.text, "Step();")
        self.assertEqual(self.span_text(anonymous[0]), "Step")
        geo = self.client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(self.geo)}})
        names = [s["name"] for s in geo]
        self.assertIn("Color.background", names)
        self.assertIn("Step", names)

    def test_a_label_of_a_constructor_with_its_own_fields(self):
        geo = self.geo.read_text()
        found = self.at("textDocument/definition", self.main, self.text, "both =")
        self.assertEqual(found[0]["range"]["start"]["line"], position_of(geo, "Pair{ both")[0])
        self.assertEqual(self.span_text(found[0]), "both")

    def test_an_import_alias(self):
        found = self.at("textDocument/definition", self.main, self.text, "Twin{")
        self.assertEqual(self.span_text(found[0]), "Pair")

    def test_a_package_alias(self):
        extra = self.root / "bin" / "app" / "extra.zn"
        text = extra.read_text()
        found = self.at("textDocument/references", extra, text, "g$pick", context={"includeDeclaration": True})
        lines = sorted(r["range"]["start"]["line"] for r in found if r["uri"] == uri(extra))
        # The package key and its alias in the import, and the qualifier.
        import_line = position_of(text, "as g")[0]
        self.assertEqual(lines, [import_line, import_line, position_of(text, "g$pick")[0]])


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

    def test_a_type_parameter_marked_twice(self):
        geo = self.geo.read_text()
        # The return type, and the marker of each parameter.
        self.assertEqual(len(self.refs(self.geo, geo, "T Type) => first")), 3)

    def test_a_number_parameter_in_a_type_argument(self):
        geo = self.geo.read_text()
        # The parameter's declaration, and its use as the array's length.
        self.assertEqual(len(self.refs(self.geo, geo, "size>;")), 2)


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

    def test_edits_come_last_first(self):
        edit = self.rename(self.main, self.text, "far)", "target")
        starts = [(e["range"]["start"]["line"], e["range"]["start"]["character"]) for e in edit["changes"][uri(self.main)]]
        self.assertEqual(starts, sorted(starts, reverse=True))

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

    def test_an_import_alias_keeps_its_spelling(self):
        edit = self.rename(self.main, self.text, "Twin{", "Couple")
        main = edit["changes"][uri(self.main)]
        self.assertEqual(len(main), 1)
        self.assertEqual(main[0]["range"]["start"]["line"], position_of(self.text, "Pair as")[0])

    def test_a_named_constructor(self):
        edit = self.rename(self.main, self.text, "zero()", "start")
        self.assertEqual(len(edit["changes"][uri(self.main)]), 1)
        self.assertEqual(len(edit["changes"][uri(self.geo)]), 1)

    def test_a_label(self):
        edit = self.rename(self.main, self.text, "both =", "each")
        # The caller's label, and the field and its two reads in geo.zn.
        self.assertEqual(len(edit["changes"][uri(self.main)]), 1)
        self.assertEqual(len(edit["changes"][uri(self.geo)]), 4)


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

    def test_intrinsics_get_no_semantic_token(self):
        # The Tree-sitter query colors an intrinsic such as `@primitives$Unit`,
        # so no token may start inside one.
        data = self.client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(self.main)}})["data"]
        starts, line, character = set(), 0, 0
        for i in range(0, len(data), 5):
            dl, dc = data[i : i + 2]
            line += dl
            character = character + dc if dl == 0 else dc
            starts.add((line, character))
        checked = 0
        for number, written in enumerate(self.text.split("\n")):
            for m in re.finditer(r"@[a-z]+\$[A-Za-z_][A-Za-z0-9_]*", written):
                # The suite negotiates UTF-16, so positions count UTF-16 code units.
                start = len(written[: m.start()].encode("utf-16-le")) // 2
                end = len(written[: m.end()].encode("utf-16-le")) // 2
                inside = {(number, c) for c in range(start, end)}
                self.assertFalse(inside & starts, f"main.zn:{number + 1}: `{m.group()}` has a token")
                checked += 1
        self.assertGreater(checked, 0)


    def test_every_identifier_of_the_fixture_is_recorded(self):
        # Semantic tokens come from the uses semantics recorded, so an
        # identifier with no token is a name the recorder missed.
        for path in sorted(self.root.rglob("*.zn")):
            text = self.client.open(path)
            data = self.client.request("textDocument/semanticTokens/full", {"textDocument": {"uri": uri(path)}})["data"]
            covered, line, character = set(), 0, 0
            for i in range(0, len(data), 5):
                dl, dc = data[i : i + 2]
                line += dl
                character = character + dc if dl == 0 else dc
                covered.add((line, character))
            for number, written in enumerate(text.split("\n")):
                code = re.sub(r'"[^"]*"', lambda m: " " * len(m.group()), written.split("//")[0])
                for m in re.finditer(r"[@$]?[A-Za-z_][A-Za-z0-9_]*", code):
                    word = m.group()
                    if word[0] in "@$" or word in KEYWORDS:
                        continue
                    character = len(written[: m.start()].encode("utf-16-le")) // 2
                    self.assertIn((number, character), covered, f"{path.name}:{number + 1}: `{word}` has no token")


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

    def test_a_private_field_is_hidden_outside_its_package(self):
        found = self.complete(self.main, self.text.replace("first Float = pair.left;", "first Float = pair.|"))
        self.assertTrue({"left", "right"} <= found)
        self.assertNotIn("_spare", found)

    def test_the_members_of_an_enum_type(self):
        found = self.complete(self.main, self.text.replace("Color.red", "Color.|"))
        self.assertEqual(found, {"red", "green", "blue"})

    def test_an_imported_method_of_any_subject(self):
        found = self.complete(self.main, self.text.replace("far:norm()", "far:i|"))
        self.assertIn("itself", found)
        # extra.zn imports the package, but not the method.
        extra = self.root / "bin" / "app" / "extra.zn"
        text = self.client.open(extra)
        found = self.complete(extra, text.replace("g$pick(a, b)", "a:i|"))
        self.assertNotIn("itself", found)

    def test_an_enum_value_offers_its_maps(self):
        found = self.complete(self.main, self.text.replace("c.warm", "c.|"))
        self.assertEqual(found, {"warm"})

    def items(self, path, text):
        line, character = position_of(text, "|")
        self.client.change(path, text.replace("|", ""), version=5)
        return {i["label"]: i for i in self.client.at("textDocument/completion", path, line, character)["items"]}

    def test_the_intrinsic_namespaces_after_an_at(self):
        found = self.items(self.main, self.text.replace("return Unit();", "@|\n\treturn Unit();"))
        self.assertEqual(set(found), {"primitives", "concepts", "operators", "math", "controlflow", "runtime", "program"})
        self.assertEqual(found["math"]["insertText"], "math$")
        self.assertIn("math functions", found["math"]["documentation"]["value"])

    def test_only_the_root_package_is_offered_the_program_namespace(self):
        text = self.client.open(self.geo)
        found = self.complete(self.geo, text.replace("return copy;", "@|\n\treturn copy;"))
        self.assertIn("runtime", found)
        self.assertNotIn("program", found)
        found = self.complete(self.geo, text.replace("return copy;", "x = @program$|\n\treturn copy;"))
        self.assertEqual(found, set())
        # A file no build holds may belong to any package, so it is not offered `@program$` either.
        loose = self.dir / "loose.zn"
        loose.write_text("package loose;\n")
        self.client.open(loose)
        found = self.complete(loose, "package loose;\n\n@|\n")
        self.assertIn("runtime", found)
        self.assertNotIn("program", found)

    def test_the_names_of_a_namespace_with_their_signatures_and_descriptions(self):
        found = self.items(self.main, self.text.replace("return Unit();", "x = @math$sq|\n\treturn Unit();"))
        self.assertEqual(set(found), {"sqrt"})
        self.assertIn("@math$sqrt(value @primitives$F32)", found["sqrt"]["detail"])
        self.assertIn("The square root", found["sqrt"]["documentation"]["value"])
        found = self.complete(self.main, self.text.replace("return Unit();", "@program$c|\n\treturn Unit();"))
        self.assertEqual(found, {"console"})

    def test_a_type_position_offers_only_types(self):
        found = self.complete(self.main, self.text.replace("c Color", "c @primitives$I|"))
        self.assertEqual(found, {"I32", "I64"})
        found = self.complete(self.main, self.text.replace("c Color", "c @concepts$|"))
        self.assertTrue({"Int", "Block"} <= found)
        # With no name typed yet, a type position still offers only types.
        found = self.complete(self.main, self.text.replace("c Color", "c @math$|"))
        self.assertEqual(found, set())
        found = self.complete(self.main, self.text.replace("c Color", "c @program$|"))
        self.assertEqual(found, set())
        # An expression with no name typed yet offers the functions.
        found = self.complete(self.main, self.text.replace("return Unit();", "x = @math$|\n\treturn Unit();"))
        self.assertIn("sqrt", found)

    def test_the_methods_of_a_namespace_after_a_colon(self):
        found = self.complete(self.main, self.text.replace("return Unit();", "k = label:@primitives$byte|\n\treturn Unit();"))
        # `byteSet` is a method of an array of flags, so a string does not offer it.
        self.assertEqual(found, {"byteAt", "byteCount"})
        found = self.complete(self.main, self.text.replace("return Unit();", "@program$console!@runtime$pr|\n\treturn Unit();"))
        self.assertEqual(found, {"print"})
        # `print` is `mut`, so it is called with `!`, never with `:`.
        found = self.complete(self.main, self.text.replace("return Unit();", "@program$console:@runtime$pr|\n\treturn Unit();"))
        self.assertEqual(found, set())
        found = self.complete(self.main, self.text.replace("return Unit();", "@program$console!@controlflow$|\n\treturn Unit();"))
        self.assertEqual(found, {"work", "register"})
        found = self.complete(self.main, self.text.replace("return Unit();", "x = @primitives$byte|\n\treturn Unit();"))
        self.assertEqual(found, set())

    def test_the_named_constructors_of_an_intrinsic_type(self):
        found = self.items(self.main, self.text.replace("return Unit();", "q = @primitives$ArrayRef.|\n\treturn Unit();"))
        self.assertEqual(set(found), {"fill", "refs", "roaming"})
        # The checker supplies `fill`'s last parameter, so no call writes it.
        self.assertNotIn("index", found["fill"]["detail"])

    def test_the_methods_of_an_intrinsic_type(self):
        found = self.complete(self.main, self.text.replace("return Unit();", "k = label:by|\n\treturn Unit();"))
        self.assertEqual(found, {"byteAt", "byteCount"})


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

    @unittest.skipUnless(ZANEC.exists(), "zanec is not built; run dune build")
    def test_the_outline_reads_past_a_syntax_error(self):
        # The file has never parsed, so there is no earlier text to fall back
        # on: the outline is the declarations of the current text that parse.
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "loose.zn"
            client = Client()
            try:
                client.initialize(pathlib.Path(d))
                client.open(path, "package loose;\n\nalias Unit = ;\n\nalias Bool = @primitives$Bool;\n")
                self.assertEqual(len(client.diagnostics(path)), 1)
                symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(path)}})
                self.assertEqual([s["name"] for s in symbols], ["loose", "Bool"])
                # A `(` left open in a signature does not end recovery: the
                # declaration after its body is listed, and the error after
                # that is found.
                client.change(
                    path,
                    "package loose;\n\nalias Unit = @primitives$Unit;\n\nUnit broken( {}\n\n"
                    "Unit fine() { return Unit(); }\n\nUnit another() { x Unit = ; }\n",
                )
                self.assertEqual(len(client.diagnostics(path)), 2)
                symbols = client.request("textDocument/documentSymbol", {"textDocument": {"uri": uri(path)}})
                self.assertEqual([s["name"] for s in symbols], ["loose", "Unit", "fine"])
            finally:
                client.close()


class SymlinkTest(unittest.TestCase):
    """A project the editor opens through a symbolic link, as on macOS, where
    the temporary directory `/var` links to `/private/var`."""

    @unittest.skipUnless(ZANEC.exists(), "zanec is not built; run dune build")
    def test_the_server_names_files_as_the_editor_named_them(self):
        with tempfile.TemporaryDirectory() as d:
            real = pathlib.Path(d) / "real"
            shutil.copytree(FIXTURE, real)
            root = pathlib.Path(d) / "link"
            root.symlink_to(real, target_is_directory=True)
            main = root / "bin" / "app" / "main.zn"
            client = Client()
            try:
                client.initialize(root, builds(root))
                text = client.open(main)
                line, character = position_of(text, "Point =")
                found = client.at("textDocument/definition", main, line, character)
                self.assertTrue(found)
                self.assertTrue(all(l["uri"].startswith(uri(root) + "/") for l in found), found)
                client.change(main, text + "\nbroken\n")
                self.assertTrue(client.diagnostics(main))
            finally:
                client.close()


if __name__ == "__main__":
    unittest.main()
