"""Tests of Localization/l10n.py: the value check, the faults it finds and the build step's switch."""
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import l10n  # noqa: E402


def entry(es):
    return {"localizations": {"es": {"stringUnit": {"state": "translated", "value": es}}}}


class Values(unittest.TestCase):
    def test_kinds_and_places(self):
        self.assertEqual(l10n.values("Sent to %@ · %lld min"), [("1", "@"), ("2", "d")])
        self.assertEqual(l10n.values("%2$@ de %1$@"), [("1", "@"), ("2", "@")])
        self.assertEqual(l10n.values("100%% done"), [])

    def test_the_order_by_position_is_the_same_values(self):
        self.assertEqual(l10n.values("%1$@ to %2$@"), l10n.values("%2$@ desde %1$@"))
        self.assertNotEqual(l10n.values("%@ and %lld"), l10n.values("%lld y %@"))


class Problems(unittest.TestCase):
    def test_each_kind_of_fault(self):
        catalog = {"strings": {
            "Sent to %@": entry("Enviado a %@"),
            "Gone": entry("Ido"),
            "Windows only": {"comment": "Windows: the tray menu", **entry("Solo Windows")},
            "%lld tasks": entry("tareas"),
        }}
        keys = {"Sent to %@": ["a.swift:1"], "%lld tasks": ["a.swift:2"], "New": ["a.swift:3"], "%lf h": ["a.swift:4"]}
        lines = [line for _, line in l10n.problems(catalog, keys, ["es"])]
        self.assertTrue(any("no es words: 'New'" in line for line in lines))
        self.assertTrue(any("no code shows it any more: 'Gone'" in line for line in lines))
        self.assertFalse(any("Windows only" in line for line in lines))
        self.assertTrue(any("other values than the key: '%lld tasks'" in line for line in lines))
        self.assertTrue(any("a Double goes into the lookup" in line for line in lines))
        self.assertFalse(any("'Sent to %@'" in line for line in lines))

    def test_a_key_of_its_own_is_checked_against_its_english(self):
        catalog = {"strings": {"Sent (a ping)": entry("Enviado a %@"), "Off (a server)": entry("Apagado")}}
        keys = {"Sent (a ping)": ["a:1"], "Off (a server)": ["a:2"]}
        english = {"Sent (a ping)": "Sent to %@", "Off (a server)": "Off"}
        self.assertEqual(l10n.problems(catalog, keys, ["es"], english), [])
        lines = [line for _, line in l10n.problems(catalog, keys, ["es"])]
        self.assertTrue(any("other values than the key: 'Sent (a ping)'" in line for line in lines))

    def test_plural_forms_are_checked_each(self):
        plural = {"localizations": {"es": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "%lld tarea"}},
            "other": {"stringUnit": {"state": "translated", "value": "tareas"}}}}}}}
        lines = [line for _, line in l10n.problems({"strings": {"%lld tasks": plural}}, {"%lld tasks": ["a:1"]}, ["es"])]
        self.assertEqual(len(lines), 1)
        self.assertIn("'tareas'", lines[0])


class Compile(unittest.TestCase):
    def test_no_shipped_language_writes_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            switch = pathlib.Path(folder) / "shipped"
            switch.write_text("# nothing yet\n\n")
            resources = pathlib.Path(folder) / "Resources"
            resources.mkdir()
            with mock.patch.object(l10n, "SHIPPED", switch), mock.patch.object(l10n.subprocess, "run") as run:
                self.assertEqual(l10n.command_compile([str(resources)]), 0)
            run.assert_not_called()
            self.assertEqual(list(resources.iterdir()), [])

    def test_the_switch_reads_codes_and_skips_notes(self):
        with tempfile.TemporaryDirectory() as folder:
            switch = pathlib.Path(folder) / "shipped"
            switch.write_text("# the languages\nes  # Spanish\n\n")
            with mock.patch.object(l10n, "SHIPPED", switch):
                self.assertEqual(l10n.shipped(), ["es"])


class TheTable(unittest.TestCase):
    def test_the_table_is_valid_and_its_words_keep_the_values(self):
        catalog = json.loads(l10n.CATALOG.read_text())
        self.assertEqual(catalog["sourceLanguage"], "en")
        for key, item in catalog["strings"].items():
            for language in l10n.LANGUAGES:
                for text in l10n.units(item, language):
                    self.assertEqual(l10n.values(text), l10n.values(key), (key, text))


if __name__ == "__main__":
    unittest.main()
