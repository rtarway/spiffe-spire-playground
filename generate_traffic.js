/**
 * Simulates the browser workflow: Keycloak login (password grant) + POST /api/agent/chat (BFF).
 * ai-agent is ClusterIP-only; traffic matches the real webapp path.
 *
 * Usage: node generate_traffic.js [iterations] [concurrency]
 * Env: KEYCLOAK_TOKEN_URL, WEBAPP_AGENT_URL, QUIET=1
 */

const KEYCLOAK_TOKEN_URL =
    process.env.KEYCLOAK_TOKEN_URL ||
    "http://localhost:30080/realms/megamart-edge/protocol/openid-connect/token";
const WEBAPP_AGENT_URL =
    process.env.WEBAPP_AGENT_URL ||
    "http://localhost:30000/api/agent/chat";

const QUIET = process.env.QUIET === "1" || process.env.QUIET === "true";

const PROMPTS = [
    "Check pending e-commerce orders for curbside pickup",
    "Any new orders for store local_123?",
    "Show me the order queue for curbside pickup.",
    "What is the status of pending orders?",
    "Get all pending orders for today.",
    "Hello, what can you help with today?",
];

async function getAccessToken(quiet = false) {
    const params = new URLSearchParams();
    params.append("client_id", "associate-device");
    params.append("grant_type", "password");
    params.append("username", "store-associate-user");
    params.append("password", "password");

    const response = await fetch(KEYCLOAK_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: params.toString(),
    });

    const data = await response.json();
    if (!data.access_token) {
        throw new Error("Login failed: " + JSON.stringify(data));
    }
    if (!quiet) {
        console.log("Keycloak login OK (token received).");
    }
    return data.access_token;
}

async function sendPrompt(token, prompt) {
    const response = await fetch(WEBAPP_AGENT_URL, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({ prompt }),
    });

    if (response.status !== 200) {
        const body = await response.text();
        throw new Error(`BFF/chat failed ${response.status}: ${body}`);
    }
    return response.json();
}

/** One browser-equivalent session: fresh login + one agent prompt. */
async function browserLoginAndPrompt() {
    const token = await getAccessToken(true);
    const prompt = PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
    await sendPrompt(token, prompt);
}

async function run(iterations = 1000, concurrency = 5) {
    if (!QUIET) {
        console.log(
            `Workflows: ${iterations} (each = Keycloak login + BFF /api/agent/chat), concurrency=${concurrency}`
        );
        console.log(`KEYCLOAK_TOKEN_URL=${KEYCLOAK_TOKEN_URL}`);
        console.log(`WEBAPP_AGENT_URL=${WEBAPP_AGENT_URL}`);
    }

    let completed = 0;
    let errors = 0;

    for (let offset = 0; offset < iterations; offset += concurrency) {
        const batchSize = Math.min(concurrency, iterations - offset);
        const results = await Promise.allSettled(
            Array.from({ length: batchSize }, () => browserLoginAndPrompt())
        );
        for (const r of results) {
            if (r.status === "fulfilled") {
                completed++;
            } else {
                errors++;
                console.error("Workflow error:", r.reason?.message || r.reason);
            }
        }
        if (completed % 50 === 0 && completed > 0) {
            console.log(`Progress: ${completed}/${iterations} workflows OK (${errors} errors so far).`);
        }
    }

    console.log("Traffic generation complete.");
    console.log(`Summary: ${completed} successful workflows, ${errors} failed (${iterations} total attempted).`);
}

const args = process.argv.slice(2);
const iterations = parseInt(args[0], 10) || 1000;
const concurrency = parseInt(args[1], 10) || 5;

run(iterations, concurrency).catch((err) => {
    console.error("Fatal error:", err.message);
    process.exit(1);
});
