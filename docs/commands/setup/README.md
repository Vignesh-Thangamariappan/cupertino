# cupertino setup

Download every cupertino database (the 8 per-source DBs: `apple-documentation.db`, `hig.db`, `apple-archive.db`, `swift-evolution.db`, `swift-org.db`, `swift-book.db`, `apple-sample-code.db`, `packages.db`) in one go.

## Synopsis

```bash
cupertino setup
```

## Description

The `setup` command downloads pre-built databases from Cupertino's Fly-hosted asset service, providing instant access to Apple documentation, sample code, and Swift package search without crawling or indexing.

This is the **fastest way to get started** with Cupertino.

Every database ships in a single bundle (`cupertino-databases-vX.zip`). One download, one extract, every database on disk. (Earlier releases split `packages.db` into a separate companion repo; that proved to be needless complexity and is gone as of v1.0.0.)

## What Gets Downloaded

A single zip from the Fly asset host (`cupertino-databases-vX.zip`) containing every per-source database. Exact contents vary by release; the v1.4.0 bundle ships:

| Database | Contents | Size |
|----------|----------|------|
| `apple-documentation.db` | 363,562 Apple documentation pages / 308,118 AST symbols across 417 frameworks | ~2.7 GB |
| `hig.db` | Human Interface Guidelines | ~12 MB |
| `apple-archive.db` | Legacy Apple programming guides | ~25 MB |
| `swift-evolution.db` | Swift Evolution proposals | ~25 MB |
| `swift-org.db` | Swift.org documentation | ~14 MB |
| `swift-book.db` | The Swift Programming Language book | ~2 MB |
| `apple-sample-code.db` | Apple sample-code catalog + crawled GitHub sample projects (READMEs + source files + AST symbols) | ~189 MB |
| `packages.db` | 185 Swift packages with README, Package.swift, Sources/, Tests/, .docc/ extracted | ~1.2 GB |

Numbers above are approximate and snapshot the v1.4.0 bundle (876,442,710-byte compressed download, ~4.2 GB on disk).

## Options

- `--base-dir` - Custom directory for databases (default: `~/.cupertino/`)
- `--keep-existing` - Skip the download and use whatever databases are already installed

## Default behaviour

`cupertino setup` always downloads the release matching the binary's expected `databaseVersion`. On each successful download it stamps a `.setup-version` file next to the databases so subsequent invocations can show:

- the version currently installed,
- whether it's current, stale, or unknown relative to the binary,
- whether a re-run is a no-op refresh or a real upgrade.

If you upgrade cupertino itself (via `brew upgrade cupertino` or the install script) and the new binary expects a newer `databaseVersion`, rerunning `cupertino setup` upgrades the databases in place.

## Examples

### Quick Setup (Recommended)

```bash
cupertino setup
```

### Custom Location

```bash
cupertino setup --base-dir ~/my-docs
```

### Keep Existing Databases

```bash
cupertino setup --keep-existing
```

## Output

```
📦 Cupertino Setup

⬇️  Downloading Documentation database...
   [████████████████████████████░░] 93% (186.2 MB/200.0 MB)
   ✓ Documentation database (200.0 MB)

⬇️  Downloading Sample code database...
   [██████████████████████████████] 100% (75.0 MB/75.0 MB)
   ✓ Sample code database (75.0 MB)

⬇️  Downloading Packages database...
   [██████████████████████████████] 100% (xx.x MB/xx.x MB)
   ✓ Packages database (xx.x MB)

✅ Setup complete!
   Documentation: /Users/you/.cupertino/apple-documentation.db
   Sample code:   /Users/you/.cupertino/apple-sample-code.db
   Packages:      /Users/you/.cupertino/packages.db

💡 Start the server with: cupertino serve
```

## Comparison

| Method | Time | Disk Space |
|--------|------|------------|
| `cupertino setup` | ~1-2 minutes | ~742 MB download, ~4.2 GB on disk |
| `cupertino save --remote` | ~45 minutes | ~250 MB |
| `cupertino fetch && save` | ~20+ hours | ~3 GB + 250 MB |

## Next Steps

After setup, start the MCP server:

```bash
cupertino serve
```

Or simply:

```bash
cupertino
```

## See Also

- [serve](../serve/) - Start MCP server
- [save --remote](../save/option%20%28--%29/remote/) - Stream and build locally
- [fetch](../fetch/) - Download documentation manually
