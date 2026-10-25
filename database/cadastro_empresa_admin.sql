-- RPC para cadastro administrativo de uma empresa e sua primeira licenca.
-- Executar uma vez, apos confirmar que as tabelas e politicas RLS de
-- database/multiempresa.sql estao instaladas.

BEGIN;

CREATE FUNCTION public.cadastrar_empresa_admin(
    p_nome text,
    p_data_inicio date
)
RETURNS TABLE (
    nova_empresa_id uuid,
    nova_licenca_id uuid,
    data_inicio date,
    data_vencimento date,
    valor_cobrado numeric(12, 2),
    situacao text,
    criada_em timestamptz,
    criada_por uuid
)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    v_nome text;
    v_empresa_id uuid;
    v_licenca_id uuid;
    v_data_vencimento date;
    v_criada_em timestamptz;
    v_criada_por uuid;
BEGIN
    IF (SELECT auth.uid()) IS NULL
       OR NOT COALESCE(public.usuario_e_admin_plataforma(), false) THEN
        RAISE EXCEPTION 'Apenas administradores da plataforma podem cadastrar empresas.'
            USING ERRCODE = '42501';
    END IF;

    IF p_nome IS NULL OR pg_catalog.char_length(pg_catalog.btrim(p_nome)) = 0 THEN
        RAISE EXCEPTION 'O nome da hamburgueria e obrigatorio.'
            USING ERRCODE = '22023';
    END IF;

    v_nome := pg_catalog.btrim(p_nome);
    IF pg_catalog.char_length(v_nome) > 120 THEN
        RAISE EXCEPTION 'O nome da hamburgueria deve ter no maximo 120 caracteres.'
            USING ERRCODE = '22023';
    END IF;

    IF p_data_inicio IS NULL OR NOT pg_catalog.isfinite(p_data_inicio) THEN
        RAISE EXCEPTION 'Informe uma data inicial de licenca valida.'
            USING ERRCODE = '22023';
    END IF;

    -- O vencimento e inclusivo: inicio + 12 meses no calendario - 1 dia.
    -- Exemplo: 25/10/2026 inicia em 25/10/2026 e vence em 24/10/2027.
    v_data_vencimento := (p_data_inicio + interval '12 months')::date - 1;

    INSERT INTO public.empresas (nome)
    VALUES (v_nome)
    RETURNING id INTO v_empresa_id;

    INSERT INTO public.licencas AS l (
        empresa_id,
        data_inicio,
        data_vencimento,
        valor_cobrado,
        situacao
    )
    VALUES (
        v_empresa_id,
        p_data_inicio,
        v_data_vencimento,
        100.00,
        'ativa'
    )
    RETURNING l.id, l.criada_em, l.criada_por
    INTO v_licenca_id, v_criada_em, v_criada_por;

    INSERT INTO public.historico_licencas (
        empresa_id,
        licenca_id,
        evento,
        observacao
    )
    VALUES (
        v_empresa_id,
        v_licenca_id,
        'concedida',
        'Cadastro inicial da empresa com licenca de 12 meses.'
    );

    RETURN QUERY
    SELECT
        v_empresa_id,
        v_licenca_id,
        p_data_inicio,
        v_data_vencimento,
        100.00::numeric(12, 2),
        'ativa'::text,
        v_criada_em,
        v_criada_por;
END;
$$;

REVOKE ALL ON FUNCTION public.cadastrar_empresa_admin(text, date)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cadastrar_empresa_admin(text, date)
    TO authenticated;

COMMIT;
