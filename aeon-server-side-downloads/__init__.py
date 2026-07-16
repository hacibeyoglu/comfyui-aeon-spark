# aeon-server-side-downloads
# Registers a lightweight server-side download endpoint and serves the JS
# extension that intercepts ComfyUI's "Missing Models → Download" buttons,
# routing downloads to the server volume instead of the client browser.
#
# Critical for remote-accessed Sparks where the web UI is on one machine and
# the workspace volume is on another.

import logging
import os
import threading
import urllib.error
import urllib.request

from aiohttp import web

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

# Tells ComfyUI to serve everything in ./web/ as static frontend assets and
# auto-register .js files there as ComfyUI extensions.
WEB_DIRECTORY = "./web"

_LOG = "[aeon-server-side-downloads]"

# Simple in-memory status map so the JS can poll if needed.
_download_status: dict = {}


def _download_worker(url: str, dest_path: str, filename: str) -> None:
    """Download url → dest_path in a daemon thread; honours HF_TOKEN."""
    _download_status[filename] = "queued"
    tmp = dest_path + ".tmp"
    try:
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        headers: dict = {}
        hf_token = os.environ.get("HF_TOKEN", "").strip()
        if hf_token and "huggingface.co" in url:
            headers["Authorization"] = f"Bearer {hf_token}"

        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=60) as resp, open(tmp, "wb") as fh:
            while True:
                chunk = resp.read(1 << 20)  # 1 MiB
                if not chunk:
                    break
                fh.write(chunk)
        os.replace(tmp, dest_path)
        _download_status[filename] = "ok"
        logging.info(f"{_LOG} ✓ downloaded {filename}")
    except urllib.error.HTTPError as exc:
        _download_status[filename] = f"error: HTTP {exc.code}"
        logging.error(f"{_LOG} HTTP {exc.code} downloading {url}")
    except Exception as exc:
        _download_status[filename] = f"error: {exc}"
        logging.error(f"{_LOG} failed to download {url}: {exc}")
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def _register_routes() -> None:
    try:
        from server import PromptServer  # noqa: PLC0415
        import folder_paths              # noqa: PLC0415

        routes = PromptServer.instance.routes

        @routes.post("/aeon/download_model")
        async def aeon_download_model(request: web.Request) -> web.Response:
            try:
                data = await request.json()
            except Exception:
                return web.Response(status=400, text="invalid JSON")

            url       = (data.get("url")       or "").strip()
            filename  = (data.get("filename")  or data.get("name") or "").strip()
            directory = (data.get("directory") or "").strip()

            if not url or not filename:
                return web.Response(status=400, text="url and filename are required")

            # Reject path-traversal attempts.
            bad_name = os.sep in filename or (os.altsep and os.altsep in filename) or ".." in filename
            bad_dir  = ".." in directory or directory.startswith(("/", "\\"))
            if bad_name or bad_dir:
                return web.Response(status=400, text="invalid filename or directory")

            models_base = folder_paths.models_dir
            dest_dir    = os.path.join(models_base, directory) if directory else models_base
            dest_path   = os.path.join(dest_dir, filename)

            if os.path.exists(dest_path):
                return web.json_response({"ok": True, "status": "already_exists"})

            if _download_status.get(filename) == "queued":
                return web.json_response({"ok": True, "status": "already_queued"})

            threading.Thread(
                target=_download_worker,
                args=(url, dest_path, filename),
                daemon=True,
                name=f"aeon-dl-{filename}",
            ).start()

            return web.json_response({"ok": True, "status": "queued", "path": dest_path})

        @routes.get("/aeon/download_model/status")
        async def aeon_download_status(request: web.Request) -> web.Response:
            filename = request.rel_url.query.get("filename", "")
            return web.json_response({
                "filename": filename,
                "status": _download_status.get(filename, "unknown"),
            })

        logging.info(f"{_LOG} download endpoint ready → POST /aeon/download_model")

    except Exception as exc:
        logging.warning(f"{_LOG} could not register routes: {exc}")


_register_routes()

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
