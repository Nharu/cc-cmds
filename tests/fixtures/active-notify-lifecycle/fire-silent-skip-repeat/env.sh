# Override the lifecycle driver's CC_CMDS_NOTIFY_HOST_OS=Darwin default with
# Linux so notify.sh takes the non-Darwin silent-skip branch. Exercises the
# Host-OS guard contract uniformly across both CI legs (Linux runner +
# macOS runner both reach the same silent-skip branch via positive injection).
export CC_CMDS_NOTIFY_HOST_OS=Linux
