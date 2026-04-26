import { NextRequest, NextResponse } from "next/server";

/**
 * BFF: browser never calls ai-agent directly. Only this server-side route talks to
 * ai-agent over the mesh (Istio mTLS between sidecars; SPIRE-backed workload identity).
 */
const AI_AGENT_URL =
  process.env.AI_AGENT_URL ||
  "http://ai-agent.edge-demo-store-apps.svc.cluster.local:8000";

export async function POST(req: NextRequest) {
  const auth = req.headers.get("authorization");
  if (!auth || !auth.startsWith("Bearer ")) {
    return NextResponse.json(
      { error: "Missing or invalid Authorization header" },
      { status: 401 }
    );
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const upstream = await fetch(`${AI_AGENT_URL}/agent/chat`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: auth,
    },
    body: JSON.stringify(body),
  });

  const text = await upstream.text();
  let data: unknown;
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { error: "Upstream returned non-JSON", raw: text };
  }

  return NextResponse.json(data, { status: upstream.status });
}
