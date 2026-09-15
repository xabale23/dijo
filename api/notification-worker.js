// DIJO Notification Worker
// Phase 2: Secure Supabase connectivity check

module.exports = async function handler(req, res) {
  res.setHeader("Content-Type", "application/json");

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const workerSecret = process.env.DIJO_WORKER_SECRET;

  // ----------------------------------------------------------
  // Public health check
  // ----------------------------------------------------------

  if (req.method === "GET") {
    return res.status(200).json({
      ok: true,
      service: "dijo-notification-worker",
      status: "ready",
      supabaseConfigured: Boolean(
        supabaseUrl &&
        serviceRoleKey &&
        workerSecret
      ),
    });
  }

  // ----------------------------------------------------------
  // Protected Supabase connectivity check
  // ----------------------------------------------------------

  if (req.method === "POST") {
    const suppliedSecret = req.headers["x-dijo-worker-secret"];

    if (
      !workerSecret ||
      !suppliedSecret ||
      suppliedSecret !== workerSecret
    ) {
      return res.status(401).json({
        ok: false,
        error: "Unauthorized",
      });
    }

    if (!supabaseUrl || !serviceRoleKey) {
      return res.status(500).json({
        ok: false,
        error: "Worker environment is not fully configured",
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

      const body = await response.text();

      if (!response.ok) {
        console.error(
          "Supabase connectivity check failed:",
          response.status,
          body
        );

        return res.status(502).json({
          ok: false,
          supabaseConnected: false,
          error: "Supabase RPC request failed",
        });
      }

      return res.status(200).json({
        ok: true,
        service: "dijo-notification-worker",
        supabaseConnected: true,
      });
    } catch (error) {
      console.error(
        "Notification worker connectivity error:",
        error
      );

      return res.status(500).json({
        ok: false,
        supabaseConnected: false,
        error: "Worker connectivity check failed",
      });
    }
  }

  return res.status(405).json({
    ok: false,
    error: "Method not allowed",
  });
};
