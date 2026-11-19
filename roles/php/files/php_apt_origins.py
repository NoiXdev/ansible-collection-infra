#!/usr/bin/python3
"""Reports where the installed packages come from, by apt origin.

usage: php_apt_origins.py [--ubuntu-origin O] --ppa-origin O --sury-origin O VERSION...

Prints one JSON object, both lists sorted:

- ubuntu: the installed packages named php<VERSION>-* (any VERSION given)
  whose installed version is Ubuntu's (see below): Ubuntu's own PHP, which
  the role's packages would replace.
- ppa_only: the installed packages whose installed version is the ondrej/php
  PPA's (see below) and none of whose versions comes from --sury-origin
  (packages.sury.org): the host cannot move them over.

Judged by the origin of the Release file apt has the installed version from,
not by the version string: packages.sury.org uses several version schemes.
A version that no package list has any more (dpkg's status file only, after
the archive replaced it) has no such origin. Then:

- it is the PPA's when some version of the package comes from --ppa-origin
  (Launchpad's lists carry one version per package, so an installed build
  the PPA has since replaced is in dpkg's status file only);
- it is Ubuntu's when the version string has Ubuntu's revision scheme
  ("<n>ubuntu<n>", such as 8.3.6-0ubuntu0.24.04.3, which -updates replaced)
  and none of packages.sury.org's or the PPA's ("deb.sury.org",
  "debsuryorg"); their "+ubuntu24.04" suffixes do not match "<n>ubuntu<n>".

Reads only.
"""

import argparse
import json
import re
import sys

import apt  # python3-apt, which tasks/checks.yml installs


# The origin of dpkg's status file: no archive's.
STATUS_ARCHIVE = "now"

UBUNTU_REVISION = re.compile(r"[0-9]ubuntu[0-9]")


def origins(version):
    """The origins of the Release files a version comes from (dpkg's status file left out)."""
    return {origin.origin for origin in version.origins if origin.archive != STATUS_ARCHIVE}


def ubuntu_scheme(version):
    """Whether a version string is Ubuntu's own, not packages.sury.org's or the PPA's."""
    return (
        UBUNTU_REVISION.search(version) is not None
        and "deb.sury.org" not in version
        and "debsuryorg" not in version
    )


def select(packages, versions, ubuntu_origin, ppa_origin, sury_origin):
    """The two lists of the output, from apt.Package-like objects."""
    prefixes = tuple("php%s-" % version for version in versions)
    ubuntu, ppa_only = [], []
    for package in packages:
        installed = package.installed
        if installed is None:
            continue
        installed_origins = origins(installed)
        all_origins = set().union(*(origins(version) for version in package.versions))
        if installed_origins:
            from_ubuntu = ubuntu_origin in installed_origins
            from_ppa = ppa_origin in installed_origins
        else:
            from_ubuntu = ubuntu_scheme(installed.version)
            from_ppa = ppa_origin in all_origins
        if package.shortname.startswith(prefixes) and from_ubuntu:
            ubuntu.append(package.name)
        if from_ppa and sury_origin not in all_origins:
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
