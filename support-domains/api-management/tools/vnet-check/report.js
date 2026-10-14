"use strict";
const statusFilter = document.querySelector("#status-filter");
const searchFilter = document.querySelector("#search-filter");
const rows = [...document.querySelectorAll("details.check-section tr[data-status]")];
const connectionCount = document.querySelectorAll("#native-status tr[data-connection-status]").length;
const checkSections = [...document.querySelectorAll("details.check-section")];
const sections = [...document.querySelectorAll("details")];

function filterRows() {
    const status = statusFilter.value;
    const search = searchFilter.value.trim().toLowerCase();
    let visible = 0;
    for (const row of rows) {
        const matchesStatus = status === "all" ||
            (status === "attention" ? !["Checked", "Not applicable"].includes(row.dataset.assessment) : row.dataset.assessment === status);
        row.hidden = !matchesStatus || !row.textContent.toLowerCase().includes(search);
        if (!row.hidden) visible++;
    }
    for (const section of checkSections) {
        const count = [...section.querySelectorAll("tr[data-status]")].filter(row => !row.hidden).length;
        section.querySelector(".visible-count").textContent = `${count} visible`;
        section.hidden = count === 0 && status !== "all";
    }
    const connections = connectionCount > 0
        ? `All ${connectionCount} collected network connection statuses remain visible in their separate section.`
        : "Network status read/coverage results are shown separately; no connection success is inferred from absent data.";
    document.querySelector("#filter-summary").textContent = visible === 0
        ? `No configuration checks match this filter. ${connections} This is not a health verdict.`
        : `${visible} of ${rows.length} configuration checks visible. ${connections}`;
}
statusFilter.addEventListener("change", filterRows);
searchFilter.addEventListener("input", filterRows);
document.querySelector("#expand-all").addEventListener("click", () => sections.forEach(section => { section.open = true; }));
document.querySelector("#collapse-all").addEventListener("click", () => sections.forEach(section => { section.open = false; }));
document.querySelector("#print-report").addEventListener("click", () => {
    sections.forEach(section => { section.open = true; section.hidden = false; });
    window.print();
});
window.addEventListener("beforeprint", () => sections.forEach(section => { section.open = true; section.hidden = false; }));
window.addEventListener("afterprint", filterRows);
for (const button of document.querySelectorAll(".copy-handoff")) {
    button.addEventListener("click", async () => {
        const text = document.getElementById(button.dataset.target);
        const status = button.parentElement.querySelector(".copy-status");
        try {
            await navigator.clipboard.writeText(text.value);
            status.textContent = "Change-plan request copied. Paste it into GitHub Copilot Chat; no Azure changes have been approved.";
        } catch (error) {
            console.warn("Clipboard write failed for the GHC handoff.", error);
            text.focus();
            text.select();
            status.textContent = "Clipboard write failed or is unavailable. Request text is selected; press Ctrl+C to copy, then paste into GitHub Copilot Chat.";
        }
    });
}
filterRows();
