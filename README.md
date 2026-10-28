# SoftClient4ES releases

Downloadable SoftClient4ES binaries. Each release holds one jar per Elasticsearch major
(6, 7, 8 and 9), each with a `.sha256` checksum file.

| Product | Release tags | Jar | License |
| ------- | ------------ | --- | ------- |
| REPL bundle (engine + extensions) | `cli-all-vX.Y.Z` | `softclient4es<N>-cli-all-X.Y.Z-assembly.jar` | mixed (see below) |
| REPL (engine only) | `cli-vX.Y.Z` | `softclient4es<N>-cli-X.Y.Z-assembly.jar` | Apache-2.0 |
| JDBC driver | `jdbc-vX.Y.Z` | `softclient4es<N>-jdbc-driver-X.Y.Z.jar` | mixed (see below) |
| ADBC driver | `adbc-vX.Y.Z` | `softclient4es<N>-adbc-driver-X.Y.Z.jar` | mixed (see below) |

`<N>` is the Elasticsearch major version of your cluster.

The REPL bundle and the drivers are not open source: they combine Apache-2.0 and Elastic
License 2.0 components with the proprietary JOIN engine, which is free to use. Only the plain
REPL (`cli`) is pure Apache-2.0.

## Install the REPL

The installer picks the right jar for your cluster and Java version:

```bash
curl -fsSL https://raw.githubusercontent.com/SOFTNETWORK-APP/SoftClient4ES/main/install.sh | bash
```

On Windows, use `install.ps1` from the same repository.

## Download a driver

Download the jar for your Elasticsearch major from the [releases](https://github.com/SOFTNETWORK-APP/softclient4es-releases/releases)
page, then check it:

```bash
shasum -a 256 -c softclient4es8-jdbc-driver-0.3.3.jar.sha256
```

A direct link has the form
`https://github.com/SOFTNETWORK-APP/softclient4es-releases/releases/download/<tag>/<jar>`, for example
`.../download/jdbc-v0.3.3/softclient4es8-jdbc-driver-0.3.3.jar`.

## Snapshots

Each product also has a rolling pre-release, `<product>-snapshot` (for example `jdbc-snapshot`),
holding the latest development build. Its jars are replaced on every snapshot publish, so a
snapshot link can change at any time: never use one in production.

## Documentation

See [softclient4es.dev](https://softclient4es.dev) and the
[SoftClient4ES repository](https://github.com/SOFTNETWORK-APP/SoftClient4ES).

## Publishing (maintainers)

Releases are published by the release workflows of the producer repositories through
[`scripts/publish.sh`](scripts/publish.sh), which also runs locally with an authenticated `gh`:

```bash
scripts/publish.sh release  jdbc 0.3.4          es*/target/softclient4es*-jdbc-driver-0.3.4.jar
scripts/publish.sh snapshot jdbc 0.3.5-SNAPSHOT es*/target/softclient4es*-jdbc-driver-0.3.5-SNAPSHOT.jar
```

A release is never overwritten. Versions published to JFrog before this repository existed are
copied with the **Backfill from JFrog** workflow.

### JFrog cleanup

The **JFrog cleanup** workflow deletes from JFrog the jars this repository now serves, through
[`scripts/jfrog-delete.sh`](scripts/jfrog-delete.sh): pick a product and one or more versions.

- A release version is deleted only if it was copied here: for every Elasticsearch major, its
  GitHub jar must have the sha256 of the JFrog jar. Its Scala 2.12 builds go with it.
- A `-SNAPSHOT` version is deleted from the snapshots repository (the rolling `<product>-snapshot`
  pre-releases replaced it).
- Every version is checked before anything is deleted, and the deleted folders are purged from
  the JFrog trash can.
- `dry_run` (the default) only lists what would be deleted. A real run waits for approval in the
  `jfrog-cleanup` environment, the only place that holds `JFROG_CLEANUP_TOKEN`.

```bash
scripts/jfrog-delete.sh plan cli 0.21.0 0.22.0 0.23.0        # no credentials needed
```
