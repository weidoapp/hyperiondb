# Debian packaging & apt repo

- `build-deb.sh <pg-major>` — runs `cargo pgrx package` against the system
  `postgresql-server-dev-<major>`, then wraps the staged tree into
  `postgresql-<major>-pg-replica_<version>_<arch>.deb` with `dpkg-deb`.
- `build-apt-repo.sh [deb-dir]` — lays out `pool/` + `dists/stable/main/binary-<arch>/`,
  generates `Packages(.gz)` (`dpkg-scanpackages`) and a `Release` (`apt-ftparchive`), then
  GPG-signs it (`Release.gpg` + `InRelease`) and drops the public key (`pg_replica.gpg`) and
  `install.sh` at the repo root.
- `install.sh` — installs the public key to `/usr/share/keyrings/pg_replica.gpg` and adds a
  `signed-by` apt source pointing at the Pages URL.
- `.github/workflows/packages.yml` — on a `[cd]` commit to `main` (or manual dispatch),
  builds the matrix (PG 14–18 × amd64/arm64), assembles + signs the repo, and deploys it to
  GitHub Pages.

## One-time repo setup

1. **Signing key.** Generate a *passphrase-less* signing key (CI can't type a passphrase):

   ```bash
   gpg --batch --quick-generate-key "pg_replica apt <info@nordlet.com>" rsa4096 sign never
   gpg --armor --export-secret-keys "pg_replica apt" > private.asc
   ```

   Add the contents of `private.asc` as the repo secret **`GPG_PRIVATE_KEY`**
   (`gh secret set GPG_PRIVATE_KEY < private.asc`), then delete `private.asc`.

2. **Pages.** Repo → Settings → Pages → Source = **GitHub Actions**.

3. **Permissions.** The workflow already requests `pages: write` + `id-token: write`.

After that, push a commit containing `[cd]` (or run the workflow manually) to publish.

## Local test (Debian/Ubuntu or WSL)

```bash
sudo apt-get install -y postgresql-server-dev-18 build-essential clang libclang-dev
cargo install cargo-pgrx --version 0.18.1 --locked
bash packaging/build-deb.sh 18
sudo apt-get install -y ./dist/postgresql-18-pg-replica_*.deb
```

`build-apt-repo.sh` additionally needs `dpkg-dev apt-utils gnupg` and a `GPG_KEY_ID` env var.
