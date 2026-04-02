# ✨ Auto Nginx & SSL Manager

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
bash <(curl -Ls https://raw.githubusercontent.com/saeederamy/Auto-SSL-Nginx/refs/heads/main/install.sh)
```
