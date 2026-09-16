// ============================================================
// DIJO Notification Worker
// Phase 5B - Template Component Discovery
// ============================================================
//
// CURRENT CAPABILITIES
// --------------------
// 1. Public read-only health check
// 2. Supabase authenticated connectivity verification
// 3. Meta WhatsApp authenticated connectivity verification
// 4. Confirms configured Phone Number ID belongs to the WABA
// 5. Protected Meta WhatsApp template discovery
// 6. Returns full template components/parameter definitions
// 7. Protected notification-outbox claim testing
//
// IMPORTANT
// ---------
// WhatsApp message sending is STILL DISABLED.
//
// There is intentionally NO request to:
//
//     /{PHONE_NUMBER_ID}/messages
//
// in this version.
//
// ============================================================

const crypto = require("crypto");


// ============================================================
// CONFIGURATION
// ============================================================

const WORKER_ID =
  "dijo-vercel-worker-v1";

const META_GRAPH_VERSION =
  process.env.META_GRAPH_VERSION ||
  "v26.0";


// ============================================================
// GENERAL HELPERS
// ============================================================

function removeTrailingSlash(value) {
  return String(value || "")
    .replace(/\/+$/, "");
}


function safeSecretMatch(
  expected,
  supplied
) {
  if (!expected || !supplied) {
    return false;
  }

  const expectedBuffer =
    Buffer.from(
      String(expected),
      "utf8"
    );

  const suppliedBuffer =
    Buffer.from(
      String(supplied),
      "utf8"
    );


  if (
    expectedBuffer.length !==
    suppliedBuffer.length
  ) {
    return false;
  }


  return crypto.timingSafeEqual(
    expectedBuffer,
    suppliedBuffer
  );
}


// ============================================================
// REQUEST BODY PARSER
// ============================================================

function parseRequestBody(req) {
  const body =
    req.body;


  if (!body) {
    return {};
  }


  // Vercel may already have parsed JSON.
  if (
    typeof body === "object" &&
    !Buffer.isBuffer(body)
  ) {
    return body;
  }


  try {

    const bodyText =
      Buffer.isBuffer(body)
        ? body.toString("utf8")
        : String(body);


    return JSON.parse(
      bodyText
    );

  } catch {

    return {};
  }
}


// ============================================================
// ACTION RESOLUTION
// ============================================================
//
// Preferred:
//   ?action=list_templates
//
// Also supported:
//   JSON body:
//   {
//     "action": "list_templates"
//   }
//
// IMPORTANT:
// Missing action does NOT default to a queue mutation.
// ============================================================

function getRequestedAction(req) {

  // ----------------------------------------------------------
  // 1. Vercel query parser
  // ----------------------------------------------------------

  const queryAction =
    req.query?.action;


  if (
    typeof queryAction === "string" &&
    queryAction.trim() !== ""
  ) {
    return queryAction.trim();
  }


  if (
    Array.isArray(queryAction) &&
    queryAction.length > 0
  ) {
    return String(
      queryAction[0]
    ).trim();
  }


  // ----------------------------------------------------------
  // 2. Raw URL fallback
  // ----------------------------------------------------------

  try {

    const host =
      req.headers?.host ||
      "dijo.local";


    const requestUrl =
      new URL(
        req.url || "/",
        `https://${host}`
      );


    const urlAction =
      requestUrl.searchParams
        .get("action");


    if (
      urlAction &&
      urlAction.trim() !== ""
    ) {
      return urlAction.trim();
    }

  } catch {

    // Continue to body fallback.
  }


  // ----------------------------------------------------------
  // 3. JSON body fallback
  // ----------------------------------------------------------

  const parsedBody =
    parseRequestBody(req);


  if (
    typeof parsedBody.action ===
      "string" &&
    parsedBody.action.trim() !== ""
  ) {
    return parsedBody.action.trim();
  }


  // No implicit claim_test fallback.
  return null;
}


// ============================================================
// SUPABASE RPC HELPER
// ============================================================

async function callSupabaseRpc(
  supabaseUrl,
  serviceRoleKey,
  rpcName,
  body
) {

  const baseUrl =
    removeTrailingSlash(
      supabaseUrl
    );


  const response =
    await fetch(
      `${baseUrl}/rest/v1/rpc/${encodeURIComponent(
        rpcName
      )}`,
      {
        method: "POST",

        headers: {
          "Content-Type":
            "application/json",

          apikey:
            serviceRoleKey,

          Authorization:
            `Bearer ${serviceRoleKey}`,
        },

        body:
          JSON.stringify(
            body || {}
          ),
      }
    );


  const responseText =
    await response.text();


  if (!response.ok) {

    throw new Error(
      `Supabase RPC ${rpcName} failed ` +
      `(${response.status}): ` +
      responseText
    );
  }


  if (!responseText) {
    return null;
  }


  try {

    return JSON.parse(
      responseText
    );

  } catch {

    return responseText;
  }
}


// ============================================================
// META GRAPH API HELPER
// ============================================================

async function callMetaGraph(
  accessToken,
  path,
  queryParameters = {}
) {

  const url =
    new URL(
      `https://graph.facebook.com/` +
      `${META_GRAPH_VERSION}/` +
      `${path}`
    );


  for (
    const [key, value]
    of Object.entries(
      queryParameters
    )
  ) {

    if (
      value !== undefined &&
      value !== null
    ) {

      url.searchParams.set(
        key,
        String(value)
      );
    }
  }


  const response =
    await fetch(
      url.toString(),
      {
        method: "GET",

        headers: {
          Authorization:
            `Bearer ${accessToken}`,
        },
      }
    );


  const responseText =
    await response.text();


  if (!response.ok) {

    throw new Error(
      `Meta Graph API failed ` +
      `(${response.status}): ` +
      responseText
    );
  }


  if (!responseText) {
    return {};
  }


  return JSON.parse(
    responseText
  );
}


// ============================================================
// META WHATSAPP CONNECTION CHECK
// ============================================================

async function checkMetaConnection(
  accessToken,
  businessAccountId,
  phoneNumberId
) {

  const result =
    await callMetaGraph(
      accessToken,

      `${encodeURIComponent(
        businessAccountId
      )}/phone_numbers`,

      {
        fields:
          "id,display_phone_number,verified_name",

        limit:
          100,
      }
    );


  const phoneNumbers =
    Array.isArray(
      result.data
    )
      ? result.data
      : [];


  const phoneNumberMatched =
    phoneNumbers.some(
      (phoneNumber) =>
        String(
          phoneNumber.id
        ) ===
        String(
          phoneNumberId
        )
    );


  return {
    connected:
      true,

    phoneNumberMatched,
  };
}


// ============================================================
// META TEMPLATE DISCOVERY
// ============================================================
//
// Components are deliberately included now.
//
// This lets us inspect:
//   HEADER
//   BODY
//   FOOTER
//   BUTTONS
//   parameter placeholders
//   example values
//
// before DIJO attempts any real send.
// ============================================================

async function getMetaTemplates(
  accessToken,
  businessAccountId
) {

  const result =
    await callMetaGraph(
      accessToken,

      `${encodeURIComponent(
        businessAccountId
      )}/message_templates`,

      {
        fields:
          "name,status,language,category,components",

        limit:
          100,
      }
    );


  const templates =
    Array.isArray(
      result.data
    )
      ? result.data
      : [];


  return templates.map(
    (template) => ({

      name:
        template.name ??
        null,

      status:
        template.status ??
        null,

      language:
        template.language ??
        null,

      category:
        template.category ??
        null,

      components:
        Array.isArray(
          template.components
        )
          ? template.components
          : [],
    })
  );
}


// ============================================================
// MAIN VERCEL HANDLER
// ============================================================

module.exports =
async function handler(
  req,
  res
) {

  res.setHeader(
    "Content-Type",
    "application/json"
  );


  // ==========================================================
  // ENVIRONMENT VARIABLES
  // ==========================================================

  const supabaseUrl =
    process.env
      .SUPABASE_URL;


  const serviceRoleKey =
    process.env
      .SUPABASE_SERVICE_ROLE_KEY;


  const workerSecret =
    process.env
      .DIJO_WORKER_SECRET;


  const whatsappAccessToken =
    process.env
      .WHATSAPP_ACCESS_TOKEN;


  const whatsappPhoneNumberId =
    process.env
      .WHATSAPP_PHONE_NUMBER_ID;


  const whatsappBusinessAccountId =
    process.env
      .WHATSAPP_BUSINESS_ACCOUNT_ID;


  const whatsappTestRecipient =
    process.env
      .WHATSAPP_TEST_RECIPIENT;


  // ==========================================================
  // GET
  // PUBLIC READ-ONLY HEALTH CHECK
  // ==========================================================

  if (req.method === "GET") {

    const supabaseConfigured =
      Boolean(
        supabaseUrl &&
        serviceRoleKey &&
        workerSecret
      );


    const metaConfigured =
      Boolean(
        whatsappAccessToken &&
        whatsappPhoneNumberId &&
        whatsappBusinessAccountId
      );


    const testRecipientConfigured =
      Boolean(
        whatsappTestRecipient
      );


    if (
      !supabaseConfigured ||
      !metaConfigured
    ) {

      return res
        .status(500)
        .json({

          ok:
            false,

          service:
            "dijo-notification-worker",

          status:
            "misconfigured",

          supabaseConfigured,

          metaConfigured,

          testRecipientConfigured,

          metaGraphVersion:
            META_GRAPH_VERSION,

          messageSendingEnabled:
            false,
        });
    }


    try {

      // -------------------------------------------------------
      // SUPABASE READ-ONLY CONNECTIVITY TEST
      // -------------------------------------------------------

      const eligibilityResult =
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
        eligibilityResult === true ||
        eligibilityResult === false;


      // -------------------------------------------------------
      // META READ-ONLY CONNECTIVITY TEST
      // -------------------------------------------------------

      const metaConnection =
        await checkMetaConnection(
          whatsappAccessToken,

          whatsappBusinessAccountId,

          whatsappPhoneNumberId
        );


      return res
        .status(200)
        .json({

          ok:
            true,

          service:
            "dijo-notification-worker",

          status:
            "ready",

          supabaseConfigured:
            true,

          supabaseConnected,

          metaConfigured:
            true,

          metaConnected:
            metaConnection.connected,

          phoneNumberMatched:
            metaConnection
              .phoneNumberMatched,

          testRecipientConfigured,

          metaGraphVersion:
            META_GRAPH_VERSION,

          messageSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO worker health check failed:",
        error
      );


      return res
        .status(502)
        .json({

          ok:
            false,

          service:
            "dijo-notification-worker",

          status:
            "connection-error",

          metaGraphVersion:
            META_GRAPH_VERSION,

          messageSendingEnabled:
            false,
        });
    }
  }


  // ==========================================================
  // METHOD PROTECTION
  // ==========================================================

  if (
    req.method !== "POST"
  ) {

    return res
      .status(405)
      .json({

        ok:
          false,

        error:
          "Method not allowed",
      });
  }


  // ==========================================================
  // AUTHENTICATE PROTECTED WORKER REQUEST
  // ==========================================================

  const suppliedSecret =
    req.headers[
      "x-dijo-worker-secret"
    ];


  if (
    !safeSecretMatch(
      workerSecret,
      suppliedSecret
    )
  ) {

    return res
      .status(401)
      .json({

        ok:
          false,

        error:
          "Unauthorized",
      });
  }


  // ==========================================================
  // DETERMINE ACTION
  // ==========================================================

  const action =
    getRequestedAction(
      req
    );


  if (!action) {

    return res
      .status(400)
      .json({

        ok:
          false,

        error:
          "Worker action is required",

        allowedActions: [
          "list_templates",
          "claim_test",
        ],

        messageSendingEnabled:
          false,
      });
  }


  // ==========================================================
  // ACTION:
  // LIST META WHATSAPP TEMPLATES
  //
  // READ ONLY.
  // ==========================================================

  if (
    action ===
    "list_templates"
  ) {

    if (
      !whatsappAccessToken ||
      !whatsappBusinessAccountId
    ) {

      return res
        .status(500)
        .json({

          ok:
            false,

          action:
            "list_templates",

          error:
            "Meta environment is not configured",

          messageSendingEnabled:
            false,
        });
    }


    try {

      const templates =
        await getMetaTemplates(
          whatsappAccessToken,
          whatsappBusinessAccountId
        );


      const approvedTemplates =
        templates.filter(
          (template) =>
            String(
              template.status
            ).toUpperCase() ===
            "APPROVED"
        );


      return res
        .status(200)
        .json({

          ok:
            true,

          action:
            "list_templates",

          count:
            templates.length,

          approvedCount:
            approvedTemplates.length,

          templates,

          metaGraphVersion:
            META_GRAPH_VERSION,

          messageSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO Meta template discovery failed:",
        error
      );


      return res
        .status(502)
        .json({

          ok:
            false,

          action:
            "list_templates",

          error:
            "Meta template discovery failed",

          metaGraphVersion:
            META_GRAPH_VERSION,

          messageSendingEnabled:
            false,
        });
    }
  }


  // ==========================================================
  // ACTION:
  // CLAIM TEST
  //
  // TEST MODE ONLY.
  //
  // Claims exactly one eligible notification.
  //
  // It DOES NOT send anything to Meta.
  //
  // The notification is immediately returned to PENDING using
  // mark_notification_failed() with a short retry delay.
  // ==========================================================

  if (
    action ===
    "claim_test"
  ) {

    if (
      !supabaseUrl ||
      !serviceRoleKey
    ) {

      return res
        .status(500)
        .json({

          ok:
            false,

          action:
            "claim_test",

          error:
            "Supabase worker environment is not configured",

          messageSendingEnabled:
            false,
        });
    }


    try {

      const jobs =
        await callSupabaseRpc(
          supabaseUrl,

          serviceRoleKey,

          "claim_notification_outbox",

          {
            p_worker_id:
              WORKER_ID,

            p_limit:
              1,

            p_lease_seconds:
              120,
          }
        );


      if (
        !Array.isArray(jobs) ||
        jobs.length === 0
      ) {

        return res
          .status(200)
          .json({

            ok:
              true,

            action:
              "claim_test",

            claimed:
              0,

            message:
              "No eligible notifications",

            messageSendingEnabled:
              false,
          });
      }


      const job =
        jobs[0];


      // -------------------------------------------------------
      // SAFETY
      //
      // Provider sending remains disabled.
      // Requeue claimed notification.
      // -------------------------------------------------------

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
            "DIJO worker claim test - provider send disabled",

          p_retry_after_seconds:
            60,

          p_terminal:
            false,
        }
      );


      return res
        .status(200)
        .json({

          ok:
            true,

          action:
            "claim_test",

          claimed:
            1,

          notificationId:
            job.notification_id,

          testMode:
            true,

          eventType:
            job.event_type,

          attemptCount:
            job.attempt_count,

          requeued:
            true,

          messageSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO notification claim test failed:",
        error
      );


      return res
        .status(500)
        .json({

          ok:
            false,

          action:
            "claim_test",

          error:
            "Notification claim test failed",

          messageSendingEnabled:
            false,
        });
    }
  }


  // ==========================================================
  // UNKNOWN ACTION
  // ==========================================================

  return res
    .status(400)
    .json({

      ok:
        false,

      error:
        "Unknown worker action",

      requestedAction:
        action,

      allowedActions: [
        "list_templates",
        "claim_test",
      ],

      messageSendingEnabled:
        false,
    });
};
