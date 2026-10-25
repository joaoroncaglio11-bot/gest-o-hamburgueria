-- Segurança multiempresa das tabelas financeiras.
-- Pré-requisitos:
--   1. public.vendas, public.custos e public.usuario_empresa já existem.
--   2. vendas e custos possuem empresa_id compatível com usuario_empresa.empresa_id.
--   3. O usuário autenticado já possui o vínculo correto em usuario_empresa.
-- Este script não altera registros nem implementa controle de licenças.
--
-- As políticas existentes de vendas e custos são substituídas para evitar
-- que políticas permissivas antigas concedam acesso por combinação OR.

BEGIN;

DO $$
DECLARE
    tabela text;
    politica record;
    sequencia record;
BEGIN
    FOREACH tabela IN ARRAY ARRAY['vendas', 'custos']
    LOOP
        IF pg_catalog.to_regclass(pg_catalog.format('public.%I', tabela)) IS NULL THEN
            RAISE EXCEPTION 'A tabela public.% não existe.', tabela;
        END IF;
    END LOOP;

    IF pg_catalog.to_regclass('public.usuario_empresa') IS NULL THEN
        RAISE EXCEPTION 'A tabela public.usuario_empresa não existe.';
    END IF;

    FOR politica IN
        SELECT schemaname, tablename, policyname
        FROM pg_catalog.pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('vendas', 'custos')
    LOOP
        EXECUTE pg_catalog.format(
            'DROP POLICY %I ON %I.%I',
            politica.policyname,
            politica.schemaname,
            politica.tablename
        );
    END LOOP;

    FOR sequencia IN
        SELECT seq_ns.nspname AS schema_nome, seq.relname AS sequencia_nome
        FROM pg_catalog.pg_class seq
        JOIN pg_catalog.pg_namespace seq_ns ON seq_ns.oid = seq.relnamespace
        JOIN pg_catalog.pg_depend dep
          ON dep.objid = seq.oid
         AND dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
         AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
         AND dep.deptype IN ('a', 'i')
        JOIN pg_catalog.pg_class tabela ON tabela.oid = dep.refobjid
        JOIN pg_catalog.pg_namespace tabela_ns ON tabela_ns.oid = tabela.relnamespace
        WHERE seq.relkind = 'S'
          AND tabela_ns.nspname = 'public'
          AND tabela.relname IN ('vendas', 'custos')
    LOOP
        EXECUTE pg_catalog.format(
            'REVOKE ALL ON SEQUENCE %I.%I FROM PUBLIC, anon, authenticated',
            sequencia.schema_nome,
            sequencia.sequencia_nome
        );
        EXECUTE pg_catalog.format(
            'GRANT USAGE, SELECT ON SEQUENCE %I.%I TO authenticated',
            sequencia.schema_nome,
            sequencia.sequencia_nome
        );
    END LOOP;
END;
$$;

ALTER TABLE public.vendas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.custos ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.vendas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.custos FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.vendas TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.custos TO authenticated;

CREATE POLICY vendas_select_empresa_autorizada
    ON public.vendas
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = vendas.empresa_id
        )
    );

CREATE POLICY vendas_insert_empresa_autorizada
    ON public.vendas
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = vendas.empresa_id
        )
    );

CREATE POLICY vendas_update_empresa_autorizada
    ON public.vendas
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = vendas.empresa_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = vendas.empresa_id
        )
    );

CREATE POLICY vendas_delete_empresa_autorizada
    ON public.vendas
    FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = vendas.empresa_id
        )
    );

CREATE POLICY custos_select_empresa_autorizada
    ON public.custos
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = custos.empresa_id
        )
    );

CREATE POLICY custos_insert_empresa_autorizada
    ON public.custos
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = custos.empresa_id
        )
    );

CREATE POLICY custos_update_empresa_autorizada
    ON public.custos
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = custos.empresa_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = custos.empresa_id
        )
    );

CREATE POLICY custos_delete_empresa_autorizada
    ON public.custos
    FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = custos.empresa_id
        )
    );

COMMIT;
