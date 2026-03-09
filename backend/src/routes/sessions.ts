import { randomUUID } from "node:crypto";
import { Router } from "express";
import { requireAuth } from "../middleware/auth.js";
import { supabase } from "../config/supabase.js";
import {
  sessionSamplesPayloadSchema,
  sessionSummarySchema,
  type SessionSampleInput,
  type SessionSummaryInput
} from "../types/session.js";

export const sessionsRouter = Router();
sessionsRouter.use(requireAuth);

sessionsRouter.post("/sessions", async (req, res) => {
  const parsed = sessionSummarySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Invalid payload", details: parsed.error.flatten() });
  }

  const input: SessionSummaryInput = parsed.data;
  const id = input.sessionId ?? randomUUID();
  const athleteId = res.locals.authUser?.id;
  if (!athleteId) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  const authUser = res.locals.authUser;
  const athleteEnsure = await ensureAthleteExists(athleteId, authUser?.name, authUser?.email);
  if (athleteEnsure) {
    return res.status(500).json({ error: "Failed to sync athlete profile", details: athleteEnsure });
  }

  const { error } = await supabase.from("sessions").upsert(
    {
      id,
      athlete_id: athleteId,
      sport: input.sport,
      started_at: input.startedAt,
      ended_at: input.endedAt,
      duration_sec: input.durationSec,
      distance_km: input.distanceKm,
      active_calories: input.activeCalories,
      total_calories: input.totalCalories,
      average_speed_kmh: input.averageSpeedKmh,
      max_speed_kmh: input.maxSpeedKmh,
      average_pace_min_per_km: input.averagePaceMinPerKm ?? null,
      high_speed_distance_km: input.highSpeedDistanceKm,
      sprint_distance_km: input.sprintDistanceKm,
      sprint_count: input.sprintCount,
      acceleration_count: input.accelerationCount,
      deceleration_count: input.decelerationCount
    },
    { onConflict: "id" }
  );

  if (error) {
    return res.status(500).json({ error: "Failed to upsert session", details: error.message });
  }

  return res.status(201).json({ id });
});

sessionsRouter.post("/sessions/:sessionId/samples", async (req, res) => {
  const { sessionId } = req.params;
  const athleteId = res.locals.authUser?.id;
  if (!athleteId) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  const parsed = sessionSamplesPayloadSchema.safeParse(req.body);

  if (!parsed.success) {
    return res.status(400).json({ error: "Invalid payload", details: parsed.error.flatten() });
  }

  const { data: ownedSession, error: ownedSessionError } = await supabase
    .from("sessions")
    .select("id")
    .eq("id", sessionId)
    .eq("athlete_id", athleteId)
    .maybeSingle();

  if (ownedSessionError) {
    return res.status(500).json({ error: "Failed to verify session ownership", details: ownedSessionError.message });
  }
  if (!ownedSession) {
    return res.status(404).json({ error: "Session not found for current user" });
  }

  const rows = parsed.data.samples.map((s: SessionSampleInput) => ({
    session_id: sessionId,
    timestamp: s.timestamp,
    latitude: s.latitude,
    longitude: s.longitude,
    altitude_m: s.altitudeM ?? null,
    speed_kmh: s.speedKmh,
    horizontal_accuracy_m: s.horizontalAccuracyM ?? null
  }));

  const { error } = await supabase.from("session_samples").insert(rows);
  if (error) {
    return res.status(500).json({ error: "Failed to insert samples", details: error.message });
  }

  return res.status(201).json({ inserted: rows.length });
});

sessionsRouter.get("/sessions", async (req, res) => {
  const athleteId = res.locals.authUser?.id;
  if (!athleteId) {
    return res.status(401).json({ error: "Unauthorized" });
  }

  const { data, error } = await supabase
    .from("sessions")
    .select("*")
    .eq("athlete_id", athleteId)
    .order("started_at", { ascending: false })
    .limit(100);

  if (error) {
    return res.status(500).json({ error: "Failed to fetch sessions", details: error.message });
  }

  return res.json({ sessions: data });
});

async function ensureAthleteExists(athleteId: string, displayName?: string, email?: string) {
  const firstName = displayName?.split(" ").find(Boolean) ?? null;
  const lastNameParts = displayName?.split(" ").slice(1).filter(Boolean) ?? [];
  const lastName = lastNameParts.length > 0 ? lastNameParts.join(" ") : null;

  const { error } = await supabase.from("athletes").upsert(
    {
      id: athleteId,
      external_ref: email ?? athleteId,
      first_name: firstName,
      last_name: lastName
    },
    { onConflict: "id" }
  );

  return error?.message;
}
