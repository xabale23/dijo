// DIJO Notification Worker
// Phase 1: Vercel endpoint health check

module.exports = async function handler(req, res) {
  res.setHeader("Content-Type", "application/json");

  if (req.method !== "GET") {
    return res.status(405).json({
      ok: false,
      error: "Method not allowed",
    });
  }

  return res.status(200).json({
    ok: true,
    service: "dijo-notification-worker",
    status: "ready",
  });
};
