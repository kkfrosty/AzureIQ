"use strict";
const statusFilter = document.querySelector("#status-filter");
const searchFilter = document.querySelector("#search-filter");
const rows = [...document.querySelectorAll("tr[data-status]")];
const sections = [...document.querySelectorAll("details.check-section")];

function filterRows() {
    const status = statusFilter.value;
    const search = searchFilter.value.trim().toLowerCase();
    let visible = 0;
    for (const row of rows) {
        const matchesStatus = status === "all" ||
            (status === "attention" ? ["Fail", "Unknown"].includes(row.dataset.status) : row.dataset.status === status);
        row.hidden = !matchesStatus || !row.textContent.toLowerCase().includes(search);
        if (!row.hidden) visible++;
    }
    for (const section of sections) {
        const count = [...section.querySelectorAll("tr[data-status]")].filter(row => !row.hidden).length;
        section.querySelector(".visible-count").textContent = `${count} visible`;
    }
    document.querySelector("#filter-summary").textContent = `${visible} of ${rows.length} checks visible. Section totals always include all checks.`;
}
statusFilter.addEventListener("change", filterRows);
searchFilter.addEventListener("input", filterRows);
document.querySelector("#expand-all").addEventListener("click", () => sections.forEach(section => { section.open = true; }));
document.querySelector("#collapse-all").addEventListener("click", () => sections.forEach(section => { section.open = false; }));
document.querySelector("#print-report").addEventListener("click", () => {
    sections.forEach(section => { section.open = true; });
    window.print();
});
window.addEventListener("beforeprint", () => sections.forEach(section => { section.open = true; }));
filterRows();
