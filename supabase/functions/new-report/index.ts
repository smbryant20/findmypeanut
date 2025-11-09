
import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Resend } from "https://esm.sh/resend@3"; // optional

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!; // service role for server-side
const resendKey   = Deno.env.get("RESEND_API_KEY"); // optional

const sb = createClient(supabaseUrl, serviceKey);
const resend = resendKey ? new Resend(resendKey) : null;

serve(async (req) => {
  try {
    const { report_id } = await req.json();

    // 1) Load report
    const { data: report, error: repErr } = await sb
      .from("reports_public")
      .select("id, kind, city, state, country, lat, lng, status, created_at")
      .eq("id", report_id)
      .single();
    if (repErr || !report) throw repErr ?? new Error("Report not found");

    // Only notify for FOUND/SIGHTING (tweak to taste)
    if (!["FOUND","SIGHTING"].includes(report.kind)) {
      return new Response("Ignored (kind)", { status: 200 });
    }

    // 2) Find candidate users (PostGIS version)
    // Distance in meters: radius_km * 1000
    const radiusMeters = 1000; // fallback default
    // If you store user center as (lat,lng) only, you can fetch all and compute below.
    // Here’s a simple server-side fetch (filter more in SQL if PostGIS is available):
    const { data: prefs, error: prefErr } = await sb
      .from("user_alert_prefs")
      .select("user_id, lat, lng, radius_km, kinds, email_enabled, push_enabled");
    if (prefErr) throw prefErr;

    // 3) Basic distance filter
    function haversine(lat1:number, lon1:number, lat2:number, lon2:number): number {
      const toRad = (d:number)=>d*Math.PI/180;
      const R = 6371; // km
      const dLat = toRad(lat2-lat1), dLon = toRad(lon2-lon1);
      const a = Math.sin(dLat/2)**2 +
                Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*
                Math.sin(dLon/2)**2;
      return 2*R*Math.asin(Math.sqrt(a));
    }

    const targets = (prefs ?? []).filter(p => {
      if (!p.lat || !p.lng || !p.kinds?.includes(report.kind)) return false;
      const dist = haversine(p.lat, p.lng, report.lat, report.lng);
      return dist <= (p.radius_km ?? 8);
    });

    // 4) Create alerts (dedupe via unique constraint)
    for (const t of targets) {
      await sb.from("alerts")
        .insert({ user_id: t.user_id, report_id: report.id, kind: "both" })
        .select("id").maybeSingle(); // ignore conflict errors
    }

    // 5) Send notifications
    // Push: collect device tokens for targets
    const userIds = targets.map(t => t.user_id);
    const { data: devices } = await sb.from("user_devices")
      .select("user_id, token, platform")
      .in("user_id", userIds);

    // (Pseudo) send via your FCM/APNs helper here…
    // await sendPush(devices, { title: "Nearby match", body: "Someone posted a FOUND near you" });

    // Email (via Resend) – optional
    if (resend) {
      // You need a way to map user_id -> email (either cache in prefs or query auth)
      // Example (if you stored contact email in another table):
      // await resend.emails.send({ to, from, subject, html });
    }

    // 6) Mark alerts as sent
    await sb.from("alerts")
      .update({ sent_at: new Date().toISOString() })
      .in("user_id", userIds)
      .eq("report_id", report.id);

    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(e);
    return new Response(String(e?.message ?? e), { status: 500 });
  }
});
