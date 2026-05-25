# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Cloudflare-bypassing stock monitor for the [Marukyu Koyamaen matcha principal page](https://www.marukyu-koyamaen.co.jp/english/shop/products/catalog/matcha/principal). It runs on a free-tier EC2 instance and sends Telegram alerts when stock status changes.

## Commands

### Run locally (test mode)
```bash
# Single fetch to verify scraping works (bypasses CF once, prints all products)
python monitor_light.py --once

# Continuous monitor with macOS notifications
python monitor_light.py --macos-notify

# With Telegram
python monitor_light.py --telegram-bot-token <TOKEN> --telegram-chat-id <CHAT_ID>

# Debug logging
python monitor_light.py --once --debug
```

### Terraform (run from `terraform/`)
```bash
terraform init
terraform apply -var="telegram_bot_token=<TOKEN>" -var="telegram_chat_id=<ID>"
terraform destroy

# Force reprovision after changing monitor_light.py.
# WARNING: this destroys /opt/marukyu-monitor/state.json on the EBS root volume.
# The first stock transition after redeploy is absorbed as "Initial state recorded"
# rather than firing an alert.
terraform taint aws_instance.monitor && terraform apply
```

### Operational commands
```bash
# Connect to instance (requires session-manager-plugin installed locally)
$(terraform output -raw ssm_session_command)

# Tail logs on instance
sudo tail -f /var/log/marukyu-monitor/monitor.log
sudo journalctl -u marukyu-monitor -f
```

## Architecture

### Two-phase Cloudflare bypass

The core challenge is that Cloudflare's `cf_clearance` cookie expires every ~30 minutes. Running Chromium continuously costs ~690 MB RAM (too much for t2.micro). The solution:

1. **Solve phase** (every 25 min): `scrapling.StealthySession` launches headless Chromium via `patchright`, solves the Cloudflare Turnstile, extracts `cf_clearance` + `User-Agent`, then closes Chromium immediately. Peak RAM ~200 MB, duration ~13 s.
2. **Poll phase** (every 60 s): `curl_cffi` replays cached cookies with a Chrome TLS fingerprint. No browser needed. Steady-state RAM ~58 MB, duration ~0.2 s.

### Key timing constants (`monitor_light.py`)
| Constant | Value | Purpose |
|---|---|---|
| `DEFAULT_POLL_INTERVAL` | 60 s | How often to scrape |
| `COOKIE_REFRESH_INTERVAL` | 1500 s (25 min) | Max cookie age before re-solving CF |
| `CF_SOLVE_TIMEOUT` | 120 000 ms | Chromium hard timeout |
| `MAX_RETRIES` | 3 | Retries for both solve and fetch |

### Data flow
```
LightweightStockMonitor.run()
  → _needs_cookie_refresh()  →  _refresh_cookies()  →  solve_cloudflare()
  → _fetch()                 →  fetch_lightweight()
  → parse_products(html)     →  regex against WooCommerce HTML
  → detect_changes()         →  diff against self.previous_state (dict[name → bool])
  → _handle_changes()        →  notify_telegram() / notify_macos()
```

`parse_products` uses pure regex (no HTML parser) against WooCommerce list-item markup. Stock status is derived from the presence of `instock` / `outofstock` CSS classes on `<li>` elements.

### Infrastructure (Terraform)
- **EC2**: t2.micro Ubuntu 22.04, `ap-southeast-1`, 8 GB gp3 EBS. IAM role grants only `logs:PutLogEvents` to the CloudWatch log group.
- **Lambda scheduler** (`terraform/lambda/scheduler.py`): Single function that start/stops the EC2 instance. Triggered by two EventBridge cron rules: start at 9:30 AM JST (Mon–Fri), stop at 5:30 PM JST (Mon–Fri).
- **Self-bootstrapping**: `user_data.sh.tftpl` is gzip-base64-encoded into EC2 user data (fits the 16 KB limit). It embeds `monitor_light.py` verbatim at deploy time via `${monitor_script}` template variable. **Changing `monitor_light.py` requires `terraform taint aws_instance.monitor`** to reprovision.
- **State**: Local backend (`terraform/terraform.tfstate`) — not remote, not encrypted. **The Telegram bot token and chat ID are stored in plaintext in `terraform.tfstate`** despite `sensitive = true` (which only redacts plan output). Keep the file out of git (covered by `.gitignore`) and treat the `terraform/` directory as a secrets-containing location.
- **Telegram vs Discord**: Telegram is used because Discord blocks AWS IP ranges (HTTP 403).

### AWS credentials
The provider uses the standard AWS SDK credential chain — no hardcoded profile. Export `AWS_PROFILE=<your-profile>` (or set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`) before running `terraform`. Region defaults to `ap-southeast-1` via the `region` variable.
