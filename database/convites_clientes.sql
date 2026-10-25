-- Estado privado de convites de clientes e finalizacao atomica do vinculo.
-- Executar manualmente no Supabase SQL Editor antes de implantar/testar
-- supabase/functions/convidar-cliente.
-- Esta migration nao altera politicas RLS existentes.

BEGIN;

CREATE TABLE public.convites_clientes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id uuid NOT NULL
        REFERENCES public.empresas (id) ON DELETE RESTRICT,
    email text NOT NULL
        CHECK (email = pg_catalog.lower(pg_catalog.btrim(email)))
        CHECK (pg_catalog.char_length(email) BETWEEN 3 AND 254),
    solicitado_por uuid NOT NULL
        REFERENCES auth.users (id) ON DELETE RESTRICT,
    auth_user_id uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
    estado text NOT NULL DEFAULT 'enviando'
        CHECK (estado IN ('enviando', 'concluido', 'falha')),
    codigo_erro text,
    criado_em timestamptz NOT NULL DEFAULT pg_catalog.now(),
    atualizado_em timestamptz NOT NULL DEFAULT pg_catalog.now(),
    CONSTRAINT ck_convites_clientes_usuario_concluido
        CHECK (estado <> 'concluido' OR auth_user_id IS NOT NULL)
);

-- Um e-mail so pode iniciar um convite no SaaS. Isso impede convites
-- concorrentes para empresas diferentes e evita associar contas existentes.
CREATE UNIQUE INDEX uq_convites_clientes_email
    ON public.convites_clientes (email);

-- Para localizar convites que precisam de revisao, o administrador pode
-- consultar esta lista no SQL Editor confiavel:
-- SELECT id, email, empresa_id, estado, auth_user_id, codigo_erro,
--        criado_em, atualizado_em
-- FROM public.convites_clientes
-- WHERE estado IN ('enviando', 'falha')
-- ORDER BY atualizado_em;
-- Depois de conferir o usuario convidado no Auth, solicite a acao "recover"
-- da Edge Function informando {"action":"recover","convite_id":"<id>"}.
-- A recuperacao nunca reenvia o e-mail nem cria usuarios Auth. Se nao houver
-- um usuario Auth convidado correspondente, investigue o estado do envio antes
-- de iniciar um novo convite; nao altere ou apague o historico automaticamente.

ALTER TABLE public.convites_clientes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.convites_clientes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.convites_clientes TO service_role;
GRANT SELECT ON TABLE public.empresas TO service_role;
GRANT SELECT, INSERT ON TABLE public.usuario_empresa TO service_role;

CREATE FUNCTION public.finalizar_convite_cliente(
    p_convite_id uuid,
    p_auth_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_empresa_id uuid;
    v_estado text;
    v_auth_user_id uuid;
BEGIN
    IF p_convite_id IS NULL OR p_auth_user_id IS NULL THEN
        RAISE EXCEPTION 'Convite e usuario sao obrigatorios.'
            USING ERRCODE = '22023';
    END IF;

    SELECT cc.empresa_id, cc.estado, cc.auth_user_id
      INTO v_empresa_id, v_estado, v_auth_user_id
      FROM public.convites_clientes cc
     WHERE cc.id = p_convite_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Convite nao encontrado.'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_auth_user_id IS NOT NULL AND v_auth_user_id <> p_auth_user_id THEN
        RAISE EXCEPTION 'Usuario nao corresponde ao usuario registrado no convite.'
            USING ERRCODE = '42501';
    END IF;

    IF v_estado = 'concluido' AND v_auth_user_id = p_auth_user_id THEN
        RETURN;
    END IF;

    IF v_estado NOT IN ('enviando', 'falha') THEN
        RAISE EXCEPTION 'Convite nao esta aguardando finalizacao.'
            USING ERRCODE = '55000';
    END IF;

    -- Serializa finalizacoes concorrentes para a mesma conta, mesmo se houver
    -- convites distintos, antes de verificar se ela ja pertence a outra empresa.
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(p_auth_user_id::text, 0)
    );

    PERFORM 1
      FROM public.empresas e
     WHERE e.id = v_empresa_id
       AND e.situacao <> 'encerrada'
     FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Empresa inexistente ou encerrada.'
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.usuario_empresa ue
         WHERE ue.user_id = p_auth_user_id
           AND ue.empresa_id <> v_empresa_id
    ) THEN
        RAISE EXCEPTION 'Usuario ja possui vinculo com outra empresa.'
            USING ERRCODE = '23505';
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM public.usuario_empresa ue
         WHERE ue.user_id = p_auth_user_id
           AND ue.empresa_id = v_empresa_id
    ) THEN
        INSERT INTO public.usuario_empresa (user_id, empresa_id)
        VALUES (p_auth_user_id, v_empresa_id);
    END IF;

    UPDATE public.convites_clientes
       SET auth_user_id = p_auth_user_id,
           estado = 'concluido',
           codigo_erro = NULL,
           atualizado_em = pg_catalog.now()
     WHERE id = p_convite_id;
END;
$$;

REVOKE ALL ON FUNCTION public.finalizar_convite_cliente(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalizar_convite_cliente(uuid, uuid)
    TO service_role;

COMMIT;
