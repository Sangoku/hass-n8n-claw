-- ============================================================
-- Migration 003: Rename anthropic tools_config to generic llm
-- Converts Anthropic-specific config to OpenAI-compatible shape
-- ============================================================

-- Rename existing 'anthropic' entry to 'llm' and add base_url/model fields
UPDATE public.tools_config
SET
    tool_name = 'llm',
    config = jsonb_build_object(
        'api_key',  COALESCE(config->>'api_key', ''),
        'base_url', COALESCE(config->>'base_url', 'https://api.openai.com/v1'),
        'model',    COALESCE(config->>'model', 'gpt-4o-mini')
    )
WHERE tool_name = 'anthropic';

-- Insert default llm config if not already present (fresh installs)
INSERT INTO public.tools_config (tool_name, config, enabled)
VALUES (
    'llm',
    '{"api_key":"","base_url":"https://api.openai.com/v1","model":"gpt-4o-mini"}',
    false
)
ON CONFLICT (tool_name) DO NOTHING;
