import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_BODY_BYTES = 8 * 1024;
const ALLOWED_METHODS = "POST, OPTIONS";
const ALLOWED_HEADERS = "authorization, apikey, content-type, x-client-info";

type InviteRequest =
  | {
      action: "invite";
      empresa_id: string;
      email: string;
    }
  | {
      action: "recover";
      convite_id: string;
    };

type InviteRecord = {
  id: string;
  empresa_id: string;
  email: string;
  estado: "enviando" | "concluido" | "falha";
  auth_user_id: string | null;
};

type AuthInviteUser = {
  id: string;
  email?: string | null;
  invited_at?: string | null;
};

type AuthUserLookup =
  | { status: "found"; user: AuthInviteUser }
  | { status: "not_found" }
  | { status: "not_invited" }
  | { status: "ambiguous" }
  | { status: "incomplete" }
  | { status: "error"; error: unknown };

type InviteFinalization =
  | { status: "completed" }
  | { status: "other_company" }
  | { status: "check_failed"; error: unknown }
  | { status: "finalize_failed"; error: unknown };

function jsonResponse(
  status: number,
  body: Record<string, unknown>,
  corsHeaders: Record<string, string>,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function getCorsHeaders(request: Request): Record<string, string> | null {
  const configuredOrigin = Deno.env.get("CONVITE_ALLOWED_ORIGIN");
  const requestOrigin = request.headers.get("Origin");

  if (requestOrigin && (!configuredOrigin || requestOrigin !== configuredOrigin)) {
    return null;
  }

  if (!requestOrigin) return {};

  return {
    "Access-Control-Allow-Origin": configuredOrigin,
    "Access-Control-Allow-Methods": ALLOWED_METHODS,
    "Access-Control-Allow-Headers": ALLOWED_HEADERS,
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

function getRequiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function parseInviteRequest(value: unknown): InviteRequest | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;

  const body = value as Record<string, unknown>;
  const action = body.action === undefined ? "invite" : body.action;

  if (action === "recover") {
    if (
      Object.keys(body).some((key) => key !== "action" && key !== "convite_id") ||
      typeof body.convite_id !== "string" ||
      !UUID_PATTERN.test(body.convite_id)
    ) {
      return null;
    }
    return { action, convite_id: body.convite_id.toLowerCase() };
  }

  if (action !== "invite") return null;
  if (
    Object.keys(body).some((key) =>
      key !== "action" && key !== "empresa_id" && key !== "email"
    ) ||
    typeof body.empresa_id !== "string" ||
    !UUID_PATTERN.test(body.empresa_id) ||
    typeof body.email !== "string"
  ) {
    return null;
  }

  const email = body.email.trim().toLowerCase();
  if (
    email.length > 254 ||
    !EMAIL_PATTERN.test(email) ||
    /[\u0000-\u001f\u007f]/.test(email)
  ) {
    return null;
  }

  return { action, empresa_id: body.empresa_id.toLowerCase(), email };
}

function createAuthClient(url: string, anonKey: string, accessToken: string): SupabaseClient {
  return createClient(url, anonKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
    global: {
      headers: { Authorization: `Bearer ${accessToken}` },
    },
  });
}

function createServiceClient(url: string, serviceRoleKey: string): SupabaseClient {
  return createClient(url, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      detectSessionInUrl: false,
      persistSession: false,
    },
  });
}

async function markInviteFailed(
  client: SupabaseClient,
  inviteId: string,
  failureCode: string,
  authUserId?: string,
): Promise<void> {
  try {
    let updateQuery = client
      .from("convites_clientes")
      .update({
        estado: "falha",
        ...(authUserId ? { auth_user_id: authUserId } : {}),
        codigo_erro: failureCode,
        atualizado_em: new Date().toISOString(),
      })
      .eq("id", inviteId)
      .in("estado", ["enviando", "falha"]);
    if (authUserId) {
      updateQuery = updateQuery.or(`auth_user_id.is.null,auth_user_id.eq.${authUserId}`);
    }
    const { error } = await updateQuery;

    if (error) {
      console.error("Could not persist invite failure state", {
        inviteId,
        code: error.code,
      });
    }
  } catch (error) {
    console.error("Could not persist invite failure state", {
      inviteId,
      error,
    });
  }
}

async function findAuthUserForInvite(
  client: SupabaseClient,
  invite: InviteRecord,
): Promise<AuthUserLookup> {
  try {
    if (invite.auth_user_id) {
      const { data, error } = await client.auth.admin.getUserById(invite.auth_user_id);
      if (error) return { status: "error", error };
      if (!data.user) return { status: "not_found" };
      if (data.user.email?.trim().toLowerCase() !== invite.email) {
        return { status: "not_invited" };
      }
      if (!data.user.invited_at) return { status: "not_invited" };
      return { status: "found", user: data.user };
    }

    const perPage = 1000;
    const maxPages = 100;
    for (let page = 1; page <= maxPages; page += 1) {
      const { data, error } = await client.auth.admin.listUsers({ page, perPage });
      if (error) return { status: "error", error };

      const matchingUsers = data.users.filter(
        (user) => user.email?.trim().toLowerCase() === invite.email,
      );
      if (matchingUsers.length > 1) return { status: "ambiguous" };
      if (matchingUsers.length === 1) {
        const candidate = matchingUsers[0];
        const { data: verified, error: verificationError } = await client.auth.admin
          .getUserById(candidate.id);
        if (verificationError) return { status: "error", error: verificationError };
        if (!verified.user || verified.user.email?.trim().toLowerCase() !== invite.email) {
          return { status: "not_found" };
        }
        if (!verified.user.invited_at) return { status: "not_invited" };
        return { status: "found", user: verified.user };
      }
      if (data.users.length < perPage) return { status: "not_found" };
    }

    return { status: "incomplete" };
  } catch (error) {
    return { status: "error", error };
  }
}

async function finalizeInviteForUser(
  client: SupabaseClient,
  inviteId: string,
  companyId: string,
  authUserId: string,
): Promise<InviteFinalization> {
  try {
    const { data: memberships, error: membershipError } = await client
      .from("usuario_empresa")
      .select("empresa_id")
      .eq("user_id", authUserId);

    if (membershipError) return { status: "check_failed", error: membershipError };
    if (memberships?.some((membership) => membership.empresa_id !== companyId)) {
      return { status: "other_company" };
    }

    const { error } = await client.rpc("finalizar_convite_cliente", {
      p_convite_id: inviteId,
      p_auth_user_id: authUserId,
    });
    if (!error) return { status: "completed" };

    const { data: completedInvite, error: lookupError } = await client
      .from("convites_clientes")
      .select("estado,auth_user_id,empresa_id")
      .eq("id", inviteId)
      .maybeSingle();

    if (
      !lookupError &&
      completedInvite?.estado === "concluido" &&
      completedInvite.auth_user_id === authUserId &&
      completedInvite.empresa_id === companyId
    ) {
      return { status: "completed" };
    }
    return { status: "finalize_failed", error };
  } catch (error) {
    return { status: "finalize_failed", error };
  }
}

async function recoverInvite(
  client: SupabaseClient,
  inviteId: string,
  corsHeaders: Record<string, string>,
): Promise<Response> {
  let invite: InviteRecord | null;
  try {
    const { data, error } = await client
      .from("convites_clientes")
      .select("id,empresa_id,email,estado,auth_user_id")
      .eq("id", inviteId)
      .maybeSingle();
    if (error) {
      console.error("Could not load invite for recovery", { inviteId, code: error.code });
      return jsonResponse(500, { error: "Não foi possível consultar o convite." }, corsHeaders);
    }
    invite = data as InviteRecord | null;
  } catch (error) {
    console.error("Could not load invite for recovery", { inviteId, error });
    return jsonResponse(500, { error: "Não foi possível consultar o convite." }, corsHeaders);
  }

  if (!invite) {
    return jsonResponse(404, { error: "Convite não encontrado." }, corsHeaders);
  }
  if (invite.estado === "concluido") {
    return jsonResponse(200, {
      status: "already_completed",
      message: "Este convite já foi concluído.",
    }, corsHeaders);
  }
  if (invite.estado !== "enviando" && invite.estado !== "falha") {
    return jsonResponse(409, {
      error: "O estado atual do convite não permite recuperação.",
      status: invite.estado,
    }, corsHeaders);
  }

  const authLookup = await findAuthUserForInvite(client, invite);
  if (authLookup.status !== "found") {
    const responses = {
      not_found: {
        status: 409,
        error: "Não foi encontrado usuário convidado no Auth. Esta recuperação não criou usuários nem enviou e-mails; confira o resultado do convite original antes de tentar novamente.",
      },
      not_invited: {
        status: 409,
        error: "A conta localizada não tem estado de convite confirmado ou o e-mail diverge. Nenhum vínculo foi criado.",
      },
      ambiguous: {
        status: 409,
        error: "Mais de uma conta Auth corresponde ao e-mail. Nenhum vínculo foi criado; revisão manual necessária.",
      },
      incomplete: {
        status: 503,
        error: "A busca no Auth atingiu o limite de paginação sem resultado conclusivo. Nenhum vínculo foi criado.",
      },
      error: {
        status: 502,
        error: "Não foi possível verificar o estado real do usuário no Auth. Tente novamente mais tarde.",
      },
    } as const;
    const failure = responses[authLookup.status];
    if (authLookup.status === "error") {
      console.error("Could not verify invited Auth user", { inviteId, error: authLookup.error });
    }
    return jsonResponse(failure.status, { error: failure.error }, corsHeaders);
  }

  if (authLookup.user.email?.trim().toLowerCase() !== invite.email) {
    return jsonResponse(409, {
      error: "O e-mail do usuário no Auth não corresponde ao convite. Nenhum vínculo foi criado.",
    }, corsHeaders);
  }

  try {
    const { data: updatedInvite, error } = await client
      .from("convites_clientes")
      .update({
        auth_user_id: authLookup.user.id,
        atualizado_em: new Date().toISOString(),
      })
      .eq("id", invite.id)
      .eq("empresa_id", invite.empresa_id)
      .eq("email", invite.email)
      .in("estado", ["enviando", "falha"])
      .or(`auth_user_id.is.null,auth_user_id.eq.${authLookup.user.id}`)
      .select("id")
      .maybeSingle();

    if (error || !updatedInvite) {
      console.error("Could not bind Auth user to invite recovery", {
        inviteId,
        code: error?.code,
      });
      return jsonResponse(409, {
        error: "O convite mudou de estado ou já aponta para outro usuário. Nenhum vínculo foi criado.",
      }, corsHeaders);
    }
  } catch (error) {
    console.error("Could not bind Auth user to invite recovery", { inviteId, error });
    return jsonResponse(500, {
      error: "Não foi possível registrar o usuário Auth no convite. Nenhum vínculo foi criado.",
    }, corsHeaders);
  }

  const result = await finalizeInviteForUser(
    client,
    invite.id,
    invite.empresa_id,
    authLookup.user.id,
  );
  if (result.status === "completed") {
    return jsonResponse(200, {
      status: "recovered",
      message: "Convite recuperado e vínculo confirmado. Nenhum usuário ou e-mail foi criado novamente.",
    }, corsHeaders);
  }

  if (result.status === "other_company") {
    await markInviteFailed(client, invite.id, "user_already_linked_to_other_company", authLookup.user.id);
    return jsonResponse(409, {
      error: "O usuário já está vinculado a outra empresa. O vínculo não foi alterado.",
    }, corsHeaders);
  }

  const failureCode = result.status === "check_failed"
    ? "membership_check_failed"
    : "membership_finalize_failed";
  await markInviteFailed(client, invite.id, failureCode, authLookup.user.id);
  console.error("Could not recover customer invite", {
    inviteId,
    failureCode,
    error: result.status === "completed" || result.status === "other_company"
      ? undefined
      : result.error,
  });
  return jsonResponse(502, {
    error: "Não foi possível concluir o vínculo. O convite permanece registrado para nova tentativa administrativa.",
  }, corsHeaders);
}

function existingInviteResponse(
  record: InviteRecord,
  empresaId: string,
  corsHeaders: Record<string, string>,
): Response {
  if (record.estado === "concluido" && record.empresa_id === empresaId) {
    return jsonResponse(200, {
      status: "already_invited",
      message: "Este e-mail já possui um convite concluído para esta empresa.",
    }, corsHeaders);
  }

  return jsonResponse(409, {
    error: "Já existe uma solicitação para este e-mail. Nenhum novo convite ou vínculo foi criado.",
    status: record.estado,
  }, corsHeaders);
}

Deno.serve(async (request: Request): Promise<Response> => {
  const corsHeaders = getCorsHeaders(request);
  if (!corsHeaders) {
    return jsonResponse(403, { error: "Origem não permitida." }, {});
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "Método não permitido." }, corsHeaders);
  }

  const authorization = request.headers.get("Authorization") ?? "";
  const tokenMatch = /^Bearer\s+(.+)$/i.exec(authorization);
  if (!tokenMatch) {
    return jsonResponse(401, { error: "Autenticação obrigatória." }, corsHeaders);
  }

  const contentLength = Number(request.headers.get("Content-Length") ?? 0);
  if (contentLength > MAX_BODY_BYTES) {
    return jsonResponse(413, { error: "Requisição muito grande." }, corsHeaders);
  }

  let requestBody: unknown;
  try {
    const rawBody = await request.text();
    if (new TextEncoder().encode(rawBody).length > MAX_BODY_BYTES) {
      return jsonResponse(413, { error: "Requisição muito grande." }, corsHeaders);
    }
    requestBody = JSON.parse(rawBody);
  } catch {
    return jsonResponse(400, { error: "Corpo JSON inválido." }, corsHeaders);
  }

  const payload = parseInviteRequest(requestBody);
  if (!payload) {
    return jsonResponse(400, {
      error: "Informe um UUID de empresa válido e um e-mail válido.",
    }, corsHeaders);
  }

  let serviceClient: SupabaseClient;
  let authenticatedClient: SupabaseClient;
  let redirectTo: string;
  try {
    const supabaseUrl = getRequiredEnv("SUPABASE_URL");
    const anonKey = getRequiredEnv("SUPABASE_ANON_KEY");
    const serviceRoleKey = getRequiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    redirectTo = getRequiredEnv("CONVITE_REDIRECT_URL");
    serviceClient = createServiceClient(supabaseUrl, serviceRoleKey);
    authenticatedClient = createAuthClient(supabaseUrl, anonKey, tokenMatch[1]);
  } catch (error) {
    console.error("Invite function configuration error", error);
    return jsonResponse(500, { error: "Função de convite não configurada." }, corsHeaders);
  }

  let redirectUrl: URL;
  try {
    redirectUrl = new URL(redirectTo);
    const isLocalHttp = redirectUrl.protocol === "http:" &&
      ["localhost", "127.0.0.1", "[::1]"].includes(redirectUrl.hostname);
    if (redirectUrl.protocol !== "https:" && !isLocalHttp) {
      throw new Error("CONVITE_REDIRECT_URL must use HTTPS.");
    }
    if (redirectUrl.username || redirectUrl.password) {
      throw new Error("CONVITE_REDIRECT_URL must not contain credentials.");
    }
  } catch (error) {
    console.error("Invite redirect URL configuration error", error);
    return jsonResponse(500, { error: "URL de configuração de senha inválida." }, corsHeaders);
  }

  const { data: userData, error: userError } = await authenticatedClient.auth.getUser(tokenMatch[1]);
  if (userError || !userData.user) {
    return jsonResponse(401, { error: "Sessão inválida ou expirada." }, corsHeaders);
  }

  const requesterId = userData.user.id;
  const { data: administrator, error: administratorError } = await serviceClient
    .from("administradores_plataforma")
    .select("user_id")
    .eq("user_id", requesterId)
    .maybeSingle();

  if (administratorError) {
    console.error("Could not verify platform administrator", {
      userId: requesterId,
      code: administratorError.code,
    });
    return jsonResponse(500, { error: "Não foi possível verificar a autorização." }, corsHeaders);
  }
  if (!administrator) {
    return jsonResponse(403, { error: "Somente administradores da plataforma podem convidar clientes." }, corsHeaders);
  }

  if (payload.action === "recover") {
    return await recoverInvite(serviceClient, payload.convite_id, corsHeaders);
  }

  const { data: company, error: companyError } = await serviceClient
    .from("empresas")
    .select("id,situacao")
    .eq("id", payload.empresa_id)
    .maybeSingle();

  if (companyError) {
    console.error("Could not verify invite company", {
      companyId: payload.empresa_id,
      code: companyError.code,
    });
    return jsonResponse(500, { error: "Não foi possível verificar a empresa." }, corsHeaders);
  }
  if (!company || company.situacao === "encerrada") {
    return jsonResponse(404, { error: "Empresa não encontrada ou encerrada." }, corsHeaders);
  }

  const { data: existingInvite, error: existingInviteError } = await serviceClient
    .from("convites_clientes")
    .select("id,empresa_id,estado,auth_user_id")
    .eq("email", payload.email)
    .maybeSingle();

  if (existingInviteError) {
    console.error("Could not check prior invite", {
      companyId: payload.empresa_id,
      code: existingInviteError.code,
    });
    return jsonResponse(500, { error: "Não foi possível verificar convites anteriores." }, corsHeaders);
  }
  if (existingInvite) {
    return existingInviteResponse(existingInvite as InviteRecord, payload.empresa_id, corsHeaders);
  }

  const { data: reservedInvite, error: reservationError } = await serviceClient
    .from("convites_clientes")
    .insert({
      empresa_id: payload.empresa_id,
      email: payload.email,
      solicitado_por: requesterId,
      estado: "enviando",
    })
    .select("id")
    .single();

  if (reservationError) {
    if (reservationError.code === "23505") {
      const { data: concurrentInvite, error: concurrentInviteError } = await serviceClient
        .from("convites_clientes")
        .select("id,empresa_id,estado,auth_user_id")
        .eq("email", payload.email)
        .maybeSingle();

      if (!concurrentInviteError && concurrentInvite) {
        return existingInviteResponse(
          concurrentInvite as InviteRecord,
          payload.empresa_id,
          corsHeaders,
        );
      }
    }

    console.error("Could not reserve customer invite", {
      companyId: payload.empresa_id,
      code: reservationError.code,
    });
    return jsonResponse(500, { error: "Não foi possível iniciar o convite." }, corsHeaders);
  }

  const inviteId = reservedInvite.id as string;
  let invitedUser: { id: string; email?: string | null } | null = null;
  try {
    const { data, error } = await serviceClient.auth.admin
      .inviteUserByEmail(payload.email, { redirectTo: redirectUrl.toString() });
    if (error) {
      await markInviteFailed(serviceClient, inviteId, "auth_invite_failed");
      console.error("Supabase Auth invitation failed", {
        inviteId,
        status: error.status,
        code: error.code,
      });
      return jsonResponse(409, {
        error: "Não foi possível enviar o convite. O endereço pode já estar em uso; nenhum vínculo foi criado e a solicitação foi bloqueada para revisão.",
      }, corsHeaders);
    }
    invitedUser = data.user;
  } catch (error) {
    await markInviteFailed(serviceClient, inviteId, "auth_invite_failed");
    console.error("Supabase Auth invitation failed", {
      inviteId,
      error,
    });
    return jsonResponse(502, {
      error: "Não foi possível confirmar o envio do convite. Nenhum vínculo foi criado e a solicitação foi bloqueada para revisão.",
    }, corsHeaders);
  }

  if (!invitedUser) {
    await markInviteFailed(serviceClient, inviteId, "auth_user_missing");
    console.error("Supabase Auth invitation returned no user", { inviteId });
    return jsonResponse(502, {
      error: "O serviço de autenticação não confirmou o usuário convidado. Nenhum vínculo foi criado.",
    }, corsHeaders);
  }

  if (invitedUser.email?.trim().toLowerCase() !== payload.email) {
    await markInviteFailed(serviceClient, inviteId, "auth_email_mismatch", invitedUser.id);
    console.error("Auth invitation returned an unexpected email", { inviteId });
    return jsonResponse(502, {
      error: "O serviço de autenticação retornou um usuário inesperado. Nenhum vínculo foi criado.",
    }, corsHeaders);
  }

  let existingMemberships: { empresa_id: string }[] | null;
  let membershipError: { code?: string } | null;
  try {
    const result = await serviceClient
      .from("usuario_empresa")
      .select("empresa_id")
      .eq("user_id", invitedUser.id)
      .limit(1);
    existingMemberships = result.data;
    membershipError = result.error;
  } catch (error) {
    await markInviteFailed(serviceClient, inviteId, "membership_check_failed", invitedUser.id);
    console.error("Could not verify existing customer memberships", { inviteId, error });
    return jsonResponse(500, {
      error: "Não foi possível verificar vínculos existentes. Nenhum vínculo novo foi criado.",
    }, corsHeaders);
  }

  if (membershipError) {
    await markInviteFailed(serviceClient, inviteId, "membership_check_failed", invitedUser.id);
    console.error("Could not verify existing customer memberships", {
      inviteId,
      code: membershipError.code,
    });
    return jsonResponse(500, {
      error: "Não foi possível verificar vínculos existentes. Nenhum vínculo novo foi criado.",
    }, corsHeaders);
  }
  if (existingMemberships?.length) {
    await markInviteFailed(serviceClient, inviteId, "user_already_linked", invitedUser.id);
    return jsonResponse(409, {
      error: "A conta convidada já possui um vínculo com empresa. Nenhum vínculo novo foi criado.",
    }, corsHeaders);
  }

  let finalizeError: { code?: string } | null = null;
  try {
    const result = await serviceClient.rpc("finalizar_convite_cliente", {
      p_convite_id: inviteId,
      p_auth_user_id: invitedUser.id,
    });
    finalizeError = result.error;
  } catch (error) {
    finalizeError = { code: "network_error" };
    console.error("Customer invite finalization request failed", { inviteId, error });
  }

  if (finalizeError) {
    let finalizedInvite: { estado: string; auth_user_id: string | null } | null = null;
    let finalStateError: { code?: string } | null = null;
    try {
      const result = await serviceClient
        .from("convites_clientes")
        .select("estado,auth_user_id")
        .eq("id", inviteId)
        .maybeSingle();
      finalizedInvite = result.data;
      finalStateError = result.error;
    } catch (error) {
      console.error("Could not verify customer invite final state", { inviteId, error });
    }

    if (
      !finalStateError &&
      finalizedInvite?.estado === "concluido" &&
      finalizedInvite.auth_user_id === invitedUser.id
    ) {
      return jsonResponse(200, {
        status: "invited",
        message: "Convite enviado e vínculo da empresa criado.",
      }, corsHeaders);
    }

    await markInviteFailed(serviceClient, inviteId, "membership_finalize_failed", invitedUser.id);
    console.error("Could not finalize customer invite", {
      inviteId,
      code: finalizeError.code,
    });
    return jsonResponse(502, {
      error: "O convite foi enviado, mas o vínculo não pôde ser confirmado. Nenhum vínculo incorreto foi criado; solicitação bloqueada para revisão administrativa.",
    }, corsHeaders);
  }

  return jsonResponse(201, {
    status: "invited",
    message: "Convite enviado e vínculo da empresa criado.",
  }, corsHeaders);
});
