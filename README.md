# DNS Redirect

A native macOS app (Swift, SwiftUI, macOS 14+) for redirecting domain names on this Mac only, for example making `dashboard.com` open `google.com`. It can map a domain to an IP address or to another domain.

Redirects are local. They change how names resolve on this Mac and nowhere else. The app doesn't touch real DNS records at a registrar or DNS provider, and it doesn't change DNS for your network or for other devices.

<!-- Screenshots: render them with the Debug-only `-DNSRedirectSnapshotPath <prefix>` launch argument
     (see "Developer launch arguments") and add them to docs/screenshots/. -->
> 📸 *Screenshots coming soon.*

**Contents:** [Install](#install) · [Build & run](#build--run) · [Architecture](#architecture) · [Features](#features) · [Limitations](#limitations) · [Installer](#installer) · [Files](#files)

## Install

Download `DNS-Redirect-<version>.dmg` from the [Releases](../../releases) page, open it and run **Install DNS Redirect**. The build is universal (Apple Silicon and Intel). It is ad-hoc signed, so the first launch on a new Mac needs **System Settings → Privacy & Security → Open Anyway** once. See [Installer](#installer) for details, or build it yourself below.

| Source Domain     | Destination       | Type   | How it's applied                       |
|-------------------|-------------------|--------|----------------------------------------|
| `example.com`     | `192.168.1.100`   | IP     | `/etc/hosts` managed section           |
| `test.local`      | `127.0.0.1, ::1`  | IP     | `/etc/hosts` (IPv4 + IPv6)             |
| `old.example.com` | `new.example.com` | Domain | snapshot in `/etc/hosts`, **or** a live CNAME alias through the local resolver |

> **DNS-level mapping only.** DNS Redirect changes which IP address apps connect to for a name. It is **not** an HTTP redirect: the URL in the browser, the `Host` header and the HTTPS certificate the server must present all stay the same.

---

## Build & run

Requirements: Xcode 16 or later (the project uses file-system-synchronized groups), macOS 14 or later.

```bash
# Open in Xcode and press ⌘R
open DNSRedirect.xcodeproj

# …or from the command line
xcodebuild -project DNSRedirect.xcodeproj -scheme DNSRedirect -configuration Release \
           -derivedDataPath build build
open "build/Build/Products/Release/DNS Redirect.app"
```

If `xcode-select` points at the Command Line Tools, prefix commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or `Xcode-beta.app`).

> **Tip:** If the project lives in an iCloud-synced folder (for example `~/Documents` with Desktop & Documents sync), code signing can fail with *"resource fork, Finder information, or similar detritus not allowed"*. Use a `-derivedDataPath` outside the synced folder, as shown above.

The app is ad-hoc signed ("Sign to Run Locally"). To distribute it, set your team, enable the Hardened Runtime and notarize.

### Tests

```bash
# All 55 core tests, through the app scheme
xcodebuild -project DNSRedirect.xcodeproj -scheme DNSRedirect -derivedDataPath build test

# …or directly with SwiftPM
cd Packages/DNSRedirectCore && swift test
```

The tests never need root. All system access goes through injectable interfaces:

- `SystemPaths` lets tests point at temporary hosts and resolver directories.
- `DirectExecutor` stands in for the privileged helper.
- `AddressResolving` and `UpstreamDNS` are mock resolvers.

The tests cover:

- **Validation:** domains and IPv4/IPv6 addresses.
- **Hosts section:** byte-exact round trips of the managed `/etc/hosts` section, refusal to edit a damaged section, preserved permissions and symlinks.
- **Rule engine:** conflicts, duplicates, chains, loops, and cache fallback.
- **Rule testing:** the tester's pass, partial and fail outcomes.
- **DNS:** the wire codec, including compression and malformed input.
- **Local resolver:** answers queries over a real loopback UDP socket.
- **Storage:** import/export and recovery from a corrupt configuration file.

---

## Architecture

```
DNSRedirect.xcodeproj
├── DNSRedirect/                 App target (SwiftUI)
│   ├── App/                     @main, menu bar extra, commands, AppDelegate
│   ├── Services/AppModel.swift  @Observable state, orchestration, autosave
│   └── UI/                      Dashboard, editor, lookup, activity log, system, settings
├── DNSRedirectHelper/main.swift Privileged helper (the only code that runs as root)
└── Packages/DNSRedirectCore/    Local Swift package: all logic, fully unit-tested
    ├── Model/        Rules, profiles, settings (Codable JSON)
    ├── Validation/   IPAddress (inet_pton), DomainName
    ├── Hosts/        ManagedHostsBlock: parse/insert/replace/remove the marked section
    ├── Engine/       RuleEngine (desired state), conflict checker, rule tester
    ├── DNS/          DNS message codec, upstream client, getaddrinfo resolver, LocalDNSServer
    ├── Privileged/   PrivilegedRequest, SystemOperations, executors
    └── Storage/      ConfigurationStore, activity log, import/export
```

**How a change flows:**

1. You edit a rule. `AppModel` autosaves to `~/Library/Application Support/DNS Redirect/configuration.json`.
2. `RuleEngine` computes the desired state: hosts entries plus live aliases.
3. `SystemSnapshot` reads what is actually installed. Reading needs no privileges.
4. If the two differ, `AppleScriptExecutor` runs the bundled helper as root.
5. The helper writes the changes and flushes the DNS cache.

### Privileged operations

- The app runs `Contents/MacOS/dnsredirect-helper apply <request.json>` through the standard macOS administrator dialog (`do shell script … with administrator privileges`). The command line is fixed, and both paths are passed through AppleScript's `quoted form of`.
- **No user text ever reaches a shell.** The request is a typed JSON document of IP addresses, hostnames, resolver domains and a port. It is written to a `0700` staging directory.
- The helper re-validates everything before touching a file. It accepts only valid hostnames, refuses reserved names (`localhost`, `broadcasthost`, …), single-label resolver domains, and ports below 1024, and it reads the request file only if it is a regular file (not a symlink) of bounded size.
- It edits **only**:
  - the block between `# >>> DNS Redirect managed section — do not edit >>>` and `# <<< DNS Redirect managed section <<<` in `/etc/hosts`;
  - files in `/etc/resolver/` whose first line is the DNS Redirect marker. A resolver file you created yourself is reported as a conflict and left alone.
- Writes are atomic (temporary file, then `rename(2)`). They keep the file's mode and owner and write through a symlinked `/etc/hosts`. If the managed section is damaged (missing start or end marker, or two sections), the helper refuses to write anything.
- If `/etc/hosts` is locked (`uchg`), the helper reports that clearly. It never unlocks the file.
- macOS remembers the authorization for a few minutes, so a burst of edits prompts once. If you cancel the dialog, nothing changes, and the dashboard shows a banner with **Retry**.
- SIP, Gatekeeper, the firewall and other protections are never touched.

### Domain → domain

There are three methods. Only **Web redirect** makes the browser land on the destination site. The other two change DNS only, so the browser still asks the new server for the *original* name. Shared hosts (Google, Cloudflare, AWS, Vercel…) then serve the original site, and others show a certificate error.

0. **Web redirect (default for new rules).** The source (and `www.` + source, for two-label domains) is mapped to `127.0.0.1` and `::1` in the managed hosts section. DNS Redirect listens on ports 80 and 443. macOS lets unprivileged apps bind low ports only on the wildcard address, so the listener is pinned to the loopback interface and also drops any connection that isn't from a loopback address. It answers with `302 Found` + `Cache-Control: no-store`, keeping the path (`youtube.com/watch?v=1` → `https://google.com/watch?v=1`). For HTTPS, the app creates a **"DNS Redirect Local CA"**: a P-256 key in your login keychain that can't be exported, with trust limited to your user account and to SSL server certificates. It then issues a leaf certificate for exactly the redirected hosts. macOS asks for your password once to trust the CA. Remove it at any time under System → Web Redirect, or by uninstalling. Web redirects work while the app runs. On quit, their hosts entries are removed so the sites don't simply fail, then restored at the next launch.

1. **Snapshot (default).** The destination is resolved through your upstream DNS servers, bypassing `/etc/hosts` so stale entries can't feed back in. Its addresses are written to the hosts file. The addresses are stored and reused, so CDNs that rotate their IPs don't cause constant re-applies and password prompts. Use **Refresh Resolved IPs** (⇧⌘R) to update them. If resolution fails, the last known addresses are used and the rule shows a warning. Chains between rules (`a → b`, `b → 10.0.0.5`) are resolved internally, and loops are rejected.
2. **Live alias (optional local resolver).** The app runs a small DNS server on `127.0.0.1:<port>` (default 53535, unprivileged). It writes `/etc/resolver/<source>` so macOS sends lookups for that domain to it, and answers each lookup with `source CNAME destination` plus the destination's current A/AAAA records (TTL 30 s). Subdomains of the source are forwarded unchanged to your configured DNS servers. The resolver only works **while the app is running**, so by default its resolver files are removed when you quit.

### Status is real

A rule shows **Active** only when its mapping is actually present in `/etc/hosts`, or, for live aliases, when the resolver file is installed and the server is running. Other states are Pending, Disabled, Inactive (master switch or profile turned off), and Error (validation, conflict, resolution failure, or resolver down). The app re-reads the system each time it is brought to the front, so hand edits are picked up.

---

## Features

- **Rules:** add (several sources at once map to one destination), edit, enable or disable, duplicate, delete (⌫, with confirmation), search, filter by status and type, and pause or enable everything with the master switch.
- **Validation:** IPv4/IPv6 via `inet_pton`, RFC-style hostnames, URL pasting (`https://x.com/path` becomes `x.com`), duplicate and conflict detection, and loop detection.
- **Profiles:** any number. Activate several at once or **Switch to This Profile Only**. Rename, delete, and see conflicts between active profiles.
- **Rule testing:** resolves through the system resolver (what apps actually see) and compares against the intended addresses. Results are Working, Partly working (for example, extra IPv6 records) or Not working, with caching and DNS-over-HTTPS hints.
- **DNS Lookup:** side by side, what this Mac resolves (`getaddrinfo`), what upstream DNS says (a direct UDP query), and what DNS Redirect intends, plus a verdict.
- **Activity log:** timestamped, filterable, persisted (last 1,000 entries). It records the app's own actions only. It does **not** claim to see other apps' DNS queries. The only query counts shown come from the local resolver, which really does answer them.
- **Menu bar:** active rule count, hosts and resolver status, the master toggle, per-profile toggles, Apply, Flush DNS Cache, Open Dashboard, Settings, Quit.
- **Import/Export:** JSON (`dns-redirect.rules` format, a single profile, or a bare array of `{source, destination}` objects). Duplicates are skipped, invalid rules are reported, and imported rules get fresh IDs.
- **Persistence:** `/etc/hosts` changes survive reboots. *Re-apply at launch* repairs any drift, and *Launch at login* uses `SMAppService`.
- **Restore Original Configuration:** removes the managed section and the app's resolver files, then pauses redirects. Your rules are kept. A copy of the original `/etc/hosts` is saved under `Application Support/DNS Redirect/Backups/` before the first change.

---

## Limitations

- **Snapshot and live aliases are DNS only.** See *Domain → domain*. Use Web redirect to send the browser to another site.
- **Web redirect needs the app running and ports 80/443 free.** If another local web server holds them, the System page shows the error. Firefox uses its own certificate store, so set `security.enterprise_roots.enabled` in `about:config`. Apps with their own certificate pinning reject the local certificate. Browsers do accept it for HSTS sites, because they allow locally trusted roots.
- **Some apps bypass system DNS.** This includes browsers with Secure DNS / DNS-over-HTTPS, iCloud Private Relay, some VPNs and configuration profiles, and apps with their own resolvers.
- **Caching.** The app flushes the macOS cache (`dscacheutil -flushcache`, `killall -HUP mDNSResponder`) after each change. Browsers and open connections keep their own caches.
- **IPv4-only rules.** If the real domain has AAAA records, some apps may still connect over IPv6. Add an IPv6 destination such as `::1` to override both. The rule tester flags this case.
- **Snapshot aliases can go stale** when the destination's IPs change. Refresh them, or use a live alias.
- **Live aliases need the app running.** The local resolver is UDP-only, so very large forwarded answers that need TCP fallback aren't supported.
- **No wildcards in `/etc/hosts`.** A live alias's `/etc/resolver` file does cover subdomains, but those subdomains are forwarded to your normal DNS, not aliased.
- **Internationalized names** must be entered in punycode (`xn--…`).

### Out of scope

- Editing real DNS records at a registrar, DNS provider or registry.
- Network-wide redirects for other devices on the LAN.
- An iOS version.

## Installer

`Scripts/build-installer.sh` produces `dist/DNS-Redirect-<version>.dmg`, a compressed disk image with the **Install DNS Redirect** app, a themed Finder background and a volume icon. Everything is universal (arm64 + x86_64, `minos 14.0`), so it runs natively on Apple Silicon and Intel. End users need no Xcode, Homebrew or Terminal.

The wizard has five steps: Welcome → System Check → Setup → Install → Finish (**Launch App**).

- **System check:** macOS ≥ 14, the real CPU architecture (even under Rosetta) against the slices in the app, the code signature of the embedded app (all architectures, nested code, strict), whether the install folder is writable, free disk space, an existing install and its version, admin-group membership, and any active DNS Redirect changes.
- **Install:** needs no administrator password. `/Applications` is admin-writable. For standard accounts, the app goes into `~/Applications`. The steps are: quit running copies gracefully, copy into a temporary name, then swap atomically. Then re-verify the installed signature and helper, register with Launch Services, and write first-run settings. Existing rules are kept. *Open at login* is applied by the app itself on first launch, through `SMAppService`.
- **Uninstall:** in the installer (Welcome → *Uninstall…*), or in the app (System → *Uninstall…*). It removes only the managed `/etc/hosts` section and the marker-tagged `/etc/resolver` files, using the bundled helper behind the standard admin prompt. If anything else is left, it stops before deleting anything. It also removes the local CA (trust, certificate and keys) and the login item, then moves the app to the Trash. You can optionally delete your rules and logs. It verifies afterwards that no DNS Redirect entries remain.
- **Headless mode for testing:** `"Install DNS Redirect.app/Contents/MacOS/DNS Redirect Installer" --unattended check|install|uninstall [--target DIR] [--data-dir DIR] [--system-root DIR] [--launch-at-login] [--remove-data]` prints one JSON line per step. `--system-root` points the hosts and resolver paths at a sandbox for tests.

**Distribution and Gatekeeper.** Without a Developer ID, the build is ad-hoc signed. That's fine on the Mac that built it, but a copy downloaded on another Mac is blocked the first time. The user then has to choose **System Settings → Privacy & Security → Open Anyway** once. To ship with no prompts, run:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=<notarytool-profile> Scripts/build-installer.sh
```

That signs with the hardened runtime and the Apple Events entitlement needed for the admin prompt, then notarizes and staples the DMG.

## Files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/DNS Redirect/configuration.json` | rules, profiles, settings, resolved-address cache |
| `…/activity-log.json` | activity log |
| `…/Backups/hosts.original` | your `/etc/hosts` before DNS Redirect first changed it |
| `/etc/hosts` (marked section) | installed hosts-file rules |
| `/etc/resolver/<domain>` (marker-tagged) | live-alias routing to the local resolver |
| `…/WebRedirect/local-ca.cer` + login keychain keys | the HTTPS web-redirect certificate authority |
| `…/install-receipt.json` | where and what the installer installed |

## Developer launch arguments

- `-DNSRedirectDataDirectory <path>` uses a different configuration directory, for demos and manual testing.
- `-DNSRedirectSnapshotPath <prefix>` (Debug builds only) writes off-screen PNG renders of the main pages.
