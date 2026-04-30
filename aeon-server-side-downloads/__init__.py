# aeon-server-side-downloads
# JS-only extension that intercepts the new ComfyUI Workflow-Overview
# "Missing Models -> Download all/Download" buttons and routes the download
# through the server-side Manager install API instead of letting the browser
# pull the file to the client machine.
#
# Critical for remote-accessed Sparks where the web UI is on one machine and
# the workspace volume is on another.

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

# Tells ComfyUI to serve everything in ./web/ as static frontend assets and
# auto-register .js files there as ComfyUI extensions.
WEB_DIRECTORY = "./web"

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
