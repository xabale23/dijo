// DIJO Notification Worker
// Phase 3: Supabase connectivity health check

module.exports = async function handler(req, res) {
  res.setHeader("Content-Type", "application/json");

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const workerSecret = process.env.DIJO_WORKER_SECRET;

  if (req.method !== "GET") {
    return res.status(405).json({
      ok: false,
      error: "Method not allowed",
    });
  }

  if (!supabaseUrl || !serviceRoleKey || !workerSecret) {
    return res.status(500).json({
      ok: false,
      service: "dijo-notification-worker",
      status: "misconfigured",
      supabaseConfigured: false,
    });
  }

  try {
    const response = await fetch(
      `${supabaseUrl}/rest/v1/rpc/can_receive_whatsapp_notification`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
        },
        body: JSON.stringify({
          p_profile_id:
            "00000000-0000-0000-0000-000000000000",
          p_event_type:
            "worker.healthcheck",
        }),
      }
    );

    if (!response.ok) {
      const errorBody = await response.text();

      console.error(
        "Supabase health check failed:",
        response.status,
        errorBody
      );

      return res.status(502).json({
        ok: false,
        service: "dijo-notification-worker",
        status: "supabase-error",
        supabaseConfigured: true,
        supabaseConnected: false,
      });
    }

    return res.status(200).json({
      ok: true,
      service: "dijo-notification-worker",
      status: "ready",
      supabaseConfigured: true,
      supabaseConnected: true,
    });
  } catch (error) {
    console.error("Worker health check error:", error);

    return res.status(500).json({
      ok: false,
      service: "dijo-notification-worker",
      status: "connectivity-error",
      supabaseConfigured: true,
      supabaseConnected: false,
    });
  }
};
