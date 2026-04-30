// aeon-server-side-downloads
// ──────────────────────────────────────────────────────────────────────────
// Intercepts the new ComfyUI 0.20+ "Workflow Overview → Errors → Missing
// Models → Download all / Download" buttons and the older
// "Missing Models" dialog buttons, and routes downloads through the
// server-side Manager install API instead of triggering a browser download.
//
// The default core-ComfyUI behavior calls window.open(url) / <a download>
// which downloads to the *client* machine — useless for remote-accessed
// servers like a DGX Spark that you SSH into.
//
// What this script does:
//   - Captures clicks on download anchors and buttons inside the missing-
//     models panel (matched by surrounding text + structure)
//   - Pulls the model URL+directory metadata from the workflow's
//     properties.models[] arrays on each loader node
//   - POSTs to /v2/manager/queue/batch with install_model action
//   - Calls /v2/manager/queue/start to drain the queue
//   - Shows a small toast confirming the file is going to the server volume
//
// If the server-side route isn't reachable for any reason, it falls back
// silently to the original browser download — never breaks worse than today.
// ──────────────────────────────────────────────────────────────────────────

import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";

const LOG_PREFIX = "[aeon-server-side-downloads]";

// Try to extract a model's {name, url, directory} from a clicked element by
// walking up the DOM and reading data attributes / text / nearby button info.
function extractModelFromElement(el) {
    if (!el) return null;

    // Strategy 1: anchor with href
    const anchor = el.closest("a[href]");
    if (anchor && anchor.href) {
        const url = anchor.href;
        // Try to get the filename from the URL or surrounding text
        const filename = anchor.dataset.filename
            || (url.split("/").pop() || "").split("?")[0]
            || null;
        return filename ? { url, name: filename } : null;
    }

    // Strategy 2: button inside a row that has model metadata in dataset
    const row = el.closest("[data-model-name], [data-name], [role='row']");
    if (row && (row.dataset.modelName || row.dataset.name)) {
        return {
            name: row.dataset.modelName || row.dataset.name,
            url: row.dataset.url,
            directory: row.dataset.directory,
        };
    }

    return null;
}

// Walk every node in every graph (incl. subgraph definitions) and collect
// {name, url, directory} entries from properties.models[] arrays.
function collectMissingModelsFromWorkflow() {
    const out = [];
    const seen = new Set();

    function walkNode(node) {
        const models = node?.properties?.models;
        if (Array.isArray(models)) {
            for (const m of models) {
                if (!m?.name || !m?.url || !m?.directory) continue;
                const key = `${m.directory}/${m.name}`;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ name: m.name, url: m.url, directory: m.directory });
            }
        }
    }

    function walkGraph(graph) {
        if (!graph) return;
        const nodes = graph._nodes || graph.nodes || [];
        for (const n of nodes) {
            walkNode(n);
            // Recurse into subgraph if this node is a subgraph host
            if (n.subgraph) walkGraph(n.subgraph);
        }
    }

    try {
        walkGraph(app.graph);
        const root = app.graph?.rootGraph;
        if (root && root !== app.graph) walkGraph(root);
    } catch (e) {
        console.warn(LOG_PREFIX, "graph walk failed:", e);
    }
    return out;
}

// POST to Manager's batch install API; falls back gracefully on error.
async function queueServerSideInstall(models) {
    if (!models?.length) return { ok: false, reason: "no models" };

    try {
        const res = await api.fetchApi("/v2/manager/queue/batch", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ install_model: models }),
        });
        if (!res.ok) {
            return { ok: false, reason: `HTTP ${res.status}` };
        }
        // Kick the queue processor
        await api.fetchApi("/v2/manager/queue/start", { method: "POST" });
        return { ok: true, count: models.length };
    } catch (e) {
        return { ok: false, reason: String(e) };
    }
}

// Quick toast helper — uses ComfyUI's app.extensionManager if available,
// otherwise falls back to a plain DOM banner.
function toast(message, severity = "info") {
    try {
        if (app.extensionManager?.toast?.add) {
            app.extensionManager.toast.add({
                severity,
                summary: "Server-side download",
                detail: message,
                life: 8000,
            });
            return;
        }
    } catch {}
    // Fallback
    const banner = document.createElement("div");
    banner.textContent = message;
    Object.assign(banner.style, {
        position: "fixed", bottom: "20px", right: "20px",
        background: severity === "error" ? "#7f1d1d" : "#1e3a8a",
        color: "white", padding: "12px 16px", borderRadius: "6px",
        zIndex: 99999, fontFamily: "system-ui, sans-serif", fontSize: "13px",
        boxShadow: "0 4px 12px rgba(0,0,0,0.3)",
    });
    document.body.appendChild(banner);
    setTimeout(() => banner.remove(), 6000);
}

// Look at a clicked DOM node and decide whether it's the missing-models
// "Download all" / "Download" button. We match by text + nearby structure
// to be robust against minified class names.
function isMissingModelDownloadClick(target) {
    if (!target) return false;
    const el = target.closest("button, a");
    if (!el) return false;

    const text = (el.textContent || "").trim().toLowerCase();
    const isDownloadVerb =
        text === "download" ||
        text === "download all" ||
        text === "download available" ||
        text.startsWith("download all (") ||
        text.startsWith("download (");

    if (!isDownloadVerb) {
        // Also catch the bare-icon variant (just the lucide download glyph)
        const hasDownloadIcon = !!el.querySelector(
            "[class*='lucide--download'], [class*='icon-download']"
        );
        if (!hasDownloadIcon) return false;
    }

    // Confirm we're inside a missing-models / errors panel context
    const panel = el.closest(
        "[data-section*='missing'],[class*='missing-models']," +
            "[class*='MissingModels'],[class*='missingModels']," +
            "[class*='right-side-panel'],[class*='workflow-overview']," +
            "[class*='WorkflowOverview']"
    );
    if (panel) return true;

    // Last-ditch: if there's a header with "Missing Models" nearby
    let cursor = el;
    for (let i = 0; i < 6 && cursor; i++) {
        cursor = cursor.parentElement;
        if (!cursor) break;
        if (/missing models/i.test(cursor.textContent || "")) {
            // Make sure it's a proximate header and not the whole document
            if (cursor.textContent.length < 4000) return true;
        }
    }
    return false;
}

let interceptInFlight = false;

async function onCaptureClick(e) {
    // Only intercept primary-button clicks
    if (e.button !== undefined && e.button !== 0) return;
    if (interceptInFlight) return;
    if (!isMissingModelDownloadClick(e.target)) return;

    // Try to identify which specific model was clicked (Download per-row),
    // otherwise treat it as Download all and pull every entry.
    const single = extractModelFromElement(e.target);
    let queue;
    if (single?.name && single?.url && single?.directory) {
        queue = [single];
    } else {
        queue = collectMissingModelsFromWorkflow();
    }

    if (!queue.length) {
        // Nothing actionable; let the original handler run (browser download).
        return;
    }

    // We're going to handle this — block the original browser download.
    e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
    interceptInFlight = true;

    toast(
        `Queueing ${queue.length} file${queue.length === 1 ? "" : "s"} for ` +
            `server-side download (saved to your Spark, not your browser)…`,
        "info"
    );

    const result = await queueServerSideInstall(queue);
    interceptInFlight = false;

    if (result.ok) {
        toast(
            `✓ Server-side install started for ${result.count} file` +
                `${result.count === 1 ? "" : "s"}. Watch progress in ` +
                `Manager → Install Queue.`,
            "success"
        );
    } else {
        toast(
            `⚠ Server-side install API unreachable (${result.reason}). ` +
                `Falling back to browser download — please move the file ` +
                `into your workspace volume manually.`,
            "warn"
        );
        // Re-trigger the original click without our interceptor active
        const orig = e.target.closest("button, a");
        if (orig && typeof orig.click === "function") {
            // Disable our interceptor for this one synchronous call
            const old = onCaptureClick;
            document.removeEventListener("click", old, { capture: true });
            try { orig.click(); } finally {
                document.addEventListener("click", old, { capture: true });
            }
        }
    }
}

app.registerExtension({
    name: "aeon.server-side-downloads",
    init() {
        document.addEventListener("click", onCaptureClick, { capture: true });
        console.log(
            LOG_PREFIX,
            "active — Workflow-Overview download buttons routed server-side"
        );
    },
});
