-- Estrutura inicial de empresas, administradores da plataforma e licencas.
-- Executar somente apos conferir os pre-requisitos descritos abaixo.
--
-- Pre-requisitos verificados/esperados:
--   1. public.usuario_empresa existe e possui user_id e empresa_id UUID.
--   2. O UUID atual do Nobre Burger e 9299d1fd-f54d-4f2b-bdd8-5161e795bebc.
--   3. Todos os empresa_id existentes em usuario_empresa correspondem ao
--      Nobre Burger. Se houver outros UUIDs, cadastre/valide essas empresas
--      antes de adicionar a chave estrangeira.
--   4. A migration e executada por um papel administrativo confiavel do
--      Supabase que possa criar tabelas, politicas e funcoes.
--   5. Os nomes empresas, administradores_plataforma, licencas,
--      historico_licencas e das duas funcoes abaixo ainda nao estao em uso.
--
-- Este script nao altera dados de vendas, custos, insumos ou fichas tecnicas,
-- nem suas politicas RLS. Nao concede acesso de administrador a nenhum usuario.

BEGIN;

DO $$
DECLARE
    tipo_empresa text;
    objeto text;
BEGIN
    IF pg_catalog.to_regclass('public.usuario_empresa') IS NULL THEN
        RAISE EXCEPTION 'Pre-requisito ausente: public.usuario_empresa nao existe.';
    END IF;

    SELECT c.data_type
      INTO tipo_empresa
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name = 'usuario_empresa'
       AND c.column_name = 'empresa_id';

    IF tipo_empresa IS DISTINCT FROM 'uuid' THEN
        RAISE EXCEPTION
            'Pre-requisito invalido: public.usuario_empresa.empresa_id deve ser UUID.';
    END IF;

    FOREACH objeto IN ARRAY ARRAY[
        'empresas',
        'administradores_plataforma',
        'licencas',
        'historico_licencas'
    ]
    LOOP
        IF pg_catalog.to_regclass(pg_catalog.format('public.%I', objeto)) IS NOT NULL THEN
            RAISE EXCEPTION 'O objeto public.% ja existe; revise o banco antes de continuar.', objeto;
        END IF;
    END LOOP;

    IF pg_catalog.to_regprocedure('public.usuario_e_admin_plataforma()') IS NOT NULL
       OR pg_catalog.to_regprocedure('public.usuario_tem_licenca_ativa(uuid)') IS NOT NULL THEN
        RAISE EXCEPTION 'Uma das funcoes desta migration ja existe; revise o banco antes de continuar.';
    END IF;
END;
$$;

CREATE TABLE public.empresas (
    id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
    nome text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(nome)) > 0),
    criada_em timestamptz NOT NULL DEFAULT pg_catalog.now(),
    situacao text NOT NULL DEFAULT 'ativa'
        CHECK (situacao IN ('ativa', 'suspensa', 'encerrada'))
);

-- Registra a empresa atual usando o UUID que ja identifica seus dados.
-- Se o ID ja existir, preserva integralmente o registro existente.
INSERT INTO public.empresas (id, nome)
VALUES ('9299d1fd-f54d-4f2b-bdd8-5161e795bebc', 'Nobre Burger')
ON CONFLICT (id) DO NOTHING;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.usuario_empresa ue
        LEFT JOIN public.empresas e ON e.id = ue.empresa_id
        WHERE e.id IS NULL
    ) THEN
        RAISE EXCEPTION
            'Existem vinculos usuario_empresa sem empresa correspondente. Identifique e cadastre cada empresa antes de adicionar a chave estrangeira.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_constraint c
        WHERE c.conrelid = 'public.usuario_empresa'::pg_catalog.regclass
          AND c.conname = 'fk_usuario_empresa_empresa'
    ) THEN
        ALTER TABLE public.usuario_empresa
            ADD CONSTRAINT fk_usuario_empresa_empresa
            FOREIGN KEY (empresa_id)
            REFERENCES public.empresas (id)
            ON DELETE RESTRICT;
    END IF;
END;
$$;

CREATE TABLE public.administradores_plataforma (
    user_id uuid PRIMARY KEY
        REFERENCES auth.users (id) ON DELETE RESTRICT,
    criado_em timestamptz NOT NULL DEFAULT pg_catalog.now(),
    criado_por uuid REFERENCES auth.users (id) ON DELETE RESTRICT
);

CREATE TABLE public.licencas (
    id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
    empresa_id uuid NOT NULL
        REFERENCES public.empresas (id) ON DELETE RESTRICT,
    licenca_anterior_id uuid,
    data_inicio date NOT NULL,
    data_vencimento date NOT NULL,
    valor_cobrado numeric(12, 2) NOT NULL DEFAULT 100.00
        CHECK (valor_cobrado >= 0),
    situacao text NOT NULL DEFAULT 'ativa'
        CHECK (situacao IN ('ativa', 'suspensa', 'cancelada')),
    suspensa_em timestamptz,
    suspensa_por uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
    motivo_suspensao text,
    criada_em timestamptz NOT NULL DEFAULT pg_catalog.now(),
    criada_por uuid NOT NULL DEFAULT auth.uid()
        REFERENCES auth.users (id) ON DELETE RESTRICT,
    CONSTRAINT ck_licencas_periodo_valido
        CHECK (data_vencimento >= data_inicio),
    CONSTRAINT ck_licencas_dados_suspensao
        CHECK (
            (situacao = 'suspensa'
                AND suspensa_em IS NOT NULL
                AND suspensa_por IS NOT NULL)
            OR
            (situacao <> 'suspensa'
                AND suspensa_em IS NULL
                AND suspensa_por IS NULL
                AND motivo_suspensao IS NULL)
        ),
    CONSTRAINT uq_licencas_empresa_id
        UNIQUE (empresa_id, id),
    CONSTRAINT fk_licencas_anterior_mesma_empresa
        FOREIGN KEY (empresa_id, licenca_anterior_id)
        REFERENCES public.licencas (empresa_id, id)
        ON DELETE RESTRICT,
    CONSTRAINT uq_licencas_anterior
        UNIQUE (licenca_anterior_id)
);

CREATE INDEX idx_licencas_empresa_periodo
    ON public.licencas (empresa_id, data_inicio DESC, criada_em DESC);

CREATE TABLE public.historico_licencas (
    id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
    empresa_id uuid NOT NULL
        REFERENCES public.empresas (id) ON DELETE RESTRICT,
    licenca_id uuid NOT NULL,
    evento text NOT NULL
        CHECK (evento IN ('concedida', 'renovada', 'suspensa', 'reativada', 'cancelada')),
    registrado_em timestamptz NOT NULL DEFAULT pg_catalog.now(),
    registrado_por uuid NOT NULL DEFAULT auth.uid()
        REFERENCES auth.users (id) ON DELETE RESTRICT,
    observacao text,
    CONSTRAINT fk_historico_licencas_mesma_empresa
        FOREIGN KEY (empresa_id, licenca_id)
        REFERENCES public.licencas (empresa_id, id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_historico_licencas_empresa_data
    ON public.historico_licencas (empresa_id, registrado_em DESC);

-- A lista de administradores nao pode ser consultada ou alterada por usuarios
-- comuns. A primeira inclusao deve ser feita por SQL Editor confiavel ou por
-- um backend seguro usando service_role; nunca a partir do HTML.
ALTER TABLE public.administradores_plataforma ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.administradores_plataforma FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.administradores_plataforma TO service_role;

CREATE FUNCTION public.usuario_e_admin_plataforma()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.administradores_plataforma ap
        WHERE ap.user_id = (SELECT auth.uid())
    );
$$;

REVOKE ALL ON FUNCTION public.usuario_e_admin_plataforma()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.usuario_e_admin_plataforma()
    TO authenticated;

ALTER TABLE public.empresas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.licencas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.historico_licencas ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.empresas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.licencas FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.historico_licencas FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE public.empresas TO authenticated;
GRANT INSERT (nome), UPDATE (nome, situacao)
    ON TABLE public.empresas TO authenticated;
GRANT SELECT ON TABLE public.licencas TO authenticated;
GRANT INSERT (
    empresa_id,
    licenca_anterior_id,
    data_inicio,
    data_vencimento,
    valor_cobrado,
    situacao
) ON TABLE public.licencas TO authenticated;
GRANT UPDATE (situacao, suspensa_em, suspensa_por, motivo_suspensao)
    ON TABLE public.licencas TO authenticated;
GRANT SELECT ON TABLE public.historico_licencas TO authenticated;
GRANT INSERT (empresa_id, licenca_id, evento, observacao)
    ON TABLE public.historico_licencas TO authenticated;

CREATE POLICY empresas_select_membro_ou_admin
    ON public.empresas
    FOR SELECT
    TO authenticated
    USING (
        public.usuario_e_admin_plataforma()
        OR EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = empresas.id
        )
    );

CREATE POLICY empresas_insert_admin
    ON public.empresas
    FOR INSERT
    TO authenticated
    WITH CHECK (public.usuario_e_admin_plataforma());

CREATE POLICY empresas_update_admin
    ON public.empresas
    FOR UPDATE
    TO authenticated
    USING (public.usuario_e_admin_plataforma())
    WITH CHECK (public.usuario_e_admin_plataforma());

CREATE POLICY licencas_select_membro_ou_admin
    ON public.licencas
    FOR SELECT
    TO authenticated
    USING (
        public.usuario_e_admin_plataforma()
        OR EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = licencas.empresa_id
        )
    );

CREATE POLICY licencas_insert_admin
    ON public.licencas
    FOR INSERT
    TO authenticated
    WITH CHECK (public.usuario_e_admin_plataforma());

CREATE POLICY licencas_update_admin
    ON public.licencas
    FOR UPDATE
    TO authenticated
    USING (public.usuario_e_admin_plataforma())
    WITH CHECK (public.usuario_e_admin_plataforma());

CREATE POLICY historico_licencas_select_membro_ou_admin
    ON public.historico_licencas
    FOR SELECT
    TO authenticated
    USING (
        public.usuario_e_admin_plataforma()
        OR EXISTS (
            SELECT 1
            FROM public.usuario_empresa ue
            WHERE ue.user_id = (SELECT auth.uid())
              AND ue.empresa_id = historico_licencas.empresa_id
        )
    );

CREATE POLICY historico_licencas_insert_admin
    ON public.historico_licencas
    FOR INSERT
    TO authenticated
    WITH CHECK (public.usuario_e_admin_plataforma());

-- Esta funcao prepara uma verificacao reutilizavel para futuras politicas RLS.
-- Ela nao e adicionada as politicas de nenhum modulo nesta migration.
-- Retorna true somente se o usuario atual pertence a empresa e a licenca mais
-- recente esta ativa, dentro do prazo, e a empresa nao esta suspensa/encerrada.
CREATE FUNCTION public.usuario_tem_licenca_ativa(p_empresa_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
SET row_security = off
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.usuario_empresa ue
        JOIN public.empresas e ON e.id = ue.empresa_id
        JOIN LATERAL (
            SELECT l.situacao, l.data_inicio, l.data_vencimento
            FROM public.licencas l
            WHERE l.empresa_id = ue.empresa_id
              AND l.data_inicio <= CURRENT_DATE
            ORDER BY l.data_inicio DESC, l.criada_em DESC, l.id DESC
            LIMIT 1
        ) ultima_licenca ON true
        WHERE ue.user_id = (SELECT auth.uid())
          AND ue.empresa_id = p_empresa_id
          AND e.situacao = 'ativa'
          AND ultima_licenca.situacao = 'ativa'
          AND CURRENT_DATE BETWEEN
              ultima_licenca.data_inicio AND ultima_licenca.data_vencimento
    );
$$;

REVOKE ALL ON FUNCTION public.usuario_tem_licenca_ativa(uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.usuario_tem_licenca_ativa(uuid)
    TO authenticated;

COMMENT ON TABLE public.licencas IS
    'Cada linha representa um periodo de licenca; renovacoes criam novos registros e preservam o historico.';
COMMENT ON TABLE public.historico_licencas IS
    'Eventos administrativos de concessao, renovacao, suspensao, reativacao e cancelamento de licencas.';
COMMENT ON FUNCTION public.usuario_tem_licenca_ativa(uuid) IS
    'Verifica a licenca mais recente para uma empresa a que auth.uid() esteja vinculado. Preparada para futuras politicas RLS; nao aplicada nesta migration.';

COMMIT;
