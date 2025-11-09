import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE')!);


serve(async () => {
// For all open reports in last 7 days, recompute
const { data } = await sb.from('reports').select('id, created_at').gte('created_at', new Date(Date.now()-7*86400000).toISOString()).limit(500);
if (!data) return new Response('ok');
for (const r of data) {
await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/match?report_id=${r.id}`, { method: 'POST', headers: { 'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE')}` } });
}
return new Response('ok');
});