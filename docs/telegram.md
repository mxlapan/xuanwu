# Telegram bot & notifications

Setting `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ADMIN_IDS` on the **panel** enables two
things at once, both using the same bot:

1. a **management bot** — you send it commands to manage users/nodes;
2. **push notifications** — the panel proactively messages admins on events.

Leave either variable blank to disable the whole feature.

## Setup

1. Create a bot with **@BotFather** and copy its token.
2. Send your bot any message, then get your **numeric chat id** (e.g. from
   **@userinfobot**). Multiple admins: comma-separated.

### Configure it in the panel (recommended)

Open **Security → Telegram** in the panel and fill in:

- **Bot token** — the @BotFather token (stored write-only; the panel never shows
  it back, only whether one is set).
- **Admin chat IDs** — comma-separated numeric chat IDs.

Click **Save** — it takes effect immediately (the bot restarts live, no panel
restart). Use **Send test** to verify, or **Disable** to clear the token. The
settings are stored in the panel database and survive restarts.

### Or seed it from the environment

You can pre-seed the config with `TELEGRAM_BOT_TOKEN` + `TELEGRAM_ADMIN_IDS` in
`deploy/panel/.env` (already wired into the panel compose). These are used as the
**initial** values; anything saved in the panel afterwards overrides them.

Only configured chat IDs are authorized. An unknown chat that messages the bot is
told its own id so you can add it in the panel.

## Push notifications

Sent to every configured admin chat:

| Event | Message | When |
|---|---|---|
| Node offline | `⚠️ Node offline: <name> (<address>)` | The node has been disconnected for **90 s** without reconnecting (debounced, so routine restarts stay quiet). |
| Node recovered | `✅ Node back online: <name>` | A previously-alerted node reconnects. |
| User inactive | `🔕 User inactive: <username> (<reason>)` | A user flips from active to inactive. `reason` ∈ `disabled by admin`, `expired`, `over quota`. Checked every ~30 s. |
| Test | `🔔 Xuanwu test notification — your alerts are working.` | You click *Send test message* in the panel. |

## Bot commands

Send these to the bot (authorized chats only):

| Command | Action |
|---|---|
| `/users` | list users with state and usage |
| `/nodes` | list nodes with online status |
| `/adduser <name> [limitGB] [days]` | create a user (assigned to all nodes), print its sub link |
| `/deluser <name>` | delete a user |
| `/enable <name>` / `/disable <name>` | toggle a user |
| `/traffic <name>` | show a user's usage |
| `/reset <name>` | reset a user's traffic counter |
| `/sub <name>` | show a user's subscription link |
| `/help` | list commands |
