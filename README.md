# docker-structs-guild

The default Compose file runs a non-validating node, PostgreSQL, the block indexer,
NATS, GRASS, the webapp, TSA and the guild crawler. The instructions below apply
to `compose.yaml` on testnet `structstestnet-111`. The Discord and reactor files
are separate legacy configurations.

## Fresh installation

Clone this repository and a v0.22-compatible `playstructs/structs-webapp`
checkout into sibling directories. From the guild repository:

```sh
cp .env.example .env
(cd ../structs-webapp/src && npm ci && npm run build)
```

Set the node moniker, guild details and a random webapp secret in `.env`.
`WEBAPP_SOURCE` must point to the prepared webapp `src` directory. Set
`TSA_GAS_PRICE` to the node's admission price if using priced operations.
Leave both migration contracts empty on a fresh database.

```sh
docker compose config --quiet
docker compose up -d
docker compose ps -a
```

For the optional admin SPA, set `CONTROL_SOURCE` to a structs-control checkout
and add `COMPOSE_PROFILES=control` to `.env`. This also includes the admin SPA
in subsequent start and stop commands.

## Upgrade an existing database to v0.22

1. Record the current indexed height and the image versions. Stage compatible
   node, PG/indexer, TSA and webapp releases. `STRUCTS_PG_IMAGE` selects one
   image for init, the server, auto-migration and sync-state. Use a tested
   tag or digest when staging a recovery.
2. Stop submissions and every writer using this database, including external
   clients. Run `docker compose --profile control stop` and verify PostgreSQL
   has shut down. Take a restorable cold backup of **both** PG volumes together
   and back up the TSA keyring (including its send journal) and guild configuration.
   Retain the chain volume.
3. With PostgreSQL still stopped, run the init service alone. The temporary
   settings acknowledge the writer and signer transition for this invocation.

   ```sh
   STRUCTS_LEDGER_WRITER_CONTRACT=denomination-v1 STRUCTS_SIGNER_CONTRACT=v022-1 \
     docker compose up --no-deps --force-recreate --exit-code-from structs-pg-init structs-pg-init
   ```

   Proceed only after the log confirms Sqitch deployed and verified the intended
   target and initialization completed. A skipped init due to a locked data
   directory means another PostgreSQL process still owns the volumes.

4. If the old writer stopped **before 3,353,000**, start the upgraded stack
   with `docker compose up -d`. If it indexed **exactly 3,353,000** with the
   old contract, start only the node and database, wait for RPC and PG, and
   reconcile that exact block before starting the writer:

   ```sh
   docker compose up -d --no-deps structsd structs-pg
   docker compose run --rm --no-deps structs-sync-state /src/scripts/sync_state.sh reconcile-current-block -start=3353000 -mirror-raw=true
   ```

   After a successful repair, run `docker compose up -d`. If the old writer
   advanced **past 3,353,000 without source coverage**, keep it stopped. Restore
   a verified complete PG checkpoint at or before the boundary and reconcile
   newer off-chain application and signer state before resuming. If no suitable
   checkpoint exists, build a fresh index in a new pair of PG volumes using
   `STRUCTS_PG_DATA_VOLUME` and `STRUCTS_PG_CONFIG_VOLUME`. Keep the originals
   for recovering off-chain state. The indexer can reuse a healthy archive node
   with full block results. Rebuilding from genesis can take hours. Moving the cursor, enabling
   replay or inserting a coverage row manually can corrupt ledger history.
   See the [PG migration and recovery procedure](https://github.com/playstructs/docker-structs-pg/blob/main/docs/v022-migrations.md).

## Checking readiness

```sh
docker compose ps -a
docker compose logs --tail=30 structs-sync-state structs-tsa
docker compose exec structs-pg psql -h structs-pg -U structs_webapp -d structs -c 'SELECT indexed_height, observed_tip, protocol, transaction_ready FROM structs.api_readiness()'
```

Sign-up needs transaction readiness **and** a reconciled, authorized guild signer.
During catch-up, use the indexer's completed-window rate to estimate progress.
A repeating failure at height 1,907,566 mentioning a missing transfer recipient
requires a PG image that supports the historical empty recipient. Retrying the
same binary or skipping the block cannot complete the ledger.

If `structsd` loops before startup with `could not read committed chain height`
and an `EOF` opening `application.db`, stop the node and preserve its complete
chain volume for diagnosis. LevelDB journal files may contain committed data.
Keep them with the database and validate any recovery on an offline copy before
using it on the original volume.

PostgreSQL defaults to a 4096 MiB limit. Set `POSTGRES_MEMORY_MB` to size the
server limit and shared buffers together. On Apple Silicon, backfill speed
depends on the image architecture and Docker Desktop's emulation settings.
Docker Desktop offers Rosetta for amd64 emulation with the Apple Virtualization
framework. [Docker Desktop settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)

To update GRASS from the official Docker Hub image, run
`docker compose up -d --pull always --no-deps structs-grass`. Check
`docker compose ps structs-grass` and `docker compose logs --tail=30 structs-grass`.
Keep a single relay listening to the guild's PG channel to avoid duplicate
publications.

The GRASS probe waits 15 seconds for a PG notification to reach NATS. If tuning
it for a slower host, keep `GRASS_HEALTHCHECK_TIMEOUT` longer than
`GRASS_HEALTH_TIMEOUT` to allow for client setup and cleanup.

## Structs

In the distant future the species of the galaxy are embroiled in a race for Alpha Matter, the rare and dangerous substance that fuels galactic civilization. Players take command of Structs, a race of sentient machines, and must forge alliances, conquer enemies and expand their influence to control Alpha Matter and the fate of the galaxy.

# Learn more

- [Structs](https://playstructs.com)
- [Project Wiki](https://watt.wiki)
- [@PlayStructs Twitter](https://twitter.com/playstructs)


# License

Copyright 2021 [Slow Ninja Inc](https://slow.ninja).

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

[http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
