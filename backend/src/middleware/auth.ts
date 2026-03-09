import type { NextFunction, Request, Response } from "express";
import { publicSupabase } from "../config/supabase.js";

export type AuthenticatedUser = {
  id: string;
  email: string;
  name: string;
};

declare global {
  namespace Express {
    interface Locals {
      authUser?: AuthenticatedUser;
    }
  }
}

export async function requireAuth(req: Request, res: Response, next: NextFunction) {
  const token = bearerTokenFromRequest(req);
  if (!token) {
    return res.status(401).json({ error: "Missing bearer token" });
  }

  const { data, error } = await publicSupabase.auth.getUser(token);
  if (error || !data.user) {
    return res.status(401).json({ error: "Invalid or expired token", details: error?.message });
  }

  const metadata = data.user.user_metadata as Record<string, unknown> | undefined;
  const candidateName = metadata?.name ?? metadata?.full_name;
  const resolvedName =
    typeof candidateName === "string" && candidateName.trim().length > 0
      ? candidateName.trim()
      : deriveNameFromEmail(data.user.email);

  res.locals.authUser = {
    id: data.user.id,
    email: data.user.email ?? "",
    name: resolvedName
  };

  return next();
}

function bearerTokenFromRequest(req: Request) {
  const auth = req.header("authorization");
  if (!auth) return null;
  const [scheme, value] = auth.split(" ");
  if (scheme?.toLowerCase() !== "bearer" || !value) return null;
  return value;
}

function deriveNameFromEmail(email?: string) {
  if (!email || !email.includes("@")) return "Athlete";
  return email.split("@")[0] ?? "Athlete";
}
