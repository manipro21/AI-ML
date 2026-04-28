#!/bin/bash
set -euo pipefail

cat > /testbed/solution_patch.diff << '__SOLUTION__'
diff --git a/src/fastmcp/server/providers/filesystem.py b/src/fastmcp/server/providers/filesystem.py
index 774021d..6c69272 100644
--- a/src/fastmcp/server/providers/filesystem.py
+++ b/src/fastmcp/server/providers/filesystem.py
@@ -28,8 +28,9 @@ Example:
 from __future__ import annotations
 
 import asyncio
-from collections.abc import Sequence
+from collections.abc import Callable, Sequence
 from pathlib import Path
+from typing import Any
 
 from fastmcp.prompts.base import Prompt
 from fastmcp.resources.base import Resource
@@ -96,16 +97,20 @@ class FileSystemProvider(LocalProvider):
         self._warned_files: dict[Path, float] = {}
         # Lock for serializing reload operations (created lazily)
         self._reload_lock: asyncio.Lock | None = None
+        # Generation counter to deduplicate concurrent reloads
+        self._reload_generation: int = 0
 
         # Always load once at init to catch errors early
         self._load_components()
 
     def _load_components(self) -> None:
         """Discover and register all components from the filesystem."""
-        # Clear existing components if reloading
         if self._loaded:
             self._components.clear()
 
+        if not self._root.exists():
+            logger.warning("FileSystemProvider root does not exist: %s", self._root)
+
         result = discover_and_import(self._root)
 
         # Log warnings for failed files (only once per file version)
@@ -154,73 +159,67 @@ class FileSystemProvider(LocalProvider):
         else:
             logger.debug("Ignoring unknown component type: %r", type(component))
 
-    async def _ensure_loaded(self) -> None:
-        """Ensure components are loaded, reloading if in reload mode.
+    async def _with_reload(self, coro_fn: Callable[..., Any], *args: Any) -> Any:
+        """Acquire the reload lock, reload if needed, then run *coro_fn*.
+
+        Holding the lock across both the reload and the read prevents
+        concurrent readers from seeing a partially-rebuilt ``_components``
+        dict (the ``clear()`` + re-register window).
 
-        Uses a lock to serialize concurrent reload operations and runs
-        filesystem I/O off the event loop using asyncio.to_thread.
+        A generation counter deduplicates concurrent reload requests:
+        if another caller already reloaded while we waited for the lock,
+        we skip the redundant reload.
         """
         if not self._reload and self._loaded:
-            return
+            return await coro_fn(*args)
 
         # Create lock lazily (can't create in __init__ without event loop)
         if self._reload_lock is None:
             self._reload_lock = asyncio.Lock()
 
+        generation_before = self._reload_generation
+
         async with self._reload_lock:
-            # Double-check after acquiring lock
-            if self._reload or not self._loaded:
+            if not self._loaded or (
+                self._reload and self._reload_generation == generation_before
+            ):
                 await asyncio.to_thread(self._load_components)
+                self._reload_generation += 1
+            return await coro_fn(*args)
 
     # Override provider methods to support reload mode
 
     async def _list_tools(self) -> Sequence[Tool]:
-        """Return all tools, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._list_tools()
+        return await self._with_reload(super()._list_tools)
 
     async def _get_tool(
         self, name: str, version: VersionSpec | None = None
     ) -> Tool | None:
-        """Get a tool by name, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._get_tool(name, version)
+        return await self._with_reload(super()._get_tool, name, version)
 
     async def _list_resources(self) -> Sequence[Resource]:
-        """Return all resources, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._list_resources()
+        return await self._with_reload(super()._list_resources)
 
     async def _get_resource(
         self, uri: str, version: VersionSpec | None = None
     ) -> Resource | None:
-        """Get a resource by URI, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._get_resource(uri, version)
+        return await self._with_reload(super()._get_resource, uri, version)
 
     async def _list_resource_templates(self) -> Sequence[ResourceTemplate]:
-        """Return all resource templates, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._list_resource_templates()
+        return await self._with_reload(super()._list_resource_templates)
 
     async def _get_resource_template(
         self, uri: str, version: VersionSpec | None = None
     ) -> ResourceTemplate | None:
-        """Get a resource template, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._get_resource_template(uri, version)
+        return await self._with_reload(super()._get_resource_template, uri, version)
 
     async def _list_prompts(self) -> Sequence[Prompt]:
-        """Return all prompts, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._list_prompts()
+        return await self._with_reload(super()._list_prompts)
 
     async def _get_prompt(
         self, name: str, version: VersionSpec | None = None
     ) -> Prompt | None:
-        """Get a prompt by name, reloading if in reload mode."""
-        await self._ensure_loaded()
-        return await super()._get_prompt(name, version)
+        return await self._with_reload(super()._get_prompt, name, version)
 
     def __repr__(self) -> str:
         return f"FileSystemProvider(root={self._root!r}, reload={self._reload})"
diff --git a/src/fastmcp/server/providers/filesystem_discovery.py b/src/fastmcp/server/providers/filesystem_discovery.py
index 5dc15e1..db8e0ce 100644
--- a/src/fastmcp/server/providers/filesystem_discovery.py
+++ b/src/fastmcp/server/providers/filesystem_discovery.py
@@ -8,6 +8,8 @@ This module provides functions to:
 
 from __future__ import annotations
 
+import contextlib
+import hashlib
 import importlib.util
 import sys
 from dataclasses import dataclass, field
@@ -68,10 +70,16 @@ def _is_package_dir(directory: Path) -> bool:
     return (directory / "__init__.py").exists()
 
 
-def _find_package_root(file_path: Path) -> Path | None:
+def _find_package_root(file_path: Path, stop_at: Path | None = None) -> Path | None:
     """Find the root of the package containing this file.
 
-    Walks up the directory tree until we find a directory without __init__.py.
+    Walks up the directory tree until we find a directory without __init__.py,
+    but never above stop_at (the provider root). This prevents escaping into
+    ancestor packages when the provider is nested inside a larger Python project.
+
+    Args:
+        file_path: Path to the Python file.
+        stop_at: Do not walk above this directory. Typically the provider root.
 
     Returns:
         The package root directory, or None if not in a package.
@@ -80,6 +88,8 @@ def _find_package_root(file_path: Path) -> Path | None:
     package_root = None
 
     while current != current.parent:  # Stop at filesystem root
+        if stop_at is not None and current == stop_at.parent:
+            break  # Don't escape above the provider root
         if _is_package_dir(current):
             package_root = current
             current = current.parent
@@ -106,15 +116,22 @@ def _compute_module_name(file_path: Path, package_root: Path) -> str:
     return ".".join(parts)
 
 
-def import_module_from_file(file_path: Path) -> ModuleType:
+def import_module_from_file(
+    file_path: Path, provider_root: Path | None = None
+) -> ModuleType:
     """Import a Python file as a module.
 
     If the file is part of a package (directory has __init__.py), imports
     it as a proper package member (relative imports work). Otherwise,
     imports directly using spec_from_file_location.
 
+    sys.path is modified only for the duration of the import and restored
+    immediately after, so no permanent pollution occurs.
+
     Args:
         file_path: Path to the Python file.
+        provider_root: The provider's root directory. Prevents package root
+            discovery from walking above this boundary into ancestor packages.
 
     Returns:
         The imported module.
@@ -123,22 +140,24 @@ def import_module_from_file(file_path: Path) -> ModuleType:
         ImportError: If the module cannot be imported.
     """
     file_path = file_path.resolve()
+    if provider_root is not None:
+        provider_root = provider_root.resolve()
 
     # Check if this file is part of a package
-    package_root = _find_package_root(file_path)
+    package_root = _find_package_root(file_path, stop_at=provider_root)
 
     if package_root is not None:
         # Import as part of a package
         module_name = _compute_module_name(file_path, package_root)
 
-        # Ensure package root's parent is in sys.path
+        # Temporarily add package root's parent to sys.path for the import
         package_parent = str(package_root.parent)
-        if package_parent not in sys.path:
+        path_added = package_parent not in sys.path
+        if path_added:
             sys.path.insert(0, package_parent)
 
-        # Import using standard import machinery
-        # If already imported, reload to pick up changes (for reload mode)
         try:
+            # If already imported, reload to pick up changes (for reload mode)
             if module_name in sys.modules:
                 return importlib.reload(sys.modules[module_name])
             return importlib.import_module(module_name)
@@ -146,30 +165,71 @@ def import_module_from_file(file_path: Path) -> ModuleType:
             raise ImportError(
                 f"Failed to import {module_name} from {file_path}: {e}"
             ) from e
+        finally:
+            if path_added:
+                with contextlib.suppress(ValueError):
+                    sys.path.remove(package_parent)
     else:
         # Import directly using spec_from_file_location
-        module_name = file_path.stem
-
-        # Ensure parent directory is in sys.path for imports
+        stem = file_path.stem
         parent_dir = str(file_path.parent)
-        if parent_dir not in sys.path:
-            sys.path.insert(0, parent_dir)
 
-        spec = importlib.util.spec_from_file_location(module_name, file_path)
-        if spec is None or spec.loader is None:
-            raise ImportError(f"Cannot load spec for {file_path}")
+        # Determine the sys.modules key. Prefer the bare stem (so that sibling
+        # imports like `import helpers` resolve correctly), but fall back to a
+        # private collision-safe key if the bare stem is already claimed by
+        # something else (stdlib, a third-party package, or another provider file
+        # from a different directory).
+        existing = sys.modules.get(stem)
+        if existing is not None and getattr(existing, "__file__", None) != str(
+            file_path
+        ):
+            module_name = f"_fastmcp_{stem}_{hashlib.sha1(str(file_path).encode()).hexdigest()[:12]}"
+        else:
+            module_name = stem
 
-        module = importlib.util.module_from_spec(spec)
-        sys.modules[module_name] = module
+        # Temporarily add parent to sys.path so module-level sibling imports resolve.
+        # Safe to remove after exec_module: all top-level imports are resolved by then,
+        # and sibling files imported as side effects are already in sys.modules.
+        path_added = parent_dir not in sys.path
+        if path_added:
+            sys.path.insert(0, parent_dir)
 
         try:
-            spec.loader.exec_module(module)
-        except Exception as e:
-            # Clean up sys.modules on failure
-            sys.modules.pop(module_name, None)
-            raise ImportError(f"Failed to execute module {file_path}: {e}") from e
-
-        return module
+            spec = importlib.util.spec_from_file_location(module_name, file_path)
+            if spec is None or spec.loader is None:
+                raise ImportError(f"Cannot load spec for {file_path}")
+
+            existing = sys.modules.get(module_name)
+            if existing is not None:
+                # Re-exec in place rather than importlib.reload: reload() re-finds
+                # the module by name via sys.path, which fails for private keys
+                # (the file is tool.py, not _fastmcp_tool_xxx.py).
+                existing.__spec__ = spec
+                existing.__loader__ = spec.loader
+                existing.__file__ = str(file_path)
+                try:
+                    spec.loader.exec_module(existing)
+                except Exception as e:
+                    raise ImportError(
+                        f"Failed to reload module {file_path}: {e}"
+                    ) from e
+                return existing
+
+            module = importlib.util.module_from_spec(spec)
+            sys.modules[module_name] = module
+
+            try:
+                spec.loader.exec_module(module)
+            except Exception as e:
+                # Clean up sys.modules on failure
+                sys.modules.pop(module_name, None)
+                raise ImportError(f"Failed to execute module {file_path}: {e}") from e
+
+            return module
+        finally:
+            if path_added:
+                with contextlib.suppress(ValueError):
+                    sys.path.remove(parent_dir)
 
 
 def extract_components(module: ModuleType) -> list[FastMCPComponent]:
@@ -316,10 +376,7 @@ def discover_and_import(root: Path) -> DiscoveryResult:
 
     for file_path in discover_files(root):
         try:
-            module = import_module_from_file(file_path)
-        except ImportError as e:
-            result.failed_files[file_path] = str(e)
-            continue
+            module = import_module_from_file(file_path, provider_root=root)
         except Exception as e:
             result.failed_files[file_path] = str(e)
             continue
__SOLUTION__

cd /testbed
patch --fuzz=5 -p1 -i /testbed/solution_patch.diff
