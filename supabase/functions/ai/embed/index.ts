// deno run -A
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE")!;
const OPENAI_KEY   = Deno.env.get("OPENAI_API_KEY") ?? "";
const MODEL        = Deno.env.get("EMBEDDINGS_MODEL") ?? "text-embedding-3-small";

const sb = createClient(SUPABASE_URL, SERVICE_KEY);

function mockEmbed(text: string): number[] {
  // deterministic 768-dim mock embedding (fast, offline)
  const dim = 768;
  const out = new Array(dim).fill(0);
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  for (let i = 0; i < dim; i++) {
    const v = Math.sin((h + i * 374761393) % 104729) * 0.5 + 0.5;
    out[i] = v;
  }
  return out;
}

async function openAIEmbed(input: string): Promise<number[]> {
  const r = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${OPENAI_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ model: MODEL, input }),
  });
  if (!r.ok) {
    const t = await r.text();
    throw new Error(`OpenAI error: ${r.status} ${t}`);
  }
  const j = await r.json();
  const vec: number[] = j.data[0].embedding;
  if (vec.length !== 768) {
    // If your model dimension differs, adjust SQL and code to match!
    throw new Error(`Embedding dimension ${vec.length} != 768`);
  }
  return vec;
}

serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  try {
    const body = await req.json();
    const { report_id, text } = body as { report_id: string; text: string };

    if (!report_id || typeof text !== "string")
      return new Response(JSON.stringify({ error: "report_id and text required" }), { status: 400 });

    const vector = OPENAI_KEY ? await openAIEmbed(text) : mockEmbed(text);

    const { error } = await sb.from("embeddings").upsert({
      report_id,
      modality: "TEXT",
      vector,
    });
    if (error) return new Response(JSON.stringify({ error }), { status: 400 });

    return new Response(JSON.stringify({ ok: true, provider: OPENAI_KEY ? "openai" : "mock" }), {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
