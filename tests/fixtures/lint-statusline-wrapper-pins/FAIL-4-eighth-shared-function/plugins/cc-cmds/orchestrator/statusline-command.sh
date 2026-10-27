#!/usr/bin/env bash
# Fixture stand-in for the shared wrapper grammar. Only the definition LINES are
# read by the lint, so the bodies are empty on purpose — a fixture that carried
# real logic would drift away from the file it stands in for and start failing
# for reasons the fixture is not about.

wrapper_path_ok() { :; }

sl_wrapper_prefix() { :; }
sl_unwrap_once() { :; }
sl_unwrap() { :; }
sl_is_bare_ours() { :; }
sl_classify() { :; }
sl_desired_command() { :; }
sl_render_desired() { :; }

sl_settings_path() { :; }
