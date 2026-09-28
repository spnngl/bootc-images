#!/usr/bin/python3

"""Build firewalld ipsets for France-only geo-blocking and threat-feed
blocklists, from the raw data fetched at build time by the Containerfile.

Usage: geoblock_ipsets.py <src-dir> <dst-dir>

<src-dir> must contain:
  fr-aggregated.zone       ipdeny IPv4 CIDRs for France
  fr-aggregated-v6.zone    ipdeny IPv6 CIDRs for France
  blocklists/*.txt         one file per threat feed, one address per line

Writes to <dst-dir>:
  geoblock-v4.xml, geoblock-v6.xml     firewalld ipsets, all of France
  blocklist-v4.xml, blocklist-v6.xml   firewalld ipsets, feed entries that
                                        overlap a French network

`firewall-offline-cmd --check-config` does not validate ipset entries: an
invalid entry is silently ignored, and overlapping or empty sets are
accepted. This script is therefore the only thing that validates the
data; see PLAN.geoblock.md, "Facts checked" and "Generator".
"""

import bisect
import ipaddress
import pathlib
import sys

# France: ipdeny data changes rarely, a drop below this points at a
# truncated or empty download.
MIN_FRANCE_V4 = 1000
MIN_FRANCE_V6 = 100

# Each feed individually, before merging: catches an empty or truncated
# download for that one feed.
MIN_FEED_ENTRIES = 100


def parse_file(path, strict):
    """Parse one address-per-line file into a list of ip_network.

    Each line may carry an inline comment, introduced by whitespace, '#'
    or ';' (matches abuseipdb's "ip  # CC ASN name" and spamhaus-drop's
    "cidr ; SBLnnn"). Blank and comment-only lines are skipped. Any
    remaining token that isn't a valid address or network fails the build,
    naming the offending file and line.
    """
    networks = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        token = line.strip().split("#", 1)[0].split(";", 1)[0].split()
        if not token:
            continue
        try:
            networks.append(ipaddress.ip_network(token[0], strict=strict))
        except ValueError as exc:
            sys.exit(f"{path}:{lineno}: {exc}")
    return networks


def by_family(networks):
    """Split into IPv4/IPv6, each collapsed: merged, deduplicated, sorted."""
    return {
        version: list(
            ipaddress.collapse_addresses(n for n in networks if n.version == version)
        )
        for version in (4, 6)
    }


def load_france(src):
    v4 = parse_file(src / "fr-aggregated.zone", strict=True)
    v6 = parse_file(src / "fr-aggregated-v6.zone", strict=True)
    france = by_family(v4 + v6)

    if len(france[4]) < MIN_FRANCE_V4:
        sys.exit(
            f"France IPv4: {len(france[4])} entries, expected at least {MIN_FRANCE_V4}"
        )
    if len(france[6]) < MIN_FRANCE_V6:
        sys.exit(
            f"France IPv6: {len(france[6])} entries, expected at least {MIN_FRANCE_V6}"
        )

    # The bogon ipsets already drop non-global sources at runtime,
    # whatever this data says; this catches ipdeny publishing one at
    # build time instead, with a clearer error.
    for version, networks in france.items():
        for net in networks:
            if not net.is_global:
                sys.exit(
                    f"France IPv{version}: non-global network in source data: {net}"
                )

    return france


def load_blocklists(src):
    feeds = sorted((src / "blocklists").glob("*.txt"))
    if not feeds:
        sys.exit(f"{src / 'blocklists'}: no feed files found")

    networks = []
    for feed in feeds:
        entries = parse_file(feed, strict=False)
        if len(entries) < MIN_FEED_ENTRIES:
            sys.exit(
                f"{feed}: {len(entries)} entries, expected at least {MIN_FEED_ENTRIES}"
            )
        networks.extend(entries)

    return by_family(networks)


def overlaps_any(sorted_networks, network):
    """True if `network` overlaps any entry of `sorted_networks`.

    `sorted_networks` must be sorted and non-overlapping, as returned by
    `collapse_addresses`: only the entries immediately before and after
    where `network` would be inserted can possibly overlap it.
    """
    i = bisect.bisect_right(sorted_networks, network)
    return any(
        sorted_networks[j].overlaps(network)
        for j in (i - 1, i)
        if 0 <= j < len(sorted_networks)
    )


def keep_in_france(france, blocklists):
    """Keep only blocklist entries that overlap a French network.

    Correct only because the geoblock policy runs before the blocklist
    policy (see PLAN.geoblock.md, section 1.3): the blocklist policy never
    sees non-French traffic, so an entry outside France can never match,
    whether it is dropped here or not. An entry that is only partly French
    is kept whole; the non-French part is already dropped by geoblock.
    """
    return {
        version: [n for n in networks if overlaps_any(france[version], n)]
        for version, networks in blocklists.items()
    }


def render_ipset(networks, family):
    entries = "".join(f"  <entry>{n}</entry>\n" for n in networks)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ipset type="hash:net">\n'
        f'  <option name="family" value="{family}"/>\n'
        f"{entries}"
        "</ipset>\n"
    )


def write_ipset(dst, name, version, networks):
    family = "inet" if version == 4 else "inet6"
    (dst / f"{name}.xml").write_text(render_ipset(networks, family))


def main(argv):
    if len(argv) != 3:
        sys.exit(f"usage: {argv[0]} <src-dir> <dst-dir>")
    src, dst = pathlib.Path(argv[1]), pathlib.Path(argv[2])

    france = load_france(src)
    blocklists = keep_in_france(france, load_blocklists(src))

    for version in (4, 6):
        write_ipset(dst, f"geoblock-v{version}", version, france[version])
        write_ipset(dst, f"blocklist-v{version}", version, blocklists[version])
        print(
            f"IPv{version}: geoblock {len(france[version])}, "
            f"blocklist {len(blocklists[version])}"
        )


if __name__ == "__main__":
    main(sys.argv)
