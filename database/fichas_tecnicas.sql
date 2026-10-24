-- Fichas técnicas e composição por insumos.
-- Executar manualmente somente após revisar e executar database/insumos.sql.
-- Este script não altera vendas, custos, configuracoes ou dados financeiros.
-- O custo da view acompanha o custo atual dos insumos.

BEGIN;

CREATE SCHEMA IF NOT EXISTS nobre_private;
REVOKE ALL ON SCHEMA nobre_private FROM PUBLIC, anon, authenticated;

-- =========================================================
-- 1. Produtos com ficha técnica
-- =========================================================

CREATE TABLE public.fichas_tecnicas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id uuid NOT NULL,
    nome text NOT NULL CHECK (length(btrim(nome)) > 0),
    categoria text NOT NULL DEFAULT 'hamburguer'
        CHECK (length(btrim(categoria)) > 0),
    descricao text,
    preco_venda numeric(14, 2) NOT NULL DEFAULT 0 CHECK (preco_venda >= 0),
    ativo boolean NOT NULL DEFAULT true,
    criado_em timestamptz NOT NULL DEFAULT now(),
    atualizado_em timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_fichas_tecnicas_empresa_id UNIQUE (empresa_id, id)
);

CREATE UNIQUE INDEX uq_fichas_tecnicas_empresa_nome
    ON public.fichas_tecnicas (empresa_id, lower(btrim(nome)));

CREATE INDEX idx_fichas_tecnicas_empresa_ativo
    ON public.fichas_tecnicas (empresa_id, ativo);

ALTER TABLE public.fichas_tecnicas ENABLE ROW LEVEL SECURITY;

CREATE POLICY fichas_tecnicas_select_empresa
    ON public.fichas_tecnicas
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = fichas_tecnicas.empresa_id
        )
    );

CREATE POLICY fichas_tecnicas_insert_empresa
    ON public.fichas_tecnicas
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = fichas_tecnicas.empresa_id
        )
    );

CREATE POLICY fichas_tecnicas_update_empresa
    ON public.fichas_tecnicas
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = fichas_tecnicas.empresa_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = fichas_tecnicas.empresa_id
        )
    );

REVOKE ALL ON TABLE public.fichas_tecnicas FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON TABLE public.fichas_tecnicas TO authenticated;
GRANT UPDATE (nome, categoria, descricao, preco_venda, ativo)
    ON TABLE public.fichas_tecnicas TO authenticated;

-- =========================================================
-- 2. Insumos da ficha (ingredientes, embalagens e outros itens)
-- =========================================================

CREATE TABLE public.ficha_tecnica_insumos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    empresa_id uuid NOT NULL,
    ficha_tecnica_id uuid NOT NULL,
    insumo_id uuid NOT NULL,
    -- A quantidade é sempre expressa em g, ml ou unidade,
    -- conforme public.insumos.unidade_base. Não é saldo de estoque.
    quantidade_base numeric(18, 6) NOT NULL CHECK (quantidade_base > 0),
    observacao text,
    criado_em timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_ficha_tecnica_insumo
        UNIQUE (empresa_id, ficha_tecnica_id, insumo_id),

    CONSTRAINT fk_ficha_insumos_ficha_empresa
        FOREIGN KEY (empresa_id, ficha_tecnica_id)
        REFERENCES public.fichas_tecnicas (empresa_id, id)
        ON DELETE CASCADE,

    CONSTRAINT fk_ficha_insumos_insumo_empresa
        FOREIGN KEY (empresa_id, insumo_id)
        REFERENCES public.insumos (empresa_id, id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_ficha_tecnica_insumos_ficha
    ON public.ficha_tecnica_insumos (empresa_id, ficha_tecnica_id);

CREATE INDEX idx_ficha_tecnica_insumos_insumo
    ON public.ficha_tecnica_insumos (empresa_id, insumo_id);

ALTER TABLE public.ficha_tecnica_insumos ENABLE ROW LEVEL SECURITY;

CREATE POLICY ficha_tecnica_insumos_select_empresa
    ON public.ficha_tecnica_insumos
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = ficha_tecnica_insumos.empresa_id
        )
    );

CREATE POLICY ficha_tecnica_insumos_insert_empresa
    ON public.ficha_tecnica_insumos
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = ficha_tecnica_insumos.empresa_id
        )
    );

CREATE POLICY ficha_tecnica_insumos_update_empresa
    ON public.ficha_tecnica_insumos
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = ficha_tecnica_insumos.empresa_id
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = ficha_tecnica_insumos.empresa_id
        )
    );

CREATE POLICY ficha_tecnica_insumos_delete_empresa
    ON public.ficha_tecnica_insumos
    FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = ficha_tecnica_insumos.empresa_id
        )
    );

REVOKE ALL ON TABLE public.ficha_tecnica_insumos FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE
    ON TABLE public.ficha_tecnica_insumos TO authenticated;
GRANT UPDATE (quantidade_base, observacao)
    ON TABLE public.ficha_tecnica_insumos TO authenticated;

-- =========================================================
-- 3. Impedir mudança entre dimensões incompatíveis do insumo
-- =========================================================
-- kg <-> g e L <-> ml permanecem compatíveis. Alterações entre
-- massa, volume e unidade são bloqueadas quando o insumo está em uso.

CREATE FUNCTION nobre_private.validar_dimensao_insumo_em_fichas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    dimensao_antiga text;
    dimensao_nova text;
BEGIN
    dimensao_antiga := CASE
        WHEN OLD.unidade_compra IN ('kg', 'g') THEN 'massa'
        WHEN OLD.unidade_compra IN ('L', 'ml') THEN 'volume'
        ELSE 'unidade'
    END;

    dimensao_nova := CASE
        WHEN NEW.unidade_compra IN ('kg', 'g') THEN 'massa'
        WHEN NEW.unidade_compra IN ('L', 'ml') THEN 'volume'
        ELSE 'unidade'
    END;

    IF dimensao_antiga <> dimensao_nova
       AND EXISTS (
           SELECT 1
           FROM public.ficha_tecnica_insumos fti
           WHERE fti.empresa_id = OLD.empresa_id
             AND fti.insumo_id = OLD.id
       )
    THEN
        RAISE EXCEPTION
            'Não é possível alterar a dimensão deste insumo: ele está sendo usado em uma ficha técnica.'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION nobre_private.validar_dimensao_insumo_em_fichas()
    FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_insumos_validar_dimensao_fichas
    BEFORE UPDATE OF unidade_compra ON public.insumos
    FOR EACH ROW
    EXECUTE FUNCTION nobre_private.validar_dimensao_insumo_em_fichas();

-- =========================================================
-- 4. Atualizar timestamp da ficha
-- =========================================================

CREATE FUNCTION nobre_private.atualizar_timestamp_ficha_tecnica()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    NEW.atualizado_em := pg_catalog.now();
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION nobre_private.atualizar_timestamp_ficha_tecnica()
    FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_fichas_tecnicas_atualizado_em
    BEFORE UPDATE ON public.fichas_tecnicas
    FOR EACH ROW
    EXECUTE FUNCTION nobre_private.atualizar_timestamp_ficha_tecnica();

-- =========================================================
-- 5. Salvar cabeçalho e composição em uma única transação
-- =========================================================
-- SECURITY INVOKER mantém os privilégios e as políticas RLS do usuário.

CREATE FUNCTION public.salvar_ficha_tecnica(
    p_empresa_id uuid,
    p_ficha_id uuid,
    p_nome text,
    p_categoria text,
    p_descricao text,
    p_preco_venda numeric,
    p_insumos jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
    ficha_id uuid;
BEGIN
    IF p_insumos IS NULL OR pg_catalog.jsonb_typeof(p_insumos) <> 'array' THEN
        RAISE EXCEPTION 'A composição da ficha deve ser uma lista de insumos.'
            USING ERRCODE = '22023';
    END IF;
    IF pg_catalog.jsonb_array_length(p_insumos) = 0 THEN
        RAISE EXCEPTION 'A ficha técnica deve conter ao menos um insumo.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.usuario_empresa ue
        WHERE ue.user_id = (SELECT auth.uid())
          AND ue.empresa_id = p_empresa_id
    ) THEN
        RAISE EXCEPTION 'Usuário sem vínculo autorizado para esta empresa.'
            USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_to_recordset(p_insumos)
            AS item(insumo_id uuid, quantidade_base numeric, observacao text)
        LEFT JOIN public.insumos i
          ON i.id = item.insumo_id
         AND i.empresa_id = p_empresa_id
        WHERE i.id IS NULL
           OR (
               NOT i.ativo
               AND (
                   p_ficha_id IS NULL
                   OR NOT EXISTS (
                       SELECT 1
                       FROM public.ficha_tecnica_insumos existente
                       WHERE existente.empresa_id = p_empresa_id
                         AND existente.ficha_tecnica_id = p_ficha_id
                         AND existente.insumo_id = item.insumo_id
                   )
               )
           )
    ) THEN
        RAISE EXCEPTION 'A composição contém insumo inexistente, inativo ou de outra empresa.'
            USING ERRCODE = '23503';
    END IF;

    IF p_ficha_id IS NULL THEN
        INSERT INTO public.fichas_tecnicas (
            empresa_id, nome, categoria, descricao, preco_venda
        )
        VALUES (
            p_empresa_id, p_nome, p_categoria, p_descricao, p_preco_venda
        )
        RETURNING id INTO ficha_id;
    ELSE
        UPDATE public.fichas_tecnicas
        SET nome = p_nome,
            categoria = p_categoria,
            descricao = p_descricao,
            preco_venda = p_preco_venda
        WHERE id = p_ficha_id
          AND empresa_id = p_empresa_id
        RETURNING id INTO ficha_id;

        IF ficha_id IS NULL THEN
            RAISE EXCEPTION 'Ficha técnica não encontrada ou não autorizada.'
                USING ERRCODE = '42501';
        END IF;

        DELETE FROM public.ficha_tecnica_insumos
        WHERE empresa_id = p_empresa_id
          AND ficha_tecnica_id = ficha_id;
    END IF;

    INSERT INTO public.ficha_tecnica_insumos (
        empresa_id, ficha_tecnica_id, insumo_id, quantidade_base, observacao
    )
    SELECT
        p_empresa_id,
        ficha_id,
        item.insumo_id,
        item.quantidade_base,
        item.observacao
    FROM pg_catalog.jsonb_to_recordset(p_insumos)
        AS item(insumo_id uuid, quantidade_base numeric, observacao text);

    RETURN ficha_id;
END;
$$;

REVOKE ALL ON FUNCTION public.salvar_ficha_tecnica(
    uuid, uuid, text, text, text, numeric, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.salvar_ficha_tecnica(
    uuid, uuid, text, text, text, numeric, jsonb
) TO authenticated;

-- =========================================================
-- 6. Custo atual de produção, lucro estimado e margem
-- =========================================================

CREATE VIEW public.vw_fichas_tecnicas_custos
WITH (security_invoker = true)
AS
SELECT
    ft.id,
    ft.empresa_id,
    ft.nome,
    ft.categoria,
    ft.descricao,
    ft.preco_venda,
    ft.ativo,
    ft.criado_em,
    ft.atualizado_em,
    COALESCE(composicao.quantidade_insumos, 0) AS quantidade_insumos,
    COALESCE(composicao.custo_total_producao, 0::numeric) AS custo_total_producao,
    ft.preco_venda - COALESCE(composicao.custo_total_producao, 0::numeric)
        AS lucro_estimado,
    CASE
        WHEN ft.preco_venda > 0 THEN
            (
                (
                    ft.preco_venda
                    - COALESCE(composicao.custo_total_producao, 0::numeric)
                ) / ft.preco_venda
            ) * 100
        ELSE NULL
    END AS margem_lucro_pct
FROM public.fichas_tecnicas ft
LEFT JOIN LATERAL (
    SELECT
        pg_catalog.count(*) AS quantidade_insumos,
        pg_catalog.round(
            pg_catalog.sum(fti.quantidade_base * i.custo_por_unidade_base),
            4
        ) AS custo_total_producao
    FROM public.ficha_tecnica_insumos fti
    JOIN public.insumos i
      ON i.empresa_id = fti.empresa_id
     AND i.id = fti.insumo_id
    WHERE fti.empresa_id = ft.empresa_id
      AND fti.ficha_tecnica_id = ft.id
) composicao ON true;

REVOKE ALL ON TABLE public.vw_fichas_tecnicas_custos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.vw_fichas_tecnicas_custos TO authenticated;

COMMIT;
