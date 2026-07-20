-- postgrez integration schema and the auth-matrix roles.
-- Runs once at first container start, inside POSTGRES_DB (postgrez_test).

CREATE ROLE role_scram LOGIN PASSWORD 'postgrez_scram_pw';
CREATE ROLE role_scram_plus LOGIN PASSWORD 'postgrez_scram_plus_pw';
CREATE ROLE role_cleartext LOGIN PASSWORD 'postgrez_cleartext_pw';

CREATE TABLE users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    email text NOT NULL UNIQUE,
    age smallint NOT NULL,
    bio text,
    score double precision NOT NULL DEFAULT 0,
    active boolean NOT NULL DEFAULT true,
    tag uuid NOT NULL DEFAULT gen_random_uuid(),
    balance numeric(12, 3) NOT NULL DEFAULT 0,
    profile jsonb NOT NULL DEFAULT '{}',
    created_at timestamp NOT NULL DEFAULT now()
);

CREATE TABLE ledger (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    amount bigint NOT NULL
);

CREATE TABLE metrics (
    ts text NOT NULL,
    value bigint NOT NULL
);

CREATE TABLE logs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    msg text NOT NULL
);

GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON users, ledger, metrics, logs
    TO role_scram, role_scram_plus, role_cleartext;
