import { z } from "zod";

export const sessionSummarySchema = z.object({
  sessionId: z.string().uuid().optional(),
  athleteId: z.string().uuid().optional(),
  sport: z.string().min(1),
  startedAt: z.string().datetime(),
  endedAt: z.string().datetime(),
  durationSec: z.number().nonnegative(),
  distanceKm: z.number().nonnegative(),
  activeCalories: z.number().nonnegative(),
  totalCalories: z.number().nonnegative(),
  averageSpeedKmh: z.number().nonnegative(),
  maxSpeedKmh: z.number().nonnegative(),
  averagePaceMinPerKm: z.number().nonnegative().nullable().optional(),
  highSpeedDistanceKm: z.number().nonnegative(),
  sprintDistanceKm: z.number().nonnegative(),
  sprintCount: z.number().int().nonnegative(),
  accelerationCount: z.number().int().nonnegative(),
  decelerationCount: z.number().int().nonnegative()
});

export const sessionSampleSchema = z.object({
  timestamp: z.string().datetime(),
  latitude: z.number(),
  longitude: z.number(),
  altitudeM: z.number().nullable().optional(),
  speedKmh: z.number().nonnegative(),
  horizontalAccuracyM: z.number().nonnegative().nullable().optional()
});

export const sessionSamplesPayloadSchema = z.object({
  samples: z.array(sessionSampleSchema).min(1).max(2000)
});

export type SessionSummaryInput = z.infer<typeof sessionSummarySchema>;
export type SessionSampleInput = z.infer<typeof sessionSampleSchema>;
