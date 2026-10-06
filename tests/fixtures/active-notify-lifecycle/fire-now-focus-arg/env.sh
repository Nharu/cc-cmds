# A dispatcher running inside a tmux pane. The driver clears TMUX and TMUX_PANE
# before this file is sourced, so these are the only values the fixture sees.
# The socket path carries a comma: TMUX is taken apart from the right.
export TMUX="/tmp/tmux-fx,a/default,4242,7"
export TMUX_PANE="%48"
