import { Router } from "express";
import { z } from "zod";
import { env } from "../config/env.js";
import { requireAuth } from "../middleware/auth.js";
import { publicSupabase } from "../config/supabase.js";

export const authRouter = Router();

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(6)
});

const registerSchema = z.object({
  name: z.string().trim().min(1),
  email: z.string().email(),
  password: z.string().min(6)
});

authRouter.post("/auth/register", async (req, res) => {
  const parsed = registerSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Invalid payload", details: parsed.error.flatten() });
  }

  const { name, email, password } = parsed.data;
  const { data, error } = await publicSupabase.auth.signUp({
    email,
    password,
    options: {
      data: { name },
      emailRedirectTo: env.AUTH_EMAIL_REDIRECT_URL
    }
  });

  if (error) {
    const message = error.message.toLowerCase();
    if (message.includes("already")) {
      return res.status(409).json({ error: "Account already exists" });
    }
    return res.status(400).json({ error: "Failed to create account", details: error.message });
  }

  const resolvedName = resolveDisplayName(data.user?.user_metadata, data.user?.email, name);
  if (!data.session) {
    return res.status(202).json({
      requiresEmailVerification: true,
      message: "Verification email sent. Please verify your email before logging in.",
      user: {
        id: data.user?.id ?? "",
        name: resolvedName,
        email: data.user?.email ?? email
      }
    });
  }

  return res.status(201).json({
    accessToken: data.session.access_token,
    refreshToken: data.session.refresh_token,
    user: {
      id: data.user?.id ?? "",
      name: resolvedName,
      email: data.user?.email ?? email
    }
  });
});

authRouter.post("/auth/login", async (req, res) => {
  const parsed = loginSchema.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: "Invalid payload", details: parsed.error.flatten() });
  }

  const { email, password } = parsed.data;
  const { data, error } = await publicSupabase.auth.signInWithPassword({ email, password });

  if (error || !data.session) {
    const details = error?.message ?? "Unknown auth error";
    if (details.toLowerCase().includes("email not confirmed")) {
      return res.status(403).json({
        error: "Please verify your email before logging in.",
        details
      });
    }
    return res.status(401).json({ error: "Invalid email or password", details: error?.message });
  }

  const name = resolveDisplayName(data.user?.user_metadata, data.user?.email, "Athlete");

  return res.json({
    accessToken: data.session.access_token,
    refreshToken: data.session.refresh_token,
    user: {
      id: data.user?.id ?? "",
      name,
      email: data.user?.email ?? email
    }
  });
});

authRouter.get("/auth/me", requireAuth, async (_req, res) => {
  return res.json({ user: res.locals.authUser });
});

function resolveDisplayName(
  metadata: Record<string, unknown> | undefined,
  email: string | undefined,
  fallback: string
) {
  const candidate = metadata?.name ?? metadata?.full_name;
  if (typeof candidate === "string" && candidate.trim().length > 0) {
    return candidate.trim();
  }
  if (email && email.includes("@")) {
    return email.split("@")[0] ?? fallback;
  }
  return fallback;
}
