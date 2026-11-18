#!/bin/sh
# clean.sh: take every trace of the three monitoring tools off the test
# container, whatever way it was installed.
for pkg in $(dpkg-query -W -f='${Package}\n' | grep -E '^(netdata|zabbix|check-mk-agent|xinetd)'); do
  dpkg --purge --force-all "$pkg" >/dev/null 2>&1 || true
done
for unit in netdata netdata-updater.timer netdata-updater.service zabbix-agent zabbix-agent2 \
  check-mk-agent.socket check-mk-agent-async cmk-agent-ctl-daemon xinetd; do
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
done
rm -rf /opt/netdata /usr/libexec/netdata /usr/lib/netdata /usr/share/netdata /usr/sbin/netdata /usr/sbin/netdatacli \
  /etc/cron.daily/netdata-updater /etc/logrotate.d/netdata /etc/default/netdata /etc/netdata /var/lib/netdata \
  /var/cache/netdata /var/log/netdata /usr/share/keyrings/netdata-archive-keyring.gpg \
  /etc/zabbix /run/zabbix /var/log/zabbix-agent /var/log/zabbix-agent2 \
  /usr/lib/check_mk_agent /usr/bin/check_mk_agent /usr/bin/check_mk_caching_agent /usr/bin/mk-job /usr/bin/waitmax \
  /usr/bin/cmk-agent-ctl /usr/bin/cmk-update-agent /etc/xinetd.d /etc/check_mk /var/lib/check_mk_agent /var/lib/cmk-agent
rm -f /etc/apt/sources.list.d/netdata* /etc/apt/sources.list.d/zabbix* /etc/systemd/system/netdata* \
  /etc/systemd/system/zabbix* /etc/systemd/system/check-mk-agent* /etc/systemd/system/cmk-agent-ctl* \
  /usr/lib/systemd/system/netdata* /usr/lib/systemd/system/zabbix* /usr/lib/systemd/system/check-mk-agent* \
  /usr/lib/systemd/system/cmk-agent-ctl*
for user in netdata zabbix cmk-agent; do
  userdel "$user" >/dev/null 2>&1 || true
  groupdel "$user" >/dev/null 2>&1 || true
done
systemctl daemon-reload
exit 0
