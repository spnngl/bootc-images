# Build the firewalld ipsets for geo-blocking (blocked countries) and the
# threat-feed blocklists, from the raw data the Containerfile fetches at
# build time. IPv4 only: IPv6 is disabled on the hosts
# (images/fedora/sysroot/etc/sysctl.d/990-disable-ipv6.conf).
#
# Usage: use geoblock.nu; geoblock <src-dir> <bogons-dir> <dst-dir>
#        (or: nu geoblock.nu <src-dir> <bogons-dir> <dst-dir>)
#
# <src-dir> must contain:
#   countries/*.zone    ipdeny CIDRs, one file per blocked country
#   blocklists/*.txt    one file per threat feed, one address per line
# <bogons-dir> holds the static geoblock-bogons.xml ipset.
#
# Writes to <dst-dir>:
#   geoblock.xml    firewalld ipset, all blocked countries
#   blocklist.xml   firewalld ipset, feed entries not inside a blocked
#                   country
#
# `firewall-offline-cmd --check-config` does not validate ipset entries: an
# invalid entry is silently ignored, and overlapping or empty sets are
# accepted (firewalld only rejects overlaps at runtime). This script is
# therefore the only thing that validates the data.
#
# Networks are records {start: int, len: int}: the network address as an
# integer, and the prefix length.

# Each feed individually, before merging: catches an empty or truncated
# download for that one feed.
const MIN_FEED_ENTRIES = 100

# Number of addresses in a /len.
def net-size [len: int]: nothing -> int {
    1 bit-shl (32 - $len)
}

# Parse "addr" or "addr/len". Null if invalid; `exact` is false when bits
# are set after the prefix (9.9.9.9/24): the network is then 9.9.9.0/24.
export def parse-net [token: string]: nothing -> oneof<record<start: int, len: int, exact: bool>, nothing> {
    let parts = $token | split row '/'
    if ($parts | length) > 2 { return null }
    # No leading zeros: some parsers read them as octal.
    if $parts.0 !~ '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' { return null }
    let o = $parts.0 | split row '.' | into int
    if ($o | math max) > 255 { return null }
    let len = if ($parts | length) == 1 { 32 } else {
        if $parts.1 !~ '^(0|[1-9][0-9]?)$' or ($parts.1 | into int) > 32 { return null }
        $parts.1 | into int
    }
    let addr = $o.0 * 16777216 + $o.1 * 65536 + $o.2 * 256 + $o.3
    let start = $addr - ($addr mod (net-size $len))
    {start: $start, len: $len, exact: ($start == $addr)}
}

# Back to text: 1.2.3.0/24.
export def format-net []: record -> string {
    let net = $in
    let addr = [24 16 8 0] | each {|s| $net.start bit-shr $s bit-and 255 } | str join '.'
    $'($addr)/($net.len)'
}

# Parse a one-address-per-line file. Each line may carry an inline comment,
# introduced by whitespace, '#' or ';' (abuseipdb's "ip  # CC ASN name",
# spamhaus-drop's "cidr ; SBLnnn"). Blank and comment-only lines are
# skipped, and so are IPv6 entries (any token with a ':'), which some feeds
# mix in. Any other token that isn't a valid IPv4 address or network fails
# the build, naming the file and line. With --strict, so does a network
# with bits set after its prefix: the ipdeny and bogon data never has any,
# so it would mean corrupt data.
export def parse-file [path: path, --strict]: nothing -> list<record<start: int, len: int>> {
    open --raw $path | lines | parse --regex '^\s*(?<token>[^\s#;]*)' | enumerate | each {|line|
        let token = $line.item.token
        if $token == '' or ($token | str contains ':') { return }
        let net = parse-net $token
        let where = $'($path):($line.index + 1)'
        if $net == null {
            error make --unspanned {msg: $"($where): not an IPv4 address or network: '($token)'"}
        }
        if $strict and not $net.exact {
            error make --unspanned {msg: $"($where): host bits set: '($token)'"}
        }
        $net | reject exact
    }
}

# Pair each network with `root`, the outermost network of the list that
# contains it (null when none does: it is itself outermost). A duplicate's
# root is its first copy. CIDR networks either nest or are disjoint, so
# once sorted by start then length (containing networks first), a
# network's root is the last outermost network before it, if that one
# reaches it. The sort is stable: for equal networks, input order decides
# which one is the root.
export def with-root []: list<record> -> list<record<net: record, root: any>> {
    sort-by start len | generate {|net, state|
        if $state.root? != null and $net.start <= $state.end {
            {out: {net: $net, root: $state.root}, next: $state}
        } else {
            {out: {net: $net, root: null}, next: {root: $net, end: ($net.start + (net-size $net.len) - 1)}}
        }
    } {}
}

# Merge into a sorted list without duplicates or overlaps: firewalld
# rejects an ipset whose entries overlap.
export def collapse []: list<record> -> list<record> {
    with-root | where root == null | get net
}

# Every country network, collapsed. Fails on a network overlapping a bogon
# (non-global range): the bogon ipset already drops those at runtime, so
# this only catches corrupt data (0.0.0.0/0 would block everything) with a
# clearer error.
export def load-countries [src: path, bogons: list<record>]: nothing -> list<record<start: int, len: int>> {
    let files = glob ($src | path join countries '*.zone') | sort
    if ($files | is-empty) { error make --unspanned {msg: $"($src)/countries: no zone files found"} }
    let countries = $files | each {|f|
        let nets = parse-file --strict $f
        if ($nets | is-empty) { error make --unspanned {msg: $"($f): no entries"} }
        $nets
    } | flatten

    let overlap = [...($bogons | insert kind bogon) ...($countries | insert kind country)]
        | with-root | where {|r| $r.root != null and $r.root.kind != $r.net.kind } | get 0?
    if $overlap != null {
        let pair = [$overlap.net $overlap.root]
        let country = $pair | where kind == country | first | format-net
        let bogon = $pair | where kind == bogon | first | format-net
        error make --unspanned {msg: $"country network ($country) overlaps non-global ($bogon)"}
    }
    $countries | collapse
}

export def load-bogons [dir: path]: nothing -> list<record<start: int, len: int>> {
    let path = $dir | path join geoblock-bogons.xml
    open --raw $path | parse --regex '<entry>(?<e>[^<]+)</entry>' | get e | each {|e|
        let net = parse-net $e
        if $net == null or not $net.exact {
            error make --unspanned {msg: $"($path): invalid entry '($e)'"}
        }
        $net | reject exact
    }
}

# Every feed entry, collapsed, minus those inside a blocked country: the
# blocklist policy runs after the geoblock one, so it never sees traffic
# from those, and they could never match. An entry only partly inside a
# country is kept whole.
export def load-blocklists [src: path, countries: list<record>]: nothing -> list<record<start: int, len: int>> {
    let feeds = glob ($src | path join blocklists '*.txt') | sort
    if ($feeds | is-empty) { error make --unspanned {msg: $"($src)/blocklists: no feed files found"} }
    let entries = $feeds | each {|f|
        let nets = parse-file $f
        if ($nets | length) < $MIN_FEED_ENTRIES {
            error make --unspanned {msg: $"($f): ($nets | length) entries, expected at least ($MIN_FEED_ENTRIES)"}
        }
        $nets
    } | flatten

    # Countries first: on a tie, the country network is the root and the
    # equal feed entry is dropped.
    [...($countries | insert kind country) ...($entries | insert kind feed)]
        | with-root | where root == null and net.kind == feed | get net | reject kind
}

export def render-ipset [nets: list<record>]: nothing -> string {
    [
        '<?xml version="1.0" encoding="utf-8"?>'
        '<ipset type="hash:net">'
        '  <option name="family" value="inet"/>'
        ...($nets | each {|n| $'  <entry>($n | format-net)</entry>' })
        '</ipset>'
        ''
    ] | str join "\n"
}

export def main [src: path, bogons: path, dst: path] {
    let countries = load-countries $src (load-bogons $bogons)
    let blocklists = load-blocklists $src $countries
    mkdir $dst
    render-ipset $countries | save --force ($dst | path join geoblock.xml)
    render-ipset $blocklists | save --force ($dst | path join blocklist.xml)
    print $"geoblock ($countries | length), blocklist ($blocklists | length)"
}
