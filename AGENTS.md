# Working agreement

This repository, `sing-box-vps-bootstrap-simple`, is the primary workspace for
further development. Run commands and make commits in this repository; keep the
previous controller workspace and private operator reports outside it.

The user reset this project on 2026-09-06: one Bash installer for one Ubuntu VPS,
then authorized an equally simple companion client script for the Mac.
The previous controller, schemas and ADRs are historical at commit
`d559ca25ab00aa1af35d39ca266f082d1248f68c`; they do not govern this rewrite.

## Scope

- Read this file, README.md and relevant script/tests before editing.
- Ship `scripts/prepare-vps.sh` as one Bash file, without a build step or Python runtime.
- Ship `scripts/connect-vps.sh` as one Bash file for Apple Silicon macOS.
- The user requires current stable client dependencies: Homebrew Bash, curl, jq,
  OpenSSL and sing-box. Use explicit Homebrew paths, require its current Bash
  (5.3+), and refuse dependencies reported outdated after the preparation update.
  Do not return to system Bash 3.2 or hardcoded client release downloads.
- Client scope: private config import, terminal-owned SOCKS5 on 127.0.0.1:17890,
  explicit physical interface (default en4), MUX off, one HTTPS check and Ctrl+C cleanup.
- Ubuntu 24.04, amd64/arm64; sing-box 1.14.0; single-user SS2022 on IPv4 TCP 443.
- APT refresh/dependencies, explicit optional system upgrade, conditional 1 GiB swap,
  private configuration and a non-root systemd service are the first version.
- Use ordinary backups and clear errors. No general transaction/recovery engine,
  generated release pair, SSH migration, rotation or Mac measurement framework.
- Preserve existing SSH, firewall and Mac networking. Report the TCP 443 prerequisite.

## Execution boundaries

- Repository changes and disposable CI/VM tests are authorized development work.
  Operating a real VPS still needs the user's precise target/action authorization.
- Never read, execute, copy or upload local `secret` or `vps-conn.sh` files.
  Keep them ignored/untracked; package explicit files, never the whole workspace.
- Never print a PSK or put it in argv/environment/logs. Real reports remain private.
- Do not overwrite another installation, disable TLS verification, remove APT locks,
  reset firewall rules or reboot automatically.

## Quality

- Fixed PATH, locale and private umask; quoted expansions and checked command results.
- Server archives/executables retain their reviewed hashes. Client dependency
  installation, versions and checksums belong to Homebrew's stable formulas.
  No curl-pipe-shell installer or silent fallback to older client dependencies.
- Check configuration before replacing it atomically; keep a private previous-file backup.
- Reruns preserve the key, avoid duplicate swap entries and leave an unchanged healthy
  service running. APT refresh is allowed on each invocation.
- Run Bash syntax, ShellCheck and focused tests. Run actual installation in a disposable
  Ubuntu VM before calling it tested. VM evidence does not establish a real Mac link.
- Reports contain revision, commands, outcomes and remaining limits. Routine details
  do not need an ADR or another design approval.
