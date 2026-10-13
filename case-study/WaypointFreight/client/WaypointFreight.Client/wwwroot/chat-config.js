window.AI_CHAT_CONFIG = Object.freeze({
    // AI Foundry gateway deployed by infra/ai-foundry/main.bicep.
    gatewayUrl: "",
    apiVersion: "2024-10-21",
    models: ["gpt-5.4-mini", "gpt-5.4-nano"],
    maxCompletionTokens: 800,
    systemPrompt: "You are the Waypoint Freight operations assistant. Answer concisely and say when you are unsure."
});
