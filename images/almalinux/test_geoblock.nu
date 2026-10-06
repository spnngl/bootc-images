# Tests for geoblock.nu, run by the Containerfile before geoblock.nu
# processes the real data: `use test_geoblock.nu; test_geoblock` (or
# `nu test_geoblock.nu`) from this folder. Stops at the first failure, with
# an error.

use std/assert
use geoblock.nu *

def net [token: string]: nothing -> record {
    parse-net $token | reject exact
}

# Errors raised inside `each` come wrapped: get the innermost message.
def root-msg []: record -> string {
    let e = $in
    if ($e.inner | is-empty) { $e.msg } else { $e.inner | first | root-msg }
}

def fails-with [needle: string, test: closure] {
    let msg = try { do $test; '' } catch {|e| $e.details | root-msg }
    assert str contains $msg $needle
}

# 100 distinct addresses: MIN_FEED_ENTRIES.
def feed [prefix: string]: nothing -> string {
    0..99 | each {|i| $'($prefix).($i)' } | str join "\n"
}

def write [path: path, text: string] {
    mkdir ($path | path dirname)
    $text | save --force $path
}

def country [dir: path, text: string] {
    write ($dir | path join xx.zone) $text
}

# Networks as text, for readable assertions.
def texts []: list<record> -> list<string> {
    each { format-net }
}

const BOGONS = [{start: 167772160, len: 8}]  # 10.0.0.0/8

export def main [] {
    let tmp = mktemp --directory
    let tests = {
        'parse-net: with or without prefix': {||
            assert equal (parse-net '1.2.3.4') {start: 16909060, len: 32, exact: true}
            assert equal (parse-net '10.0.0.0/8') {start: 167772160, len: 8, exact: true}
            assert equal (parse-net '0.0.0.0/0') {start: 0, len: 0, exact: true}
        }
        'parse-net: host bits set are dropped, and flagged': {||
            assert equal (parse-net '9.9.9.9/24') ((net '9.9.9.0/24') | insert exact false)
        }
        'parse-net: invalid tokens': {||
            for token in [
                'not-an-address' '1.2.3' '1.2.3.4.5' '256.0.0.0' '01.2.3.4' '1.2.3.4/33' '1.2.3.4/08' '1.2.3.4/'
                '1.2.3.4/8/8' ' 1.2.3.4' '2001:db8::1'
            ] {
                assert equal (parse-net $token) null $'($token) should be invalid'
            }
        }
        'format-net: canonical text': {||
            for text in ['1.2.3.0/24' '0.0.0.0/0' '255.255.255.255/32' '128.0.0.0/1'] {
                assert equal (net $text | format-net) $text
            }
        }
        'parse-file: line formats, IPv6 skipped': {||
            let p = $tmp | path join formats.txt
            write $p "1.2.3.4  # FR  AS1234  Some Name\n5.6.7.0/24 ; SBL123456\n2001:db8::1\n9.9.9.9/24\n"
            assert equal (parse-file $p) [(net '1.2.3.4') (net '5.6.7.0/24') (net '9.9.9.0/24')]
        }
        'parse-file: blank and comment lines are skipped': {||
            let p = $tmp | path join comments.txt
            write $p "\n# a full-line comment\n   \n; another\n1.2.3.4\n"
            assert equal (parse-file $p) [(net '1.2.3.4')]
        }
        'parse-file: garbage fails with file and line': {||
            let p = $tmp | path join garbage.txt
            write $p "1.2.3.4\nnot-an-address\n"
            fails-with $'($p):2: not an IPv4 address' {|| parse-file $p }
        }
        'parse-file: --strict rejects host bits set': {||
            let p = $tmp | path join strict.txt
            write $p "9.9.9.9/24\n"
            fails-with $'($p):1: host bits set' {|| parse-file --strict $p }
        }
        'collapse: drops duplicates and contained networks, sorts': {||
            let got = [(net '10.0.0.0/25') (net '10.0.0.0/24') (net '10.0.0.0/24') (net '10.0.2.0/24') (net '10.0.1.255') (net '8.0.0.0/8')]
                | collapse | texts
            assert equal $got ['8.0.0.0/8' '10.0.0.0/24' '10.0.1.255/32' '10.0.2.0/24']
        }
        'collapse: merges adjacent networks into the fewest covering them': {||
            # Siblings merge, recursively.
            assert equal ([(net '1.0.1.0/24') (net '1.0.0.0/24') (net '1.0.2.0/23')] | collapse | texts) ['1.0.0.0/22']
            assert equal ([(net '0.0.0.0/1') (net '128.0.0.0/1')] | collapse | texts) ['0.0.0.0/0']
            # Adjacent but not siblings: 1.0.1.0/23 isn't a network.
            assert equal ([(net '1.0.1.0/24') (net '1.0.2.0/24')] | collapse | texts) ['1.0.1.0/24' '1.0.2.0/24']
            # 1.0.0.1 to 1.0.0.6, split on alignment.
            assert equal (1..6 | each {|i| net $'1.0.0.($i)' } | collapse | texts) ['1.0.0.1/32' '1.0.0.2/31' '1.0.0.4/31' '1.0.0.6/32']
            # Overlapping networks extend the range, contained ones don't end it.
            assert equal ([(net '1.0.0.0/23') (net '1.0.0.5') (net '1.0.2.0/24')] | collapse | texts) ['1.0.0.0/23' '1.0.2.0/24']
            assert equal ([] | collapse) []
        }
        'load-countries: valid data loads, compacted': {||
            let dir = $tmp | path join countries-ok
            country $dir "51.0.0.0/24\n51.0.0.0/25\n51.0.1.0/24\n51.1.0.0/24\n"
            let got = load-countries $dir [xx] $BOGONS
            assert equal $got.code ['xx']
            assert equal ($got.nets.0 | texts) ['51.0.0.0/23' '51.1.0.0/24']
        }
        'load-countries: no countries fails': {||
            fails-with 'no countries given' {|| load-countries $tmp [] $BOGONS }
        }
        'load-countries: unknown country fails': {||
            let dir = $tmp | path join countries-unknown
            country $dir "51.0.0.0/24\n"
            fails-with "country 'yy': no zone file" {|| load-countries $dir [xx yy] $BOGONS }
        }
        'load-countries: empty zone file fails': {||
            let dir = $tmp | path join countries-empty
            country $dir ''
            fails-with 'xx.zone: no entries' {|| load-countries $dir [xx] $BOGONS }
        }
        'load-countries: network overlapping a bogon fails, either way round': {||
            let inside = $tmp | path join countries-inside
            country $inside "51.0.0.0/24\n10.1.0.0/16\n"
            fails-with 'country network 10.1.0.0/16 overlaps non-global 10.0.0.0/8' {|| load-countries $inside [xx] $BOGONS }
            let outside = $tmp | path join countries-outside
            country $outside "0.0.0.0/1\n"
            fails-with 'country network 0.0.0.0/1 overlaps non-global 10.0.0.0/8' {|| load-countries $outside [xx] $BOGONS }
        }
        'load-blocklists: merges feeds, drops entries inside a country, keeps supersets whole, compacts': {||
            let dir = $tmp | path join blocklists-ok
            write ($dir | path join a.txt) $"(feed '51.0.0')\n8.8.8.8\n"
            write ($dir | path join b.txt) $"(feed '52.0.0')\n51.1.0.0/16\n"
            let got = load-blocklists $dir [(net '51.0.0.0/24') (net '51.1.0.0/24')]
            # 52.0.0.0 to 52.0.0.99 is 0/26 (64) + 64/27 (32) + 96/30 (4).
            assert equal ($got | texts) ['8.8.8.8/32' '51.1.0.0/16' '52.0.0.0/26' '52.0.0.64/27' '52.0.0.96/30']
        }
        'load-blocklists: entry equal to a country network is dropped': {||
            let dir = $tmp | path join blocklists-equal
            write ($dir | path join a.txt) $"(feed '52.0.0')\n51.0.0.0/24\n"
            assert equal (load-blocklists $dir [(net '51.0.0.0/24')] | texts) ['52.0.0.0/26' '52.0.0.64/27' '52.0.0.96/30']
        }
        'load-blocklists: no feed files fails': {||
            let dir = $tmp | path join blocklists-none
            mkdir $dir
            fails-with 'no feed files found' {|| load-blocklists $dir [] }
        }
        'load-blocklists: feed below the minimum fails, IPv6 not counted': {||
            let dir = $tmp | path join blocklists-short
            write ($dir | path join a.txt) $"1.2.3.4\n(0..99 | each {|i| $'2001:db8::($i)' } | str join "\n")\n"
            fails-with 'a.txt: 1 entries, expected at least 100' {|| load-blocklists $dir [] }
        }
        'render-ipset: family and entries': {||
            assert equal (render-ipset [(net '1.2.3.0/24')]) ([
                '<?xml version="1.0" encoding="utf-8"?>'
                '<ipset type="hash:net">'
                '  <option name="family" value="inet"/>'
                '  <entry>1.2.3.0/24</entry>'
                '</ipset>'
                ''
            ] | str join "\n")
        }
        'geoblock: writes each country compacted, and both ipsets': {||
            let dir = $tmp | path join main
            write ($dir | path join zones aa.zone) "51.0.0.0/24\n51.0.1.0/24\n"
            write ($dir | path join zones bb.zone) "51.0.2.0/23\n"
            write ($dir | path join zones cc.zone) "53.0.0.0/8\n"
            write ($dir | path join feeds a.txt) $"(feed '52.0.0')\n51.0.0.1\n"
            write ($dir | path join bogons geoblock-bogons.xml) '<entry>10.0.0.0/8</entry>'
            let out = $dir | path join out
            # geoblock.nu's main, as imported by `use geoblock.nu *`.
            geoblock ($dir | path join zones) ($dir | path join feeds) ($dir | path join bogons) $out aa bb | ignore
            let zones = $out | path join usr share geoblock countries
            assert equal (ls $zones | get name | path basename | sort) ['aa.zone' 'bb.zone']
            assert equal (open --raw ($zones | path join aa.zone)) "51.0.0.0/23\n"
            let ipsets = $out | path join usr lib firewalld ipsets
            assert str contains (open --raw ($ipsets | path join geoblock.xml)) "<entry>51.0.0.0/22</entry>\n</ipset>"
            assert not ((open --raw ($ipsets | path join blocklist.xml)) | str contains '51.0.0.1')
        }
    }
    $tests | items {|name, test| do $test; print $'ok: ($name)' } | ignore
    rm --recursive $tmp
}
