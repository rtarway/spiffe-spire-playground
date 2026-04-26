"use client";
import { useState } from "react";

export default function Home() {
  const [username, setUsername] = useState("store-associate-user"); // To be created in KC
  const [password, setPassword] = useState("password");
  const [token, setToken] = useState("");
  const [prompt, setPrompt] = useState("");
  const [response, setResponse] = useState("");

  const login = async () => {
    try {
      // Simulate Keycloak login (Direct Access Grant for demo purposes)
      // In production, use standard Auth Code flow with NextAuth.js
      const params = new URLSearchParams();
      params.append("client_id", "associate-device");
      params.append("grant_type", "password");
      params.append("username", username);
      params.append("password", password);
      
      const res = await fetch("http://localhost:30080/realms/edge-demo/protocol/openid-connect/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: params.toString()
      });
      const data = await res.json();
      if (data.access_token) {
        setToken(data.access_token);
        alert("Logged in successfully! Token received.");
      } else {
        alert("Login failed: " + JSON.stringify(data));
      }
    } catch (e) {
      alert("Error: Keycloak might not be running or accessible.");
    }
  };

  const submitPrompt = async () => {
    try {
      // Same-origin BFF: webapp backend proxies to ai-agent over the mesh (no direct browser→ai-agent).
      const res = await fetch("/api/agent/chat", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${token}`
        },
        body: JSON.stringify({ prompt })
      });
      const data = await res.json();
      setResponse(JSON.stringify(data, null, 2));
    } catch (e) {
      setResponse("Error calling AI Agent: " + e);
    }
  };

  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-10">
      <div className="w-full max-w-4xl p-8 bg-white/10 backdrop-blur-md rounded-2xl shadow-2xl border border-white/20">
        <h1 className="text-4xl font-bold mb-8 text-transparent bg-clip-text bg-gradient-to-r from-blue-400 to-purple-500">
          Edge demo associate tablet
        </h1>
        
        {!token ? (
          <div className="flex flex-col gap-4 max-w-sm">
            <h2 className="text-xl">Associate Login</h2>
            <input 
              className="p-3 rounded bg-black/30 border border-white/10 text-white" 
              placeholder="Username" 
              value={username} onChange={e => setUsername(e.target.value)} 
            />
            <input 
              className="p-3 rounded bg-black/30 border border-white/10 text-white" 
              type="password" placeholder="Password" 
              value={password} onChange={e => setPassword(e.target.value)} 
            />
            <button onClick={login} className="p-3 bg-blue-600 hover:bg-blue-500 transition rounded shadow-lg font-semibold">
              Login via Keycloak
            </button>
          </div>
        ) : (
          <div className="flex flex-col gap-4">
            <h2 className="text-xl">Ask the Edge AI</h2>
            <textarea 
              className="w-full p-4 rounded-xl bg-black/30 border border-white/10 text-white h-32" 
              placeholder="e.g., 'Check pending e-commerce orders for curbside pickup'" 
              value={prompt} onChange={e => setPrompt(e.target.value)} 
            />
            <button onClick={submitPrompt} className="p-4 bg-purple-600 hover:bg-purple-500 transition rounded-xl font-bold shadow-lg">
              Execute Agentic Task
            </button>

            {response && (
              <div className="mt-8">
                <h3 className="text-lg mb-2">Agent Response:</h3>
                <pre className="bg-black/50 p-4 rounded-xl overflow-x-auto text-green-400 text-sm border border-white/10">
                  {response}
                </pre>
              </div>
            )}
          </div>
        )}
      </div>
    </main>
  );
}
