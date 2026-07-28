# nextdeploy

Take a fresh Ubuntu EC2 instance to a live Next.js app on HTTPS — with one command.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rajjayavant/nextdeploy/main/setup.sh)
```

This is the **first** command you run on a brand-new server. It assumes nothing is installed.

> Use `bash <(curl ...)` as written — **not** `curl ... | bash`. The pipe form hands the script's own text to `read` as if you had typed it, so prompts answer themselves and `sudo` has no terminal to ask for a password on.

---

## What it does

The script walks you through twelve steps, asking questions as it goes:

| # | Step | What happens |
|---|------|--------------|
| 0 | Pre-flight | Checks Ubuntu, sudo, disk, RAM. Offers a swap file on small instances. |
| 1 | System update | `apt update`, installs `curl`, `git`, `ufw`, `dnsutils`. |
| 2 | Node.js | Installs Node 20 LTS from NodeSource (Ubuntu's own package is too old). |
| 3 | Package manager | You choose **npm** or **yarn**. |
| 4 | Repository | You paste a repo URL. It detects whether the repo is public or private. |
| 5 | Deploy key | *Private repos only* — generates an SSH key, shows you exactly where to paste it, then verifies access. |
| 6 | Clone | Clones the repo and confirms it's actually a Next.js project. |
| 7 | Environment | You paste your `.env` contents. Happens **before** the build, because Next.js bakes `NEXT_PUBLIC_*` vars in at build time. |
| 8 | Install & build | Installs dependencies and runs the production build. |
| 9 | PM2 | Starts the app, waits until it really responds, enables start-on-reboot. |
| 10 | Nginx | Reverse-proxies port 80 to your app. |
| 11 | HTTPS | Shows the exact DNS records to add, waits until they resolve to this server, then gets a Let's Encrypt certificate via Certbot. |

At the end you get a `~/redeploy.sh` for shipping updates:

```bash
./redeploy.sh    # pull → install → build → restart
```

## Requirements

- A fresh **Ubuntu** EC2 instance (20.04 / 22.04 / 24.04)
- SSH access as a **non-root** sudo user (on stock Ubuntu AMIs that's `ubuntu`)
- A Next.js app in a Git repository
- Optionally, a domain name if you want HTTPS

### Do I need a sudo password?

**No.** Run the script as `ubuntu` (or whichever normal user you SSH in as) — *not* with `sudo`:

```bash
./setup.sh          # ✓
sudo ./setup.sh     # ✗ — the script refuses this
```

The script calls `sudo` itself for the handful of steps that need root. On a stock EC2 Ubuntu image the `ubuntu` user has **passwordless sudo** and no password set at all, so you'll never be asked for one.

If you *are* prompted for a password, you're most likely logged in as a user you created yourself rather than `ubuntu`. Log in as `ubuntu` instead:

```bash
ssh ubuntu@your-server-ip
```

If you deliberately created your own user and it isn't in the sudo group, add it from a root shell, then log out and back in:

```bash
usermod -aG sudo YOUR_USERNAME
```

### One thing the script can't do for you

It runs *on* the server, so it cannot change your **EC2 security group** — that lives in AWS. Before running, allow inbound traffic:

| Type | Port | Source |
|------|------|--------|
| SSH | 22 | Your IP |
| HTTP | 80 | `0.0.0.0/0` |
| HTTPS | 443 | `0.0.0.0/0` |

Port 80 must be open from anywhere or Let's Encrypt cannot verify your domain.

## Design principles

**Every step is retryable.** When something fails you get a menu — retry, drop to a shell and investigate, skip, or abort — not a stack trace and a half-configured server.

```
✗ Step failed: Install and build

? What would you like to do?
    1) Retry this step
    2) Open a shell to investigate, then retry
    3) Skip this step (only if you know it's already done)
    4) Abort setup
```

**Check before doing.** The script waits for the `apt` lock instead of failing on it, verifies DNS resolves to this server before calling Certbot, confirms the app answers on its port before setting up Nginx, and checks port 80 is externally reachable before requesting a certificate. Most failures are prevented rather than reported.

**Errors explain themselves.** Every failure says what went wrong, why it usually happens, and the command to investigate:

```
✗ DNS isn't ready yet.
  ┌─
  │ If you've only just added the records, this is normal — give it
  │ 2–5 minutes and check again.
  │
  │ If it's been longer, check:
  │   • The record type is A (not CNAME, not AAAA)
  │   • The value is exactly 13.234.56.78
  │   • Cloudflare proxying is OFF (grey cloud, not orange)
  └─
```

**Ambiguous inputs get examples.** Anywhere you could reasonably get it wrong, the format is shown first:

```
  ┌─
  │ Enter just the domain, nothing else.
  │
  │     ✓  wikipedia.org
  │     ✓  app.mycompany.io
  │
  │     ✗  https://wikipedia.org      ← no protocol
  │     ✗  wikipedia.org/wiki/Home    ← no path
  │     ✗  wikipedia.org:3000         ← no port
  └─
```

**Safe to re-run.** Re-running detects what's already done: it won't duplicate Nginx configs, stack PM2 processes, or re-clone over your app. Run it again any time to add a domain or set up HTTPS you skipped.

## Notes on a few decisions

- **Node 20 from NodeSource**, because `apt install nodejs` on Ubuntu 22.04 gives you Node 12, which no current Next.js supports.
- **A swap file on instances under 2GB.** `next build` is memory-hungry and gets OOM-killed on a `t2.micro` with striking reliability. The script offers 2GB of swap and explains why.
- **A PM2 ecosystem file** rather than `pm2 start "npm start"` — the latter makes PM2 look for a *file* named `npm start`, and an env var set before `pm2` reaches the CLI, not your app.
- **`.env` before build, not after.** Getting this backwards means `NEXT_PUBLIC_*` variables silently end up `undefined` in the browser bundle.
- **The app runs as your user, not root.** Root-owned app files and a root PM2 daemon cause permission problems later and widen the blast radius of any app vulnerability.

## Project layout

```
setup.sh          the installer
lib/ui.sh         prompts, colours, the retry engine
lib/validate.sh   input validation and pre-flight checks
```

`setup.sh` fetches `lib/` automatically when piped from `curl`, so the one-liner works without cloning.

## Troubleshooting

```bash
pm2 logs myapp              # app logs — start here
pm2 status                  # is it running?
sudo nginx -t               # is the Nginx config valid?
sudo systemctl status nginx # is Nginx running?
sudo certbot certificates   # certificate status and expiry
curl -I http://127.0.0.1:3000   # does the app answer locally?
```

If the site works on `http://<ip>` but not on your domain, DNS hasn't propagated. If it works locally via `curl` but not from your browser, it's the EC2 security group.

## Status

v0.1.0 — **not yet tested end-to-end on a real EC2 instance.**

The logic that can be tested off-server has been: URL/domain/port/email validation, the retry engine's four paths, the prompt helpers, and the generated Nginx, PM2, and redeploy configs (see `tests/`). But the full run — apt, NodeSource, Certbot, a live DNS check — has not been exercised against a real Ubuntu box yet.

Treat the first run as a shakedown, and please open an issue if a step misbehaves.

## License

MIT — see [LICENSE](LICENSE).
