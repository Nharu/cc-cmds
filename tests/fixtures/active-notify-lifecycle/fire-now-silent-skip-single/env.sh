# Override CC_CMDS_NOTIFY_HOST_OS to Linux so notify.sh takes the non-Darwin
# silent-skip branch. Uniformly exercises the Host-OS guard contract across
# both CI legs.
export CC_CMDS_NOTIFY_HOST_OS=Linux
