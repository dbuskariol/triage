# Triage 0.2.0

Filtering and prioritization, rebuilt: hide work completely, target what Copilot notices, see why anything ranks where it does, and let Triage suggest rules from how you work.

- **One filter language for search and rules.** GitHub-style filters with `OR`, parentheses, `-` to exclude, and `@me`, plus new filters for assignees, commenters, reviewers, checks, comment and description text, age, and size. Mistakes are explained as you type (“Did you mean `status:`?”). Saved searches move into your encrypted vault automatically.
- **Hide means gone.** Hide rules remove matching work from the Inbox, Briefing, Weekly Review, notifications, and the menu bar; it waits in **Hidden by Rules**. Rules now **Hide**, **Move** to a section, or **Rank** higher or lower, in a fixed, predictable order. Your existing rules convert automatically; Mute rules become Hide rules.
- **Mute one item until you're addressed.** Mute (M, ⇧⌘M) hides an item until someone mentions you, requests your review, assigns you, or requests changes on your pull request.
- **Rules for what Copilot notices.** Copilot tags work with signals such as *waiting on an approval gate*, *CI failing*, and *bot noise*, and with your own **Topics** — describe anything in plain English, like “blocked on a FedRAMP or other compliance deployment approval”, and use `topic:` in rules and search.
- **Checks you can filter on.** Triage reads each pull request's individual checks and whether they're required: `check:build:failing`, `status:required-failing`.
- **Why this rank.** Click Priority to see Copilot's assessment, a few fixed factors (asked directly, waiting on you for days, a failing required check on your pull request, a fresh mention, staleness), and your Rank rules.
- **Not right? asks what you meant.** Hide work like this, mute just this one, move or rank work like this — straight into the rule editor, with its most specific filter chosen and an Add Filter menu for the rest.
- **Suggested rules.** Triage notices work you keep setting aside and, when you ask, has Copilot suggest rules with the evidence and a live preview. Nothing changes until you add one. Learning history stays encrypted on your Mac for 90 days and can be cleared in Settings.
- **Less re-analysis.** Changing a rule re-checks only the work Copilot needs to see again; Hide and Rank rules never do.

## Triage 0.1.2

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
