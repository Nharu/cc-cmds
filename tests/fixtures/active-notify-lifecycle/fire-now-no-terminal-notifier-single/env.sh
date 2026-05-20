# Override the driver-injected stub by pointing PATH at bare system utilities
# only. Combined with the driver's CC_CMDS_NOTIFY_PATH_DISABLE_PREPEND=1, this
# leaves `command -v terminal-notifier` with no resolution → missing-binary
# branch is exercised.
export PATH="/usr/bin:/bin"
