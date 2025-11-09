// deno run -A
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE")!);
const FUN_BASE = `${Deno.env.get("SUPABASE_URL")}/functions/v1`;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE")!;

function timeDecay(days: number) { return Math.max(0, 1 - days / 30); }

async function ensureTextEmbedding(report: any) {
  // If missing, call ai/embed with raw_text
  const { data: emb } = await sb.from("embeddings").select("report_id").eq("report_id", report.id).eq("modality","TEXT").maybeSingle();
  if (!emb) {
    await fetch(`${FUN_BASE}/ai/embed`, {
      method: "POST",
      headers: { "Authorization": `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ report_id: report.id, text: report.raw_text ?? "" })
    });
  }
}

serve(async (req) => {
  const url = new URL(req.url);
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const id = url.searchParams.get("report_id");
  if (!id) return new Response(JSON.stringify({ error: "report_id required" }), { status: 400 });

  // Load target report
  const { data: target, error: tErr } = await sb.from("reports").select("*").eq("id", id).single();
  if (tErr || !target) return new Response(JSON.stringify({ error: tErr ?? "not found" }), { status: 400 });

  const opposite = target.kind === "LOST" ? "FOUND" : "LOST";

  // Make sure we have an embedding for the target
  await ensureTextEmbedding(target);

  // Choose candidate pool (same species via text heuristics? optional)
  const { data: cands, error: cErr } = await sb
    .from("reports")
    .select("*")
    .neq("id", target.id)
    .eq("kind", opposite)
    .gte("created_at", new Date(Date.now() - 30*86400000).toISOString()) // last 30 days
    .limit(400);
  if (cErr) return new Response(JSON.stringify({ error: cErr }), { status: 400 });

  // Ensure embeddings for candidates (basic loop; okay for small MVP batches)
  for (const c of cands ?? []) {
    await ensureTextEmbedding(c);
  }

  // Vector similarity: do a KNN against embeddings table
  // We'll fetch top 100 by cosine distance to target vector using a SQL RPC
  const { data: top } = await sb.rpc("match_knn_text", { report_in: target.id, k_in: 100 });
  const results: any[] = [];

  for (const row of top ?? []) {
    // row: { report_id, other_id, cos_sim }
    // Load candidate row (we already have cands; index them by id)
    const cand = (cands ?? []).find((x: any) => x.id === row.other_id);
    if (!cand) continue;

    // Geo
    let geoScore = 0;
    if (target.geom && cand.geom) {
      const { data: meters } = await sb.rpc("geom_distance_m", { a: target.id, b: cand.id });
      const m = typeof meters === "number" ? meters : (meters as any);
      const cap = 16093.4; // 10 miles
      geoScore = Math.max(0, 1 - Math.min(m, cap) / cap);
    }

    // Time
    const days = Math.abs((new Date(target.event_time).getTime() - new Date(cand.event_time).getTime()) / 86400000);
    const timeScore = timeDecay(days);

    const textScore = row.cos_sim ?? 0; // 0..1
    const score = 0.5*textScore + 0.3*geoScore + 0.2*timeScore;

    if (score > 0.35) {
      results.push({
        lost: target.kind === "LOST" ? target.id : cand.id,
        found: target.kind === "FOUND" ? target.id : cand.id,
        score,
        explanation: { textScore, geoScore, timeScore }
      });
    }
  }

  results.sort((a,b)=>b.score-a.score);
  for (const r of results.slice(0, 20)) {
    await sb.from("matches").upsert({
      lost_report_id: r.lost,
      found_report_id: r.found,
      score: r.score,
      explanation: r.explanation
    }, { onConflict: "lost_report_id,found_report_id" });
  }

  return new Response(JSON.stringify({ count: results.length, top: results.slice(0,3) }), {
    headers: { "content-type": "application/json" }
  });
});
