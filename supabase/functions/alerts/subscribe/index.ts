import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE')!);
serve(async (req) => {
if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
const body = await req.json();
const center = body.lat && body.lng ? `SRID=4326;POINT(${body.lng} ${body.lat})` : null;
const { data, error } = await sb.from('alerts').insert({
auth_id: body.auth_id ?? null,
email: body.email,
pet_type: body.pet_type,
radius_miles: body.radius ?? 10,
center
}).select('*').single();
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify({ ok: true, id: data.id }), { headers: { 'content-type': 'application/json' } });
});