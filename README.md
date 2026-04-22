# ✨ Auto Nginx & SSL Manager (Black-SSL)

A powerful, interactive, and beautifully designed Bash script to effortlessly manage Nginx reverse proxies, SSL certificates, and sub-path routing. This tool is specifically optimized for custom web applications, VPN panels (like **X-UI**), and dynamic scripts (like **Black Hub**).

## 🌟 Key Features

* 🚀 **Global Command:** Installs itself as a system command. Just type `auto-ssl` anywhere in your terminal to launch the interactive menu.
* 🔒 **Multi-Provider SSL Support:** * **Certbot:** Recommended for standard domains.
  * **Acme.sh:** Great for strict rate limits.
  * **Manual / Custom:** Easily use your own certificates (e.g., Cloudflare Origin Certificates).
* 🔀 **Advanced Reverse Proxy:** Map any internal port (`127.0.0.1:PORT`) to a root domain (`example.com`) or a specific sub-path (`example.com/panel/`).
* 🧠 **Smart Application Routing:**
  * **Mode 1 (Custom Apps / Black Hub):** Automatically injects `sub_filter` and rewrites hardcoded HTML/JS links to fix broken assets and login pages on sub-paths.
  * **Mode 2 (X-UI Panel):** Clean, direct proxying optimized for Vue.js based Single Page Applications (SPAs).
* ⚙️ **Custom Listen Ports:** Run Nginx on custom HTTP and HTTPS ports to avoid conflicts with existing services.
* 🗂 **Domain & SSL Manager:** Easily list active domains, check SSL certificate expiration dates, and safely remove specific paths or entire domain configurations.
* 🧹 **Deep Clean Uninstall:** A built-in option to safely and completely wipe Nginx, all SSL certificates, and proxy configurations from your server.

## 🚀 Installation & Usage

Run the following one-liner command on your server (requires `root` privileges):

```bash
rm -f /usr/local/bin/auto-ssl
bash <(curl -Ls "https://raw.githubusercontent.com/saeederamy/black-ssl/refs/heads/main/install.sh?v=7")
```

**Note:** After the first installation, you no longer need the `curl` command. Simply type `black-ssl` in your terminal to open the manager!

## 📋 Interactive Menu Overview

When you launch `auto-ssl`, you will be greeted with a modern CLI interface offering the following options:

1. **Install Nginx & Setup Domain:** Install Nginx (if not present), configure your HTTP/HTTPS listen ports, and acquire/setup an SSL certificate for your domain.
2. **Add Reverse Proxy (Port ➔ Path):** Link an internal port to your domain. You can choose to proxy the root `/` or a sub-path like `/app/`. You will also be prompted to select the **App Type** (Black Hub vs. X-UI) for optimal routing.
3. **Manage Domains & SSL:** View a list of your configured domains, check the exact expiration date of their SSL certificates, or completely delete a domain's config.
4. **List Configured Proxies:** See a clean tree-view of all domains, their paths, and the internal ports they are pointing to.
5. **Remove a Specific Proxy Path:** Safely remove a single sub-path proxy without affecting the rest of the domain's configuration.
6. **Danger: Deep Remove All:** Completely uninstall Nginx and purge all related configurations and Let's Encrypt files from your server.

## ⚠️ Important Note for X-UI Users

If you are using **Mode 2 (X-UI Panel)** to host your panel on a sub-path (e.g., `example.com/my-panel/`), you **MUST** configure the panel to recognize this path:

1. Log into your X-UI panel using `IP:PORT` first.
2. Go to **Panel Settings**.
3. Find the **Panel url root path** setting.
4. Enter your exact path (e.g., `/my-panel/`) and save/restart the panel.

## 🛠 OS Compatibility

* Ubuntu 20.04 / 22.04 / 24.04
* Debian 11 / 12

## 💖 Support the Project

If this tool has helped you manage your Windows services more efficiently, consider supporting its development. Your donations help keep the project updated and maintained.

### 💰 Crypto Donations

You can support me by sending **Litecoin** or **TON** to the following addresses:

| Asset | Wallet Address |
| :--- | :--- |
| **Litecoin (LTC)** | `ltc1qxhuvs6j0suvv50nqjsuujqlr3u4ekfmys2ydps` |
| **TON Network** | `UQAHI_ySJ1HTTCkNxuBB93shfdhdec4LSgsd3iCOAZd5yGmc` |

---

### 🌟 Other Ways to Help
* **Give a Star:** If you can't donate, simply giving this repository a ⭐ **Star** means a lot and helps others find this project.
* **Feedback:** Open an issue if you encounter bugs or have suggestions for improvements.

> **Note:** Please double-check the address before sending. Crypto transactions are irreversible. Thank you for your generosity!

