# DNS Pointer

A small macOS app for adding local DNS redirects ("pointers") on your own machine, for example making `dashboard.com` open what `google.com` serves.

Redirects are local only. They change how names resolve on this Mac and nowhere else. The app does not touch real DNS records at a registrar or DNS provider.

## Status

Early planning. There is no working app yet, and nothing below is built or decided unless it says so.

## Goals

- Add, edit, enable/disable and remove local redirects from a simple Mac UI.
- Point a domain at another domain (`dashboard.com` → `google.com`) or directly at an IP address.
- Make changes easy to undo, and leave the system clean when a redirect is removed or the app is uninstalled.

## Non-goals

- Editing real DNS records at a registrar, DNS provider or registry.
- A phone (iOS) version. That may come much later, but it is out of scope for now.
- Network-wide redirects for other devices on the LAN.

## Planned approach (open questions)

The simplest local mechanism on macOS is the `/etc/hosts` file, which the app could manage in its own clearly marked block. Two catches shape the design:

1. **Hosts files map names to IP addresses, not names to names.** To make `dashboard.com` follow `google.com`, the app would have to look up `google.com`'s IP and write that IP, which goes stale when the target's IPs change. The alternative is a local resolver approach (for example a small local DNS server with per-domain rules via `/etc/resolver/`) that can answer with a CNAME-style mapping. Which approach to use is still open.
2. **Pointing a name at another site's IP doesn't always load that site.** Many sites check the `Host` header and the TLS certificate name, so `https://dashboard.com` served from Google's IPs will usually fail with a certificate error. True "open B when I type A" behavior may need an HTTP redirect (for example a tiny local web server) rather than DNS alone. This is also an open question.

Other things to work out:

- Editing `/etc/hosts` or `/etc/resolver/` needs admin rights, so the app will need a privileged helper or an authorization prompt.
- The DNS cache needs flushing after changes (`dscacheutil -flushcache; sudo killall -HUP mDNSResponder`).
- Language and UI framework (likely Swift/SwiftUI, not yet decided).

## Roadmap

1. Decide the redirect mechanism (hosts file, local resolver, local HTTP redirect, or a mix).
2. Prototype adding and removing a single redirect.
3. Build the basic Mac UI for managing a list of redirects.
4. Handle permissions, cache flushing and clean uninstall.

## Build and run

TBD. Instructions will be added once the project is set up.
