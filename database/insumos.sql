-- Cadastro de insumos e histórico de preços.
-- Executar manualmente no SQL Editor somente após revisão.
-- Não altera vendas, custos ou configuracoes.
-- RLS não concede acesso a anon. O vínculo inicial de administrador
-- deve ser criado manualmente no SQL Editor.

BEGIN;

CREATE SCHEMA nobre_private;
REVOKE ALL ON SCHEMA nobre_private FROM PUBLIC, anon, authenticated;

CREATE TABLE public.usuario_empresa (
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    empresa_id uuid NOT NULL,
    criado_em timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_usuario_empresa PRIMARY KEY (user_id, empresa_id)
);

CREATE INDEX idx_usuario_empresa_empresa
    ON public.usuario_empresa (empresa_id, user_id);

ALTER TABLE public.usuario_empresa ENABLE ROW LEVEL SECURITY;

CREATE POLICY usuario_empresa_select_proprio
    ON public.usuario_empresa
    FOR SELECT
    TO authenticated
    USING (user_id = (SELECT auth.uid()));

REVOKE ALL ON TABLE public.usuario_empresa FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.usuario_empresa TO authenticated;

CREATE TABLE public.insumos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id uuid NOT NULL,
    nome text NOT NULL CHECK (length(btrim(nome)) > 0),
    categoria text NOT NULL CHECK (
        categoria IN ('ingrediente', 'bebida', 'embalagem', 'material', 'outro')
    ),
    unidade_compra text NOT NULL CHECK (
        unidade_compra IN ('kg', 'g', 'L', 'ml', 'unidade')
    ),
    quantidade_referencia numeric(18, 6) NOT NULL CHECK (quantidade_referencia > 0),
    valor_pago numeric(14, 2) NOT NULL CHECK (valor_pago >= 0),
    estoque_minimo numeric(18, 6) NOT NULL DEFAULT 0 CHECK (estoque_minimo >= 0),
    unidade_base text GENERATED ALWAYS AS (
        CASE
            WHEN unidade_compra IN ('kg', 'g') THEN 'g'
            WHEN unidade_compra IN ('L', 'ml') THEN 'ml'
            ELSE 'unidade'
        END
    ) STORED,
    quantidade_base numeric(18, 6) GENERATED ALWAYS AS (
        quantidade_referencia *
        CASE unidade_compra
            WHEN 'kg' THEN 1000::numeric
            WHEN 'L' THEN 1000::numeric
            ELSE 1::numeric
        END
    ) STORED,
    custo_por_unidade_base numeric(18, 8) GENERATED ALWAYS AS (
        valor_pago /
        (
            quantidade_referencia *
            CASE unidade_compra
                WHEN 'kg' THEN 1000::numeric
                WHEN 'L' THEN 1000::numeric
                ELSE 1::numeric
            END
        )
    ) STORED,
    ativo boolean NOT NULL DEFAULT true,
    criado_em timestamptz NOT NULL DEFAULT now(),
    atualizado_em timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_insumos_empresa_id UNIQUE (empresa_id, id)
);

CREATE UNIQUE INDEX uq_insumos_empresa_nome
    ON public.insumos (empresa_id, lower(btrim(nome)));

CREATE INDEX idx_insumos_empresa_ativo
    ON public.insumos (empresa_id, ativo);

CREATE INDEX idx_insumos_empresa_categoria
    ON public.insumos (empresa_id, categoria);

ALTER TABLE public.insumos ENABLE ROW LEVEL SECURITY;

CREATE POLICY insumos_select_empresa_autorizada
    ON public.insumos
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = insumos.empresa_id
        )
    );

CREATE POLICY insumos_insert_empresa_autorizada
    ON public.insumos
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = insumos.empresa_id
        )
    );

CREATE POLICY insumos_update_empresa_autorizada
    ON public.insumos
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = insumos.empresa_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = insumos.empresa_id
        )
    );

REVOKE ALL ON TABLE public.insumos FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON TABLE public.insumos TO authenticated;
GRANT UPDATE (nome, categoria, unidade_compra, quantidade_referencia, valor_pago, estoque_minimo, ativo)
    ON TABLE public.insumos TO authenticated;

CREATE TABLE public.insumo_historico_precos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id uuid NOT NULL,
    insumo_id uuid NOT NULL,
    quantidade_referencia numeric(18, 6) NOT NULL CHECK (quantidade_referencia > 0),
    unidade_compra text NOT NULL CHECK (
        unidade_compra IN ('kg', 'g', 'L', 'ml', 'unidade')
    ),
    valor_pago numeric(14, 2) NOT NULL CHECK (valor_pago >= 0),
    unidade_base text GENERATED ALWAYS AS (
        CASE
            WHEN unidade_compra IN ('kg', 'g') THEN 'g'
            WHEN unidade_compra IN ('L', 'ml') THEN 'ml'
            ELSE 'unidade'
        END
    ) STORED,
    quantidade_base numeric(18, 6) GENERATED ALWAYS AS (
        quantidade_referencia *
        CASE unidade_compra
            WHEN 'kg' THEN 1000::numeric
            WHEN 'L' THEN 1000::numeric
            ELSE 1::numeric
        END
    ) STORED,
    custo_por_unidade_base numeric(18, 8) GENERATED ALWAYS AS (
        valor_pago /
        (
            quantidade_referencia *
            CASE unidade_compra
                WHEN 'kg' THEN 1000::numeric
                WHEN 'L' THEN 1000::numeric
                ELSE 1::numeric
            END
        )
    ) STORED,
    origem text NOT NULL CHECK (origem IN ('cadastro', 'atualizacao')),
    registrado_em timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_historico_preco_insumo_empresa
        FOREIGN KEY (empresa_id, insumo_id)
        REFERENCES public.insumos (empresa_id, id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_historico_preco_empresa_insumo_data
    ON public.insumo_historico_precos (empresa_id, insumo_id, registrado_em DESC);

ALTER TABLE public.insumo_historico_precos ENABLE ROW LEVEL SECURITY;

CREATE POLICY historico_precos_select_empresa_autorizada
    ON public.insumo_historico_precos
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = insumo_historico_precos.empresa_id
        )
    );

REVOKE ALL ON TABLE public.insumo_historico_precos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.insumo_historico_precos TO authenticated;

CREATE FUNCTION public.atualizar_timestamp_insumo()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.atualizado_em := pg_catalog.now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_insumos_atualizado_em
    BEFORE UPDATE ON public.insumos
    FOR EACH ROW
    EXECUTE FUNCTION public.atualizar_timestamp_insumo();

CREATE FUNCTION nobre_private.registrar_historico_preco_insumo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.quantidade_referencia IS NOT DISTINCT FROM OLD.quantidade_referencia
       AND NEW.unidade_compra IS NOT DISTINCT FROM OLD.unidade_compra
       AND NEW.valor_pago IS NOT DISTINCT FROM OLD.valor_pago
    THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.insumo_historico_precos (
        empresa_id,
        insumo_id,
        quantidade_referencia,
        unidade_compra,
        valor_pago,
        origem
    )
    VALUES (
        NEW.empresa_id,
        NEW.id,
        NEW.quantidade_referencia,
        NEW.unidade_compra,
        NEW.valor_pago,
        CASE WHEN TG_OP = 'INSERT' THEN 'cadastro' ELSE 'atualizacao' END
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_insumos_historico_preco
    AFTER INSERT OR UPDATE OF quantidade_referencia, unidade_compra, valor_pago
    ON public.insumos
    FOR EACH ROW
    EXECUTE FUNCTION nobre_private.registrar_historico_preco_insumo();

REVOKE ALL ON FUNCTION public.atualizar_timestamp_insumo() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION nobre_private.registrar_historico_preco_insumo() FROM PUBLIC, anon, authenticated;

COMMIT;

-- Após criar manualmente o administrador em Authentication > Users,
-- vincule-o manualmente ao tenant autorizado com este comando substituindo
-- o UUID do usuário:
--
-- INSERT INTO public.usuario_empresa (user_id, empresa_id)
-- VALUES ('<UUID_DO_AUTH_USER>', '9299d1fd-f54d-4f2b-bdd8-5161e795bebc')
-- ON CONFLICT (user_id, empresa_id) DO NOTHING;
