import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE')!);


serve(async (req) => {
if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
const body = await req.json();
if (body.url) {
// For MVP, only allow CSV/RSS explicitly provided (no scraping)
// Pseudo: fetch CSV, map columns -> report fields
// Here we just mock a single transformed record
const { error } = await sb.from('reports').insert({
kind: 'FOUND', raw_text: `Imported: ${body.url}`, city: 'Demo', state: 'MA', country: 'USA',
lat: 42.7, lng: -73.1, geom: 'SRID=4326;POINT(-73.1 42.7)', source: 'SHELTER', source_url: body.url
});
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify({ ok: true }));
}
if (body.json) {
const r = body.json;
const geom = r.lat && r.lng ? `SRID=4326;POINT(${r.lng} ${r.lat})` : null;
const { error } = await sb.from('reports').insert({
kind: r.kind ?? 'FOUND', raw_text: r.raw_text ?? '', city: r.city, state: r.state, country: r.country,
lat: r.lat, lng: r.lng, geom, source: r.source ?? 'SOCIAL', source_url: r.source_url ?? null, images: r.images ?? []
});
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify({ ok: true }));
}
return new Response(JSON.stringify({ error: 'Provide url or json' }), { status: 400 });
});