const DATABASE_NAME = "pictoiq-local";
const DATABASE_VERSION = 1;
const STORE_NAME = "assets";
const MAX_HASH_SIZE = 100 * 1024 * 1024;

const state = {
  assets: [],
  previews: new Map(),
  view: "overview",
  query: "",
  busy: false,
  cancelRequested: false,
};

const elements = {
  grid: document.querySelector("#photo-grid"),
  empty: document.querySelector("#empty-state"),
  noResults: document.querySelector("#no-results"),
  picker: document.querySelector("#photo-picker"),
  scanButton: document.querySelector("#scan-button"),
  scanLabel: document.querySelector("#scan-button-label"),
  toast: document.querySelector("#toast"),
  modal: document.querySelector("#info-modal"),
};

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, DATABASE_VERSION);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE_NAME, { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function readAssets() {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, "readonly");
    const request = transaction.objectStore(STORE_NAME).getAll();
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    transaction.oncomplete = () => database.close();
    transaction.onerror = () => reject(transaction.error);
  });
}

async function saveAssets(assets) {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, "readwrite");
    const store = transaction.objectStore(STORE_NAME);
    for (const asset of assets) store.put(asset);
    transaction.oncomplete = () => {
      database.close();
      resolve();
    };
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error ?? new Error("The local library could not be saved."));
  });
}

async function deleteAsset(id) {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, "readwrite");
    transaction.objectStore(STORE_NAME).delete(id);
    transaction.oncomplete = () => {
      database.close();
      resolve();
    };
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error ?? new Error("The library entry could not be removed."));
  });
}

function formatBytes(bytes) {
  if (bytes === 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 ? 0 : 1)} ${units[unit]}`;
}

function formatDate(timestamp) {
  if (!timestamp) return "Date unknown";
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(timestamp);
}

function duplicateGroups() {
  const groups = new Map();
  for (const asset of state.assets) {
    if (!asset.sha256) continue;
    const group = groups.get(asset.sha256) ?? [];
    group.push(asset);
    groups.set(asset.sha256, group);
  }
  return [...groups.values()].filter((group) => group.length > 1);
}

function duplicateAssetIds() {
  return new Set(duplicateGroups().flatMap((group) => group.map((asset) => asset.id)));
}

function reclaimableBytes() {
  return duplicateGroups().reduce((total, group) => {
    const size = group[0].size;
    return total + size * (group.length - 1);
  }, 0);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]);
}

function showToast(message) {
  elements.toast.textContent = message;
  elements.toast.classList.add("show");
  clearTimeout(showToast.timeout);
  showToast.timeout = setTimeout(() => elements.toast.classList.remove("show"), 3500);
}

function updateSummary() {
  const groups = duplicateGroups();
  const duplicatedAssets = groups.reduce((total, group) => total + group.length, 0);
  document.querySelector("#stat-assets").textContent = state.assets.length.toLocaleString();
  document.querySelector("#stat-groups").textContent = groups.length.toLocaleString();
  document.querySelector("#stat-space").innerHTML = `${escapeHtml(formatBytes(reclaimableBytes()))}`;
  document.querySelector("#stat-duplicate-assets").textContent = duplicatedAssets
    ? `${duplicatedAssets} photos in ${groups.length} group${groups.length === 1 ? "" : "s"}`
    : "No duplicates found";
  document.querySelector("#nav-photo-count").textContent = state.assets.length.toLocaleString();
  document.querySelector("#nav-duplicate-count").textContent = groups.length.toLocaleString();
  document.querySelector("#stat-last-scan").textContent = state.assets.length
    ? `Updated ${formatDate(Math.max(...state.assets.map((asset) => asset.scannedAt)))}`
    : "Ready when you are";
}

function getVisibleAssets() {
  const duplicateIds = duplicateAssetIds();
  let assets = state.view === "duplicates"
    ? state.assets.filter((asset) => duplicateIds.has(asset.id))
    : [...state.assets];
  if (state.query) {
    const query = state.query.toLocaleLowerCase();
    assets = assets.filter((asset) => asset.name.toLocaleLowerCase().includes(query));
  }
  const sort = document.querySelector("#sort-select").value;
  if (sort === "name") assets.sort((left, right) => left.name.localeCompare(right.name));
  else if (sort === "largest") assets.sort((left, right) => right.size - left.size);
  else assets.sort((left, right) => right.scannedAt - left.scannedAt);
  return assets;
}

function updateViewText() {
  const duplicateView = state.view === "duplicates";
  document.querySelector("#breadcrumb-current").textContent = duplicateView ? "Exact duplicates" : "Overview";
  document.querySelector("#page-title").innerHTML = duplicateView
    ? 'Same photo, different<br><span>file copy.</span>'
    : 'A calmer camera roll<br>starts <span>right here.</span>';
  document.querySelector("#page-intro").textContent = duplicateView
    ? "Identical files, found by content—not by filename. Review each one before making a decision."
    : "Find the photos worth keeping. Your library stays on your device, always.";
  document.querySelector("#library-title").textContent = duplicateView ? "Exact duplicates" : "Your library";
  document.querySelector("#library-description").textContent = duplicateView
    ? "Every group contains byte-for-byte identical image files."
    : "Your moments, organized in one quiet place.";
  document.querySelector("#empty-title").textContent = duplicateView ? "No exact duplicates found." : "Your next favorite is waiting.";
  document.querySelector("#empty-description").textContent = duplicateView
    ? "When PictoIQ finds identical files, they’ll appear here for a careful review."
    : "Choose a few photos to start your private library. We’ll find exact matches right on this device.";
}

function renderAssets() {
  updateSummary();
  updateViewText();
  const visibleAssets = getVisibleAssets();
  document.querySelector("#library-count").textContent = visibleAssets.length.toLocaleString();
  elements.grid.replaceChildren();
  elements.grid.hidden = visibleAssets.length === 0;
  elements.empty.hidden = state.query.length > 0 || visibleAssets.length > 0;
  elements.noResults.hidden = !state.query || visibleAssets.length > 0;

  const duplicates = duplicateAssetIds();
  for (const asset of visibleAssets) {
    const card = document.createElement("article");
    card.className = "photo-card";
    const preview = document.createElement("div");
    preview.className = "photo-preview";
    const source = state.previews.get(asset.id);
    if (source) {
      const image = document.createElement("img");
      image.src = source;
      image.alt = asset.name;
      image.loading = "lazy";
      preview.append(image);
    } else {
      preview.classList.add("missing-preview");
      preview.setAttribute("aria-label", "Reselect this photo to preview it");
      preview.innerHTML = '<span class="preview-placeholder"><svg viewBox="0 0 36 36" aria-hidden="true"><rect x="5" y="6" width="26" height="24" rx="5"/><circle cx="13.5" cy="14" r="2.5"/><path d="m8 27 8-8 4 4 3-3 6 7"/></svg><small>Reselect to preview</small></span>';
    }
    if (duplicates.has(asset.id)) {
      const tag = document.createElement("span");
      tag.className = "duplicate-tag";
      tag.textContent = "Exact match";
      preview.append(tag);
    }
    const metadata = document.createElement("div");
    metadata.className = "photo-meta";
    metadata.innerHTML = `<div class="photo-name" title="${escapeHtml(asset.name)}">${escapeHtml(asset.name)}</div><div class="photo-details"><span>${escapeHtml(formatDate(asset.modifiedAt))}</span><span>${escapeHtml(formatBytes(asset.size))}</span></div>`;
    const removeButton = document.createElement("button");
    removeButton.className = "remove-photo-button";
    removeButton.type = "button";
    removeButton.textContent = "Remove from library";
    removeButton.setAttribute("aria-label", `Remove ${asset.name} from PictoIQ library`);
    removeButton.addEventListener("click", () => removeAsset(asset));
    metadata.append(removeButton);
    card.append(preview, metadata);
    elements.grid.append(card);
  }
}

async function removeAsset(asset) {
  const shouldRemove = window.confirm(`Remove “${asset.name}” from the PictoIQ library? The original photo file will not be changed.`);
  if (!shouldRemove) return;

  try {
    await deleteAsset(asset.id);
    state.assets = state.assets.filter((item) => item.id !== asset.id);
    const preview = state.previews.get(asset.id);
    if (preview) URL.revokeObjectURL(preview);
    state.previews.delete(asset.id);
    renderAssets();
    showToast("Removed from the PictoIQ library. The original photo is unchanged.");
  } catch (error) {
    console.error("Could not remove a local library entry.", error);
    showToast("PictoIQ could not update the local library. Please try again.");
  }
}

async function digestFile(file) {
  const bytes = await file.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function waitForUi() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function scanFiles(fileList) {
  if (state.busy) return;
  const files = [...fileList].filter((file) => file.type.startsWith("image/"));
  if (!files.length) {
    showToast("Choose one or more image files to scan.");
    return;
  }

  state.busy = true;
  state.cancelRequested = false;
  elements.scanButton.disabled = false;
  elements.scanLabel.textContent = "Cancel scan";
  elements.scanButton.setAttribute("aria-label", "Cancel photo scan");
  elements.scanButton.onclick = cancelScan;
  let completed = 0;
  let tooLarge = 0;
  let failures = 0;
  const indexedAt = Date.now();
  const bySignature = new Map();
  for (const asset of state.assets) {
    const signature = `${asset.name}\0${asset.size}\0${asset.modifiedAt}`;
    const matches = bySignature.get(signature) ?? [];
    matches.push(asset);
    bySignature.set(signature, matches);
  }
  const signatureOccurrences = new Map();
  const updates = [];
  const newPreviews = [];

  try {
    for (const file of files) {
      if (state.cancelRequested) break;
      if (file.size > MAX_HASH_SIZE) {
        tooLarge += 1;
        continue;
      }

      try {
        const sha256 = await digestFile(file);
        const signature = `${file.name}\0${file.size}\0${file.lastModified}`;
        const occurrence = signatureOccurrences.get(signature) ?? 0;
        signatureOccurrences.set(signature, occurrence + 1);
        const existing = bySignature.get(signature)?.[occurrence];
        const asset = {
          id: existing?.id ?? crypto.randomUUID(),
          name: file.name,
          size: file.size,
          mimeType: file.type,
          modifiedAt: file.lastModified || null,
          sha256,
          scannedAt: indexedAt,
        };
        updates.push(asset);
        newPreviews.push([asset.id, URL.createObjectURL(file)]);
      } catch (error) {
        console.error("Could not fingerprint a selected image.", error);
        failures += 1;
      }

      completed += 1;
      elements.scanLabel.textContent = `Scanning ${completed}/${files.length}`;
      await waitForUi();
    }

    if (updates.length) {
      await saveAssets(updates);
      for (const asset of updates) {
        const existingIndex = state.assets.findIndex((item) => item.id === asset.id);
        if (existingIndex >= 0) state.assets[existingIndex] = asset;
        else state.assets.push(asset);
      }
      for (const [id, url] of newPreviews) {
        const oldUrl = state.previews.get(id);
        if (oldUrl) URL.revokeObjectURL(oldUrl);
        state.previews.set(id, url);
      }
    }
    state.view = "overview";
    document.querySelectorAll(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.view === "overview"));
    renderAssets();
    const parts = [`Scanned ${updates.length} photo${updates.length === 1 ? "" : "s"} on this device`];
    if (tooLarge) parts.push(`${tooLarge} over 100 MB skipped`);
    if (failures) parts.push(`${failures} could not be read`);
    if (state.cancelRequested) parts.push("scan paused");
    showToast(`${parts.join(" · ")}.`);
  } catch (error) {
    console.error("The local photo scan could not be saved.", error);
    for (const [, url] of newPreviews) URL.revokeObjectURL(url);
    showToast("PictoIQ could not finish this scan. Please try again.");
  } finally {
    state.busy = false;
    elements.scanButton.onclick = () => elements.picker.click();
    elements.scanLabel.textContent = "Choose photos";
    elements.scanButton.removeAttribute("aria-label");
    elements.scanButton.disabled = false;
  }
}

function cancelScan() {
  state.cancelRequested = true;
  elements.scanLabel.textContent = "Finishing current photo…";
  elements.scanButton.disabled = true;
}

function openInfo(title, paragraphs) {
  document.querySelector("#modal-title").textContent = title;
  const content = document.querySelector("#modal-copy");
  content.replaceChildren(...paragraphs.map((text) => {
    const paragraph = document.createElement("p");
    paragraph.textContent = text;
    return paragraph;
  }));
  elements.modal.showModal();
}

document.querySelectorAll(".nav-item, .brand").forEach((item) => {
  item.addEventListener("click", () => {
    state.view = item.dataset.view ?? "overview";
    document.querySelectorAll(".nav-item").forEach((navItem) => navItem.classList.toggle("active", navItem.dataset.view === state.view));
    renderAssets();
  });
});

elements.scanButton.addEventListener("click", () => {
  if (state.busy) cancelScan();
  else elements.picker.click();
});
document.querySelector("#empty-scan-button").addEventListener("click", () => elements.picker.click());
elements.picker.addEventListener("change", async (event) => {
  await scanFiles(event.target.files);
  event.target.value = "";
});
document.querySelector("#search-input").addEventListener("input", (event) => {
  state.query = event.target.value.trim();
  renderAssets();
});
document.querySelector("#sort-select").addEventListener("change", renderAssets);
document.querySelector("#privacy-details").addEventListener("click", () => openInfo("Your photos never leave this device.", [
  "PictoIQ processes the images you choose inside your browser. Image bytes are never sent to the PictoIQ server or to a third-party service.",
  "A small index—filenames, file sizes, dates, and SHA-256 fingerprints—is saved in this browser’s local storage so your library is still here next time.",
  "Your browser does not let this web app delete original photos. The index is not your photo backup; clearing browser data removes it.",
]));
document.querySelector("#help-button").addEventListener("click", () => openInfo("A private library, in three steps.", [
  "Choose image files from your device. Only the files you select are read, and duplicate detection runs right here in your browser.",
  "PictoIQ compares SHA-256 fingerprints to find byte-for-byte identical copies. Similar-looking photos and video files are not analyzed in this first release.",
  "Review your library before making decisions. This web MVP cannot delete originals; device-approved cleanup belongs in the native mobile app.",
]));
document.querySelector("#learn-more").addEventListener("click", () => document.querySelector("#help-button").click());

document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
    event.preventDefault();
    document.querySelector("#search-input").focus();
  }
});

window.addEventListener("beforeunload", () => {
  for (const url of state.previews.values()) URL.revokeObjectURL(url);
});

async function initialize() {
  try {
    state.assets = await readAssets();
    renderAssets();
  } catch (error) {
    console.error("The local PictoIQ library could not be opened.", error);
    showToast("Local storage is unavailable. Check your browser’s site storage settings.");
    document.querySelector("#footer-status").innerHTML = '<span class="tiny-dot orange"></span> Local storage unavailable';
  }
}

initialize();
