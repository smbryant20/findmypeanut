// deno run -A
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";


const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE')!;
const sb = createClient(supabaseUrl, serviceKey);


serve(async (req) => {
const url = new URL(req.url);
if (req.method === 'POST') {
// Create report
const body = await req.json();
const geom = body.lat && body.lng ? `SRID=4326;POINT(${body.lng} ${body.lat})` : null;
const { data, error } = await sb.from('reports').insert({
kind: body.kind,
raw_text: body.raw_text ?? '',
city: body.city, state: body.state, country: body.country,
lat: body.lat, lng: body.lng, geom,
event_time: body.event_time ?? new Date().toISOString(),
images: body.images ?? [],
source: body.source ?? 'USER',
source_url: body.source_url ?? null,
created_by: body.created_by ?? null,
contact_email: body.contact_email ?? null,
contact_phone: body.contact_phone ?? null
}).select('id').single();
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify({ id: data.id }), { headers: { 'content-type': 'application/json' } });
}


// GET /?kind=&near=lat,lng&radius=mi&breed=&color=
if (req.method === 'GET') {
const kind = url.searchParams.get('kind');
const near = url.searchParams.get('near');
const radiusMi = Number(url.searchParams.get('radius') ?? '25');
let query = sb.from('reports_public').select('*').order('created_at', { ascending: false }).limit(100);


if (kind) query = query.eq('kind', kind);
if (near) {
const [lat, lng] = near.split(',').map(Number);
const radiusMeters = radiusMi * 1609.34;
// Filter by distance using PostGIS function through RPC via SQL filter
// Supabase JS doesn't expose ST_DistanceSphere; use a stored view or SQL filter
query = query.filter('geom', 'not.is', null);
const { data, error } = await sb.rpc('reports_nearby', { lat_in: lat, lng_in: lng, radius_m: radiusMeters });
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify(data), { headers: { 'content-type': 'application/json' } });
}


const { data, error } = await query;
if (error) return new Response(JSON.stringify({ error }), { status: 400 });
return new Response(JSON.stringify(data), { headers: { 'content-type': 'application/json' } });
}


return new Response('Method not allowed', { status: 405 });
});