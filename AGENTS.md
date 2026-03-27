# AGENTS.md

## First instruction: prefer git worktrees

- Default to using a **git worktree** for non-trivial tasks instead of working directly in the main checkout.
- Create or reuse an existing worktree before making changes whenever the task will touch multiple files, require iterative verification, or may leave the branch in a temporary broken state.
- Complete the work inside the worktree first, and **merge it back into the main repository only after the task is finished and verified**.
- If a worktree-specific workflow is in effect, keep notes, verification, and commits isolated to that worktree until merge time.
- Only skip worktree usage when the user explicitly says to work in-place, or when the task is truly trivial and isolated.

This repository is `luci-app-homeproxy`, an OpenWrt/LuCI package for configuring HomeProxy and its sing-box integration.

This guide is for coding agents working in this repo.
It is based on checked-in files, not assumed toolchains.

## What this repo is

- Single-package OpenWrt/LuCI repo, not a Node/Python monorepo.
- Packaging metadata: `Makefile`
- LuCI frontend: `htdocs/luci-static/resources/`
- Installed runtime files: `root/`
- Translations: `po/`
- CI and maintenance scripts: `.github/`

Key files and directories:

- `Makefile`
- `htdocs/luci-static/resources/homeproxy.js`
- `htdocs/luci-static/resources/view/homeproxy/client.js`
- `htdocs/luci-static/resources/view/homeproxy/server.js`
- `htdocs/luci-static/resources/view/homeproxy/node.js`
- `htdocs/luci-static/resources/view/homeproxy/status.js`
- `root/etc/config/homeproxy`
- `root/etc/homeproxy/scripts/`
- `root/usr/share/rpcd/ucode/luci.homeproxy`
- `root/etc/init.d/homeproxy`
- `.github/build-ipk.sh`
- `.github/workflows/build-ipk.yml`

## Existing editor/agent rules

Checked and not found:

- previous top-level `AGENTS.md`
- `.cursorrules`
- `.cursor/rules/`
- `.github/copilot-instructions.md`

There are GitHub issue templates under `.github/ISSUE_TEMPLATE/`, but no Cursor or Copilot rule files.

## Build, lint, and test commands

There is no `package.json`, no repo-defined lint config, and no repo-defined test runner.
Treat the CI workflow and package scripts as the source of truth.

### Canonical build commands

From repo root:

```sh
fakeroot bash .github/build-ipk.sh apk snapshot
fakeroot bash .github/build-ipk.sh ipk snapshot
```

For release-style versioning, replace `snapshot` with `release`.

These commands package the repo into `.apk` and `.ipk` artifacts using `.github/build-ipk.sh`.

### CI setup commands worth knowing

Defined in `.github/workflows/build-ipk.yml`:

```sh
meson setup build -Db_lto=true -Dcompressed-help=false -Ddocs=disabled -Dhelp=enabled -Dlua_version=5.1 -Ddefault_library=static -Durl_backend=wget -Dzstd=false -Dpython=disabled -Dtests=disabled -Dcrypto_backend=openssl
ninja -C build
meson install -C build --strip
make po2lmo
```

These build helper tools in CI. They are not a frontend compile pipeline for this repo.

### Translation maintenance

```sh
bash .github/rescan-translation.sh
```

Run this when translated UI strings change.
Current packaging in `.github/build-ipk.sh` compiles `po/zh_Hans/homeproxy.po` into `homeproxy.zh-cn.lmo`.

### Resource maintenance

```sh
bash .github/update-geodata.sh
```

Use only when intentionally updating bundled resource lists.

### Lint commands

No repo-defined lint command was found.

### Typecheck commands

No repo-defined typecheck command was found.

### Test commands

No repo-defined test framework or test command was found.

### Running a single test

Single-test execution is **not available** from current repo tooling because no test runner is configured.

If tests are added later, update this file with both the full-suite and single-test commands.

## Development expectations

- Prefer minimal, package-safe changes.
- Treat `.github/workflows/build-ipk.yml` as the most reliable build reference.
- Keep frontend, UCI schema, rpcd handlers, and generated config logic aligned.
- When changing UI text, remember `_()` translation wrappers and translation maintenance.
- When changing UCI option names or section structure, inspect both frontend and backend usage first.

## Frontend code style

Frontend code here is LuCI JavaScript, not ESM and not TypeScript.

Observed file structure:

- SPDX/copyright header
- `'use strict';`
- LuCI `'require ...';` directives
- `return view.extend({ ... })` for pages
- `return baseclass.extend({ ... })` for shared helpers

### Imports / requires

- Use LuCI `'require ...';` directives at the top of the file.
- Keep core LuCI requires first, then local/shared aliases such as `'require homeproxy as hp';`.
- Follow the ordering already used in the file you edit.
- Do not convert files to `import` / `export` module syntax.

### Formatting

- Match surrounding file style exactly.
- Use tabs where the existing file uses tabs.
- Keep comments, spacing, and line breaks consistent with neighboring LuCI form code.
- Preserve section comments that separate protocol/config blocks.

### Naming

- Preserve existing UCI keys and option names exactly.
- `snake_case` is common for local variables and config-related names.
- Use descriptive helper function names like `getServiceStatus`, `renderStatus`, and `parseShareLink`.
- Backend constants may use upper snake case.

### Values and validation

- This repo has no static type system; be explicit about object shapes.
- Preserve string-valued booleans like `'1'` and `'0'` when interacting with UCI.
- Keep values in the string forms expected by LuCI widgets and config storage.
- Form validators should return `true` on success or a translated error string on failure.

### LuCI UI patterns

- Use `form.Map`, `NamedSection`, `TypedSection`, `GridSection`, and `SectionValue` the way current files do.
- Prefer shared helpers from `homeproxy.js` instead of duplicating validators/utilities.
- Use `depends(...)` for conditional UI.
- Use `o.validate = function(...) { ... }` or `L.bind(...)` consistently with nearby code.
- Use `poll.add(...)` for refresh loops.
- Use `ui.createHandlerFn(...)` for interactive handlers.
- Wrap user-visible strings in `_()`.

### RPC and async handling

- Declare RPC methods with `rpc.declare({ ... })`.
- Use `L.resolveDefault(...)` when the UI should degrade gracefully.
- Keep response handling defensive; existing code frequently guards missing fields.
- For interactive failures, prefer visible feedback such as `ui.addNotification(...)`.

### Error handling

- Do not add new empty `catch` blocks.
- Empty `catch` blocks do exist in current frontend files such as `client.js`, `node.js`, and `server.js`, but new code should avoid adding more.
- If swallowing an error is necessary, make the fallback behavior explicit.

## Backend and packaging guidance

- Keep UCI schema changes synchronized with frontend forms, rpcd code, and config-generation scripts.
- Preserve `Makefile` structure as OpenWrt package metadata, not a generic make-based build.
- Preserve filesystem paths under `root/`; they map directly into the installed package.
- Be careful with service, firewall, dnsmasq, and runtime-script changes; they affect real router behavior.
- In shell scripts, follow existing fail-fast patterns where present, such as `set -o errexit` and `set -o pipefail`.

## Files to inspect before making changes

For frontend changes:

- `htdocs/luci-static/resources/homeproxy.js`
- the relevant file under `htdocs/luci-static/resources/view/homeproxy/`
- `root/etc/config/homeproxy`

For backend/RPC changes:

- `root/etc/init.d/homeproxy`
- `root/usr/share/rpcd/ucode/luci.homeproxy`
- `root/etc/homeproxy/scripts/homeproxy.uc`
- `root/etc/homeproxy/scripts/generate_client.uc`
- `root/etc/homeproxy/scripts/generate_server.uc`
- related generator scripts under `root/etc/homeproxy/scripts/`

For packaging/release changes:

- `Makefile`
- `.github/build-ipk.sh`
- `.github/workflows/build-ipk.yml`

## Practical do / do-not guidance

- Do not assume npm, pnpm, yarn, pytest, cargo, or other absent workflows exist.
- Do not introduce unrelated framework tooling just because it is common elsewhere.
- Do not replace LuCI module conventions with modern frontend abstractions.
- Prefer small diffs and consistency with neighboring code over broad rewrites.
- If you add commands, tests, or automation, update this file so future agents inherit the real workflow.
