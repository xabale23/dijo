// ============================================================
// DIJO WhatsApp Webhook
// Secure Meta webhook verification
// ============================================================
//
// CURRENT PURPOSE
// ---------------
// 1. GET  -> Meta webhook verification handshake
// 2. POST -> Verify X-Hub-Signature-256
// 3. Parse WhatsApp webhook payload safely
// 4. Acknowledge legitimate Meta events
//
// IMPORTANT
// ---------
// This version DOES NOT:
// - modify DIJO orders
// - modify deliveries
// - send WhatsApp messages
// - store inbound message content
// - log customer phone numbers or message text
//
// ============================================================

const crypto = require("crypto");


// ============================================================
// CONSTANTS
// ============================================================

const SERVICE_NAME =
  "dijo-whatsapp-webhook";


// ============================================================
// GENERAL HELPERS
// ============================================================

function safeStringMatch(expected, supplied) {
  if (!expected || !supplied) {
    return false;
  }

  const expectedBuffer =
    Buffer.from(String(expected), "utf8");

  const suppliedBuffer =
    Buffer.from(String(supplied), "utf8");

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
// QUERY PARAMETER HELPER
// ============================================================

function getQueryParameter(req, name) {

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
    return String(queryValue[0]);
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
// RAW REQUEST BODY
// ============================================================
//
// Meta signs the exact raw POST bytes.
//
// We therefore verify the signature BEFORE parsing JSON.
//
// ============================================================

async function readRawBody(req) {

  const chunks = [];

  for await (const chunk of req) {

    chunks.push(
      Buffer.isBuffer(chunk)
        ? chunk
        : Buffer.from(chunk)
    );
  }

  return Buffer.concat(chunks);
}


// ============================================================
// META SIGNATURE VERIFICATION
// ============================================================
//
// Header:
//
// X-Hub-Signature-256:
// sha256=<HMAC-SHA256>
//
// Secret:
// Meta App Secret
//
// Data:
// exact raw webhook request body
//
// ============================================================

function verifyMetaSignature(
  rawBody,
  signatureHeader,
  appSecret
) {

  if (
    !rawBody ||
    !signatureHeader ||
    !appSecret
  ) {
    return false;
  }


  const expectedSignature =
    "sha256=" +
    crypto
      .createHmac(
        "sha256",
        appSecret
      )
      .update(rawBody)
      .digest("hex");


  const expectedBuffer =
    Buffer.from(
      expectedSignature,
      "utf8"
    );


  const suppliedBuffer =
    Buffer.from(
      String(signatureHeader),
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
// SAFE WEBHOOK SUMMARY
// ============================================================
//
// We deliberately do NOT log:
//
// - phone numbers
// - message text
// - names
// - addresses
//
// Only structural counts/types are returned.
//
// ============================================================

function summarizeWebhook(payload) {

  let changeCount = 0;
  let messageCount = 0;
  let statusCount = 0;

  const messageTypes =
    new Set();


  const entries =
    Array.isArray(payload?.entry)
      ? payload.entry
      : [];


  for (const entry of entries) {

    const changes =
      Array.isArray(entry?.changes)
        ? entry.changes
        : [];


    for (const change of changes) {

      changeCount += 1;

      const value =
        change?.value || {};


      const messages =
        Array.isArray(value.messages)
          ? value.messages
          : [];


      const statuses =
        Array.isArray(value.statuses)
          ? value.statuses
          : [];


      messageCount +=
        messages.length;

      statusCount +=
        statuses.length;


      for (const message of messages) {

        if (
          message?.type &&
          typeof message.type ===
            "string"
        ) {
          messageTypes.add(
            message.type
          );
        }
      }
    }
  }


  return {

    object:
      payload?.object ||
      null,

    entries:
      entries.length,

    changes:
      changeCount,

    messages:
      messageCount,

    statuses:
      statusCount,

    messageTypes:
      Array.from(
        messageTypes
      ),
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
    "Cache-Control",
    "no-store"
  );


  // ==========================================================
  // GET
  // META WEBHOOK VERIFICATION
  // ==========================================================

  if (
    req.method === "GET"
  ) {

    const verifyToken =
      process.env
        .WHATSAPP_WEBHOOK_VERIFY_TOKEN;


    // --------------------------------------------------------
    // Meta sends:
    //
    // hub.mode
    // hub.verify_token
    // hub.challenge
    //
    // --------------------------------------------------------

    const mode =
      getQueryParameter(
        req,
        "hub.mode"
      );


    const suppliedToken =
      getQueryParameter(
        req,
        "hub.verify_token"
      );


    const challenge =
      getQueryParameter(
        req,
        "hub.challenge"
      );


    // --------------------------------------------------------
    // Normal browser health check
    //
    // If Meta verification parameters are absent, return
    // non-sensitive endpoint status.
    // --------------------------------------------------------

    if (
      mode === null &&
      suppliedToken === null &&
      challenge === null
    ) {

      return res
        .status(200)
        .json({

          ok:
            true,

          service:
            SERVICE_NAME,

          status:
            "ready",

          verifyTokenConfigured:
            Boolean(
              verifyToken
            ),

          appSecretConfigured:
            Boolean(
              process.env
                .META_APP_SECRET
            ),

          inboundProcessingEnabled:
            false,
        });
    }


    // --------------------------------------------------------
    // Meta verification handshake
    // --------------------------------------------------------

    if (
      mode === "subscribe" &&
      challenge &&
      safeStringMatch(
        verifyToken,
        suppliedToken
      )
    ) {

      console.log(
        "DIJO WhatsApp webhook verification succeeded"
      );


      // Meta requires the raw challenge,
      // not a JSON object.
      res.setHeader(
        "Content-Type",
        "text/plain"
      );


      return res
        .status(200)
        .send(
          String(challenge)
        );
    }


    console.warn(
      "DIJO WhatsApp webhook verification rejected"
    );


    return res
      .status(403)
      .json({

        ok:
          false,

        error:
          "Webhook verification failed",
      });
  }


  // ==========================================================
  // POST
  // WHATSAPP WEBHOOK DELIVERY
  // ==========================================================

  if (
    req.method === "POST"
  ) {

    const appSecret =
      process.env
        .META_APP_SECRET;


    if (!appSecret) {

      console.error(
        "META_APP_SECRET is not configured"
      );


      return res
        .status(500)
        .json({

          ok:
            false,

          error:
            "Webhook security is not configured",
        });
    }


    // --------------------------------------------------------
    // Read exact raw request bytes.
    // --------------------------------------------------------

    let rawBody;


    try {

      rawBody =
        await readRawBody(
          req
        );

    } catch (error) {

      console.error(
        "Unable to read WhatsApp webhook body:",
        error
      );


      return res
        .status(400)
        .json({

          ok:
            false,

          error:
            "Invalid webhook body",
        });
    }


    // --------------------------------------------------------
    // Verify Meta signature BEFORE parsing.
    // --------------------------------------------------------

    const signatureHeader =
      req.headers[
        "x-hub-signature-256"
      ];


    const signatureValid =
      verifyMetaSignature(
        rawBody,
        signatureHeader,
        appSecret
      );


    if (!signatureValid) {

      console.warn(
        "Rejected WhatsApp webhook with invalid signature"
      );


      return res
        .status(401)
        .json({

          ok:
            false,

          error:
            "Invalid webhook signature",
        });
    }


    // --------------------------------------------------------
    // Parse JSON only after signature verification.
    // --------------------------------------------------------

    let payload;


    try {

      payload =
        JSON.parse(
          rawBody.toString(
            "utf8"
          )
        );

    } catch (error) {

      console.error(
        "Verified WhatsApp webhook contained invalid JSON:",
        error
      );


      return res
        .status(400)
        .json({

          ok:
            false,

          error:
            "Invalid webhook JSON",
        });
    }


    // --------------------------------------------------------
    // Confirm this is a WhatsApp Business Account webhook.
    // --------------------------------------------------------

    if (
      payload?.object !==
      "whatsapp_business_account"
    ) {

      console.warn(
        "Received signed non-WhatsApp webhook object"
      );


      // Acknowledge a valid Meta-signed event,
      // but do not process it.
      return res
        .status(200)
        .json({

          ok:
            true,

          received:
            true,

          processed:
            false,
        });
    }


    // --------------------------------------------------------
    // Phase safety:
    //
    // We only inspect structure and acknowledge delivery.
    // No application-side mutation occurs yet.
    // --------------------------------------------------------

    const summary =
      summarizeWebhook(
        payload
      );


    console.log(
      "Verified DIJO WhatsApp webhook received:",
      summary
    );


    return res
      .status(200)
      .json({

        ok:
          true,

        received:
          true,

        signatureVerified:
          true,

        processed:
          false,

        summary,
      });
  }


  // ==========================================================
  // OTHER HTTP METHODS
  // ==========================================================

  return res
    .status(405)
    .json({

      ok:
        false,

      error:
        "Method not allowed",
    });
};
