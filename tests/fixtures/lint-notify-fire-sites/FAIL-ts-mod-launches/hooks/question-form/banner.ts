// A mod that launches the notifier itself raises a banner with no seat guard.
export async function raiseBanner($: any, title: string): Promise<void> {
  await $.process.run(['terminal-notifier', '-title', title])
}
