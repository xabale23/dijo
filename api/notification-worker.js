// DIJO Notification Worker
// Phase 5B:
// - Supabase connectivity
// - Meta connectivity
// - Secure template discovery
// - Secure queue claim testing
// - NO WhatsApp sending yet

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
    throw new Error(
      `Meta Graph API request failed (${response.status}): ${text}`
    );
  }

  const result = JSON.parse(text);

  const numbers = Array.isArray(result.data)
    ? result.data
    : [];

  return {
    connected: true,
    phoneNumberMatched: numbers.some(
      (item) =>
        String(item.id) === String(phoneNumberId)
    ),
  };
}

async function getMetaTemplates(
  accessToken,
  businessAccountId
) {
  const url =
    `https://graph.facebook.com/${META_GRAPH_VERSION}/` +
    `${businessAccountId}/message_templates` +
    `?fields=name,status,language,category&limit=100`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });

  const text = await response.text();

  if (!response.ok) {
    throw new Error(
      `Meta template request failed (${response.status}): ${text}`
    );
  }

  const result = JSON.parse(text);

  return Array.isArray(result.data)
    ? result.data.map((template) => ({
        name: template.name,
        status: template.status,
        language: template.language,
        category: template.category,
      }))
    : [];
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

  const whatsappTestRecipient =
    process.env.WHATSAPP_TEST_RECIPIENT;


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

    const testRecipientConfigured =
      Boolean(whatsappTestRecipient);

    if (!supabaseConfigured || !metaConfigured) {
      return res.status(500).json({
        ok: false,
        service: "dijo-notification-worker",
        status: "misconfigured",
        supabaseConfigured,
        metaConfigured,
        testRecipientConfigured,
      });
    }

    try {

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
        supabaseConnected:
          connected === false ||
          connected === true,

        metaConfigured: true,
        metaConnected: meta.connected,

        phoneNumberMatched:
          meta.phoneNumberMatched,

        testRecipientConfigured,

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
  // ONLY POST MAY ACCESS PROTECTED WORKER OPERATIONS
  // ==========================================================

  if (req.method !== "POST") {
    return res.status(405).json({
      ok: false,
      error: "Method not allowed",
    });
  }


  // ==========================================================
  // AUTHENTICATE WORKER REQUEST
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


  const action =
    req.body?.action || "claim_test";


  // ==========================================================
  // ACTION: LIST META TEMPLATES
  // ==========================================================

  if (action === "list_templates") {

    if (
      !whatsappAccessToken ||
      !whatsappBusinessAccountId
    ) {
      return res.status(500).json({
        ok: false,
        error:
          "Meta environment is not configured",
      });
    }

    try {

      const templates =
        await getMetaTemplates(
          whatsappAccessToken,
          whatsappBusinessAccountId
        );

      return res.status(200).json({
        ok: true,
        action: "list_templates",
        count: templates.length,
        templates,
        messageSendingEnabled: false,
      });

    } catch (error) {

      console.error(
        "Template discovery failed:",
        error
      );

      return res.status(502).json({
        ok: false,
        error:
          "Meta template discovery failed",
      });
    }
  }


  // ==========================================================
  // ACTION: PHASE 4/5 CLAIM TEST
  // ==========================================================

  if (action !== "claim_test") {
    return res.status(400).json({
      ok: false,
      error: "Unknown worker action",
    });
  }


  if (!supabaseUrl || !serviceRoleKey) {
    return res.status(500).json({
      ok: false,
      error:
        "Worker environment is not configured",
    });
  }


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


    // Meta sending is still disabled.
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
          "DIJO worker Phase 5B - provider send disabled",

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
