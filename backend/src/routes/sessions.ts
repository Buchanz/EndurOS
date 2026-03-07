import { randomUUID } from "node:crypto";
import { Router } from "express";
import { supabase } from "../config/supabase.js";
import {
  sessionSamplesPayloadSchema,
  sessionSummarySchema,
  type SessionSampleInput,
  type SessionSummaryInput
} from "../types/session.js";

export const sessionsRouter = Router();

sessionsRouter.post("/sessions", async (req, res) => {
  const parsed = sessionSummarySchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Invalid payload", details: parsed.error.flatten() });
  }

  const input: SessionSummaryInput = parsed.data;
  const id = input.sessionId ?? randomUUID();

  const { error } = await supabase.from("sessions").upsert(
    {
      id,
      athlete_id: input.athleteId,
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
  const parsed = sessionSamplesPayloadSchema.safeParse(req.body);

  if (!parsed.success) {
    return res.status(400).json({ error: "Invalid payload", details: parsed.error.flatten() });
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

sessionsRouter.get("/athletes/:athleteId/sessions", async (req, res) => {
  const { athleteId } = req.params;

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
