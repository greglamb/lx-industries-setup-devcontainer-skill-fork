# Ecosystem Dev Tools

Dev tools that CI validates against (linters, formatters, type checkers, test runners) must
be present in the devcontainer so developers get the same feedback locally. Scan for these
during Phase 1 analysis and install them in Phase 2.

## Detection signals

Scan two sources during Phase 1: CI configuration files and project manifests.

### CI config commands

Look for tool invocations in CI pipelines (`.gitlab-ci.yml`, `.github/workflows/*.yml`,
Makefile, justfile, Taskfile.yml, etc.):

| Ecosystem | Commands to scan for |
|-----------|---------------------|
| Rust | `cargo clippy`, `cargo fmt`, `rustfmt`, `cargo audit` |
| Python | `ruff`, `mypy`, `black`, `flake8`, `pylint`, `isort`, `pytest` |
| Go | `golangci-lint`, `staticcheck`, `gofumpt` |
| JS/TS | `eslint`, `prettier`, `biome`, `vitest`, `jest` |
| Kubernetes | `kubectl apply`, `kubectl run`, `helm install`, `helm upgrade`, `helm lint`, `helm template`, `helmfile sync`, `helmfile diff`, `helmfile apply`, `kustomize build` |

### Project manifests

Check for tool-specific config files and dev dependency declarations:

| Ecosystem | Where to look |
|-----------|--------------|
| Rust | `.clippy.toml`, `rustfmt.toml`, `.rustfmt.toml`, `Cargo.toml` `[dev-dependencies]` |
| Python | `pyproject.toml` (`[tool.ruff]`, `[tool.mypy]`, `[tool.black]`, `[dependency-groups]`, `[project.optional-dependencies]`), `requirements-dev.txt`, `.flake8`, `setup.cfg` `[flake8]` |
| Go | `.golangci.yml`, `.golangci.yaml`, `.golangci.toml` |
| JS/TS | `package.json` `devDependencies`, `.eslintrc.*`, `.prettierrc.*`, `biome.json` |
| Kubernetes | `Chart.yaml`, `helmfile.yaml`, `helmfile.yml`, `kustomization.yaml`, `values.yaml`, `Chart.lock`, `requirements.yaml`, `.helmignore` |

For ecosystems not listed here, apply the same pattern: check CI scripts for tool
invocations, then check ecosystem-standard config files and dev dependency sections.

## Install scope rule

A tool can be installed either **globally** in the Dockerfile or **project-managed** via the
ecosystem's package manager (e.g., `cargo install`, `pip install -e '.[dev]'`, `npm install`).

When a tool appears in both CI commands and project dev dependencies, the project dependency
takes precedence — skip the global Dockerfile install. The project's package manager will
handle it at `devcontainer.json` `postCreateCommand` time or when the developer runs the
install step.

Exception: tools that are language toolchain components (e.g., Rust's clippy and rustfmt via
`rustup`) are always installed globally regardless of project dependency files — they are
managed by the toolchain, not the package manager.

Only install globally in the Dockerfile when the tool is used in CI but **not** declared in
project dev dependencies.

## Dockerfile patterns

Place dev tool installations after system packages and before runtime configuration — layer
position 4 (versioned tool installations) from [dockerfile.md](dockerfile.md).

### Rust: clippy and rustfmt

Clippy and rustfmt are rustup components bundled with the toolchain. No separate version
pinning or Renovate annotation needed.

```dockerfile
# ── Rust dev tools (bundled with toolchain) ──────────────────────────
RUN rustup component add clippy rustfmt
```

Skip if the base image already includes these components (many `rust:` images do).

### Python: linters and formatters

Use `pip install` with `pypi` datasource Renovate annotations. Skip any tool that appears
in `pyproject.toml` dependency groups or `requirements-dev.txt` — the project manages those.

```dockerfile
# ── Python dev tools ─────────────────────────────────────────────────
# renovate: datasource=pypi depName=ruff
ARG RUFF_VERSION="0.8.6"
# renovate: datasource=pypi depName=mypy
ARG MYPY_VERSION="1.14.1"

RUN pip install --no-cache-dir \
    ruff==${RUFF_VERSION} \
    mypy==${MYPY_VERSION}
```

Alternative — use `pipx` for isolated installs that avoid polluting the project virtualenv:

```dockerfile
# Same ARGs as above — pipx alternative for isolated installs:
RUN pipx install ruff==${RUFF_VERSION} \
    && pipx install mypy==${MYPY_VERSION}
```

### Go: golangci-lint

Always install globally — Go linters are not managed via `go.mod`. Use the official binary
download with `github-releases` datasource Renovate.

```dockerfile
# ── Go dev tools ─────────────────────────────────────────────────────
# renovate: datasource=github-releases depName=golangci/golangci-lint
ARG GOLANGCI_LINT_VERSION="1.63.4"

RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
    | sh -s -- -b /usr/local/bin v${GOLANGCI_LINT_VERSION}
```

### JS/TS: eslint, prettier, biome

Only install globally if the tool is **not** in `package.json` `devDependencies` — this is
rare since JS/TS projects almost always declare these as dev dependencies. When needed:

```dockerfile
# ── JS/TS dev tools (only if not in package.json devDependencies) ────
# renovate: datasource=npm depName=eslint
ARG ESLINT_VERSION="9.17.0"

RUN npm install -g eslint@${ESLINT_VERSION}
```

Use `npm` datasource for Renovate.

### Kubernetes: kubectl, helm, helmfile

Kubernetes tools are always installed globally — they are standalone infrastructure CLIs, not
project-managed dependencies. Install only the tools the project actually uses (detected from
CI commands or project manifests).

```dockerfile
# ── Kubernetes tools ─────────────────────────────────────────────────
# renovate: datasource=github-tags depName=kubernetes/kubernetes extractVersion=^v(?<version>.+)$
ARG KUBECTL_VERSION="1.32.3"

RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client
```

```dockerfile
# renovate: datasource=github-releases depName=helm/helm
ARG HELM_VERSION="3.17.3"

RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" | tar xz -C /tmp \
    && mv /tmp/linux-${arch}/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-${arch} \
    && helm version
```

```dockerfile
# renovate: datasource=github-releases depName=helmfile/helmfile
ARG HELMFILE_VERSION="0.171.0"

RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${arch}.tar.gz" | tar xz -C /tmp \
    && mv /tmp/helmfile /usr/local/bin/helmfile \
    && helmfile version
```

Key points:
- **kubectl** uses `dl.k8s.io` download URLs, not GitHub release assets. Renovate tracks versions via `github-tags` on `kubernetes/kubernetes` with `extractVersion` to strip the `v` prefix — the `kubernetes/kubectl` mirror repo doesn't have usable release tags
- **helm** uses the `get.helm.sh` CDN — extracts from a tar archive with a `linux-<arch>/helm` path
- **helmfile** moved from `roboll/helmfile` to `helmfile/helmfile` — use the current org
- Architecture mapping: `dpkg --print-architecture` produces `amd64`/`arm64` which matches all three tools' naming
- Only install what the project uses — if only `helm` is detected, skip `kubectl` and `helmfile`

### Unlisted ecosystems

For ecosystems not covered above, follow these steps:

1. Identify the tool name and version from CI config.
2. Check if the tool is declared in the project's dev dependencies — if so, skip the global install.
3. Find the canonical install method (binary download, package manager, language toolchain component).
4. Add a Renovate annotation with the appropriate datasource (`github-releases`, `pypi`, `npm`, etc.).
5. Place the install in layer position 4 alongside other versioned tool installations.

## Verification

When dev tools are installed, add to the Phase 7 checklist:

- `<tool> --version` for each globally installed tool — confirms it is on `PATH` and runnable
- For project-managed tools, verify the project install step succeeds and the tool is available
