# GRDB SQLCipher vendoring

This directory contains GRDB 7.11.1 from commit
`b83108d10f42680d78f23fe4d4d80fc88dab3212`, licensed under the upstream MIT
license in `LICENSE`.

The deterministic SHA-256 fingerprint of the retained upstream `GRDB` and
`Sources` trees is
`a884ed4d3fe5cf382e34e1f6e162ca57a4c4ca00f07d8e37fca988c439fda6cf`.

GRDB's upstream Swift Package manifest documents that SQLCipher use requires a
custom package configuration until Swift Package Manager supports selecting the
SQLite implementation without it. This package makes only that documented
configuration change:

- link SQLCipher.swift 4.18.0;
- compile GRDB with `SQLITE_HAS_CODEC` and `SQLCipher`;
- replace GRDB's system SQLite bridge with its upstream `GRDBSQLCipher` bridge.

The vendor source and configuration are version-locked and audited as part of
Triage's release process. Upgrades must start from the upstream tagged source,
repeat this minimal configuration, preserve the upstream license, and pass the
encrypted-vault verification suite.
