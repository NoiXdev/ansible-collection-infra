#!/usr/bin/python3
"""Reports where the installed packages come from, by apt origin.

usage: php_apt_origins.py [--ubuntu-origin O] --ppa-origin O --sury-origin O VERSION...

Prints one JSON object, both lists sorted:

- ubuntu: the installed packages named php<VERSION>-* (any VERSION given)
  whose installed version comes from the origin --ubuntu-origin (Ubuntu by
  default): Ubuntu's own PHP, which the role's packages would replace.
- ppa_only: the installed packages whose installed version comes from the
  origin --ppa-origin (the ondrej/php PPA) and none of whose versions comes
  from --sury-origin (packages.sury.org): the host cannot move them over.

The origin is the one of the Release file apt has the version from, not the
version string: packages.sury.org uses several version schemes. A version
that no package list has any more (dpkg's status file only) has no origin
besides dpkg's own, so it counts as neither. Reads only.
"""

import argparse
import json
import sys

import apt  # python3-apt, which tasks/checks.yml installs


def origins(version):
    """The origins of the Release files a version comes from."""
    return {origin.origin for origin in version.origins}


def select(packages, versions, ubuntu_origin, ppa_origin, sury_origin):
    """The two lists of the output, from apt.Package-like objects."""
    prefixes = tuple("php%s-" % version for version in versions)
    ubuntu, ppa_only = [], []
    for package in packages:
        installed = package.installed
        if installed is None:
            continue
        installed_origins = origins(installed)
        if package.shortname.startswith(prefixes) and ubuntu_origin in installed_origins:
            ubuntu.append(package.name)
        if ppa_origin in installed_origins and not any(
            sury_origin in origins(version) for version in package.versions
        ):
            ppa_only.append(package.name)
    return {"ubuntu": sorted(ubuntu), "ppa_only": sorted(ppa_only)}


def main(argv):
    parser = argparse.ArgumentParser(description="Reports where the installed packages come from.")
    parser.add_argument("--ubuntu-origin", default="Ubuntu")
    parser.add_argument("--ppa-origin", required=True)
    parser.add_argument("--sury-origin", required=True)
    parser.add_argument("versions", nargs="+", metavar="VERSION")
    args = parser.parse_args(argv)

    result = select(apt.Cache(), args.versions, args.ubuntu_origin, args.ppa_origin, args.sury_origin)
    json.dump(result, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
