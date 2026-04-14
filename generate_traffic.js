const KEYCLOAK_TOKEN_URL = "http://localhost:30080/realms/megamart-edge/protocol/openid-connect/token";
const AI_AGENT_URL = "http://localhost:30001/agent/chat";

const PROMPTS = [
    "Check pending e-commerce orders for curbside pickup",
    "Any new orders for store local_123?",
    "Show me the order queue for curbside pickup.",
    "What is the status of pending orders?",
    "Get all pending orders for today."
];

async function getAccessToken() {
    console.log("Authenticating with Keycloak...");
    const params = new URLSearchParams();
    params.append("client_id", "associate-device");
    params.append("grant_type", "password");
    params.append("username", "store-associate-user");
    params.append("password", "password");

    const response = await fetch(KEYCLOAK_TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: params.toString()
    });

    const data = await response.json();
    if (!data.access_token) {
        throw new Error("Lgin failed: " + JSON.stringify(data));
    }
    console.log("Authenticated successfully.");
    return data.access_token;
}

async function sendPrompt(token, prompt) {
    const response = await fetch(AI_AGENT_URL, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${token}`
        },
        body: JSON.stringify({ prompt })
    });

    if (response.status !== 200) {
        throw new Error(`Request failed with status ${response.status}: ${await response.text()}`);
    }
    return response.json();
}

async function run(iterations = 1000, concurrency = 5) {
    try {
        const token = await getAccessToken();
        console.log(`Starting traffic generation: ${iterations} iterations, concurrency: ${concurrency}`);

        let completed = 0;
        let errors = 0;

        const executeBatch = async (batchSize) => {
            const promises = [];
            for (let i = 0; i < batchSize; i++) {
                const prompt = PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
                promises.push(
                    sendPrompt(token, prompt)
                        .then(() => {
                            completed++;
                            if (completed % 50 === 0) {
                                console.log(`Progress: ${completed}/${iterations} requests completed.`);
                            }
                        })
                        .catch(err => {
                            errors++;
                            console.error(`Error at request ${completed + errors}: ${err.message}`);
                        })
                );
            }
            await Promise.all(promises);
        };

        for (let i = 0; i < iterations; i += concurrency) {
            const currentBatchSize = Math.min(concurrency, iterations - i);
            await executeBatch(currentBatchSize);
        }

        console.log("Traffic generation complete.");
        console.log(`Summary: ${completed} successful, ${errors} failed.`);
    } catch (err) {
        console.error("Fatal error:", err.message);
    }
}

const args = process.argv.slice(2);
const iterations = parseInt(args[0]) || 1000;
const concurrency = parseInt(args[1]) || 5;

run(iterations, concurrency);
