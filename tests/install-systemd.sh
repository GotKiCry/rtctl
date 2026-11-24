#!/bin/sh
# Run as a regular Linux user with a systemd user manager and a local agent binary.
set -eu
[ "$(id -u)" != 0 ]
agent=$(realpath "${1:?provide the path to rtctl-agent}")
legacy_agent=$(realpath "${2:-$agent}")
manager_dir=${XDG_RUNTIME_DIR:?}/systemd/user
systemctl --user show-environment >/dev/null
installer=$(cd "$(dirname "$0")/.." && pwd)/install.sh
fixture=$(mktemp -d)
unit="rtctl-test-${fixture##*/}.service"
mkdir -p "$manager_dir"
cleanup() {
    systemctl --user stop "$unit" 2>/dev/null || :
    rm -f "$manager_dir/$unit" "$manager_dir/$unit.d/home.conf" "$manager_dir/$unit.d/failure.conf"
    rmdir "$manager_dir/$unit.d" 2>/dev/null || :
    systemctl --user daemon-reload
    rm -rf "$fixture"
}
trap cleanup EXIT
# Load the same install, status and logs handlers used by the CLI.
sed '/^main "\$@"/,$d' "$installer" >"$fixture/functions.sh"
. "$fixture/functions.sh"
rt_init_defaults
RT_SCOPE=user
RT_NO_PRINT_TOKEN=1
RT_NO_FIREWALL=1
RT_RELEASE=v1.0.2-dev.6
RT_AGENT_SRC=$agent
RT_LISTEN=127.0.0.1
home_dir() { RT_HOME_DIR=$fixture; }
self_script_source() { printf '%s' "$installer"; }
svc_enable() { :; } # Keep this runtime-only unit out of login autostart.
scope_paths
RT_SVC_NAME=${unit%.service}
RT_UNIT="$manager_dir/$unit"
mkdir -p "$RT_BIN_DIR" "$RT_UNIT.d"
printf '[Service]\nEnvironment=HOME=%s\n' "$fixture" >"$RT_UNIT.d/home.conf"
cp "$legacy_agent" "$RT_BIN_AGENT"
"$RT_BIN_AGENT" -init -config "$fixture/old.conf" -listen 127.0.0.1:0 >/dev/null 2>&1
printf '[Service]\nExecStart=%s -foreground -print-token=false -open-firewall=false -config %s/old.conf -log-file %s/old.log -pid-file %s/old.pid\n' \
    "$RT_BIN_AGENT" "$fixture" "$fixture" "$fixture" >"$RT_UNIT"
systemctl --user daemon-reload
systemctl --user start "$unit"
oldpid=$(systemctl --user show "$unit" -p MainPID --value)
[ "$oldpid" -gt 0 ]
cp "$agent" "$RT_BIN_AGENT.new"
mv "$RT_BIN_AGENT.new" "$RT_BIN_AGENT"
[ "$(readlink "/proc/$oldpid/exe")" = "$RT_BIN_AGENT (deleted)" ]
[ ! -e "$RT_STATE_FILE" ]
(cmd_install) >"$fixture/install.out"
state_require
newpid=$(systemctl --user show "$unit" -p MainPID --value)
[ "$newpid" -gt 0 ] && [ "$newpid" != "$oldpid" ]
[ ! -e "/proc/$oldpid/exe" ]
[ "$(stat -Lc '%d:%i' "/proc/$newpid/exe")" = "$(stat -Lc '%d:%i' "$RT_BIN_AGENT")" ]
health_probe "$RT_LISTEN_STATE"
cmd_status >"$fixture/status.out"
grep -q '服务状态   : active$' "$fixture/status.out"
[ -n "$RT_TOKEN_FP" ] && [ -n "$RT_INSTALLED_AT" ]
echo 'PASS legacy service without installer state replaced and healthy'

# Make the unit stay active without an agent listener or a log file.
printf '[Service]\nExecStart=/bin/sleep infinity\nExecStartPost=/bin/echo rtctl-test-journal\n' >"$RT_UNIT"
systemctl --user daemon-reload
systemctl --user restart "$unit"
rm -f "$RT_SVC_LOG"
cmd_status >"$fixture/status.out"
grep -q '服务状态   : 未就绪' "$fixture/status.out"
cmd_logs >"$fixture/logs.out"
grep -q 'rtctl-test-journal' "$fixture/logs.out"
sleep_pid=$(systemctl --user show "$unit" -p MainPID --value)
if (cmd_install) >"$fixture/conflict.out" 2>&1; then exit 1; else [ "$?" = "$EX_CONFLICT" ]; fi
[ "$(systemctl --user show "$unit" -p MainPID --value)" = "$sleep_pid" ]
echo 'PASS active without a listener, journal fallback and unrelated process preserved'

# A first start can fail before the agent writes its log. Save the failure and
# the install metadata, then recover by reinstalling with the same configuration.
systemctl --user stop "$unit"
rm -f "$RT_STATE_FILE"
printf '[Service]\nExecStart=\nExecStart=/bin/false\n' >"$RT_UNIT.d/failure.conf"
if (cmd_install) >"$fixture/failed.out" 2>&1; then exit 1; fi
state_require
[ -n "$RT_TOKEN_FP" ] && [ -n "$RT_INSTALLED_AT" ] && [ -n "$RT_LAST_ERROR" ]
failure_time=$RT_INSTALLED_AT
rm "$RT_UNIT.d/failure.conf"
systemctl --user daemon-reload
(cmd_install) >"$fixture/reinstall.out"
state_require
[ "$RT_INSTALLED_AT" = "$failure_time" ] && [ -z "$RT_LAST_ERROR" ]
health_probe "$RT_LISTEN_STATE"
echo 'PASS failed start records metadata and reinstall recovers'
