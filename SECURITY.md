# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in LumeEngine, please report it **privately** —
do not open a public issue, pull request, or discussion, as that may put users of
downstream apps at risk before a fix is available.

Use one of the following:

- **GitHub private advisory** (preferred): open a report at
  <https://github.com/bilipp/LumeEngine/security/advisories/new>
- **Email**: p.bischoff@innoloft.com

Please include, as far as you can:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept — for parser/decoder issues, the smallest
  media file or `generate-fixtures.sh` recipe that triggers it
- The affected platform(s), OS version, and engine commit
- Any suggested remediation

You can expect an initial acknowledgement within **5 business days**. We will keep you
informed of progress toward a fix and will credit you in the release notes once the
issue is resolved, unless you prefer to remain anonymous.

## Scope

LumeEngine is a **client-side media engine**. It ships no servers, no bundled streams,
and no backend. It does, however, parse hostile input by design: an IPTV stream is
attacker-controlled data fed straight into demuxers and decoders. Relevant areas:

- Memory safety in the FFI layer (`Sources/LumeEngineCore/FFI/`) — lifetime handling of
  `AVPacket`/`AVFrame`, and anything that could survive a session teardown
- Demux/decode handling of malformed, truncated, or adversarial containers and codecs
- The bounded channels and thread supervision (a remotely triggerable hang, deadlock, or
  unbounded memory growth counts as a security issue, not just a bug)
- Handling of per-session headers, cookies, and credentials passed in
  `PlayerConfiguration` — including whether any of them can leak into logs or events
- TLS behavior via SecureTransport, and the network protocols enabled in the FFmpeg build
- The build pipeline under `build/` (pinned versions, checksum verification, patches)

**Vulnerabilities in FFmpeg itself** should be reported upstream to the FFmpeg project.
If a known-vulnerable FFmpeg version is pinned in `build/versions.json`, that *is* in
scope here — please report it so the pin can be bumped.

Out of scope: the security of third-party IPTV providers or the streams a user chooses
to connect to.

## Supported versions

LumeEngine is actively developed and pre-1.0. Security fixes target `main` and the
latest release. Please confirm you are on the most recent commit before reporting.
