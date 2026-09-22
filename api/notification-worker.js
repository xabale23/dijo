// ============================================================
// DIJO Notification Worker
// Phase 5D - WABA Webhook Subscription
// ============================================================
//
// CAPABILITIES
// ------------
// 1. Public read-only health check
// 2. Supabase connectivity verification
// 3. Meta WhatsApp connectivity verification
// 4. Phone Number ID / WABA relationship verification
// 5. Meta template discovery
// 6. Notification-outbox claim testing
// 7. Controlled WhatsApp test-template sending
// 8. Subscribe DIJO app to configured WABA webhooks
//
// IMPORTANT
// ---------
// Production notification_outbox -> WhatsApp sending remains
// DISABLED.
//
// subscribe_waba:
//   - uses WHATSAPP_BUSINESS_ACCOUNT_ID from Vercel
//   - uses WHATSAPP_ACCESS_TOKEN from Vercel
//   - caller cannot supply another WABA
//   - sends no WhatsApp message
//   - touches no Supabase notification jobs
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


const TEST_TEMPLATE_NAME =
  "jaspers_market_order_confirmation_v1";

const TEST_TEMPLATE_LANGUAGE =
  "en_US";


const TEST_TEMPLATE_PARAMETERS = [
  "DIJO Test",
  "DIJO-TEST-001",
  "Today",
];


const TEST_SEND_CONFIRMATION =
  "SEND_DIJO_TEST";


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


function normalizeWhatsAppNumber(value) {
  return String(value || "")
    .replace(/\D/g, "");
}


function maskWhatsAppNumber(value) {
  const normalized =
    normalizeWhatsAppNumber(value);

  if (!normalized) {
    return null;
  }

  return `********${normalized.slice(-4)}`;
}


// ============================================================
// REQUEST BODY
// ============================================================

function parseRequestBody(req) {

  const body =
    req.body;


  if (!body) {
    return {};
  }


  if (
    typeof body === "object" &&
    !Buffer.isBuffer(body)
  ) {
    return body;
  }


  try {

    const text =
      Buffer.isBuffer(body)
        ? body.toString("utf8")
        : String(body);


    return JSON.parse(text);

  } catch {

    return {};
  }
}


// ============================================================
// QUERY PARAMETERS
// ============================================================

function getQueryParameter(
  req,
  name
) {

  const queryValue =
    req.query?.[name];


  if (
    typeof queryValue === "string"
  ) {
    return queryValue;
  }


  if (
    Array.isArray(queryValue) &&
    queryValue.length > 0
  ) {
    return String(
      queryValue[0]
    );
  }


  try {

    const host =
      req.headers?.host ||
      "dijo.local";


    const requestUrl =
      new URL(
        req.url || "/",
        `https://${host}`
      );


    return requestUrl
      .searchParams
      .get(name);

  } catch {

    return null;
  }
}


// ============================================================
// ACTION RESOLUTION
// ============================================================
//
// Preferred:
//
// ?action=list_templates
// ?action=claim_test
// ?action=send_test_template
// ?action=subscribe_waba
//
// JSON body action remains a fallback.
//
// Missing action never defaults to a mutating operation.
// ============================================================

function getRequestedAction(req) {

  const queryAction =
    getQueryParameter(
      req,
      "action"
    );


  if (
    queryAction &&
    queryAction.trim() !== ""
  ) {
    return queryAction.trim();
  }


  const parsedBody =
    parseRequestBody(req);


  if (
    typeof parsedBody.action === "string" &&
    parsedBody.action.trim() !== ""
  ) {
    return parsedBody.action.trim();
  }


  return null;
}


// ============================================================
// SUPABASE RPC
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
// META GRAPH GET
// ============================================================

async function callMetaGraphGet(
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
      `Meta Graph GET failed ` +
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
// META GRAPH POST
// ============================================================

async function callMetaGraphPost(
  accessToken,
  path,
  body = null
) {

  const url =
    `https://graph.facebook.com/` +
    `${META_GRAPH_VERSION}/` +
    `${path}`;


  const options = {

    method:
      "POST",

    headers: {
      Authorization:
        `Bearer ${accessToken}`,
    },
  };


  if (
    body !== null &&
    body !== undefined
  ) {

    options.headers[
      "Content-Type"
    ] =
      "application/json";


    options.body =
      JSON.stringify(body);
  }


  const response =
    await fetch(
      url,
      options
    );


  const responseText =
    await response.text();


  if (!response.ok) {

    throw new Error(
      `Meta Graph POST failed ` +
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
// META CONNECTION CHECK
// ============================================================

async function checkMetaConnection(
  accessToken,
  businessAccountId,
  phoneNumberId
) {

  const result =
    await callMetaGraphGet(
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

async function getMetaTemplates(
  accessToken,
  businessAccountId
) {

  const result =
    await callMetaGraphGet(
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
// VERIFY CONTROLLED TEST TEMPLATE
// ============================================================

async function verifyTestTemplate(
  accessToken,
  businessAccountId
) {

  const templates =
    await getMetaTemplates(
      accessToken,
      businessAccountId
    );


  const template =
    templates.find(
      (candidate) =>
        candidate.name ===
          TEST_TEMPLATE_NAME &&
        candidate.language ===
          TEST_TEMPLATE_LANGUAGE
    );


  if (!template) {

    throw new Error(
      "Configured test template was not found"
    );
  }


  if (
    String(
      template.status
    ).toUpperCase() !==
    "APPROVED"
  ) {

    throw new Error(
      "Configured test template is not approved"
    );
  }


  return template;
}


// ============================================================
// CONTROLLED WHATSAPP TEST SEND
// ============================================================

async function sendControlledTestTemplate(
  accessToken,
  phoneNumberId,
  testRecipient
) {

  const recipient =
    normalizeWhatsAppNumber(
      testRecipient
    );


  if (
    recipient.length < 8 ||
    recipient.length > 15
  ) {

    throw new Error(
      "Configured test recipient is invalid"
    );
  }


  const result =
    await callMetaGraphPost(
      accessToken,

      `${encodeURIComponent(
        phoneNumberId
      )}/messages`,

      {
        messaging_product:
          "whatsapp",

        recipient_type:
          "individual",

        to:
          recipient,

        type:
          "template",

        template: {

          name:
            TEST_TEMPLATE_NAME,

          language: {
            code:
              TEST_TEMPLATE_LANGUAGE,
          },

          components: [
            {
              type:
                "body",

              parameters:
                TEST_TEMPLATE_PARAMETERS
                  .map(
                    (text) => ({
                      type:
                        "text",

                      text:
                        String(text),
                    })
                  ),
            },
          ],
        },
      }
    );


  const providerMessageId =
    Array.isArray(
      result.messages
    ) &&
    result.messages.length > 0
      ? result.messages[0]?.id
      : null;


  if (!providerMessageId) {

    throw new Error(
      "Meta returned no WhatsApp message ID"
    );
  }


  return {

    providerMessageId,

    messagingProduct:
      result.messaging_product ??
      "whatsapp",
  };
}


// ============================================================
// WABA WEBHOOK SUBSCRIPTION
// ============================================================
//
// Meta endpoint:
//
// POST
// /{WABA-ID}/subscribed_apps
//
// No request body is required.
//
// ============================================================

async function subscribeAppToWaba(
  accessToken,
  businessAccountId
) {

  const result =
    await callMetaGraphPost(
      accessToken,

      `${encodeURIComponent(
        businessAccountId
      )}/subscribed_apps`
    );


  const success =
    result?.success === true ||
    result?.success === "true";


  if (!success) {

    throw new Error(
      "Meta did not confirm the WABA subscription"
    );
  }


  return {
    success:
      true,
  };
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
  // ENVIRONMENT
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

  if (
    req.method === "GET"
  ) {

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

          messageSendingMode:
            "test_only",

          productionQueueSendingEnabled:
            false,
        });
    }


    try {

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

          messageSendingMode:
            "test_only",

          productionQueueSendingEnabled:
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

          productionQueueSendingEnabled:
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
  // AUTHENTICATION
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
  // ACTION
  // ==========================================================

  const action =
    getRequestedAction(
      req
    );


  const allowedActions = [
    "list_templates",
    "claim_test",
    "send_test_template",
    "subscribe_waba",
  ];


  if (!action) {

    return res
      .status(400)
      .json({

        ok:
          false,

        error:
          "Worker action is required",

        allowedActions,

        productionQueueSendingEnabled:
          false,
      });
  }


  // ==========================================================
  // ACTION: LIST TEMPLATES
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
        });
    }


    try {

      const templates =
        await getMetaTemplates(
          whatsappAccessToken,
          whatsappBusinessAccountId
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
            templates.filter(
              (template) =>
                String(
                  template.status
                ).toUpperCase() ===
                "APPROVED"
            ).length,

          templates,

          metaGraphVersion:
            META_GRAPH_VERSION,

          productionQueueSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO template discovery failed:",
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
        });
    }
  }


  // ==========================================================
  // ACTION: CLAIM TEST
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

            productionQueueSendingEnabled:
              false,
          });
      }


      const job =
        jobs[0];


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

          productionQueueSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO claim test failed:",
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
        });
    }
  }


  // ==========================================================
  // ACTION: CONTROLLED TEST TEMPLATE SEND
  // ==========================================================

  if (
    action ===
    "send_test_template"
  ) {

    const confirmation =
      getQueryParameter(
        req,
        "confirm"
      );


    if (
      confirmation !==
      TEST_SEND_CONFIRMATION
    ) {

      return res
        .status(400)
        .json({

          ok:
            false,

          action:
            "send_test_template",

          error:
            "Explicit test-send confirmation is required",

          requiredConfirmation:
            TEST_SEND_CONFIRMATION,

          productionQueueSendingEnabled:
            false,
        });
    }


    if (
      !whatsappAccessToken ||
      !whatsappPhoneNumberId ||
      !whatsappBusinessAccountId ||
      !whatsappTestRecipient
    ) {

      return res
        .status(500)
        .json({

          ok:
            false,

          action:
            "send_test_template",

          error:
            "WhatsApp test environment is not configured",
        });
    }


    try {

      const metaConnection =
        await checkMetaConnection(
          whatsappAccessToken,

          whatsappBusinessAccountId,

          whatsappPhoneNumberId
        );


      if (
        !metaConnection
          .phoneNumberMatched
      ) {

        return res
          .status(409)
          .json({

            ok:
              false,

            action:
              "send_test_template",

            error:
              "Configured phone number does not belong to configured WABA",
          });
      }


      await verifyTestTemplate(
        whatsappAccessToken,

        whatsappBusinessAccountId
      );


      const sendResult =
        await sendControlledTestTemplate(
          whatsappAccessToken,

          whatsappPhoneNumberId,

          whatsappTestRecipient
        );


      return res
        .status(200)
        .json({

          ok:
            true,

          action:
            "send_test_template",

          sent:
            true,

          testMode:
            true,

          templateName:
            TEST_TEMPLATE_NAME,

          templateLanguage:
            TEST_TEMPLATE_LANGUAGE,

          recipient:
            maskWhatsAppNumber(
              whatsappTestRecipient
            ),

          providerMessageId:
            sendResult
              .providerMessageId,

          messagingProduct:
            sendResult
              .messagingProduct,

          productionQueueSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO controlled WhatsApp test failed:",
        error
      );


      return res
        .status(502)
        .json({

          ok:
            false,

          action:
            "send_test_template",

          sent:
            false,

          error:
            "Controlled WhatsApp test send failed",
        });
    }
  }


  // ==========================================================
  // ACTION: SUBSCRIBE APP TO WABA
  //
  // NO MESSAGE SEND
  // NO SUPABASE MUTATION
  // ==========================================================

  if (
    action ===
    "subscribe_waba"
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
            "subscribe_waba",

          error:
            "Meta WABA environment is not configured",

          productionQueueSendingEnabled:
            false,
        });
    }


    try {

      const result =
        await subscribeAppToWaba(
          whatsappAccessToken,

          whatsappBusinessAccountId
        );


      return res
        .status(200)
        .json({

          ok:
            true,

          action:
            "subscribe_waba",

          subscribed:
            result.success,

          webhookEndpoint:
            "/api/webhook",

          messageSent:
            false,

          notificationQueueTouched:
            false,

          metaGraphVersion:
            META_GRAPH_VERSION,

          productionQueueSendingEnabled:
            false,
        });

    } catch (error) {

      console.error(
        "DIJO WABA subscription failed:",
        error
      );


      return res
        .status(502)
        .json({

          ok:
            false,

          action:
            "subscribe_waba",

          subscribed:
            false,

          error:
            "WABA subscription failed",

          productionQueueSendingEnabled:
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

      allowedActions,

      productionQueueSendingEnabled:
        false,
    });
};
