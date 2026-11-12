"""noixdev.infra.warn: shows msg as an Ansible warning ([WARNING] in the output).

For what needs attention but must not fail the run. Runs on the controller
and changes nothing. Documentation: plugins/modules/warn.py.
"""

from ansible.plugins.action import ActionBase
from ansible.utils.display import Display


class ActionModule(ActionBase):
    _requires_connection = False
    _supports_check_mode = True
    _VALID_ARGS = frozenset(("msg",))

    def run(self, tmp=None, task_vars=None):
        result = super().run(tmp, task_vars)
        msg = str(self._task.args.get("msg", ""))
        host = (task_vars or {}).get("inventory_hostname")
        # formatted: one line, not wrapped to the terminal's width.
        Display().warning("%s: %s" % (host, msg) if host else msg, formatted=True)
        result.update(changed=False, msg=msg)
        return result
