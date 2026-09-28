#!/usr/bin/python3

"""Tests for geoblock_ipsets.py.

Run before it processes the real data, in the same build stage (see
PLAN.geoblock.md, "Generator tests"): `python3 -m unittest` from this
directory.
"""

import ipaddress
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

import geoblock_ipsets as gb


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class TmpDirCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = pathlib.Path(tmp.name)


class ParseFile(TmpDirCase):
    def test_feed_line_formats(self):
        # abuseipdb: "ip  # CC ASN name"; spamhaus-drop: "cidr ; SBLnnn";
        # blocklist-de: bare IPv6; a feed entry with host bits set.
        p = self.dir / "feed.txt"
        write(
            p,
            "1.2.3.4  # FR  AS1234  Some Name\n"
            "5.6.7.0/24 ; SBL123456\n"
            "2001:db8::1\n"
            "9.9.9.9/24\n",
        )
        self.assertEqual(
            gb.parse_file(p, strict=False),
            [
                ipaddress.ip_network("1.2.3.4/32"),
                ipaddress.ip_network("5.6.7.0/24"),
                ipaddress.ip_network("2001:db8::1/128"),
                ipaddress.ip_network("9.9.9.0/24"),
            ],
        )

    def test_blank_and_comment_lines_are_skipped(self):
        p = self.dir / "feed.txt"
        write(p, "\n# a full-line comment\n   \n1.2.3.4\n")
        self.assertEqual(
            gb.parse_file(p, strict=False), [ipaddress.ip_network("1.2.3.4/32")]
        )

    def test_garbage_line_fails_with_file_and_line_number(self):
        p = self.dir / "feed.txt"
        write(p, "1.2.3.4\nnot-an-address\n")
        with self.assertRaises(SystemExit) as cm:
            gb.parse_file(p, strict=False)
        self.assertIn(str(p), str(cm.exception))
        self.assertIn(":2:", str(cm.exception))

    def test_strict_rejects_host_bits_set(self):
        # The ipdeny lists are parsed strict=True: they must already be
        # aligned network addresses.
        p = self.dir / "feed.txt"
        write(p, "9.9.9.9/24\n")
        with self.assertRaises(SystemExit):
            gb.parse_file(p, strict=True)


class ByFamily(unittest.TestCase):
    def test_splits_by_version_and_collapses_overlaps(self):
        got = gb.by_family(
            [
                ipaddress.ip_network("10.0.0.0/24"),
                ipaddress.ip_network("10.0.0.0/25"),  # contained in the /24
                ipaddress.ip_network("2001:db8::/32"),
            ]
        )
        self.assertEqual(got[4], [ipaddress.ip_network("10.0.0.0/24")])
        self.assertEqual(got[6], [ipaddress.ip_network("2001:db8::/32")])


class OverlapsAny(unittest.TestCase):
    def test_true_when_contained_or_containing_or_partial(self):
        sorted_networks = [
            ipaddress.ip_network("10.0.0.0/24"),
            ipaddress.ip_network("10.0.2.0/23"),
        ]
        self.assertTrue(
            gb.overlaps_any(sorted_networks, ipaddress.ip_network("10.0.0.128/25"))
        )
        self.assertTrue(
            gb.overlaps_any(sorted_networks, ipaddress.ip_network("10.0.0.0/16"))
        )
        # 10.0.1.128/25 overlaps neither 10.0.0.0/24 nor 10.0.2.0/23, but
        # sits right between them: exercises both bisect neighbours.
        self.assertFalse(
            gb.overlaps_any(sorted_networks, ipaddress.ip_network("10.0.1.128/25"))
        )

    def test_false_on_empty_list(self):
        self.assertFalse(gb.overlaps_any([], ipaddress.ip_network("10.0.0.0/24")))


class LoadFrance(TmpDirCase):
    def setUp(self):
        super().setUp()
        # Shrink the minimums so tests don't need thousands of lines of
        # fixture data; restored after each test.
        self.addCleanup(setattr, gb, "MIN_FRANCE_V4", gb.MIN_FRANCE_V4)
        self.addCleanup(setattr, gb, "MIN_FRANCE_V6", gb.MIN_FRANCE_V6)
        gb.MIN_FRANCE_V4 = 2
        gb.MIN_FRANCE_V6 = 1

    def write_france(self, v4, v6):
        write(self.dir / "fr-aggregated.zone", v4)
        write(self.dir / "fr-aggregated-v6.zone", v6)

    def test_valid_data_loads(self):
        self.write_france("51.0.0.0/24\n51.1.0.0/24\n", "2001:4860::/32\n")
        france = gb.load_france(self.dir)
        self.assertEqual(
            france[4],
            [ipaddress.ip_network("51.0.0.0/24"), ipaddress.ip_network("51.1.0.0/24")],
        )
        self.assertEqual(france[6], [ipaddress.ip_network("2001:4860::/32")])

    def test_too_few_entries_fails(self):
        self.write_france("51.0.0.0/24\n", "2001:4860::/32\n")  # only 1 v4, need 2
        with self.assertRaises(SystemExit) as cm:
            gb.load_france(self.dir)
        self.assertIn("IPv4", str(cm.exception))

    def test_non_global_entry_fails(self):
        # 2001:db8::/32 is the IANA documentation range: valid CIDR, not
        # globally routable.
        self.write_france("51.0.0.0/24\n51.1.0.0/24\n", "2001:db8::/32\n")
        with self.assertRaises(SystemExit) as cm:
            gb.load_france(self.dir)
        self.assertIn("non-global", str(cm.exception))


class LoadBlocklists(TmpDirCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(setattr, gb, "MIN_FEED_ENTRIES", gb.MIN_FEED_ENTRIES)
        gb.MIN_FEED_ENTRIES = 1

    def test_merges_all_feed_files(self):
        write(self.dir / "blocklists" / "feed-a.txt", "1.2.3.4\n")
        write(self.dir / "blocklists" / "feed-b.txt", "2001:db8::1\n")
        got = gb.load_blocklists(self.dir)
        self.assertEqual(got[4], [ipaddress.ip_network("1.2.3.4/32")])
        self.assertEqual(got[6], [ipaddress.ip_network("2001:db8::1/128")])

    def test_no_feed_files_fails(self):
        (self.dir / "blocklists").mkdir()
        with self.assertRaises(SystemExit):
            gb.load_blocklists(self.dir)

    def test_feed_below_minimum_fails(self):
        gb.MIN_FEED_ENTRIES = 2
        write(self.dir / "blocklists" / "feed-a.txt", "1.2.3.4\n")
        with self.assertRaises(SystemExit) as cm:
            gb.load_blocklists(self.dir)
        self.assertIn("feed-a.txt", str(cm.exception))


class KeepInFrance(unittest.TestCase):
    def test_outside_dropped_superset_kept_whole(self):
        # CIDR blocks only ever nest or are disjoint, never partially
        # overlap: "kept even though only partly French" means a broader
        # block that contains the French range, not a block that starts
        # inside it and ends outside.
        france = {4: [ipaddress.ip_network("51.0.0.0/16")], 6: []}
        blocklists = {
            4: [
                ipaddress.ip_network("51.0.5.0/24"),  # fully inside France: kept
                ipaddress.ip_network("51.1.0.0/24"),  # outside France: dropped
                ipaddress.ip_network(
                    "51.0.0.0/8"
                ),  # contains France and more: kept whole
                ipaddress.ip_network(
                    "10.0.0.0/8"
                ),  # bogon, not French either way: dropped
            ],
            6: [],
        }
        got = gb.keep_in_france(france, blocklists)
        self.assertEqual(
            got[4],
            [ipaddress.ip_network("51.0.5.0/24"), ipaddress.ip_network("51.0.0.0/8")],
        )
        self.assertEqual(got[6], [])


class RenderAndWriteIpset(TmpDirCase):
    def test_xml_has_family_and_entries(self):
        xml = gb.render_ipset(
            [ipaddress.ip_network("51.0.0.0/16"), ipaddress.ip_network("52.0.0.0/16")],
            "inet",
        )
        root = ET.fromstring(xml)
        self.assertEqual(root.tag, "ipset")
        self.assertEqual(root.attrib["type"], "hash:net")
        option = root.find("option")
        self.assertEqual(option.attrib, {"name": "family", "value": "inet"})
        self.assertEqual(
            sorted(e.text for e in root.findall("entry")),
            ["51.0.0.0/16", "52.0.0.0/16"],
        )

    def test_write_ipset_picks_family_from_version(self):
        gb.write_ipset(
            self.dir, "geoblock-v6", 6, [ipaddress.ip_network("2001:db8::/32")]
        )
        root = ET.fromstring((self.dir / "geoblock-v6.xml").read_text())
        self.assertEqual(root.find("option").attrib["value"], "inet6")


class Main(TmpDirCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(setattr, gb, "MIN_FRANCE_V4", gb.MIN_FRANCE_V4)
        self.addCleanup(setattr, gb, "MIN_FRANCE_V6", gb.MIN_FRANCE_V6)
        self.addCleanup(setattr, gb, "MIN_FEED_ENTRIES", gb.MIN_FEED_ENTRIES)
        gb.MIN_FRANCE_V4 = 1
        gb.MIN_FRANCE_V6 = 1
        gb.MIN_FEED_ENTRIES = 1

    def test_end_to_end(self):
        src, dst = self.dir / "src", self.dir / "dst"
        write(src / "fr-aggregated.zone", "51.0.0.0/16\n")
        write(src / "fr-aggregated-v6.zone", "2001:4860::/32\n")
        write(
            src / "blocklists" / "feed.txt", "51.0.5.5  # in France\n9.9.9.9  # not\n"
        )
        dst.mkdir()

        gb.main(["geoblock_ipsets.py", str(src), str(dst)])

        geoblock_v4 = ET.fromstring((dst / "geoblock-v4.xml").read_text())
        self.assertEqual(
            [e.text for e in geoblock_v4.findall("entry")], ["51.0.0.0/16"]
        )
        blocklist_v4 = ET.fromstring((dst / "blocklist-v4.xml").read_text())
        self.assertEqual(
            [e.text for e in blocklist_v4.findall("entry")], ["51.0.5.5/32"]
        )
        blocklist_v6 = ET.fromstring((dst / "blocklist-v6.xml").read_text())
        self.assertEqual(blocklist_v6.findall("entry"), [])

    def test_wrong_argument_count_fails(self):
        with self.assertRaises(SystemExit):
            gb.main(["geoblock_ipsets.py", "only-one-arg"])


if __name__ == "__main__":
    unittest.main()
