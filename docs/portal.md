# Self-service portal

The portal lets end users sign in to see their own account and grab their
subscription — without any access to the admin panel.

- **URL:** `PANEL_PUBLIC_URL/portal`
- **Credentials:** their **username** + a **portal password** the admin sets.

The portal is fully isolated from the admin surface: a separate cookie
(`xuanwu_portal`), a separate signed session role (`user`), and endpoints that
only ever read the signed-in user's own row. A portal session can never act as
an admin, and vice-versa. Users **cannot** see devices, admin notes, other
users, or any node internals.

## Giving a user portal access

In a user's **Access** dialog (link icon), set a **portal password**. This
password is **temporary**: it marks the account "must change", and the user is
forced to choose their own on first login (see below). A "temp pw" badge shows
on the user row until they do.

Clear the password field to disable portal login for that user (this also kicks
any active portal session).

## Forced password change on first login

Because the initial password is admin-chosen, the portal blocks everything until
the user replaces it:

1. User signs in at `/portal` with the temporary password.
2. The portal immediately shows **"Set a new password"** — nothing else is
   accessible.
3. On success the temporary flag clears, **all other sessions for that user are
   revoked**, and the current tab stays signed in.

The old temporary password no longer works afterward.

## Password policy

All passwords (portal and admin) must be **at least 8 characters and include an
uppercase letter, a lowercase letter, a digit, and a special character**. The
rule is enforced server-side on every password-setting endpoint, with a matching
client-side hint.

> Note: the policy is checked only when a password is **set or changed**. A
> pre-existing password that predates the policy keeps working until changed, so
> tightening the policy never locks out existing accounts.

## What the user sees

- **Usage** — traffic used / limit with a progress bar, expiry (with a "N days
  left"), node count, and an account-status banner if disabled / over quota /
  expired.
- **Subscription** — base64, Clash and sing-box links with copy buttons,
  one-tap **Import to Clash / sing-box** deep links, and **QR codes** for the
  base64 and Clash subscriptions.
- **Nodes** — the per-node `vless://` links, copyable.
