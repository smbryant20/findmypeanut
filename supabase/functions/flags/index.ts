import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE')!);
serve(async (req) => {
if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
const body = await req.json();
const { error } = await sb.from('flags').insert({ report_id: body.report_id, reason: body.reason, created_by: body.created_by ?? null });
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify({ ok: true }), { headers: { 'content-type': 'application/json' } });
});