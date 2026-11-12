#!/usr/bin/python
# The action plugin plugins/action/warn.py does the work; this file holds its
# documentation only.

DOCUMENTATION = r"""
---
module: warn
short_description: Show a message as an Ansible warning
description:
  - Shows O(msg), prefixed with the host name, as an Ansible warning
    (C([WARNING]) in the output), for what needs attention but must not fail
    the run.
  - Runs on the controller and never changes anything.
options:
  msg:
    description: The warning.
    type: str
    required: true
author: NoiXdev
"""

EXAMPLES = r"""
- name: Report a reboot that was not taken
  noixdev.infra.warn:
    msg: A reboot is required, but the host was not rebooted.
"""

RETURN = r"""
msg:
  description: The warning that was shown.
  type: str
  returned: always
"""
