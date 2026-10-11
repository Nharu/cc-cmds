// The banner goes through the shell seat, which sources the emitter; this file
// never runs terminal-notifier itself.
export async function raiseBanner($: any, root: string): Promise<void> {
  await $.process.run(['bash', `${root}/hooks/session-ask-notify.sh`])
}
