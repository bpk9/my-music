# Security

This is a personal, paired music player for a trusted LAN or private VPN. Keep
the companion port off the public Internet. The server requires a random bearer
token and the app pins the exact server certificate for API requests, streaming,
and background downloads. Redirects are rejected. The music mount is read-only;
the container runs without root privileges or Linux capabilities.

`scripts/prepare.py` creates local credentials. Never commit `Connection.plist`,
`Local.xcconfig`, `.env` files, TLS keys, signing material, catalog state, media,
logs, screenshots, or build artifacts. Git ignores these files and the Docker
build context includes only an explicit source allowlist. Review staged files
before every push; ignore rules do not protect files forcibly added to Git.

A paired app bundle contains its bearer token. Keep installed/exported personal
builds and their backups private. Anyone with the token can read the library if
they can reach the server. If a pairing file, private key, or paired build leaks,
remove `UNDERTONE_TOKEN` from the local `.env`, run `prepare.py` again, redeploy,
and rebuild all paired apps. This rotates both the token and the certificate;
deleting a leaked file from a repository alone does not revoke it.

Dependencies are resolved in `server/requirements.lock`; Docker and CI use that
file. After updating `requirements.txt`, regenerate the lock in a clean Python
3.12 environment, run the server tests and `pip-audit`, and review the diff.
CI has read-only repository access and uses commit-pinned GitHub actions.

Source review, tests, and secret/dependency scans reduce risk; they cannot
guarantee that an app has no vulnerabilities or prevent disclosure from a
compromised phone, host, or GitHub account.
