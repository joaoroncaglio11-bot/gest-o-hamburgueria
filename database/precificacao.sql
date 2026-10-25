-- Configuracoes da precificacao por empresa.
-- Executar manualmente somente apos revisar e executar database/insumos.sql.
-- Nao altera custos existentes nem inclui custos operacionais nas fichas tecnicas.

BEGIN;

CREATE SCHEMA IF NOT EXISTS nobre_private;

CREATE TABLE public.configuracoes_precificacao (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id uuid NOT NULL UNIQUE,
    custo_mensal_gas numeric(14, 2) NOT NULL DEFAULT 130.00
        CHECK (custo_mensal_gas >= 0),
    custo_mensal_oleo_fritadeira numeric(14, 2) NOT NULL DEFAULT 42.00
        CHECK (custo_mensal_oleo_fritadeira >= 0),
    taxa_cartao_percentual numeric(7, 4) NOT NULL DEFAULT 0
        CHECK (taxa_cartao_percentual BETWEEN 0 AND 100),
    outras_taxas_percentuais jsonb NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(outras_taxas_percentuais) = 'array'),
    producao_mensal_estimada integer NOT NULL DEFAULT 0
        CHECK (producao_mensal_estimada >= 0),
    criado_em timestamptz NOT NULL DEFAULT now(),
    atualizado_em timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.configuracoes_precificacao.outras_taxas_percentuais
    IS 'Lista JSON de taxas adicionais, por exemplo: [{"nome":"Marketplace","percentual":5.00}].';

ALTER TABLE public.configuracoes_precificacao ENABLE ROW LEVEL SECURITY;

CREATE POLICY configuracoes_precificacao_select_empresa
    ON public.configuracoes_precificacao
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = configuracoes_precificacao.empresa_id
        )
    );

CREATE POLICY configuracoes_precificacao_insert_empresa
    ON public.configuracoes_precificacao
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = configuracoes_precificacao.empresa_id
        )
    );

CREATE POLICY configuracoes_precificacao_update_empresa
    ON public.configuracoes_precificacao
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = configuracoes_precificacao.empresa_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = configuracoes_precificacao.empresa_id
        )
    );

REVOKE ALL ON TABLE public.configuracoes_precificacao FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.configuracoes_precificacao TO authenticated;
GRANT INSERT (
    empresa_id,
    custo_mensal_gas,
    custo_mensal_oleo_fritadeira,
    taxa_cartao_percentual,
    outras_taxas_percentuais,
    producao_mensal_estimada
) ON TABLE public.configuracoes_precificacao TO authenticated;
GRANT UPDATE (
    custo_mensal_gas,
    custo_mensal_oleo_fritadeira,
    taxa_cartao_percentual,
    outras_taxas_percentuais,
    producao_mensal_estimada
) ON TABLE public.configuracoes_precificacao TO authenticated;

CREATE FUNCTION nobre_private.atualizar_timestamp_configuracao_precificacao()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.atualizado_em := pg_catalog.now();
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION nobre_private.atualizar_timestamp_configuracao_precificacao()
    FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_configuracoes_precificacao_atualizado_em
    BEFORE UPDATE ON public.configuracoes_precificacao
    FOR EACH ROW
    EXECUTE FUNCTION nobre_private.atualizar_timestamp_configuracao_precificacao();

COMMIT;
