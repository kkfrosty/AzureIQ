const chatConfig = window.AI_CHAT_CONFIG ?? {
    gatewayUrl: "",
    apiVersion: "2024-10-21",
    models: [],
    maxCompletionTokens: 800,
    systemPrompt: "You are a helpful assistant."
};

const elements = {
    gatewayUrl: document.querySelector("#gateway-url"),
    gatewayKey: document.querySelector("#gateway-key"),
    modelSelect: document.querySelector("#model-select"),
    apiVersion: document.querySelector("#api-version"),
    resetButton: document.querySelector("#reset-button"),
    chatState: document.querySelector("#chat-state"),
    chatUsage: document.querySelector("#chat-usage"),
    chatLog: document.querySelector("#chat-log"),
    chatForm: document.querySelector("#chat-form"),
    chatInput: document.querySelector("#chat-input"),
    sendButton: document.querySelector("#send-button")
};

let conversation = [];

initialize();

function initialize() {
    elements.gatewayUrl.value = chatConfig.gatewayUrl ?? "";
    elements.apiVersion.value = chatConfig.apiVersion ?? "";

    for (const model of chatConfig.models ?? []) {
        const option = document.createElement("option");
        option.value = model;
        option.textContent = model;
        elements.modelSelect.appendChild(option);
    }

    resetConversation();

    elements.resetButton.addEventListener("click", () => {
        resetConversation();
        setState("Conversation cleared.", "idle");
        elements.chatUsage.textContent = "";
    });

    elements.chatForm.addEventListener("submit", event => {
        event.preventDefault();
        const message = elements.chatInput.value.trim();
        if (message) {
            sendMessage(message);
        }
    });
}

function resetConversation() {
    conversation = chatConfig.systemPrompt
        ? [{ role: "system", content: chatConfig.systemPrompt }]
        : [];
    elements.chatLog.replaceChildren();
}

async function sendMessage(message) {
    const gatewayUrl = elements.gatewayUrl.value.trim().replace(/\/$/, "");
    const gatewayKey = elements.gatewayKey.value.trim();
    const model = elements.modelSelect.value;
    const apiVersion = elements.apiVersion.value.trim();

    if (!gatewayUrl || !gatewayKey) {
        setState("Enter the gateway URL and subscription key before sending.", "error");
        return;
    }
    if (!model || !apiVersion) {
        setState("Select a model deployment and API version before sending.", "error");
        return;
    }

    appendEntry("user", message);
    conversation.push({ role: "user", content: message });
    elements.chatInput.value = "";
    setBusy(true);
    setState(`Calling ${model}...`, "loading");

    const correlationId = crypto.randomUUID();
    const requestUrl = `${gatewayUrl}/deployments/${encodeURIComponent(model)}/chat/completions?api-version=${encodeURIComponent(apiVersion)}`;

    try {
        const response = await fetch(requestUrl, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                Accept: "application/json",
                "Ocp-Apim-Subscription-Key": gatewayKey,
                "X-Correlation-Id": correlationId
            },
            body: JSON.stringify({
                messages: conversation,
                max_completion_tokens: chatConfig.maxCompletionTokens
            })
        });

        const responseCorrelation = response.headers.get("x-correlation-id") ?? correlationId;
        const consumed = response.headers.get("x-tokens-consumed");
        const remaining = response.headers.get("x-tokens-remaining");
        elements.chatUsage.textContent = formatUsage(responseCorrelation, consumed, remaining);

        const raw = await response.text();
        let payload = null;
        try {
            payload = raw ? JSON.parse(raw) : null;
        } catch {
            throw new Error(`Gateway returned a non-JSON response (HTTP ${response.status}).`);
        }

        if (!response.ok) {
            const detail = payload?.message ?? payload?.error?.message ?? `HTTP ${response.status}`;
            throw new Error(detail);
        }

        const reply = payload?.choices?.[0]?.message?.content;
        if (!reply) {
            throw new Error("The model response did not contain any content.");
        }

        conversation.push({ role: "assistant", content: reply });
        appendEntry("assistant", reply);
        setState(`${model} responded with HTTP ${response.status}`, "ok");
    } catch (error) {
        conversation.pop();
        appendEntry("error", error.message);
        setState(error.message, "error");
    } finally {
        setBusy(false);
    }
}

function appendEntry(role, content) {
    const item = document.createElement("li");
    item.className = `chat-entry chat-${role}`;

    const label = document.createElement("span");
    label.className = "chat-role";
    label.textContent = role === "user" ? "You" : role === "assistant" ? "Assistant" : "Error";

    const body = document.createElement("p");
    body.textContent = content;

    item.append(label, body);
    elements.chatLog.appendChild(item);
    item.scrollIntoView({ block: "end" });
}

function formatUsage(correlationId, consumed, remaining) {
    const parts = [`Correlation: ${correlationId}`];
    if (consumed) {
        parts.push(`Tokens used: ${consumed}`);
    }
    if (remaining) {
        parts.push(`Tokens remaining: ${remaining}`);
    }
    return parts.join(" | ");
}

function setBusy(isBusy) {
    elements.sendButton.disabled = isBusy;
    elements.chatInput.disabled = isBusy;
}

function setState(message, state) {
    elements.chatState.textContent = message;
    elements.chatState.dataset.state = state;
}
