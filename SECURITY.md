# Security

Atelier touches deep parts of macOS, so security reports matter.

- **Report privately** through GitHub's *Report a vulnerability* button on the Security tab of
  this repository. Please do not open a public issue for a vulnerability.
- Atelier never sends personal data anywhere. It makes network requests only for features you
  turn on (wallpaper sources, updates), always with a generic User-Agent.
- Updates are verified with an Ed25519 signature before they are installed. The public key is in
  `Sources/DockStacks/Updater.swift`; a release whose signature does not match is refused.
- Privileged pieces are opt-in and removable: the Fan Control helper (asks for your administrator
  password, returns the fans to macOS whenever Atelier stops talking to it) and the Dock Bridge
  (needs System Integrity Protection partly off, which only you can do, in Recovery).
