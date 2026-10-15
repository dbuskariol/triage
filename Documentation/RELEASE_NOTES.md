# Triage 0.1.2

- **Discussions you opened or commented on.** They show up with your issues and pull requests, including a closed discussion that was updated in the last 60 days. A fine-grained token needs Discussions read. Watched discussions you haven't joined still aren't included.
- **Clear messages instead of an empty inbox.** If an organization's SAML single sign-on hides its work from your token, or your token is missing a permission Triage needs, Triage keeps your saved work and says exactly what to fix, with a link to authorize the token.
- **Fine-grained tokens find your work.** Triage now searches issues and pull requests separately, which fine-grained tokens require; before, they found nothing.
- **Replacing a token updates your organizations.** Organizations the new token can't access leave the list (their local data is kept), and a fine-grained token that can't access any organization is refused with an explanation.
- **Token setup explains exactly what's needed.** The personal access token sheets list the read-only access Triage needs, and open GitHub's token page with it already selected, for fine-grained or classic tokens.

## Triage 0.1.1

- **The list column keeps its width.** Opening an item no longer resizes the list, and the width you set is remembered across sections and launches.
- **Handled work that comes back is shown correctly.** When someone responds to work Triage marked handled, it returns to your Inbox without the old "Handled by You" label, and Triage can mark it handled again when you reply.
- **Full comments in Recent activity.** Long comments are no longer cut off; they fold behind Show More, like the description.
- **Scroll bar setting.** Settings ▸ General ▸ Show scroll bars: use the system setting, show them only when scrolling, or always. Applies the next time Triage opens.
- **Copilot reconnects on its own** after an app update or a restart of its helper, instead of pausing analysis.
- **Know before your GitHub token expires.** Triage reads your personal access token's expiration from GitHub, shows it in Settings ▸ Accounts, and warns you a week ahead. If GitHub stops accepting the token, Triage says whether it expired or was revoked, offers **Replace Token…**, and stops retrying it in the background.
- **Replace a token without removing the account.** Settings ▸ Accounts ▸ Replace Token… swaps in a new classic or fine-grained token and keeps your organizations, rules, and history.
- **Next Week means Monday.** Snooze ▸ Next Week now returns on the coming Monday morning. In 3 Days and In 7 Days are new, and choices more than a few days out show their date.
- **Notifications open their work.** Clicking a notification opens the item, even when the click launches Triage or arrives before your work has loaded. Summary notifications open the work that needs your action; follow-up reminders open the Briefing.
- **Clear message when Triage is replaced while open.** If Triage is updated or reinstalled while it is running, Copilot asks you to reopen Triage, with a Quit button, instead of reporting that the Copilot runtime is unavailable.

## Triage 0.1.0


Triage rebuilt around an AI-first core: your GitHub work, prioritized by Copilot.

- **AI-first Inbox.** Finds the issues and pull requests that involve you in an organization; Copilot sorts them into Inbox, Waiting on Others, and No Action Needed with a specific next step and reason for each.
- **Handled detection.** When you comment, review, or push, Copilot checks whether you completed its suggested step and moves handled work to Done, with evidence and Undo. Done work returns only when someone else responds.
- **Rules and instructions.** Hard rules (mute, always Inbox, needs action, waiting, no action, raise or lower priority) and plain-English instructions for Copilot, per organization, with attribution on every decision.
- **Native workspace.** Sortable lists, a rich detail view with pull request status and formatted descriptions, Mail-style keyboard navigation, and instant Done and Snooze.
- **Briefing and Weekly Review.** Full-width overviews of what needs you today and what you got through this week, with Back and Forward navigation.
- **Focus, drafts, and effort.** Work through a list one item at a time, have Copilot draft replies in your writing style (never posted for you), and see effort estimates and quick wins.
- **Saved searches, grouping, and related work.** Keep searches in the sidebar, group lists by effort, repository, or relationship, and see linked issues and pull requests.
- **Notifications.** Local notifications when work newly needs you, a daily follow-up reminder, quiet hours, and a Dock badge.
- **Setup Assistant.** A guided first launch connects GitHub, your organization, Copilot, notifications, and Mac preferences, and can be run again from the Help menu.
- **Unread, like Mail.** A blue dot marks work you haven't seen since someone else acted, an orange flag marks what needs your action, and the sidebar counts unread.
- **Multiple selection.** Select several items to mark done, snooze, restore, mark read or unread, open, or focus on them together.
- **Configurable.** Refresh interval (or manual), snooze times, automatic handling, sorting, and Copilot model, in native Settings.
- **Private.** Encrypted local storage, Keychain credentials, read-only GitHub access, opt-in Copilot per organization, and no telemetry.
- **Trusted updates.** Developer ID signed, notarized, and Sparkle-verified.
