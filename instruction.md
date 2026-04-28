The FastMCP repository at `/testbed` ships a `FileSystemProvider` that discovers Python files in a directory tree, imports them as Python modules, and registers any MCP tools, resources, and prompts they define. When constructed with `reload=True`, the provider re-imports the directory on every request for development convenience.

Six correctness bugs have been reported against this component. Find and fix all of them.

## Affected files

- `src/fastmcp/server/providers/filesystem_discovery.py` — bugs 1, 2, 3
- `src/fastmcp/server/providers/filesystem.py` — bugs 4, 5, 6

## Bug reports

**Bug 1** — After any call to `import_module_from_file` completes, `sys.path` contains more entries than it did before the call. This happens in both package mode (file inside a directory with `__init__.py`) and non-package mode (flat file). The fix must ensure `sys.path` is the same length before and after every call to `import_module_from_file`, in both modes, even when the import raises an exception.

**Bug 2** — Importing a provider file whose name matches a stdlib module (e.g. a file named `json.py`) causes subsequent `import json` calls elsewhere in the process to return the provider file instead of the real stdlib module. After the fix, importing any provider file via `import_module_from_file` must not replace an already-registered module in `sys.modules`.

**Bug 3** — `_find_package_root` has no upper bound on how far up the directory tree it walks. After the fix, `_find_package_root` must accept a boundary argument and must not walk above it. The `import_module_from_file` function must accept a `provider_root` parameter and pass it as the boundary. The `discover_and_import` function must pass its `root` as the `provider_root` when calling `import_module_from_file`.

**Bug 4** — With `reload=True`, concurrent calls to reader methods such as `_list_tools()` occasionally return empty results even though the provider has tools registered. This must hold even under heavy concurrency (8+ simultaneous callers). After the fix, no concurrent caller must ever observe an empty or partially-rebuilt components dict during a reload.

**Bug 5** — With `reload=True`, N concurrent requests each trigger a full `_load_components` call, even when another concurrent caller just completed a reload. After the fix, concurrent reload requests must be deduplicated: a caller that waited for the lock must skip `_load_components` if the lock holder already completed a reload.

**Bug 6** — When `FileSystemProvider._load_components` runs with a root path that does not exist, it silently produces zero components with no warning. After the fix, `_load_components` must log a warning when `self._root` does not exist, so that typos in the root path are visible.