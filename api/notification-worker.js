// DIJO Notification Worker
// Phase 5A:
// - Supabase connectivity
// - Meta WhatsApp connectivity
// - Secure queue claiming
// - NO WhatsApp message sending yet

const WORKER_ID = "dijo-vercel-worker-v1";
const META_GRAPH_VERSION = "v26.0";

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

async function checkMetaConnection(
  accessToken,
  businessAccountId,
  phoneNumberId
) {
  const url =
    `https://graph.facebook.com/${META_GRAPH_VERSION}/` +
    `${businessAccountId}/phone_numbers` +
    `?fields=id,display_phone_number,verified_name`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  const text = await response.text();

  if (!response.ok) {
    console.error(
      "Meta WhatsApp connectivity check failed:",
      response.status,
      text
    );

    throw new Error(
      `Meta Graph API request failed (${response.status})`
    );
  }

  const result = JSON.parse(text);

  const numbers = Array.isArray(result.data)
    ? result.data
    : [];

  const matched = numbers.some(
    (item) => String(item.id) === String(phoneNumberId)
  );

  return {
    connected: true,
    phoneNumberMatched: matched,
  };
}

module.exports = async function handler(req, res) {
  res.setHeader("Content-Type", "application/json");

  const supabaseUrl =
    process.env.SUPABASE_URL;

  const serviceRoleKey =
    process.env.SUPABASE_SERVICE_ROLE_KEY;

  const workerSecret =
    process.env.DIJO_WORKER_SECRET;

  const whatsappAccessToken =
    process.env.WHATSAPP_ACCESS_TOKEN;

  const whatsappPhoneNumberId =
    process.env.WHATSAPP_PHONE_NUMBER_ID;

  const whatsappBusinessAccountId =
    process.env.WHATSAPP_BUSINESS_ACCOUNT_ID;


  // ==========================================================
  // PUBLIC READ-ONLY HEALTH CHECK
  // ==========================================================

  if (req.method === "GET") {

    const supabaseConfigured = Boolean(
      supabaseUrl &&
      serviceRoleKey &&
      workerSecret
    );

    const metaConfigured = Boolean(
      whatsappAccessToken &&
      whatsappPhoneNumberId &&
      whatsappBusinessAccountId
    );

    if (!supabaseConfigured || !metaConfigured) {
      return res.status(500).json({
        ok: false,
        service: "dijo-notification-worker",
        status: "misconfigured",
        supabaseConfigured,
        metaConfigured,
      });
    }

    try {

      // -------------------------------------------------------
      // SUPABASE READ-ONLY CHECK
      // -------------------------------------------------------

      const connected =
        await callSupabaseRpc(
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

      const supabaseConnected =
        connected === false ||
        connected === true;


      // -------------------------------------------------------
      // META READ-ONLY CHECK
      //
      // Lists WABA phone numbers.
      // Does NOT call /messages.
      // -------------------------------------------------------

      const meta =
        await checkMetaConnection(
          whatsappAccessToken,
          whatsappBusinessAccountId,
          whatsappPhoneNumberId
        );


      return res.status(200).json({
        ok: true,
        service: "dijo-notification-worker",
        status: "ready",

        supabaseConfigured: true,
        supabaseConnected,

        metaConfigured: true,
        metaConnected: meta.connected,

        phoneNumberMatched:
          meta.phoneNumberMatched,

        metaGraphVersion:
          META_GRAPH_VERSION,

        messageSendingEnabled: false,
      });

    } catch (error) {

      console.error(
        "Worker health check failed:",
        error
      );

      return res.status(502).json({
        ok: false,
        service: "dijo-notification-worker",
        status: "connection-error",
      });
    }
  }


  // ==========================================================
  // ONLY POST MAY PROCESS QUEUE
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
  // PHASE 4 TEST BEHAVIOUR
  //
  // Still claim exactly one job.
  // Still DO NOT send to Meta.
  // Still safely requeue it.
  // ==========================================================

  try {

    const jobs =
      await callSupabaseRpc(
        supabaseUrl,
        serviceRoleKey,
        "claim_notification_outbox",
        {
          p_worker_id: WORKER_ID,
          p_limit: 1,
          p_lease_seconds: 120,
        }
      );


    if (
      !Array.isArray(jobs) ||
      jobs.length === 0
    ) {
      return res.status(200).json({
        ok: true,
        claimed: 0,
        message:
          "No eligible notifications",
      });
    }


    const job = jobs[0];


    // --------------------------------------------------------
    // SAFETY:
    //
    // Meta sending is still disabled.
    // Return claimed job to pending.
    // --------------------------------------------------------

    await callSupabaseRpc(
      supabaseUrl,
      serviceRoleKey,
      "mark_notification_failed",
      {
        p_notification_id:
          job.notification_id,

        p_worker_id:
          WORKER_ID,

        p_error:
          "DIJO worker Phase 5A - provider send disabled",

        p_retry_after_seconds:
          60,

        p_terminal:
          false,
      }
    );


    return res.status(200).json({
      ok: true,
      claimed: 1,
      testMode: true,
      eventType:
        job.event_type,
      attemptCount:
        job.attempt_count,
      requeued: true,
      messageSendingEnabled: false,
    });

  } catch (error) {

    console.error(
      "Notification worker error:",
      error
    );

    return res.status(500).json({
      ok: false,
      error:
        "Notification worker failed",
    });
  }
};
