# Changelog

All notable changes to the 2600net IRC SSL Synchronizer will be documented in this file.

## [1.0.30-OSS] - 2026-03-12
### Changed
- Sanitized all hardcoded infrastructure URLs and hostnames.
- Extracted network-specific variables (DOMAIN, HUB, IRC_USER) to a configurable block at the top of the script for open-source deployment.
- Improved terminal output instructions for the final `acme.sh` hook binding.

## [1.0.29] - 2026-03-12
### Fixed
- Corrected the `bundle.pem` compilation logic inside `acme_irc_deploy.sh` to strictly concatenate the Leaf Certificate and CA Certificate (`.cer` + `ca.cer`), keeping the Private Key separate. This perfectly matches the `SIGHUP` rehash requirements for `ircd-hybrid` and resolves the intermediate chain dropping issue.
- Removed all legacy formatting references that were breaking OpenSSL's parsing during live daemon reloads.

## [1.0.28] - 2026-03-12
### Changed
- Abandoned reliance on `acme.sh` native `--fullchain-file` export.
- Rewrote the deployment hook to manually compile the certificate bundle directly from the raw `acme.sh` source directory.

## [1.0.27] - 2026-03-12
### Fixed
- Updated the `HUB_PID_FILE` and `LEAF_PID_FILE` paths to target `var/run/ircd.pid` instead of `var/ircd.pid`, resolving an issue where SIGHUP signals were failing silently.

## [1.0.24] - 2026-03-11
### Added
- **Cascading Backups:** Implemented a dual-layer backup system (`.bak` and `.bak.old`) in `apply_certs.sh` and `rollback_certs.sh` to prevent production certificates from being lost during bad rotation cycles.
- **Graceful Permissions:** Added `chmod 600` unlocking logic prior to copying files to prevent `Permission denied` errors on read-only target files, followed by locking them back down to `400`.

## [1.0.23] - 2026-03-11
### Fixed
- Addressed `cp: cannot create regular file` errors caused by restrictive `400` permissions on existing production certificates.

## [1.0.22] - 2026-03-11
### Added
- Initial deployment of the idempotent master setup script.
- Introduced automated hub-to-leaf push mechanics using `scp` and MD5 hashing.
- Implemented the SSH `authorized_keys` security wrapper to jail remote execution.


