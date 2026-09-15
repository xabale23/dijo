// DIJO Notification Worker
// Phase 4: Secure notification claiming
// No Meta/WhatsApp sending yet.

const WORKER_ID = "dijo-vercel-worker-v1";

async function callSupabaseRpc(
  supabaseUrl,
  serviceRoleKey,
  rpcName,
  body
) {
  const response = await fetch(
    `${supabaseUrl}/rest/v1/rpc/${rpcName}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
      body: JSON.stringify(body),
    }
  );

  const text = await response.text();

  if (!response.ok) {
    throw new Error(
      `Supabase RPC ${rpcName} failed (${response.status}): ${text}`
    );
  }

  if (!text) {
    return null;
  }

  return JSON.parse(text);
}

module.exports = async function handler(req, res) {
  res.setHeader("Content-Type", "application/json");

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey =
    process.env.SUPABASE_SERVICE_ROLE_KEY;
  const workerSecret =
    process.env.DIJO_WORKER_SECRET;

  // ==========================================================
  // PUBLIC, READ-ONLY HEALTH CHECK
  // ==========================================================

  if (req.method === "GET") {
    if (!supabaseUrl || !serviceRoleKey || !workerSecret) {
      return res.status(500).json({
        ok: false,
        service: "dijo-notification-worker",
        status: "misconfigured",
      });
    }

    try {
      const connected = await callSupabaseRpc(
        supabaseUrl,
        serviceRoleKey,
        "can_receive_whatsapp_notification",
        {
          p_profile_id:
            "00000000-0000-0000-0000-000000000000",
          p_event_type:
            "worker.healthcheck",
        }
      );

      return res.status(200).json({
        ok: true,
        service: "dijo-notification-worker",
        status: "ready",
        supabaseConnected:
          connected === false || connected === true,
      });
    } catch (error) {
      console.error("Health check failed:", error);

      return res.status(502).json({
        ok: false,
        service: "dijo-notification-worker",
        status: "supabase-error",
      });
    }
  }

  // ==========================================================
  // ONLY POST MAY PROCESS THE QUEUE
  // ==========================================================

  if (req.method !== "POST") {
    return res.status(405).json({
      ok: false,
      error: "Method not allowed",
    });
  }

  // ==========================================================
  // PROTECT WORKER
  // ==========================================================

  const suppliedSecret =
    req.headers["x-dijo-worker-secret"];

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
      error: "Worker environment is not configured",
    });
  }

  // ==========================================================
  // CLAIM EXACTLY ONE JOB
  // ==========================================================

  try {
    const jobs = await callSupabaseRpc(
      supabaseUrl,
      serviceRoleKey,
      "claim_notification_outbox",
      {
        p_worker_id: WORKER_ID,
        p_limit: 1,
        p_lease_seconds: 120,
      }
    );

    if (!Array.isArray(jobs) || jobs.length === 0) {
      return res.status(200).json({
        ok: true,
        claimed: 0,
        message: "No eligible notifications",
      });
    }

    const job = jobs[0];

    // --------------------------------------------------------
    // PHASE 4 SAFETY:
    //
    // We are NOT sending to Meta yet.
    //
    // Return the claimed notification to PENDING using the
    // existing retry/backoff RPC so the test does not lose it.
    // --------------------------------------------------------

    await callSupabaseRpc(
      supabaseUrl,
      serviceRoleKey,
      "mark_notification_failed",
      {
        p_notification_id: job.notification_id,
        p_worker_id: WORKER_ID,
        p_error:
          "DIJO worker Phase 4 claim test - no provider send attempted",
        p_retry_after_seconds: 60,
        p_terminal: false,
      }
    );

    return res.status(200).json({
      ok: true,
      claimed: 1,
      testMode: true,
      eventType: job.event_type,
      attemptCount: job.attempt_count,
      requeued: true,
    });
  } catch (error) {
    console.error("Notification worker error:", error);

    return res.status(500).json({
      ok: false,
      error: "Notification worker failed",
    });
  }
};
