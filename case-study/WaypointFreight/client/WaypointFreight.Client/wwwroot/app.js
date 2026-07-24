const config = window.WAYPOINT_CONFIG ?? { apiBaseUrl: "http://localhost:5083" };

const elements = {
    apiBaseUrl: document.querySelector("#api-base-url"),
    subscriptionKey: document.querySelector("#subscription-key"),
    scenario: document.querySelector("#scenario"),
    refreshButton: document.querySelector("#refresh-button"),
    requestStatus: document.querySelector("#request-status"),
    correlationId: document.querySelector("#correlation-id"),
    connectionState: document.querySelector("#connection-state"),
    connectionLabel: document.querySelector("#connection-label"),
    shipmentCount: document.querySelector("#shipment-count"),
    shipmentTableBody: document.querySelector("#shipment-table-body"),
    trackingForm: document.querySelector("#tracking-form"),
    trackingNumber: document.querySelector("#tracking-number"),
    emptyDetail: document.querySelector("#empty-detail"),
    shipmentDetail: document.querySelector("#shipment-detail"),
    detailTracking: document.querySelector("#detail-tracking"),
    detailStatus: document.querySelector("#detail-status"),
    detailOrigin: document.querySelector("#detail-origin"),
    detailDestination: document.querySelector("#detail-destination"),
    detailEta: document.querySelector("#detail-eta"),
    detailUpdated: document.querySelector("#detail-updated"),
    eventTimeline: document.querySelector("#event-timeline")
};

elements.apiBaseUrl.value = config.apiBaseUrl;
elements.refreshButton.addEventListener("click", runSelectedRequest);
elements.trackingForm.addEventListener("submit", event => {
    event.preventDefault();
    const trackingNumber = elements.trackingNumber.value.trim();
    if (trackingNumber) {
        loadShipment(trackingNumber);
    }
});

async function apiRequest(path) {
    const baseUrl = elements.apiBaseUrl.value.trim().replace(/\/$/, "");
    const correlationId = crypto.randomUUID();
    const headers = {
        Accept: "application/json",
        "X-Correlation-Id": correlationId
    };
    const subscriptionKey = elements.subscriptionKey.value.trim();
    if (!subscriptionKey && baseUrl.includes(".azure-api.net")) {
        throw new Error("Enter the APIM subscription key to run this request.");
    }
    if (subscriptionKey) {
        headers["Ocp-Apim-Subscription-Key"] = subscriptionKey;
    }

    const response = await fetch(`${baseUrl}${path}`, { headers });
    const responseCorrelation = response.headers.get("X-Correlation-Id") ?? correlationId;
    elements.correlationId.textContent = `Correlation: ${responseCorrelation}`;

    const body = await response.text();
    let data;
    try {
        data = body ? JSON.parse(body) : null;
    } catch {
        throw new Error(`Response was not valid JSON (HTTP ${response.status}).`);
    }

    if (!response.ok) {
        const error = new Error(data?.message ?? `Request failed with HTTP ${response.status}.`);
        error.status = response.status;
        error.code = data?.code;
        throw error;
    }

    return data;
}

async function runSelectedRequest() {
    const scenario = elements.scenario.value;
    if (scenario === "none") {
        await loadShipments();
        return;
    }

    setRequestState(`Running ${scenario}...`, "loading");
    try {
        await apiRequest(`/api/test-scenarios/${encodeURIComponent(scenario)}`);
        setRequestState(`${scenario} completed with HTTP 200`, "ok");
    } catch (error) {
        const status = error.status ? `HTTP ${error.status}` : "request failure";
        const code = error.code ? `, ${error.code}` : "";
        setRequestState(`${scenario}: ${status}${code} - ${error.message}`, "error");
    }
}

async function loadShipments() {
    setRequestState("Loading shipments...", "loading");
    try {
        const shipments = await apiRequest("/api/shipments");
        if (!Array.isArray(shipments)) {
            throw new Error("Shipment list did not match the expected API contract.");
        }
        renderShipmentTable(shipments);
        setRequestState(`Loaded ${shipments.length} shipments`, "ok");
    } catch (error) {
        renderShipmentTable([]);
        setRequestState(error.message, "error");
    }
}

async function loadShipment(trackingNumber) {
    setRequestState(`Loading ${trackingNumber}...`, "loading");
    try {
        const [shipment, events] = await Promise.all([
            apiRequest(`/api/shipments/${encodeURIComponent(trackingNumber)}`),
            apiRequest(`/api/shipments/${encodeURIComponent(trackingNumber)}/events`)
        ]);
        validateShipment(shipment, events);
        renderShipmentDetail(shipment, events);
        selectShipmentRow(shipment.trackingNumber);
        setRequestState(`Loaded ${shipment.trackingNumber}`, "ok");
    } catch (error) {
        hideShipmentDetail();
        setRequestState(error.message, "error");
    }
}

function validateShipment(shipment, events) {
    if (!shipment || typeof shipment.trackingNumber !== "string" || !Array.isArray(events)) {
        throw new Error("Shipment detail did not match the expected API contract.");
    }
}

function renderShipmentTable(shipments) {
    elements.shipmentTableBody.replaceChildren();
    elements.shipmentCount.textContent = String(shipments.length);

    for (const shipment of shipments) {
        const row = document.createElement("tr");
        row.tabIndex = 0;
        row.dataset.trackingNumber = shipment.trackingNumber;
        row.setAttribute("aria-selected", "false");
        row.addEventListener("click", () => loadShipment(shipment.trackingNumber));
        row.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                loadShipment(shipment.trackingNumber);
            }
        });

        appendCell(row, shipment.trackingNumber, true);
        appendCell(row, `${shipment.origin} to ${shipment.destination}`);
        appendCell(row, formatStatus(shipment.status));
        appendCell(row, formatDate(shipment.estimatedDelivery));
        elements.shipmentTableBody.append(row);
    }
}

function appendCell(row, text, emphasize = false) {
    const cell = document.createElement("td");
    if (emphasize) {
        const strong = document.createElement("strong");
        strong.textContent = text;
        cell.append(strong);
    } else {
        cell.textContent = text;
    }
    row.append(cell);
}

function renderShipmentDetail(shipment, events) {
    elements.emptyDetail.hidden = true;
    elements.shipmentDetail.hidden = false;
    elements.detailTracking.textContent = shipment.trackingNumber;
    elements.detailStatus.textContent = formatStatus(shipment.status);
    elements.detailOrigin.textContent = shipment.origin;
    elements.detailDestination.textContent = shipment.destination;
    elements.detailEta.textContent = formatDate(shipment.estimatedDelivery);
    elements.detailUpdated.textContent = formatDateTime(shipment.lastUpdated);
    elements.eventTimeline.replaceChildren();

    for (const shipmentEvent of events) {
        const item = document.createElement("li");
        const title = document.createElement("strong");
        const location = document.createElement("span");
        const time = document.createElement("span");
        title.textContent = shipmentEvent.description;
        location.textContent = shipmentEvent.location;
        time.textContent = formatDateTime(shipmentEvent.occurredAt);
        item.append(title, location, time);
        elements.eventTimeline.append(item);
    }
}

function hideShipmentDetail() {
    elements.emptyDetail.hidden = false;
    elements.shipmentDetail.hidden = true;
}

function selectShipmentRow(trackingNumber) {
    for (const row of elements.shipmentTableBody.querySelectorAll("tr")) {
        row.setAttribute("aria-selected", String(row.dataset.trackingNumber === trackingNumber));
    }
}

function setRequestState(message, state) {
    elements.requestStatus.textContent = message;
    elements.connectionState.dataset.state = state === "ok" ? "ok" : state === "error" ? "error" : "idle";
    elements.connectionLabel.textContent = state === "ok" ? "Connected" : state === "error" ? "Request failed" : "Working";
    document.querySelector(".status-strip").dataset.state = state;
}

function formatStatus(status) {
    return String(status).replace(/([a-z])([A-Z])/g, "$1 $2");
}

function formatDate(value) {
    return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric" }).format(new Date(`${value}T00:00:00`));
}

function formatDateTime(value) {
    return new Intl.DateTimeFormat("en-US", {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit",
        timeZoneName: "short"
    }).format(new Date(value));
}

setRequestState("Enter the APIM subscription key, select a scenario, and run the request.", "idle");