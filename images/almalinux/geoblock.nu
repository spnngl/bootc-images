# Build the firewalld ipsets for geo-blocking (blocked countries) and the
# threat-feed blocklists, from the raw data the Containerfile fetches at
# build time. IPv4 only: IPv6 is disabled on the hosts
# (images/fedora/sysroot/etc/sysctl.d/990-disable-ipv6.conf).
#
# Usage: use geoblock.nu; geoblock <zones> <feeds> <bogons> <out> ...<country>
#        (or: nu geoblock.nu <zones> <feeds> <bogons> <out> ...<country>)
#
#   <zones>     ipdeny zones, <country>.zone: the CIDRs of one country
#   <feeds>     *.txt, one file per threat feed, one address per line
#   <bogons>    holds the static geoblock-bogons.xml ipset
#   <country>   the blocked countries, lowercase ISO 3166-1 alpha-2 codes
#
# Writes under <out>, the image root:
#   usr/share/geoblock/countries/<country>.zone
#                   the networks of each blocked country, compacted
#   usr/lib/firewalld/ipsets/geoblock.xml
#                   firewalld ipset, all blocked countries
#   usr/lib/firewalld/ipsets/blocklist.xml
#                   firewalld ipset, feed entries not inside a blocked
#                   country
#
# Both ipsets are compacted: the fewest networks covering the same
# addresses, so the smallest sets for the kernel.
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

# The fewest networks covering exactly the addresses start..end: from
# start, each time the largest network aligned on it that ends by end.
def range-nets []: record<start: int, end: int> -> list<record<start: int, len: int>> {
    let end = $in.end
    generate {|start|
        mut len = 32
        while $len > 0 and $start mod (net-size ($len - 1)) == 0 and $start + (net-size ($len - 1)) - 1 <= $end {
            $len -= 1
        }
        let net = {start: $start, len: $len}
        let next = $start + (net-size $len)
        if $next > $end { {out: $net} } else { {out: $net, next: $next} }
    } $in.start
}

# Compact into the fewest networks covering the same addresses, sorted,
# without duplicates or overlaps: firewalld rejects an ipset whose entries
# overlap. Sorted by start, overlapping or adjacent networks merge into
# one address range (each network extends the range of the previous one,
# or starts a new one, so the last of each run holds the whole range),
# then range-nets splits each range back into networks: 1.0.0.0/24 and
# 1.0.1.0/24 become 1.0.0.0/23.
export def collapse []: list<record> -> list<record<start: int, len: int>> {
    sort-by start | generate {|net, range|
        let end = $net.start + (net-size $net.len) - 1
        let range = if $range.end? != null and $net.start <= $range.end + 1 {
            {start: $range.start, end: ([$range.end $end] | math max)}
        } else {
            {start: $net.start, end: $end}
        }
        {out: $range, next: $range}
    } {} | chunk-by {|range| $range.start } | each {|run| $run | last | range-nets } | flatten
}

# The networks of each country, as {code, nets}, nets compacted. Fails on
# a country without a zone file (a typo, or a code ipdeny doesn't have),
# on an empty zone, and on a network overlapping a bogon (non-global
# range): the bogon ipset already drops those at runtime, so this only
# catches corrupt data (0.0.0.0/0 would block everything) with a clearer
# error.
export def load-countries [zones: path, codes: list<string>, bogons: list<record>]: nothing -> table<code: string, nets: list<record<start: int, len: int>>> {
    if ($codes | is-empty) { error make --unspanned {msg: 'no countries given'} }
    let countries = $codes | each {|code|
        let f = $zones | path join $'($code).zone'
        if not ($f | path exists) { error make --unspanned {msg: $"country '($code)': no zone file ($f)"} }
        let nets = parse-file --strict $f
        if ($nets | is-empty) { error make --unspanned {msg: $"($f): no entries"} }
        {code: $code, nets: $nets}
    }

    let all = $countries | get nets | flatten
    let overlap = [...($bogons | insert kind bogon) ...($all | insert kind country)]
        | with-root | where {|r| $r.root != null and $r.root.kind != $r.net.kind } | get 0?
    if $overlap != null {
        let pair = [$overlap.net $overlap.root]
        let country = $pair | where kind == country | first | format-net
        let bogon = $pair | where kind == bogon | first | format-net
        error make --unspanned {msg: $"country network ($country) overlaps non-global ($bogon)"}
    }
    $countries | update nets { collapse }
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

# Every feed entry minus those inside a blocked country, compacted: the
# blocklist policy runs after the geoblock one, so it never sees traffic
# from those, and they could never match. An entry only partly inside a
# country is kept whole.
export def load-blocklists [dir: path, countries: list<record>]: nothing -> list<record<start: int, len: int>> {
    let feeds = glob ($dir | path join '*.txt') | sort
    if ($feeds | is-empty) { error make --unspanned {msg: $"($dir): no feed files found"} }
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
        | with-root | where root == null and net.kind == feed | get net | reject kind | collapse
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

export def main [zones: path, feeds: path, bogons: path, out: path, ...countries: string] {
    let countries = load-countries $zones $countries (load-bogons $bogons)
    let geoblock = $countries | get nets | flatten | collapse
    let blocklist = load-blocklists $feeds $geoblock

    let zone_dir = $out | path join usr share geoblock countries
    let ipset_dir = $out | path join usr lib firewalld ipsets
    mkdir $zone_dir $ipset_dir
    for country in $countries {
        [...($country.nets | each { format-net }) ''] | str join "\n"
            | save --force ($zone_dir | path join $'($country.code).zone')
    }
    render-ipset $geoblock | save --force ($ipset_dir | path join geoblock.xml)
    render-ipset $blocklist | save --force ($ipset_dir | path join blocklist.xml)
    print $"geoblock ($geoblock | length), blocklist ($blocklist | length)"
}
